import Foundation

enum APIError: LocalizedError {
  case signedOut
  case offline(String)
  case http(Int, String)
  case decoding(String)

  var errorDescription: String? {
    switch self {
    case .signedOut: return "Not signed in to Buddy."
    case .offline(let reason): return "Couldn't reach the server: \(reason)"
    case .http(let status, let message): return message.isEmpty ? "Server said \(status)." : message
    case .decoding(let reason): return "Unexpected reply from the server: \(reason)"
    }
  }

  /// A failure worth trying again later rather than a verdict on the request itself.
  var isRetryable: Bool {
    switch self {
    case .offline: return true
    case .http(let status, _): return status == 408 || status == 429 || status >= 500
    default: return false
    }
  }
}

/// Every call to the server goes through here: one base URL, one bearer token, snake_case JSON.
struct APIClient {
  static let shared = APIClient()

  var session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 20
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }()

  func url(_ path: String, query: [String: String?] = [:]) -> URL {
    let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
    var components = URLComponents(
      url: BuddyConfig.serverURL.appendingPathComponent(trimmed),
      resolvingAgainstBaseURL: false,
    )!
    let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
    if !items.isEmpty { components.queryItems = items }
    return components.url!
  }

  func request(
    _ method: String,
    _ path: String,
    query: [String: String?] = [:],
    body: Encodable? = nil,
    timeout: TimeInterval? = nil,
    authorized: Bool = true,
  ) throws -> URLRequest {
    var request = URLRequest(url: url(path, query: query))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    if let timeout { request.timeoutInterval = timeout }
    if authorized {
      guard let token = Session.token else { throw APIError.signedOut }
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try SharedStore.encoder.encode(AnyEncodable(body))
    }
    return request
  }

  @discardableResult
  func send(_ request: URLRequest) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw APIError.offline(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else { throw APIError.offline("No response") }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401 { NotificationCenter.default.post(name: .buddyUnauthorized, object: nil) }
      throw APIError.http(http.statusCode, Self.errorMessage(data))
    }
    return data
  }

  func get<T: Decodable>(_ path: String, query: [String: String?] = [:], as type: T.Type) async throws -> T {
    let data = try await send(try request("GET", path, query: query))
    return try decode(T.self, data)
  }

  func post<T: Decodable>(_ path: String, body: Encodable? = nil, timeout: TimeInterval? = nil, as type: T.Type) async throws -> T {
    let data = try await send(try request("POST", path, body: body, timeout: timeout))
    return try decode(T.self, data)
  }

  @discardableResult
  func post(_ path: String, body: Encodable? = nil) async throws -> JSONValue {
    let data = try await send(try request("POST", path, body: body))
    return (try? SharedStore.decoder.decode(JSONValue.self, from: data)) ?? .null
  }

  func patch<T: Decodable>(_ path: String, body: Encodable, as type: T.Type) async throws -> T {
    let data = try await send(try request("PATCH", path, body: body))
    return try decode(T.self, data)
  }

  @discardableResult
  func delete(_ path: String) async throws -> JSONValue {
    let data = try await send(try request("DELETE", path))
    return (try? SharedStore.decoder.decode(JSONValue.self, from: data)) ?? .null
  }

  /// A multipart upload, for photos going to Buddy.
  func upload<T: Decodable>(
    _ path: String,
    fields: [String: String],
    file: (name: String, filename: String, mimeType: String, data: Data)?,
    as type: T.Type,
  ) async throws -> T {
    var request = try request("POST", path, timeout: 60)
    let boundary = "buddy-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    var body = Data()
    for (key, value) in fields {
      body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
    }
    if let file {
      body.append("--\(boundary)\r\n")
      body.append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
      body.append("Content-Type: \(file.mimeType)\r\n\r\n")
      body.append(file.data)
      body.append("\r\n")
    }
    body.append("--\(boundary)--\r\n")
    request.httpBody = body
    let data = try await send(request)
    return try decode(T.self, data)
  }

  func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    do {
      return try SharedStore.decoder.decode(T.self, from: data)
    } catch {
      throw APIError.decoding(String(describing: error))
    }
  }

  static let userAgent: String = {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    let process = Bundle.main.bundleIdentifier ?? "buddy"
    return "BuddyiOS/\(version) (\(build); \(process))"
  }()

  private static func errorMessage(_ data: Data) -> String {
    if let json = try? SharedStore.decoder.decode(JSONValue.self, from: data) {
      return json["error"]?.string ?? json["message"]?.string ?? ""
    }
    return String(data: data.prefix(200), encoding: .utf8) ?? ""
  }
}

struct AnyEncodable: Encodable {
  let value: Encodable
  init(_ value: Encodable) { self.value = value }
  func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension Data {
  mutating func append(_ string: String) {
    if let data = string.data(using: .utf8) { append(data) }
  }
}

extension Notification.Name {
  static let buddyUnauthorized = Notification.Name("buddyUnauthorized")
  static let buddyOutboxChanged = Notification.Name("buddyOutboxChanged")
  static let buddyOpenURL = Notification.Name("buddyOpenURL")
}
