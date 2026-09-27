import CryptoKit
import Foundation
import Observation

/// Downloads TimesFM checkpoints straight from Hugging Face into the models folder.
@Observable @MainActor
final class ModelDownloader {
  static let defaultRepo = "google/timesfm-3.0-pytorch"

  enum Phase: Equatable {
    case idle
    case listing
    case downloading
    case verifying
    case finished
    case failed(String)
    case cancelled
  }

  struct Progress {
    var repo: String
    var phase: Phase = .idle
    var file: String = ""
    var received: Int64 = 0
    var total: Int64 = 0
    var bytesPerSecond: Double = 0
    var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    var eta: TimeInterval? { bytesPerSecond > 0 && total > received ? Double(total - received) / bytesPerSecond : nil }
  }

  private(set) var progress: [String: Progress] = [:]
  private var tasks: [String: Task<Void, Never>] = [:]
  var onFinished: ((String) -> Void)?

  static func modelId(for repo: String) -> String { repo.replacingOccurrences(of: "/", with: "--") }

  func isActive(_ repo: String) -> Bool {
    guard let p = progress[repo] else { return false }
    return [.listing, .downloading, .verifying].contains(p.phase)
  }

  func start(repo: String, token: String?) {
    let repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !repo.isEmpty, !isActive(repo) else { return }
    progress[repo] = Progress(repo: repo, phase: .listing)
    tasks[repo] = Task { [weak self] in
      await self?.run(repo: repo, token: token)
    }
  }

  func cancel(repo: String) {
    tasks[repo]?.cancel()
    tasks[repo] = nil
    progress[repo]?.phase = .cancelled
  }

  func clear(repo: String) { progress[repo] = nil }

  // MARK: - Implementation

  private struct RepoFile: Decodable {
    struct LFS: Decodable { var oid: String; var size: Int64 }
    var type: String
    var path: String
    var size: Int64
    var lfs: LFS?
  }

  private struct RepoInfo: Decodable {
    var sha: String?
    var gated: JSONValue?
  }

  private func run(repo: String, token: String?) async {
    let modelsDir = EngineManager.modelsDir
    let finalDir = modelsDir.appendingPathComponent(Self.modelId(for: repo), isDirectory: true)
    let stagingDir = modelsDir.appendingPathComponent(".downloads/\(Self.modelId(for: repo))", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
      let info: RepoInfo = try await fetchJSON("https://huggingface.co/api/models/\(repo)", token: token)
      let revision = info.sha ?? "main"
      let tree: [RepoFile] = try await fetchJSON("https://huggingface.co/api/models/\(repo)/tree/\(revision)", token: token)
      let wanted = tree.filter { $0.type == "file" && ["config.json", "model.safetensors", "LICENSE", "README.md"].contains($0.path) }
      guard wanted.contains(where: { $0.path == "config.json" }), wanted.contains(where: { $0.path == "model.safetensors" }) else {
        throw EngineError(message: "\(repo) is not a TimesFM 3 checkpoint (config.json + model.safetensors not found).")
      }
      // Check the small config first, so an unusable model never costs a large download.
      guard await ModelCatalog.checkConfig(repo: repo, revision: revision, token: token) else {
        throw EngineError(message: "\(repo) is a different kind of model. This app runs TimesFM 3 checkpoints.")
      }
      let total = wanted.reduce(Int64(0)) { $0 + ($1.lfs?.size ?? $1.size) }
      progress[repo]?.total = total
      progress[repo]?.phase = .downloading

      var doneBytes: Int64 = 0
      for f in wanted {
        try Task.checkCancellation()
        let size = f.lfs?.size ?? f.size
        let dest = stagingDir.appendingPathComponent(f.path)
        progress[repo]?.file = f.path
        if let existing = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64, existing == size {
          doneBytes += size  // already complete from an earlier attempt
          progress[repo]?.received = doneBytes
          continue
        }
        let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(f.path)")!
        let base = doneBytes
        try await FileDownload.run(url: url, to: dest, expectedSize: size, token: token) { [weak self] received, speed in
          Task { @MainActor in
            self?.progress[repo]?.received = base + received
            self?.progress[repo]?.bytesPerSecond = speed
          }
        }
        doneBytes += size
        if let oid = f.lfs?.oid {
          progress[repo]?.phase = .verifying
          let digest = try await Self.sha256(of: dest)
          guard digest == oid else {
            try? FileManager.default.removeItem(at: dest)
            throw EngineError(message: "Checksum mismatch for \(f.path); the partial file was removed. Please retry.")
          }
          progress[repo]?.phase = .downloading
        }
      }

      let meta: [String: Any] = [
        "kind": "base",
        "source": "huggingface",
        "repo": repo,
        "revision": revision,
        "display_name": repo == Self.defaultRepo ? "TimesFM 3.0 · 330M" : repo,
        "license": repo == Self.defaultRepo ? "TimesFM Non-Commercial License v1.0" : "See the model's LICENSE",
        "downloaded": ISO8601DateFormatter().string(from: Date()),
      ]
      let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
      try metaData.write(to: stagingDir.appendingPathComponent("cogl_meta.json"))
      try? FileManager.default.removeItem(at: finalDir)
      try FileManager.default.moveItem(at: stagingDir, to: finalDir)
      progress[repo]?.phase = .finished
      progress[repo]?.received = total
      onFinished?(repo)
    } catch is CancellationError {
      progress[repo]?.phase = .cancelled
    } catch let e as URLError where e.code == .cancelled {
      progress[repo]?.phase = .cancelled
    } catch {
      progress[repo]?.phase = .failed(error.localizedDescription)
    }
    tasks[repo] = nil
  }

  private func fetchJSON<T: Decodable>(_ urlString: String, token: String?) async throws -> T {
    var req = URLRequest(url: URL(string: urlString)!)
    if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 || code == 403 {
      throw EngineError(message: "Hugging Face denied access (\(code)). If the model is gated or private, add a token in Settings.")
    }
    if code == 404 { throw EngineError(message: "Repository not found on Hugging Face.") }
    guard (200..<300).contains(code) else { throw EngineError(message: "Hugging Face returned HTTP \(code).") }
    return try JSONDecoder().decode(T.self, from: data)
  }

  nonisolated static func sha256(of url: URL) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      let h = try FileHandle(forReadingFrom: url)
      defer { try? h.close() }
      var hasher = SHA256()
      while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }.value
  }
}

/// One resumable file download (`dest.part` → `dest`) with byte-level progress.
private final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  typealias OnProgress = (_ received: Int64, _ bytesPerSecond: Double) -> Void

  private let dest: URL
  private let part: URL
  private let expected: Int64
  private let onProgress: OnProgress
  private var handle: FileHandle?
  private var received: Int64 = 0
  private var continuation: CheckedContinuation<Void, Error>?
  private var lastReport = Date.distantPast
  private var speedWindow: [(Date, Int64)] = []
  private var failure: Error?

  private init(dest: URL, expected: Int64, onProgress: @escaping OnProgress) {
    self.dest = dest
    self.part = dest.appendingPathExtension("part")
    self.expected = expected
    self.onProgress = onProgress
  }

  static func run(url: URL, to dest: URL, expectedSize: Int64, token: String?, onProgress: @escaping OnProgress) async throws {
    let d = FileDownload(dest: dest, expected: expectedSize, onProgress: onProgress)
    try await d.start(url: url, token: token)
  }

  private func start(url: URL, token: String?) async throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
    var offset = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
    if offset > expected { try? fm.removeItem(at: part); fm.createFile(atPath: part.path, contents: nil); offset = 0 }
    received = offset

    var req = URLRequest(url: url)
    if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
    if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let task = session.dataTask(with: req)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        self.continuation = c
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
    try? handle?.close()
    guard received == expected else {
      throw EngineError(message: "Download of \(dest.lastPathComponent) ended early (\(received) of \(expected) bytes). Press Download to resume.")
    }
    try? fm.removeItem(at: dest)
    try fm.moveItem(at: part, to: dest)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    do {
      if code == 200 {  // server ignored Range: start over
        try Data().write(to: part)
        received = 0
      } else if code != 206 {
        throw EngineError(message: code == 401 || code == 403
          ? "Hugging Face denied access (\(code)). Add a token in Settings."
          : "Download failed with HTTP \(code).")
      }
      handle = try FileHandle(forWritingTo: part)
      try handle?.seekToEnd()
      completionHandler(.allow)
    } catch {
      failure = error
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    do {
      try handle?.write(contentsOf: data)
    } catch {
      failure = error
      dataTask.cancel()
      return
    }
    received += Int64(data.count)
    let now = Date()
    if now.timeIntervalSince(lastReport) > 0.2 {
      speedWindow.append((now, received))
      speedWindow.removeAll { now.timeIntervalSince($0.0) > 5 }
      var speed = 0.0
      if let first = speedWindow.first, now.timeIntervalSince(first.0) > 0.1 {
        speed = Double(received - first.1) / now.timeIntervalSince(first.0)
      }
      lastReport = now
      onProgress(received, speed)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    onProgress(received, 0)
    if let failure {
      continuation?.resume(throwing: failure)
    } else if let error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
    continuation = nil
  }
}
