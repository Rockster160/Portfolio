import Foundation

/// Identity values baked into every target's Info.plist from Config/Shared.xcconfig, so the app
/// and its extensions always agree on the App Group, keychain group and server.
enum BuddyConfig {
  static let appGroup = infoString("BuddyAppGroup", fallback: "group.com.ardesian.buddy")
  static let keychainGroup = infoString("BuddyKeychainGroup", fallback: "")
  static let bundleServerURL = infoString("BuddyServerURL", fallback: "https://ardesian.com")
  static let urlScheme = "buddy"
  static let backgroundSessionPrefix = "com.ardesian.buddy.outbox"

  /// The server the app talks to; a gitignored Config/Local.xcconfig points a build at a dev server.
  static let serverURL = URL(string: bundleServerURL) ?? URL(string: "https://ardesian.com")!

  private static func infoString(_ key: String, fallback: String) -> String {
    let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
    guard let value, !value.isEmpty, !value.contains("$(") else { return fallback }
    return value
  }
}
