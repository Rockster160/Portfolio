import SwiftUI
import UIKit

/// What the site's pages can ask of the phone inside the app (see buddy_app.js). Each answer is a
/// plain dictionary or array the page gets back from its promise.
@MainActor
enum AppBridge {
  static func handle(_ name: String, _ args: [String: Any]) async throws -> Any? {
    switch name {
    case "signedIn":
      return try signedIn(args)
    case "requestPermission":
      guard let raw = args["feature"] as? String, let feature = Feature(rawValue: raw) else {
        throw WebShell.BridgeError.missing("feature")
      }
      let state = await FeatureManager.shared.requestPermission(feature)
      return ["state": state.rawValue]
    case "outbox":
      return WebShell.plain(Outbox.items)
    case "outboxRetry":
      Outbox.retry(try id(args))
      Task { await Outbox.flush() }
      return nil
    case "outboxRemove":
      Outbox.remove(try id(args))
      return nil
    case "outboxFlush":
      return ["sent": await Outbox.flush()]
    case "byteQueue":
      let data = try JSONSerialization.data(withJSONObject: args["entries"] ?? [])
      Outbox.mirror(byteQueue: try SharedStore.decoder.decode([Outbox.ByteQueueEntry].self, from: data))
      return nil
    case "symbols":
      return symbols(args["names"] as? [String] ?? [], color: args["color"] as? String)
    case "send":
      return try await send(args)
    case "activity":
      return WebShell.plain(Array(ActivityLog.entries.prefix(150)))
    case "clearActivity":
      ActivityLog.clear()
      return nil
    case "runTask":
      guard let task = args["task"] as? String else { throw WebShell.BridgeError.missing("task") }
      await FeatureManager.shared.run(task: task)
      return nil
    case "signOut":
      await AppModel.shared.signOut()
      return nil
    default:
      throw WebShell.BridgeError.unknown(name)
    }
  }

  /// The login page's hand-off: the device token, kept in the keychain, and who signed in.
  private static func signedIn(_ args: [String: Any]) throws -> Any? {
    let data = try JSONSerialization.data(withJSONObject: args)
    let reply = try SharedStore.decoder.decode(SignInReply.self, from: data)
    Session.token = reply.token
    Session.current = Session(
      deviceId: reply.device.id,
      deviceName: reply.device.name,
      userId: reply.user.id,
      username: reply.user.username,
      primaryConversationId: reply.primaryConversationId,
    )
    if let darkMode = args["dark_mode"] as? Bool {
      SharedStore.defaults.set(darkMode, forKey: SharedStore.Key.darkMode)
    }
    AppModel.shared.signedInNow()
    return nil
  }

  /// A command or Buddy message from the console or the quick prompt, through the same path as a
  /// hot link: queued with the time it was pressed, or sent and answered straight away.
  private static func send(_ args: [String: Any]) async throws -> Any? {
    guard let text = args["text"] as? String, !text.isEmpty else { throw WebShell.BridgeError.missing("text") }
    let kind: ButtonAction.Kind = (args["kind"] as? String) == "command" ? .command : .buddy
    var data: JSONValue?
    if let raw = args["data"] as? String, let json = raw.data(using: .utf8) {
      data = try? SharedStore.decoder.decode(JSONValue.self, from: json)
    }
    let action = ButtonAction(kind: kind, prefix: args["prefix"] as? String, data: data, inline: args["inline"] as? Bool)
    switch await ActionRunner.run(action, typed: text, source: "app") {
    case .replied(let reply):
      return ["status": "replied", "reply": reply]
    case .queued:
      return ["status": "queued"]
    case .open(let url):
      AppModel.shared.handle(url: url)
      return ["status": "opened"]
    }
  }

  /// SF Symbols as PNG data URLs, in the page's text colour, for the hot link icon picker: a
  /// browser can't draw them, the phone can.
  private static func symbols(_ names: [String], color: String?) -> [String: String] {
    let tint = UIColor(Color(css: color) ?? .primary)
    let configuration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
    var images: [String: String] = [:]
    for name in names {
      guard let symbol = UIImage(systemName: name, withConfiguration: configuration)?
        .withTintColor(tint, renderingMode: .alwaysOriginal) else { continue }
      let format = UIGraphicsImageRendererFormat()
      format.scale = 3
      let image = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in symbol.draw(at: .zero) }
      guard let data = image.pngData() else { continue }
      images[name] = "data:image/png;base64,\(data.base64EncodedString())"
    }
    return images
  }

  private static func id(_ args: [String: Any]) throws -> UUID {
    guard let raw = args["id"] as? String, let id = UUID(uuidString: raw) else { throw WebShell.BridgeError.missing("id") }
    return id
  }
}
