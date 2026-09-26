import Foundation

struct EngineError: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}

/// Thin async JSON client for the local engine server.
struct EngineClient {
  var baseURL: URL

  private static let session: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 60 * 30  // forecasts on long batches / model loads can take a while
    cfg.timeoutIntervalForResource = 60 * 60
    return URLSession(configuration: cfg)
  }()

  func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
    try await send(path, method: "GET", body: Optional<Int>.none)
  }

  func post<T: Decodable, B: Encodable>(_ path: String, body: B, as type: T.Type = T.self) async throws -> T {
    try await send(path, method: "POST", body: body)
  }

  func post<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
    try await send(path, method: "POST", body: Optional<Int>.none)
  }

  func delete<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
    try await send(path, method: "DELETE", body: Optional<Int>.none)
  }

  private func send<T: Decodable, B: Encodable>(_ path: String, method: String, body: B?) async throws -> T {
    var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
    req.httpMethod = method
    if let body {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONEncoder().encode(body)
    }
    let data: Data
    let resp: URLResponse
    do {
      (data, resp) = try await Self.session.data(for: req)
    } catch {
      throw EngineError(message: "Engine not reachable (\(error.localizedDescription)).")
    }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      if let err = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
        switch err.detail {
        case .string(let s): throw EngineError(message: s)
        default: throw EngineError(message: err.detail.description)
        }
      }
      throw EngineError(message: "Engine error \(status): \(String(data: data, encoding: .utf8) ?? "")")
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw EngineError(message: "Unexpected engine response for \(path): \(error)")
    }
  }
}

/// Encodes a heterogeneous dictionary (for request bodies built from UI state).
struct AnyEncodable: Encodable {
  private let encodeFn: (Encoder) throws -> Void
  init<T: Encodable>(_ value: T) { encodeFn = value.encode }
  func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
