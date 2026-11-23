import Foundation

/// Arbitrary JSON, for payloads whose shape belongs to a Jil task rather than to the app.
enum JSONValue: Codable, Equatable, Hashable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  init(_ any: Any?) {
    switch any {
    case nil, is NSNull: self = .null
    case let value as JSONValue: self = value
    case let value as Bool: self = .bool(value)
    case let value as Int: self = .number(Double(value))
    case let value as Double: self = .number(value)
    case let value as Float: self = .number(Double(value))
    case let value as NSNumber: self = .number(value.doubleValue)
    case let value as String: self = .string(value)
    case let value as Date: self = .string(ISO8601.string(value))
    case let value as URL: self = .string(value.absoluteString)
    case let value as [Any?]: self = .array(value.map { JSONValue($0) })
    case let value as [String: Any?]: self = .object(value.mapValues { JSONValue($0) })
    case let value as [String: Any]: self = .object(value.mapValues { JSONValue($0) })
    default: self = .string(String(describing: any!))
    }
  }

  var string: String? {
    switch self {
    case .string(let value): return value
    case .number(let value):
      return value.rounded() == value ? String(Int(value)) : String(value)
    case .bool(let value): return value ? "true" : "false"
    default: return nil
    }
  }

  var double: Double? {
    switch self {
    case .number(let value): return value
    case .string(let value): return Double(value)
    case .bool(let value): return value ? 1 : 0
    default: return nil
    }
  }

  var bool: Bool? {
    switch self {
    case .bool(let value): return value
    case .number(let value): return value != 0
    case .string(let value): return ["true", "on", "yes", "1"].contains(value.lowercased())
    default: return nil
    }
  }

  var object: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  var array: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  subscript(key: String) -> JSONValue? { object?[key] }

  var prettyString: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(self) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }
}
