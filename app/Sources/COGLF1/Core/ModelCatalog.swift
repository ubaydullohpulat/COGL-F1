import Foundation
import Observation

/// Finds checkpoints on Hugging Face and says which ones this engine can run.
@Observable @MainActor
final class ModelCatalog {
  struct Entry: Identifiable, Equatable {
    var repo: String
    var downloads: Int
    var sizeBytes: Int64?
    var compatible: Bool
    var id: String { repo }
    var owner: String { repo.split(separator: "/").first.map(String.init) ?? "" }
    var name: String { repo.split(separator: "/").last.map(String.init) ?? repo }
  }

  static let defaultQuery = "timesfm-3"

  /// What the person typed. Empty shows the models this app can run.
  var query = ""
  private(set) var results: [Entry] = []
  private(set) var isSearching = false
  private(set) var error: String?
  private(set) var searched = false

  /// The engine runs the TimesFM 3 layout only. Re-packed weights (for example half precision)
  /// keep the same files but need their own engine.
  nonisolated static func isCompatible(config: [String: Any]) -> Bool {
    guard config["transformer_config"] is [String: Any],
          config["input_patch_len"] != nil, config["output_patch_len"] != nil else { return false }
    if let precision = config["precision"] as? String, !["f32", "float32"].contains(precision.lowercased()) { return false }
    return true
  }

  func search() async {
    let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let q = typed.isEmpty ? Self.defaultQuery : typed
    guard !isSearching else { return }
    isSearching = true
    error = nil
    defer { isSearching = false }
    do {
      var parts = URLComponents(string: "https://huggingface.co/api/models")!
      parts.queryItems = [
        .init(name: "search", value: q), .init(name: "sort", value: "downloads"), .init(name: "direction", value: "-1"),
        .init(name: "limit", value: "30"), .init(name: "full", value: "true"),
      ]
      struct Hit: Decodable {
        struct File: Decodable { var rfilename: String }
        var id: String
        var downloads: Int?
        var siblings: [File]?
      }
      let (data, resp) = try await URLSession.shared.data(from: parts.url!)
      guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw EngineError(message: "Hugging Face did not answer. Try again in a moment.") }
      let hits = try JSONDecoder().decode([Hit].self, from: data).filter { hit in
        let files = Set(hit.siblings?.map(\.rfilename) ?? [])
        return files.contains("config.json") && files.contains("model.safetensors") && hit.id != ModelDownloader.defaultRepo
      }
      results = await withTaskGroup(of: (Int, Entry).self) { group in
        for (i, hit) in hits.enumerated() {
          group.addTask {
            let ok = await Self.checkConfig(repo: hit.id)
            return (i, Entry(repo: hit.id, downloads: hit.downloads ?? 0, sizeBytes: nil, compatible: ok))
          }
        }
        var out: [(Int, Entry)] = []
        for await r in group { out.append(r) }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
      }
      // Usable ones first; each group keeps the most-downloaded order.
      results = results.filter(\.compatible) + results.filter { !$0.compatible }
      searched = true
    } catch is CancellationError {
      // Leaving the page stops the search. That is not an error; it runs again next time.
    } catch let e as URLError where e.code == .cancelled {
    } catch let e as URLError {
      results = []
      searched = true
      error = e.code == .notConnectedToInternet ? "You are offline." : "Hugging Face did not answer. Try again in a moment."
    } catch {
      results = []
      searched = true
      self.error = error.localizedDescription
    }
  }

  nonisolated static func checkConfig(repo: String, revision: String = "main", token: String? = nil) async -> Bool {
    guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/config.json") else { return false }
    var req = URLRequest(url: url)
    req.timeoutInterval = 15
    if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200, data.count < 1 << 20,
          let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return isCompatible(config: cfg)
  }
}
