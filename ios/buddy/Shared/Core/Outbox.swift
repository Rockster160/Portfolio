import Foundation

/// Something pressed or said that the server has to hear about. It is written to disk the moment
/// it happens — no network, no running app needed — and leaves the disk only once the server has
/// answered that it received it.
struct OutboxItem: Codable, Identifiable, Equatable {
  enum Kind: String, Codable, CaseIterable {
    /// Words for the server's command processor, without a Buddy round.
    case command
    /// A message into the primary Buddy conversation.
    case buddy
    /// A Jil trigger with a JSON payload.
    case trigger
    /// Run a Jil task by id (in `key`).
    case task
    /// Run a Buddy routine by id (in `key`).
    case routine
    /// Check or uncheck a list item (list id in `key`, item in `data`).
    case listToggle = "list_toggle"
    /// An answer to a prompt or a notification button (in `data`).
    case answer
  }

  enum State: String, Codable {
    case pending
    /// A copy of a message still waiting in the Buddy page's own queue. The page sends it while
    /// it's open; this copy is released to send once the app is backgrounded.
    case held
    /// The server answered but refused it. Kept so nothing is ever silently dropped.
    case rejected
  }

  var id: UUID = UUID()
  var kind: Kind
  var text: String?
  var key: String?
  var data: JSONValue?
  var pressedAt: Date = Date()
  var source: String
  var state: State = .pending
  var attempts: Int = 0
  var lastError: String?
  var lastAttemptAt: Date?

  var summary: String {
    switch kind {
    case .command, .buddy: return text ?? ""
    case .trigger: return key ?? "trigger"
    case .task: return "Run task \(text ?? key ?? "")"
    case .routine: return "Run routine \(text ?? key ?? "")"
    case .listToggle: return "Toggle \(text ?? "item")"
    case .answer: return "Answer \(text ?? "")"
    }
  }

  var wire: SubmissionBody {
    SubmissionBody(
      id: id.uuidString.lowercased(),
      kind: kind.rawValue,
      text: text,
      key: key,
      data: data,
      pressedAt: ISO8601.string(pressedAt),
      source: source,
      timezone: TimeZone.current.identifier,
      wait: nil,
    )
  }
}

struct SubmissionBody: Encodable {
  var id: String
  var kind: String
  var text: String?
  var key: String?
  var data: JSONValue?
  var pressedAt: String
  var source: String
  var timezone: String
  var wait: Bool?
}

struct UploadReply: Decodable {
  struct Attachment: Decodable {
    var signedId: String
    var url: String?
  }
  var attachments: [Attachment]
}

struct SubmissionReply: Decodable {
  var id: String
  var status: String
  var duplicate: Bool?
  var response: String?
  var error: String?
  var messageId: Int?
  var conversationId: Int?
  var data: JSONValue?
}

/// The persisted queue. One JSON file in the App Group so the app, widgets, intents and the share
/// sheet all add to the same list.
enum Outbox {
  private static let fileName = "outbox.json"
  private static let flushLock = NSLock()
  private static var flushing = false

  static var items: [OutboxItem] {
    SharedStore.readFile([OutboxItem].self, name: fileName) ?? []
  }

  static var pendingCount: Int { items.filter { $0.state == .pending }.count }

  @discardableResult
  static func enqueue(_ item: OutboxItem) -> OutboxItem {
    SharedStore.mutateFile([OutboxItem].self, name: fileName, empty: []) { $0.append(item) }
    ActivityLog.add("Queued \(item.kind.rawValue): \(item.summary)")
    notifyChanged()
    return item
  }

  static func enqueue(kind: OutboxItem.Kind, text: String? = nil, key: String? = nil, data: JSONValue? = nil, source: String) -> OutboxItem {
    enqueue(OutboxItem(kind: kind, text: text, key: key, data: data, source: source))
  }

  static func remove(_ id: UUID) {
    SharedStore.mutateFile([OutboxItem].self, name: fileName, empty: []) { $0.removeAll { $0.id == id } }
    notifyChanged()
  }

  static func update(_ id: UUID, _ change: @escaping (inout OutboxItem) -> Void) {
    SharedStore.mutateFile([OutboxItem].self, name: fileName, empty: []) { items in
      guard let index = items.firstIndex(where: { $0.id == id }) else { return }
      change(&items[index])
    }
    notifyChanged()
  }

  /// One entry of the Buddy page's own send queue (byte/queue.js).
  struct ByteQueueEntry: Decodable {
    var localId: String
    var conversationId: Int
    var body: String?
    var clientTs: Double?
    var attachmentSignedIds: [String]?
  }

  static let byteSource = "byte"

  /// Keeps a held copy of exactly what's in the Buddy page's queue: new entries are added under
  /// their own local_id, and copies of entries the page has sent or cancelled are dropped.
  static func mirror(byteQueue entries: [ByteQueueEntry]) {
    let wanted = entries.compactMap { entry in UUID(uuidString: entry.localId).map { ($0, entry) } }
    let ids = Set(wanted.map(\.0))
    SharedStore.mutateFile([OutboxItem].self, name: fileName, empty: []) { items in
      items.removeAll { $0.source == byteSource && $0.state != .rejected && !ids.contains($0.id) }
      let present = Set(items.map(\.id))
      for (id, entry) in wanted where !present.contains(id) {
        var data: [String: JSONValue] = ["conversation_id": .number(Double(entry.conversationId))]
        if let signed = entry.attachmentSignedIds, !signed.isEmpty {
          data["attachment_signed_ids"] = .array(signed.map(JSONValue.string))
        }
        var item = OutboxItem(kind: .buddy, text: entry.body ?? "", data: .object(data), source: byteSource)
        item.id = id
        item.state = .held
        if let clientTs = entry.clientTs { item.pressedAt = Date(timeIntervalSince1970: clientTs / 1000) }
        items.append(item)
      }
    }
    notifyChanged()
  }

  /// The app went to the background: the page can't send any more, so its held copies go out,
  /// through the system's background session so they keep trying after the app is suspended.
  static func releaseHeld() {
    setHeld(false)
    items.filter { $0.source == byteSource && $0.state == .pending }.forEach(BackgroundUploader.shared.schedule)
  }

  /// The app is back: the page sends what's left of its queue itself.
  static func holdByteCopies() {
    setHeld(true)
  }

  private static func setHeld(_ held: Bool) {
    SharedStore.mutateFile([OutboxItem].self, name: fileName, empty: []) { items in
      for index in items.indices where items[index].source == byteSource {
        if held, items[index].state == .pending { items[index].state = .held }
        if !held, items[index].state == .held { items[index].state = .pending }
      }
    }
    notifyChanged()
  }

  static func retry(_ id: UUID) {
    update(id) {
      $0.state = .pending
      $0.lastError = nil
    }
  }

  /// Sends every pending item, oldest press first, one request each. An item is removed only after
  /// a 2xx for that item. A connection failure stops the pass — the rest would fail the same way —
  /// and a refusal marks just that item so the others still go.
  @discardableResult
  static func flush() async -> Int {
    let started = flushLock.withLock {
      if flushing { return false }
      flushing = true
      return true
    }
    guard started else { return 0 }
    defer { flushLock.withLock { flushing = false } }

    guard Session.isSignedIn else { return 0 }
    var sent = 0
    let queue = items.filter { $0.state == .pending }.sorted { $0.pressedAt < $1.pressedAt }
    for (index, item) in queue.enumerated() {
      do {
        _ = try await send(item)
        remove(item.id)
        sent += 1
      } catch let error as APIError where error.isRetryable {
        update(item.id) {
          $0.attempts += 1
          $0.lastAttemptAt = Date()
          $0.lastError = error.localizedDescription
        }
        // Everything left goes to the system's background session, which keeps retrying until
        // the network is back, whether or not this process is still alive.
        queue[index...].forEach(BackgroundUploader.shared.schedule)
        break
      } catch {
        update(item.id) {
          $0.attempts += 1
          $0.lastAttemptAt = Date()
          $0.lastError = error.localizedDescription
          $0.state = .rejected
        }
      }
    }
    if sent > 0 { ActivityLog.add("Sent \(sent) queued item\(sent == 1 ? "" : "s")") }
    return sent
  }

  static func send(_ item: OutboxItem, wait: Bool = false) async throws -> SubmissionReply {
    let item = try await uploadingLocalFiles(item)
    var body = item.wire
    body.wait = wait ? true : nil
    return try await APIClient.shared.post("api/ios/submissions", body: body, timeout: wait ? 45 : 20, as: SubmissionReply.self)
  }

  /// Sends now and waits for the server's answer, for the times a reply should be shown. The item
  /// is still written to the queue first, so a dropped connection leaves it to go out later rather
  /// than losing it.
  static func sendInline(kind: OutboxItem.Kind, text: String, source: String) async throws -> SubmissionReply {
    let item = enqueue(kind: kind, text: text, source: source)
    do {
      var reply = try await send(item, wait: true)
      remove(item.id)
      if reply.status == "failed" {
        reply.response = reply.error ?? "The server couldn't carry that out."
        return reply
      }
      if kind == .buddy, reply.response == nil {
        reply.response = try await awaitBuddyReply(submissionId: reply.id)
      }
      return reply
    } catch let error as APIError where !error.isRetryable {
      remove(item.id)
      throw error
    }
  }

  /// Photos shared while offline are saved beside the queue as `local_files`; they go up first and
  /// the item is rewritten to carry the server's attachment ids, so a retry never uploads twice.
  private static func uploadingLocalFiles(_ item: OutboxItem) async throws -> OutboxItem {
    guard case .object(var data)? = item.data, let files = data["local_files"]?.array, !files.isEmpty else { return item }
    var signedIds = data["attachment_signed_ids"]?.array ?? []
    for file in files.compactMap(\.string) {
      let url = SharedStore.fileURL(file)
      guard let bytes = try? Data(contentsOf: url) else { continue }
      let reply = try await APIClient.shared.upload(
        "api/ios/uploads",
        fields: [:],
        file: (name: "files[]", filename: file, mimeType: file.hasSuffix(".png") ? "image/png" : "image/jpeg", data: bytes),
        as: UploadReply.self,
      )
      signedIds += reply.attachments.map { .string($0.signedId) }
      try? FileManager.default.removeItem(at: url)
    }
    data["local_files"] = nil
    data["attachment_signed_ids"] = .array(signedIds)
    var updated = item
    updated.data = .object(data)
    update(item.id) { $0.data = .object(data) }
    return updated
  }

  /// Saves a photo beside the queue so it can go out with its message whenever there's signal.
  static func stash(imageData: Data, ext: String = "jpg") -> String {
    let name = "share-\(UUID().uuidString).\(ext)"
    try? imageData.write(to: SharedStore.fileURL(name), options: .atomic)
    return name
  }

  /// Buddy answers asynchronously, so poll the submission until the reply lands.
  static func awaitBuddyReply(submissionId: String, timeout: TimeInterval = 40) async throws -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      try await Task.sleep(nanoseconds: 1_500_000_000)
      let reply = try await APIClient.shared.get("api/ios/submissions/\(submissionId)", as: SubmissionReply.self)
      if let response = reply.response, !response.isEmpty { return response }
    }
    return nil
  }

  private static func notifyChanged() {
    NotificationCenter.default.post(name: .buddyOutboxChanged, object: nil)
  }
}

/// Hands items to a background URLSession, which the system keeps retrying until the network comes
/// back — even after the app has been suspended or killed — and relaunches the app to report.
final class BackgroundUploader: NSObject, URLSessionDataDelegate {
  static let shared = BackgroundUploader()

  var completionHandler: (() -> Void)?
  private var responses: [Int: Int] = [:]

  private lazy var session: URLSession = makeSession(identifier: Self.identifier)

  /// Each process needs its own background session name; extensions share the container so the
  /// app can pick their sessions back up.
  static var identifier: String {
    let process = Bundle.main.bundleIdentifier ?? "app"
    return "\(BuddyConfig.backgroundSessionPrefix).\(process)"
  }

  func makeSession(identifier: String) -> URLSession {
    let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
    configuration.sharedContainerIdentifier = BuddyConfig.appGroup
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }

  /// Reattaches to a session the system is reporting on after relaunching the app.
  func reconnect(identifier: String, completion: @escaping () -> Void) {
    completionHandler = completion
    if identifier == Self.identifier {
      _ = session
    } else {
      _ = makeSession(identifier: identifier)
    }
  }

  func schedule(_ item: OutboxItem) {
    guard var request = try? APIClient.shared.request("POST", "api/ios/submissions") else { return }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    guard let body = try? SharedStore.encoder.encode(item.wire) else { return }
    let file = SharedStore.fileURL("upload-\(item.id.uuidString).json")
    try? body.write(to: file, options: .atomic)
    request.httpBody = nil
    session.getAllTasks { tasks in
      // One upload per item; a second press of flush shouldn't stack copies.
      guard !tasks.contains(where: { $0.taskDescription == item.id.uuidString }) else { return }
      let task = self.session.uploadTask(with: request, fromFile: file)
      task.taskDescription = item.id.uuidString
      task.resume()
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    responses[dataTask.taskIdentifier] = (response as? HTTPURLResponse)?.statusCode
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let description = task.taskDescription, let id = UUID(uuidString: description) else { return }
    let status = (task.response as? HTTPURLResponse)?.statusCode ?? responses[task.taskIdentifier]
    try? FileManager.default.removeItem(at: SharedStore.fileURL("upload-\(description).json"))
    if error == nil, let status, (200..<300).contains(status) {
      Outbox.remove(id)
      ActivityLog.add("Background send delivered \(description.prefix(8))")
    } else if let status, (400..<500).contains(status), status != 408, status != 429, status != 401 {
      Outbox.update(id) {
        $0.state = .rejected
        $0.lastError = "Server refused it (\(status))"
      }
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    DispatchQueue.main.async {
      self.completionHandler?()
      self.completionHandler = nil
    }
  }
}

/// A short rolling log in the App Group, shown in the app so "did it send?" has an answer.
enum ActivityLog {
  struct Entry: Codable, Identifiable {
    var id = UUID()
    var at = Date()
    var process: String
    var text: String
  }

  private static let fileName = "activity_log.json"

  static var entries: [Entry] { SharedStore.readFile([Entry].self, name: fileName) ?? [] }

  static func add(_ text: String) {
    let process = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    SharedStore.mutateFile([Entry].self, name: fileName, empty: []) { entries in
      entries.insert(Entry(process: process, text: text), at: 0)
      if entries.count > 300 { entries.removeLast(entries.count - 300) }
    }
  }

  static func clear() {
    SharedStore.mutateFile([Entry].self, name: fileName, empty: []) { $0 = [] }
  }
}
