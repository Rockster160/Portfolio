import Foundation

/// Carries out a ButtonAction from whichever process was pressed: the app, a widget button, a
/// notification action, a hot link or an intent. Anything that needs the server goes through the
/// outbox, so a press is never lost to a bad connection.
enum ActionRunner {
  enum Outcome {
    /// Saved and (maybe) sent; nothing to show.
    case queued(OutboxItem)
    /// The server answered and the answer should be shown.
    case replied(String)
    /// The app has to come to the front to finish it.
    case open(URL)
  }

  @discardableResult
  static func run(_ action: ButtonAction, typed: String? = nil, source: String) async -> Outcome {
    switch action.kind {
    case .command, .buddy:
      let text = [action.prefix, typed ?? action.value].compactMap { $0 }.joined()
      let kind: OutboxItem.Kind = action.kind == .command ? .command : .buddy
      if action.inline == true {
        do {
          let reply = try await Outbox.sendInline(kind: kind, text: text, data: action.data, source: source)
          return .replied(reply.response ?? "Sent.")
        } catch {
          return .replied(error.localizedDescription)
        }
      }
      return .queued(await queue(OutboxItem(kind: kind, text: text, data: action.data, source: source)))
    case .task:
      return .queued(await queue(OutboxItem(kind: .task, key: action.value, data: action.data, source: source)))
    case .routine:
      return .queued(await queue(OutboxItem(kind: .routine, key: action.value, data: action.data, source: source)))
    case .trigger:
      // Whatever was typed (a notification button that asks for text) rides along as `text`.
      var data = action.data
      if let typed, !typed.isEmpty {
        var object = data?.object ?? [:]
        object["text"] = .string(typed)
        data = .object(object)
      }
      return .queued(await queue(OutboxItem(kind: .trigger, key: action.value ?? "ios_hot_link", data: data, source: source)))
    case .listToggle:
      return .queued(await queue(OutboxItem(kind: .listToggle, text: typed, key: action.value, data: action.data, source: source)))
    case .prompt:
      return .open(DeepLink.compose(action))
    case .checkIn:
      return .open(DeepLink.url(host: "check-in", query: ["id": action.value]))
    case .open:
      return .open(DeepLink.url(host: "open", query: ["path": action.value ?? "/"]))
    case .url:
      return .open(URL(string: action.value ?? "") ?? DeepLink.url(host: "open", query: [:]))
    }
  }

  private static func queue(_ item: OutboxItem) async -> OutboxItem {
    let saved = Outbox.enqueue(item)
    await Outbox.flush()
    return saved
  }
}

/// buddy:// links. Widgets, notifications and hot links all open the app through these.
enum DeepLink {
  enum Route: Equatable {
    case home
    case buddy(conversationId: Int?)
    /// A site path shown in the app's web view.
    case web(path: String)
    case checkIn(id: String?)
    case compose(ButtonAction)
    case queue
    case settings
    case feature(Feature)
    case hotLink(String)
  }

  static func url(host: String, query: [String: String?]) -> URL {
    var components = URLComponents()
    components.scheme = BuddyConfig.urlScheme
    components.host = host
    let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
    if !items.isEmpty { components.queryItems = items }
    return components.url!
  }

  static func web(_ path: String) -> URL { url(host: "open", query: ["path": path]) }

  static func compose(_ action: ButtonAction) -> URL {
    let data = (try? SharedStore.encoder.encode(action)) ?? Data()
    return url(host: "compose", query: ["action": data.base64EncodedString()])
  }

  static func parse(_ url: URL) -> Route? {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    func query(_ name: String) -> String? {
      components?.queryItems?.first(where: { $0.name == name })?.value
    }

    // A link to the site keeps its host, so a Board or Kiosk link on Buddy's subdomain isn't read
    // as the same path on the main site.
    if url.scheme == "https" || url.scheme == "http" {
      guard WebShell.isSite(url) else { return nil }
      return .web(path: url.absoluteString)
    }

    guard url.scheme == BuddyConfig.urlScheme else { return nil }
    switch url.host {
    case "buddy", "chat":
      return .buddy(conversationId: query("conversation").flatMap(Int.init))
    case "open":
      return .web(path: query("path") ?? "/")
    case "list":
      return .web(path: "/lists/\(query("id") ?? "")")
    case "agenda":
      return .web(path: query("path") ?? "/agenda")
    case "board":
      return .web(path: query("path") ?? "/chores/board")
    case "check-in":
      return .checkIn(id: query("id"))
    case "compose":
      guard let raw = query("action"), let data = Data(base64Encoded: raw),
            let action = try? SharedStore.decoder.decode(ButtonAction.self, from: data) else {
        return .compose(ButtonAction(kind: .prompt, sendAs: .command))
      }
      return .compose(action)
    case "queue":
      return .queue
    case "settings":
      return .settings
    case "feature":
      return query("key").flatMap(Feature.init(rawValue:)).map(Route.feature)
    case "hot-link":
      return query("id").map(Route.hotLink)
    default:
      return .home
    }
  }
}

/// A Home Screen quick action: long-press the icon, pick one.
struct HotLink: Codable, Equatable, Identifiable, Hashable {
  var id: String = UUID().uuidString
  var title: String
  var subtitle: String?
  /// An SF Symbol name.
  var icon: String = "bolt.fill"
  var action: ButtonAction

  static var all: [HotLink] {
    get { SharedStore.load([HotLink].self, key: SharedStore.Key.hotLinks) ?? [] }
    set { SharedStore.save(newValue, key: SharedStore.Key.hotLinks) }
  }
}
