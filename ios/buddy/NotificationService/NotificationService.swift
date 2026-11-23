import UserNotifications

/// Runs on every alert push before it's shown. It turns the server's `actions` list into real
/// notification buttons (iOS only offers buttons from a registered category, so each distinct set
/// of answers gets a category of its own), and attaches any image.
final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?

  override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    self.contentHandler = contentHandler
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    bestAttempt = content

    Task {
      if let actions = NotificationActions.parse(content.userInfo["actions"]), !actions.isEmpty {
        content.categoryIdentifier = await NotificationActions.register(actions)
      }
      if let raw = content.userInfo["image"] as? String, let attachment = await Self.attachment(raw) {
        content.attachments = [attachment]
      }
      NotificationLedger.record(identifier: request.identifier, userInfo: content.userInfo)
      contentHandler(content)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let contentHandler, let bestAttempt { contentHandler(bestAttempt) }
  }

  private static func attachment(_ raw: String) async -> UNNotificationAttachment? {
    guard let url = URL(string: raw, relativeTo: BuddyConfig.serverURL)?.absoluteURL else { return nil }
    var request = URLRequest(url: url)
    if url.host == BuddyConfig.serverURL.host, let token = Session.token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
    let ext = (response.mimeType?.components(separatedBy: "/").last).map { $0 == "jpeg" ? "jpg" : $0 } ?? "png"
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    guard (try? data.write(to: file)) != nil else { return nil }
    return try? UNNotificationAttachment(identifier: "image", url: file)
  }
}
