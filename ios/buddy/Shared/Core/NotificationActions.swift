import Foundation
import UserNotifications

/// A button on a notification, as the server describes it.
struct NotificationActionSpec: Codable, Hashable {
  var id: String
  var title: String
  var value: String?
  var destructive: Bool?
  /// Opens the app instead of answering in place.
  var foreground: Bool?
  /// Shows a text field; the typed text is the answer.
  var input: Bool?
  var placeholder: String?
  var icon: String?
}

enum NotificationActions {
  static let replyCategory = "buddy.reply"
  static let defaultCategory = "buddy.default"

  static func parse(_ raw: Any?) -> [NotificationActionSpec]? {
    guard let raw else { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
    return try? SharedStore.decoder.decode([NotificationActionSpec].self, from: data)
  }

  /// The category id is a digest of the buttons, so the same answers reuse one category and a
  /// thousand prompts don't leave a thousand categories behind.
  static func categoryId(_ actions: [NotificationActionSpec]) -> String {
    let joined = actions.map { "\($0.id)|\($0.title)|\($0.input == true)|\($0.destructive == true)|\($0.foreground == true)" }.joined(separator: "§")
    var hash: UInt64 = 5381
    for byte in joined.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
    return "buddy.dynamic.\(String(hash, radix: 36))"
  }

  static func category(id: String, actions: [NotificationActionSpec]) -> UNNotificationCategory {
    let built: [UNNotificationAction] = actions.prefix(10).map { spec in
      var options: UNNotificationActionOptions = []
      if spec.destructive == true { options.insert(.destructive) }
      if spec.foreground == true { options.insert(.foreground) }
      let icon = spec.icon.map { UNNotificationActionIcon(systemImageName: $0) }
      if spec.input == true {
        return UNTextInputNotificationAction(
          identifier: spec.id,
          title: spec.title,
          options: options,
          icon: icon,
          textInputButtonTitle: "Send",
          textInputPlaceholder: spec.placeholder ?? "",
        )
      }
      return UNNotificationAction(identifier: spec.id, title: spec.title, options: options, icon: icon)
    }
    return UNNotificationCategory(identifier: id, actions: built, intentIdentifiers: [], options: [.customDismissAction])
  }

  /// Adds this set's category alongside the ones already registered, and waits until iOS has it,
  /// since a notification shown before its category exists has no buttons.
  static func register(_ actions: [NotificationActionSpec]) async -> String {
    let id = categoryId(actions)
    let center = UNUserNotificationCenter.current()
    var categories = await center.notificationCategories()
    if categories.contains(where: { $0.identifier == id }) { return id }
    // Keep the newest few dozen; older prompts have long since been answered.
    var stored = SharedStore.defaults.stringArray(forKey: "dynamic_categories") ?? []
    stored.append(id)
    if stored.count > 40 {
      let drop = Set(stored.prefix(stored.count - 40))
      categories = categories.filter { !drop.contains($0.identifier) }
      stored = Array(stored.suffix(40))
    }
    SharedStore.defaults.set(stored, forKey: "dynamic_categories")
    categories.insert(category(id: id, actions: actions))
    center.setNotificationCategories(categories)
    for _ in 0..<10 {
      if await center.notificationCategories().contains(where: { $0.identifier == id }) { break }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return id
  }

  /// The categories every launch starts with: a free-text reply and the plain default.
  static var baseCategories: Set<UNNotificationCategory> {
    [
      UNNotificationCategory(
        identifier: replyCategory,
        actions: [
          UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message Buddy"),
          UNNotificationAction(identifier: "mark_read", title: "Mark Read", options: []),
        ],
        intentIdentifiers: [],
        options: [.customDismissAction],
      ),
      UNNotificationCategory(identifier: defaultCategory, actions: [], intentIdentifiers: [], options: [.customDismissAction]),
    ]
  }
}

/// Which delivered notification belongs to which server tag, so a "dismiss this tag" push can
/// find it even after the tag has fallen out of the notification's own payload.
enum NotificationLedger {
  static func record(identifier: String, userInfo: [AnyHashable: Any]) {
    guard let tag = userInfo["tag"] as? String else { return }
    var ledger = SharedStore.defaults.dictionary(forKey: SharedStore.Key.deliveredNotifications) as? [String: String] ?? [:]
    ledger[identifier] = tag
    if ledger.count > 500 { ledger = Dictionary(uniqueKeysWithValues: ledger.suffix(400).map { ($0.key, $0.value) }) }
    SharedStore.defaults.set(ledger, forKey: SharedStore.Key.deliveredNotifications)
  }

  static func identifiers(forTags tags: Set<String>) -> [String] {
    let ledger = SharedStore.defaults.dictionary(forKey: SharedStore.Key.deliveredNotifications) as? [String: String] ?? [:]
    return ledger.filter { tags.contains($0.value) }.map(\.key)
  }

  /// Removes every delivered notification carrying one of these tags.
  static func remove(tags: Set<String>) async {
    let center = UNUserNotificationCenter.current()
    let delivered = await center.deliveredNotifications()
    var ids = delivered.filter { tags.contains(($0.request.content.userInfo["tag"] as? String) ?? "") }.map(\.request.identifier)
    ids += identifiers(forTags: tags)
    center.removeDeliveredNotifications(withIdentifiers: Array(Set(ids)))
  }
}
