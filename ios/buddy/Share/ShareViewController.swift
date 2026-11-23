import UIKit
import UniformTypeIdentifiers

/// The share sheet is the site's share page (/app/share). Whatever comes in (photos, a place from
/// Maps, a link, text, a contact card) is read here and offered to the page, and the destination
/// picked there is sent through the outbox, so sharing with no signal still lands later. With no
/// connection and no saved copy of the page, it goes to Buddy, which takes anything.
final class ShareViewController: UIViewController {
  private var shell: WebShell?

  override func viewDidLoad() {
    super.viewDidLoad()
    let model = ShareModel(context: extensionContext)
    let shell = WebShell { name, args in try await model.handle(name, args) }
    shell.openExternally = { _ in }
    shell.loadFailed = { model.sendToBuddy() }
    shell.sessionExpired = { [weak shell] in shell?.load("/app/share") }
    model.shell = shell
    self.shell = shell
    shell.webView.frame = view.bounds
    shell.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(shell.webView)
    Task {
      await model.load()
      if Session.isSignedIn {
        shell.load("/app/share")
      } else {
        shell.webView.loadHTMLString(ShareModel.signedOutPage, baseURL: BuddyConfig.serverURL)
      }
    }
  }
}

struct SharedPlace: Equatable {
  var name: String?
  var address: String?
  var lat: Double?
  var lng: Double?
  var url: String?

  var navigationTarget: String {
    if let address, !address.isEmpty { return [name, address].compactMap { $0 }.joined(separator: ", ") }
    if let lat, let lng { return "\(lat),\(lng)" }
    return name ?? url ?? ""
  }
}

@MainActor
final class ShareModel {
  var images: [UIImage] = []
  var urls: [URL] = []
  var text = ""
  var place: SharedPlace?
  var contactCard: String?
  var caption = ""
  weak var shell: WebShell?

  private let context: NSExtensionContext?

  init(context: NSExtensionContext?) {
    self.context = context
  }

  var signedIn: Bool { Session.isSignedIn }

  func load() async {
    let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
         let image = await loadImage(provider) {
        images.append(image)
      } else if provider.hasItemConformingToTypeIdentifier(UTType.vCard.identifier),
                let data = try? await provider.loadItem(forTypeIdentifier: UTType.vCard.identifier) as? Data,
                let card = String(data: data, encoding: .utf8) {
        contactCard = card
        mergePlace(Self.place(fromVCard: card))
      } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
        if let place = Self.place(fromMapsURL: url) {
          mergePlace(place)
        } else {
          urls.append(url)
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
        text += (text.isEmpty ? "" : "\n") + value
      }
    }
  }

  /// The share page's calls (see buddy_app.js).
  func handle(_ name: String, _ args: [String: Any]) async throws -> Any? {
    switch name {
    case "shareItems":
      return ["items": items()]
    case "share":
      caption = (args["caption"] as? String) ?? ""
      switch args["destination"] as? String {
      case "command": runAsCommand()
      case "car": sendToCar()
      case "contact": saveAsContact()
      case "jil": sendToJil()
      default: sendToBuddy()
      }
      return nil
    case "cancelShare":
      cancel()
      return nil
    default:
      throw WebShell.BridgeError.unknown(name)
    }
  }

  /// What's being shared, for the page to show: small JPEG previews, the place, links and text.
  private func items() -> [[String: Any]] {
    var items: [[String: Any]] = images.compactMap { image in
      let size = CGSize(width: 600, height: 600 * image.size.height / max(image.size.width, 1))
      let preview = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
      guard let data = preview.jpegData(compressionQuality: 0.7) else { return nil }
      return ["image": "data:image/jpeg;base64,\(data.base64EncodedString())"]
    }
    if let place {
      items.append(["place": ["name": place.name as Any? ?? NSNull(), "address": place.address as Any? ?? NSNull()]])
    }
    items += urls.map { ["url": $0.absoluteString] }
    if !text.isEmpty { items.append(["text": text]) }
    return items
  }

  static let signedOutPage = """
    <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
    <body style="margin:0;padding:30px 10px;background:#F3F7FF;font-family:Arial;color:#3C4F63">
    <div style="background:#D5E5FF;border-radius:10px;overflow:hidden;box-shadow:3px 3px 10px #6481A1">
    <div style="background:#0160FF;color:white;font-size:32px;padding:20px">Buddy</div>
    <p style="padding:0 15px 10px">Open Buddy and log in first, then share again.</p></div>
    </body>
    """

  private func mergePlace(_ incoming: SharedPlace?) {
    guard let incoming else { return }
    var merged = place ?? SharedPlace()
    merged.name = merged.name ?? incoming.name
    merged.address = merged.address ?? incoming.address
    merged.lat = merged.lat ?? incoming.lat
    merged.lng = merged.lng ?? incoming.lng
    merged.url = merged.url ?? incoming.url
    place = merged
  }

  private func loadImage(_ provider: NSItemProvider) async -> UIImage? {
    let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
    if let image = item as? UIImage { return image }
    if let data = item as? Data { return UIImage(data: data) }
    if let url = item as? URL, let data = try? Data(contentsOf: url) { return UIImage(data: data) }
    return nil
  }

  /// Everything shared, as one message.
  var messageText: String {
    var parts: [String] = []
    if !caption.isEmpty { parts.append(caption) }
    if let place {
      parts.append([place.name, place.address].compactMap { $0 }.joined(separator: " — "))
      if let url = place.url { parts.append(url) }
    }
    parts += urls.map(\.absoluteString)
    if !text.isEmpty { parts.append(text) }
    return parts.joined(separator: "\n")
  }

  func sendToBuddy() {
    send("Sent to Buddy") {
      let files = self.images.compactMap { $0.jpegData(compressionQuality: 0.85) }.map { Outbox.stash(imageData: $0) }
      var data: [String: JSONValue] = ["source_kind": .string("share")]
      if !files.isEmpty { data["local_files"] = .array(files.map(JSONValue.string)) }
      let body = self.messageText.isEmpty ? "📷" : self.messageText
      Outbox.enqueue(OutboxItem(kind: .buddy, text: body, data: .object(data), source: "share"))
    }
  }

  func runAsCommand() {
    send("Command queued") {
      Outbox.enqueue(OutboxItem(kind: .command, text: self.messageText, source: "share"))
    }
  }

  func sendToCar() {
    guard let place else { return }
    send("Sent to the car") {
      Outbox.enqueue(OutboxItem(kind: .command, text: "Navigate to \(place.navigationTarget)", source: "share"))
    }
  }

  func saveAsContact() {
    guard let place else { return }
    send("Saved as a contact") {
      var contact: [String: JSONValue] = ["name": .string(self.caption.isEmpty ? (place.name ?? "New place") : self.caption)]
      if let address = place.address { contact["street"] = .string(address) }
      if let lat = place.lat { contact["lat"] = .number(lat) }
      if let lng = place.lng { contact["lng"] = .number(lng) }
      if let url = place.url { contact["url"] = .string(url) }
      Outbox.enqueue(OutboxItem(
        kind: .trigger,
        key: "ios_contacts",
        data: .object(["action": .string("added"), "save": .bool(true), "contact": .object(contact)]),
        source: "share",
      ))
    }
  }

  func sendToJil() {
    send("Sent to Jil") {
      let files = self.images.compactMap { $0.jpegData(compressionQuality: 0.85) }.map { Outbox.stash(imageData: $0) }
      let kind = !self.images.isEmpty ? "image" : self.place != nil ? "location" : self.contactCard != nil ? "contact" : !self.urls.isEmpty ? "url" : "text"
      var data: [String: JSONValue] = [
        "kind": .string(kind),
        "text": .string(self.messageText),
        "urls": .array(self.urls.map { .string($0.absoluteString) }),
      ]
      if let place = self.place {
        data["place"] = .object([
          "name": JSONValue(place.name),
          "address": JSONValue(place.address),
          "lat": JSONValue(place.lat),
          "lng": JSONValue(place.lng),
          "url": JSONValue(place.url),
        ])
      }
      if let card = self.contactCard { data["vcard"] = .string(card) }
      if !files.isEmpty { data["local_files"] = .array(files.map(JSONValue.string)) }
      Outbox.enqueue(OutboxItem(kind: .trigger, key: "ios_share", data: .object(data), source: "share"))
    }
  }

  private func send(_ confirmation: String, _ work: @escaping () -> Void) {
    work()
    Task {
      // Give it a moment to go out now; whatever doesn't make it stays queued for the app.
      _ = await withTaskGroup(of: Void.self) { group in
        group.addTask { await Outbox.flush() }
        group.addTask { try? await Task.sleep(nanoseconds: 6_000_000_000) }
        await group.next()
        group.cancelAll()
      }
      let waiting = Outbox.pendingCount
      shell?.flash(waiting > 0 ? "\(confirmation), sends when there's signal" : confirmation)
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      context?.completeRequest(returningItems: nil)
    }
  }

  func cancel() {
    context?.cancelRequest(withError: NSError(domain: "buddy.share", code: 0))
  }

  // MARK: - Parsing places

  /// Apple Maps shares `maps.apple.com/?ll=lat,lng&q=Name&address=…`; Google Maps uses `q=` or `@lat,lng`.
  static func place(fromMapsURL url: URL) -> SharedPlace? {
    guard let host = url.host, host.contains("maps.apple") || host.contains("google") && url.path.contains("maps") || host.contains("goo.gl") else { return nil }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    var place = SharedPlace(name: value("q") ?? value("name"), address: value("address"), url: url.absoluteString)
    let coordinate = value("ll") ?? value("sll") ?? value("coordinate") ?? url.path.components(separatedBy: "@").dropFirst().first
    if let parts = coordinate?.split(separator: ",").compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), parts.count >= 2 {
      place.lat = parts[0]
      place.lng = parts[1]
    }
    return place
  }

  /// Maps also shares a vCard with the place's name, address and a geo URL.
  static func place(fromVCard card: String) -> SharedPlace? {
    var place = SharedPlace()
    for line in card.components(separatedBy: .newlines) {
      let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      let key = parts[0].uppercased()
      if key.hasPrefix("FN") || key.hasPrefix("ORG") {
        place.name = place.name ?? parts[1]
      } else if key.contains("ADR") {
        place.address = parts[1].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
      } else if key.contains("URL"), parts[1].contains("maps") {
        place.url = parts[1].replacingOccurrences(of: "\\", with: "")
        if let fromURL = URL(string: place.url ?? "").flatMap(place(fromMapsURL:)) {
          place.lat = fromURL.lat
          place.lng = fromURL.lng
        }
      }
    }
    return place.name == nil && place.address == nil && place.lat == nil ? nil : place
  }
}
