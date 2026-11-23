import Foundation
import Security

/// The device token lives in a keychain group shared by the app and every extension, so a widget
/// button or the share sheet can talk to the server without the app running.
enum Keychain {
  private static let service = "com.ardesian.buddy"

  static func get(_ account: String) -> String? {
    var query = baseQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func set(_ value: String?, for account: String) {
    let query = baseQuery(account)
    SecItemDelete(query as CFDictionary)
    guard let value, let data = value.data(using: .utf8) else { return }
    var insert = query
    insert[kSecValueData as String] = data
    // Readable after the first unlock so background pushes and queued sends work on a locked phone.
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(insert as CFDictionary, nil)
  }

  private static func baseQuery(_ account: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if !BuddyConfig.keychainGroup.isEmpty {
      query[kSecAttrAccessGroup as String] = BuddyConfig.keychainGroup
    }
    return query
  }
}

/// Who is signed in. The token is the secret; the rest is display.
struct Session: Codable, Equatable {
  var deviceId: Int
  var deviceName: String
  var userId: Int
  var username: String
  var primaryConversationId: Int?

  static var current: Session? {
    get { SharedStore.load(Session.self, key: SharedStore.Key.session) }
    set { SharedStore.save(newValue, key: SharedStore.Key.session) }
  }

  static var token: String? {
    get {
      // Simulator builds without signing have no keychain group; fall back so they still work.
      Keychain.get("device_token") ?? SharedStore.defaults.string(forKey: "device_token_fallback")
    }
    set {
      Keychain.set(newValue, for: "device_token")
      if Keychain.get("device_token") == nil, let newValue {
        SharedStore.defaults.set(newValue, forKey: "device_token_fallback")
      } else {
        SharedStore.defaults.removeObject(forKey: "device_token_fallback")
      }
    }
  }

  static var isSignedIn: Bool { token != nil && current != nil }

  static func signOut() {
    token = nil
    current = nil
  }
}
