import CryptoKit
import Darwin
import Foundation
import Observation

/// Installs the Python runtime (private venv) and runs the engine server as a child process.
@Observable @MainActor
final class EngineManager {
  enum State: Equatable {
    case checking
    case needsPython
    case needsInstall
    case installing(String)
    case starting
    case running
    case failed(String)
    case stopped
  }

  var state: State = .checking
  var logs: [String] = []
  var health: HealthInfo?
  var port: Int = 0
  var pythonPath: String?
  var installProgress: Double = 0

  var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }
  var client: EngineClient { EngineClient(baseURL: baseURL) }
  var isRunning: Bool { state == .running }

  private var process: Process?
  private var intentionalStop = false

  // MARK: Paths

  static var appSupport: URL {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("COGL-F1", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static var modelsDir: URL {
    if let custom = UserDefaults.standard.string(forKey: "modelsDir"), !custom.isEmpty {
      return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
    }
    return appSupport.appendingPathComponent("models", isDirectory: true)
  }

  static var runtimeDir: URL { appSupport.appendingPathComponent("runtime", isDirectory: true) }
  static var venvDir: URL { runtimeDir.appendingPathComponent("venv", isDirectory: true) }
  static var venvPython: URL { venvDir.appendingPathComponent("bin/python3") }
  private static var markerFile: URL { runtimeDir.appendingPathComponent("installed.json") }

  /// Folder that contains the `coglf1_engine` package and `requirements.txt`.
  static var engineDir: URL? {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["COGLF1_ENGINE_DIR"] {
      return URL(fileURLWithPath: env, isDirectory: true)
    }
    if let res = Bundle.main.resourceURL?.appendingPathComponent("engine", isDirectory: true),
       fm.fileExists(atPath: res.appendingPathComponent("coglf1_engine").path) {
      return res
    }
    // Development: walk up from the executable to the repo's engine/ folder.
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<8 {
      let cand = dir.appendingPathComponent("engine", isDirectory: true)
      if fm.fileExists(atPath: cand.appendingPathComponent("coglf1_engine").path) { return cand }
      dir = dir.deletingLastPathComponent()
    }
    return nil
  }

  private static var requirementsHash: String {
    guard let dir = engineDir, let data = try? Data(contentsOf: dir.appendingPathComponent("requirements.txt")) else { return "" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Lifecycle

  func bootstrap() async {
    state = .checking
    if let dev = ProcessInfo.processInfo.environment["COGLF1_PYTHON"] {
      pythonPath = dev
      await start()
      return
    }
    guard Self.engineDir != nil else {
      state = .failed("Engine files are missing from the app bundle.")
      return
    }
    if runtimeIsInstalled() {
      pythonPath = Self.venvPython.path
      await start()
    } else {
      state = findBasePython() == nil && findUV() == nil ? .needsPython : .needsInstall
    }
  }

  private func runtimeIsInstalled() -> Bool {
    guard FileManager.default.isExecutableFile(atPath: Self.venvPython.path),
          let data = try? Data(contentsOf: Self.markerFile),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return (obj["requirements_hash"] as? String) == Self.requirementsHash
  }

  func start() async {
    guard let python = pythonPath ?? (runtimeIsInstalled() ? Self.venvPython.path : nil) else {
      state = .needsInstall
      return
    }
    guard let engineDir = Self.engineDir else {
      state = .failed("Engine files not found.")
      return
    }
    stop()
    intentionalStop = false
    state = .starting
    port = Self.freePort()
    try? FileManager.default.createDirectory(at: Self.modelsDir, withIntermediateDirectories: true)
    appendLog("Starting engine on port \(port) with \(python)")

    let p = Process()
    p.executableURL = URL(fileURLWithPath: python)
    p.arguments = [
      "-m", "coglf1_engine", "--port", String(port), "--models-dir", Self.modelsDir.path,
      "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
    ]
    var env = ProcessInfo.processInfo.environment
    env["PYTHONPATH"] = engineDir.path
    env["PYTHONUNBUFFERED"] = "1"
    // Keep bytecode out of the (signed, read-only) app bundle.
    env["PYTHONPYCACHEPREFIX"] = Self.runtimeDir.appendingPathComponent("pycache").path
    env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
    env["HF_HUB_OFFLINE"] = "1"  // the engine only reads local models; downloads happen in the app
    p.environment = env
    attachOutput(to: p)
    p.terminationHandler = { [weak self] proc in
      let code = proc.terminationStatus
      Task { @MainActor in
        guard let self, self.process === proc else { return }
        self.process = nil
        if self.intentionalStop {
          self.state = .stopped
        } else {
          self.appendLog("Engine exited with code \(code).")
          self.state = .failed("The engine stopped unexpectedly (exit code \(code)). See the log in Engine & API.")
        }
      }
    }
    do {
      try p.run()
    } catch {
      state = .failed("Could not launch Python: \(error.localizedDescription)")
      return
    }
    process = p

    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
      if process == nil { return }  // exited; terminationHandler set the state
      if let h = try? await client.get("health", as: HealthInfo.self) {
        health = h
        state = .running
        appendLog("Engine ready · timesfm \(h.timesfmVersion ?? "?") · Python \(h.python)")
        return
      }
      try? await Task.sleep(for: .milliseconds(300))
    }
    state = .failed("The engine did not start within 3 minutes.")
    stop()
  }

  func stop() {
    guard let p = process else { return }
    intentionalStop = true
    p.terminate()
    let pid = p.processIdentifier
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
      if p.isRunning { kill(pid, SIGKILL) }
    }
    process = nil
    state = .stopped
  }

  func restart() async {
    stop()
    await start()
  }

  // MARK: Runtime install

  func findUV() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv"]
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// A Python ≥ 3.10 to create the venv from.
  func findBasePython() -> String? {
    if let custom = UserDefaults.standard.string(forKey: "basePython"), !custom.isEmpty,
       Self.pythonVersion(custom).map({ $0 >= (3, 10) }) == true {
      return custom
    }
    var candidates: [String] = []
    for v in ["3.13", "3.12", "3.11", "3.10"] {
      candidates += [
        "/opt/homebrew/bin/python\(v)",
        "/opt/homebrew/opt/python@\(v)/bin/python\(v)",
        "/usr/local/bin/python\(v)",
        "/Library/Frameworks/Python.framework/Versions/\(v)/bin/python3",
      ]
    }
    candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
      if let v = Self.pythonVersion(c), v >= (3, 10), v < (3, 14) { return c }
    }
    return nil
  }

  nonisolated static func pythonVersion(_ path: String) -> (Int, Int)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = ["-c", "import sys; print(sys.version_info[0], sys.version_info[1])"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let parts = s.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    return parts.count == 2 ? (parts[0], parts[1]) : nil
  }

  func installRuntime() async {
    guard let engineDir = Self.engineDir else {
      state = .failed("Engine files not found.")
      return
    }
    stop()
    let req = engineDir.appendingPathComponent("requirements.txt").path
    let fm = FileManager.default
    try? fm.createDirectory(at: Self.runtimeDir, withIntermediateDirectories: true)
    try? fm.removeItem(at: Self.venvDir)
    try? fm.removeItem(at: Self.markerFile)
    installProgress = 0.02

    let uv = findUV()
    let base = findBasePython()
    var ok: Bool
    if let uv {
      state = .installing("Creating Python environment with uv…")
      var args = ["venv", Self.venvDir.path, "--seed"]
      if base == nil { args += ["--python", "3.12"] } else { args += ["--python", base!] }
      ok = await run(uv, args)
      installProgress = 0.15
      if ok {
        state = .installing("Installing TimesFM 3, MLX, PyTorch… (≈ 1 GB, several minutes)")
        ok = await run(uv, ["pip", "install", "--python", Self.venvPython.path, "-r", req], progressFrom: 0.15)
      }
    } else if let base {
      state = .installing("Creating Python environment…")
      ok = await run(base, ["-m", "venv", Self.venvDir.path])
      installProgress = 0.1
      if ok {
        state = .installing("Updating pip…")
        ok = await run(Self.venvPython.path, ["-m", "pip", "install", "--upgrade", "pip"])
      }
      installProgress = 0.15
      if ok {
        state = .installing("Installing TimesFM 3, MLX, PyTorch… (≈ 1 GB, several minutes)")
        ok = await run(Self.venvPython.path, ["-m", "pip", "install", "--progress-bar", "off", "-r", req], progressFrom: 0.15)
      }
    } else {
      state = .needsPython
      return
    }
    if ok {
      state = .installing("Verifying…")
      ok = await run(Self.venvPython.path, ["-c", "import timesfm3.mlx, timesfm3.torch, torch, mlx.core, fastapi, pandas, openpyxl; print('runtime ok')"])
    }
    guard ok else {
      state = .failed("Runtime installation failed. Check the log, your internet connection, then try again.")
      return
    }
    let marker: [String: Any] = [
      "requirements_hash": Self.requirementsHash,
      "python": base ?? "uv",
      "installed": ISO8601DateFormatter().string(from: Date()),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: marker) { try? data.write(to: Self.markerFile) }
    installProgress = 1
    pythonPath = Self.venvPython.path
    appendLog("Runtime installed.")
    await start()
  }

  /// Runs a command, streaming output to the log. Returns true on exit code 0.
  private func run(_ exe: String, _ args: [String], progressFrom: Double? = nil) async -> Bool {
    appendLog("$ \(([exe] + args).joined(separator: " "))")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    env["PYTHONUNBUFFERED"] = "1"
    p.environment = env
    attachOutput(to: p, progressFrom: progressFrom)
    return await withCheckedContinuation { cont in
      p.terminationHandler = { proc in
        cont.resume(returning: proc.terminationStatus == 0)
      }
      do { try p.run() } catch {
        Task { @MainActor in self.appendLog("Failed to run \(exe): \(error.localizedDescription)") }
        p.terminationHandler = nil
        cont.resume(returning: false)
      }
    }
  }

  private func attachOutput(to p: Process, progressFrom: Double? = nil) {
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
        h.readabilityHandler = nil
        return
      }
      Task { @MainActor in
        guard let self else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
          self.appendLog(String(line))
          if let start = progressFrom, line.contains("Downloading") || line.contains("Collecting") || line.contains("Installing") || line.contains("Prepared") {
            // pip/uv don't report an overall percentage; creep towards 95% as packages arrive.
            self.installProgress = min(0.95, max(self.installProgress, start) + (0.95 - self.installProgress) * 0.04)
          }
        }
      }
    }
  }

  func appendLog(_ line: String) {
    logs.append(line)
    if logs.count > 5000 { logs.removeFirst(logs.count - 5000) }
  }

  static func freePort() -> Int {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return 8765 }
    defer { close(sock) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, len) }
    }
    guard bound == 0 else { return 8765 }
    _ = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
    }
    return Int(UInt16(bigEndian: addr.sin_port))
  }
}
