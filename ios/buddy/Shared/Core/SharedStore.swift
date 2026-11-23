import Foundation

/// Storage every process can see: the app, widgets, the notification service and the share
/// extension all read and write the same App Group container.
enum SharedStore {
  enum Key {
    static let session = "session"
    static let features = "features"
    static let hotLinks = "hot_links"
    static let preferences = "preferences"
    static let catalog = "catalog"
    static let apnsToken = "apns_token"
    static let lastBadge = "last_badge"
    static let deliveredNotifications = "delivered_notifications"
    static let syncAnchors = "sync_anchors"
    static let darkMode = "dark_mode"
    static let webSession = "web_session"
  }

  static let defaults: UserDefaults = UserDefaults(suiteName: BuddyConfig.appGroup) ?? .standard

  static var containerURL: URL {
    let url = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: BuddyConfig.appGroup,
    ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func fileURL(_ name: String) -> URL {
    containerURL.appendingPathComponent(name)
  }

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }()

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      if let seconds = try? container.decode(Double.self) {
        return Date(timeIntervalSince1970: seconds)
      }
      let raw = try container.decode(String.self)
      if let date = ISO8601.parse(raw) { return date }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unreadable date \(raw)",
      )
    }
    return decoder
  }()

  static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? decoder.decode(T.self, from: data)
  }

  static func save<T: Encodable>(_ value: T?, key: String) {
    guard let value else {
      defaults.removeObject(forKey: key)
      return
    }
    if let data = try? encoder.encode(value) {
      defaults.set(data, forKey: key)
    }
  }

  /// Reads a JSON file under a file coordinator so a widget and the app writing at the same moment
  /// can't interleave halves of two versions.
  static func readFile<T: Decodable>(_ type: T.Type, name: String) -> T? {
    var result: T?
    var error: NSError?
    NSFileCoordinator().coordinate(readingItemAt: fileURL(name), options: [], error: &error) { url in
      guard let data = try? Data(contentsOf: url) else { return }
      result = try? decoder.decode(T.self, from: data)
    }
    return result
  }

  /// Read-modify-write under one coordinated write, so two processes appending to the outbox at
  /// once both land.
  static func mutateFile<T: Codable>(_ type: T.Type, name: String, empty: T, _ change: (inout T) -> Void) {
    var error: NSError?
    NSFileCoordinator().coordinate(writingItemAt: fileURL(name), options: [], error: &error) { url in
      var value = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(T.self, from: $0) } ?? empty
      change(&value)
      if let data = try? encoder.encode(value) {
        try? data.write(to: url, options: .atomic)
      }
    }
  }
}

enum ISO8601 {
  private static let withFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let plain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let dateOnly: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
  }()

  static func parse(_ raw: String) -> Date? {
    withFraction.date(from: raw) ?? plain.date(from: raw) ?? dateOnly.date(from: raw)
  }

  /// Keeps the device's offset in the string so the server sees the wall clock the press
  /// happened on, not just the instant.
  static func string(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = .current
    return formatter.string(from: date)
  }
}
