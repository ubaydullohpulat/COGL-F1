import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// A version such as 0.1.7. Tags may carry a leading "v".
struct AppVersion: Comparable, Hashable, CustomStringConvertible {
  var parts: [Int]

  init?(_ text: String) {
    var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if digits.hasPrefix("v") || digits.hasPrefix("V") { digits.removeFirst() }
    let numbers = digits.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
    parts = numbers.compactMap { $0 }
  }

  var description: String { parts.map(String.init).joined(separator: ".") }

  /// 0.2 and 0.2.0 are the same version.
  private var trimmed: [Int] {
    var p = parts
    while p.count > 1, p.last == 0 { p.removeLast() }
    return p
  }

  static func == (a: AppVersion, b: AppVersion) -> Bool { a.trimmed == b.trimmed }
  func hash(into hasher: inout Hasher) { hasher.combine(trimmed) }
  static func < (a: AppVersion, b: AppVersion) -> Bool { a.trimmed.lexicographicallyPrecedes(b.trimmed) }
}

/// A release on GitHub, as its API describes it.
struct GitHubRelease: Decodable {
  struct Asset: Decodable {
    var name: String
    var url: URL
    enum CodingKeys: String, CodingKey {
      case name
      case url = "browser_download_url"
    }
  }
  var tag: String
  var page: URL
  var draft: Bool?
  var prerelease: Bool?
  var assets: [Asset]

  enum CodingKeys: String, CodingKey {
    case draft, prerelease, assets
    case tag = "tag_name"
    case page = "html_url"
  }
}

/// A version of the app that can be installed.
struct AppRelease: Equatable {
  var version: AppVersion
  var page: URL
  var dmg: URL
  /// The published SHA-256 of the disk image.
  var checksum: URL?

  init?(_ release: GitHubRelease) {
    guard release.draft != true, release.prerelease != true, let version = AppVersion(release.tag),
          let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else { return nil }
    self.version = version
    page = release.page
    self.dmg = dmg.url
    checksum = release.assets.first { $0.name == dmg.name + ".sha256" }?.url
  }

  /// The digest in a `shasum -a 256` line: "<64 hex characters>  <file>".
  static func digest(inChecksumFile text: String) -> String? {
    guard let first = text.split(whereSeparator: \.isWhitespace).first.map({ $0.lowercased() }),
          first.count == 64, first.allSatisfy(\.isHexDigit) else { return nil }
    return first
  }
}

struct UpdateError: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}

/// Looks for a newer release on GitHub and installs it over the running app.
@Observable @MainActor
final class Updater {
  static let repo = "ubaydullohpulat/COGL-F1"

  enum Phase: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppRelease)
    case downloading
    case installing
    /// The new app is in place and this one is about to quit.
    case restarting
    case failed(String)
  }

  var phase: Phase = .idle
  /// What the main window has to say when a check was asked for, or an update went wrong.
  var notice: String?
  /// Off once "Don't show this again" is ticked. Settings turns it back on.
  var checksOnLaunch: Bool = UserDefaults.standard.object(forKey: "updates.checkOnLaunch") as? Bool ?? true {
    didSet { UserDefaults.standard.set(checksOnLaunch, forKey: "updates.checkOnLaunch") }
  }

  /// Nil when run as a bare executable, which has no version to compare.
  let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)

  var isWorking: Bool { phase == .downloading || phase == .installing }

  private var feed: URL {
    // A different feed, for trying an update without publishing a release.
    if let custom = ProcessInfo.processInfo.environment["COGLF1_UPDATE_FEED"], let url = URL(string: custom) { return url }
    return URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
  }

  // MARK: Checking

  /// The quiet check when the app opens. It only speaks up when there is an update.
  func checkAtLaunch() async {
    guard checksOnLaunch, current != nil else { return }
    await check()
    if case .available(let release) = phase { offer(release, canSilence: true) }
    // Being offline when the app opens is not news.
    if case .failed = phase { phase = .idle }
  }

  /// A check the person asked for from the menu: it always answers.
  func checkAndTell() async {
    await check()
    switch phase {
    case .available(let release): offer(release, canSilence: false)
    case .upToDate: notice = "You have the latest version\(current.map { ", \($0)" } ?? "")."
    case .failed(let message): notice = message
    default: break
    }
  }

  /// Asks whether to install `release`. The box ends the question for good; Settings brings it back.
  /// An AppKit alert, because a SwiftUI one drops the tick when the answer is Not Now.
  private func offer(_ release: AppRelease, canSilence: Bool) {
    let alert = NSAlert()
    alert.messageText = "Forecast Studio \(release.version) is available"
    alert.informativeText = "You have \(current?.description ?? "an older version"). The app restarts to finish the update."
    alert.addButton(withTitle: "Update")
    alert.addButton(withTitle: "Not Now")
    alert.showsSuppressionButton = canSilence
    alert.suppressionButton?.title = "Don't show this again"
    let answered: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      MainActor.assumeIsolated {
        guard let self else { return }
        if alert.suppressionButton?.state == .on { self.checksOnLaunch = false }
        if response == .alertFirstButtonReturn { Task { await self.install(release) } }
      }
    }
    let main = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("main") == true } ?? NSApp.mainWindow
    if let main {
      alert.beginSheetModal(for: main, completionHandler: answered)
    } else {
      answered(alert.runModal())
    }
  }

  func check() async {
    guard !isWorking, phase != .checking, phase != .restarting else { return }
    phase = .checking
    do {
      var request = URLRequest(url: feed)
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.timeoutInterval = 20
      let (data, response) = try await URLSession.shared.data(for: request)
      if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        throw UpdateError(message: "GitHub answered with status \(http.statusCode).")
      }
      let release = AppRelease(try JSONDecoder().decode(GitHubRelease.self, from: data))
      phase = Self.verdict(current: current, latest: release)
    } catch {
      phase = .failed("Could not check for updates. \(error.localizedDescription)")
    }
  }

  /// An update is a release newer than the running app. A build without a version never updates itself.
  nonisolated static func verdict(current: AppVersion?, latest: AppRelease?) -> Phase {
    guard let current, let latest, latest.version > current else { return .upToDate }
    return .available(latest)
  }

  // MARK: Installing

  func install(_ release: AppRelease) async {
    guard !isWorking, phase != .restarting else { return }
    guard let checksum = release.checksum else {
      // Nothing to verify the download against: leave it to the person and the browser.
      NSWorkspace.shared.open(release.page)
      return
    }
    phase = .downloading
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("ForecastStudioUpdate-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let dmg = work.appendingPathComponent(release.dmg.lastPathComponent)
      let (downloaded, response) = try await URLSession.shared.download(from: release.dmg)
      if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        throw UpdateError(message: "The download failed with status \(http.statusCode).")
      }
      try FileManager.default.moveItem(at: downloaded, to: dmg)
      let (sum, _) = try await URLSession.shared.data(from: checksum)
      let expected = AppRelease.digest(inChecksumFile: String(decoding: sum, as: UTF8.self))
      let actual = try await Task.detached { try UpdateInstaller.sha256(of: dmg) }.value
      guard let expected, expected == actual else {
        throw UpdateError(message: "The download is damaged (checksum mismatch).")
      }

      phase = .installing
      let app = Bundle.main.bundleURL
      guard UpdateInstaller.canReplace(app) else {
        try handOver(dmg, version: release.version)
        return
      }
      try await Task.detached { try UpdateInstaller.install(dmg: dmg, over: app, workDir: work) }.value
      // Not a working phase any more: the progress sheet closes, and an app with a sheet open cannot quit.
      phase = .restarting
      UpdateInstaller.relaunch(app)
    } catch {
      try? FileManager.default.removeItem(at: work)
      phase = .failed("The update could not be installed. \(error.localizedDescription)")
      notice = "The update could not be installed. \(error.localizedDescription)"
    }
  }

  /// The app cannot replace itself here, for example when it runs from the disk image. Finder can.
  private func handOver(_ dmg: URL, version: AppVersion) throws {
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    let kept = downloads.appendingPathComponent(dmg.lastPathComponent)
    try? FileManager.default.removeItem(at: kept)
    try FileManager.default.moveItem(at: dmg, to: kept)
    NSWorkspace.shared.open(kept)
    phase = .idle
    notice = "Version \(version) is in your Downloads folder. Drag Forecast Studio to Applications to finish."
  }
}

/// The file work of an update. None of it touches the interface, so it runs off the main thread.
enum UpdateInstaller {
  static func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// False for a bare executable, a read-only place, or the randomized path macOS runs a quarantined app from.
  static func canReplace(_ app: URL) -> Bool {
    let path = app.path
    return app.pathExtension == "app" && !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/")
      && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
  }

  /// Replaces `app` with the app inside `dmg`.
  static func install(dmg: URL, over app: URL, workDir: URL) throws {
    let fm = FileManager.default
    let mount = workDir.appendingPathComponent("mount", isDirectory: true)
    try fm.createDirectory(at: mount, withIntermediateDirectories: true)
    try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
    defer {
      try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
      try? fm.removeItem(at: workDir)
    }

    let ours = Bundle(url: app)?.bundleIdentifier
    let found = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
      .first { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == ours }
    guard let fresh = found else { throw UpdateError(message: "The download does not contain Forecast Studio.") }

    // Only an intact app from the same developer may take this one's place.
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh.path])
    if let team = teamIdentifier(of: app), teamIdentifier(of: fresh) != team {
      throw UpdateError(message: "The download is not signed by the developer of this app.")
    }

    // Copy next to the app, so the swap is a rename on one volume.
    let staged = app.deletingLastPathComponent().appendingPathComponent(".\(app.lastPathComponent).update")
    try? fm.removeItem(at: staged)
    try run("/usr/bin/ditto", [fresh.path, staged.path])
    do {
      _ = try fm.replaceItemAt(app, withItemAt: staged)
    } catch {
      try? fm.removeItem(at: staged)
      throw error
    }
  }

  /// Opens the new app as soon as this one has quit.
  @MainActor static func relaunch(_ app: URL) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; open \"$1\"",
                   String(ProcessInfo.processInfo.processIdentifier), app.path]
    try? p.run()
    // Once the progress sheet has closed. A sheet or dialog that is still open would refuse the quit,
    // so after a moment the app leaves anyway; the engine stops by itself when the app is gone.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
  }

  static func teamIdentifier(of app: URL) -> String? {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
  }

  private static func run(_ tool: String, _ arguments: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = arguments
    let output = Pipe()
    p.standardOutput = output
    p.standardError = output
    try p.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
      let name = URL(fileURLWithPath: tool).lastPathComponent
      throw UpdateError(message: "\(name) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
  }
}
