import XCTest

@testable import COGLF1

final class AppVersionTests: XCTestCase {
  func testReadsTagsAndPlainVersions() {
    XCTAssertEqual(AppVersion("v0.1.7")?.parts, [0, 1, 7])
    XCTAssertEqual(AppVersion("0.1.7")?.description, "0.1.7")
    XCTAssertEqual(AppVersion(" 1.2 \n")?.parts, [1, 2])
  }

  func testRejectsWhatIsNotAVersion() {
    for text in ["", "v", "latest", "1.x", "0.1.7-beta", "1..2"] {
      XCTAssertNil(AppVersion(text), text)
    }
  }

  func testOrdersByNumberNotByText() {
    XCTAssertLessThan(AppVersion("0.1.9")!, AppVersion("0.1.10")!)
    XCTAssertLessThan(AppVersion("0.9.9")!, AppVersion("1.0")!)
    XCTAssertLessThan(AppVersion("0.1")!, AppVersion("0.1.1")!)
    XCTAssertEqual(AppVersion("0.2")!, AppVersion("0.2.0")!)
    XCTAssertFalse(AppVersion("0.2.0")! > AppVersion("0.2")!)
  }
}

final class UpdateCheckTests: XCTestCase {
  /// The shape GitHub answers with for /releases/latest, cut down to what the app reads.
  private func release(tag: String = "v0.1.9", draft: Bool = false, prerelease: Bool = false, checksum: Bool = true) throws -> GitHubRelease {
    let dmg = "Forecast-Studio-\(tag.dropFirst()).dmg"
    let base = "https://github.com/ubaydullohpulat/COGL-F1/releases/download/\(tag)/"
    var assets = [#"{"name": "\#(dmg)", "browser_download_url": "\#(base)\#(dmg)", "size": 2692064}"#]
    if checksum { assets.append(#"{"name": "\#(dmg).sha256", "browser_download_url": "\#(base)\#(dmg).sha256"}"#) }
    let json = """
      {"tag_name": "\(tag)", "html_url": "https://github.com/ubaydullohpulat/COGL-F1/releases/tag/\(tag)",
       "draft": \(draft), "prerelease": \(prerelease), "body": "notes", "assets": [\(assets.joined(separator: ","))]}
      """
    return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
  }

  func testReadsARelease() throws {
    let r = try XCTUnwrap(AppRelease(release()))
    XCTAssertEqual(r.version, AppVersion("0.1.9"))
    XCTAssertEqual(r.dmg.lastPathComponent, "Forecast-Studio-0.1.9.dmg")
    XCTAssertEqual(r.checksum?.lastPathComponent, "Forecast-Studio-0.1.9.dmg.sha256")
  }

  func testIgnoresDraftsPrereleasesAndReleasesWithoutADiskImage() throws {
    XCTAssertNil(AppRelease(try release(draft: true)))
    XCTAssertNil(AppRelease(try release(prerelease: true)))
    var empty = try release()
    empty.assets = []
    XCTAssertNil(AppRelease(empty))
  }

  func testAReleaseWithoutChecksumIsKnownButNotVerifiable() throws {
    XCTAssertNil(try XCTUnwrap(AppRelease(release(checksum: false))).checksum)
  }

  func testOnlyANewerReleaseIsAnUpdate() throws {
    let latest = try XCTUnwrap(AppRelease(release(tag: "v0.1.9")))
    XCTAssertEqual(Updater.verdict(current: AppVersion("0.1.8"), latest: latest), .available(latest))
    XCTAssertEqual(Updater.verdict(current: AppVersion("0.1.9"), latest: latest), .upToDate)
    XCTAssertEqual(Updater.verdict(current: AppVersion("0.2.0"), latest: latest), .upToDate)
    XCTAssertEqual(Updater.verdict(current: AppVersion("0.1.8"), latest: nil), .upToDate)
    // A build without a version (swift run) never offers to replace itself.
    XCTAssertEqual(Updater.verdict(current: nil, latest: latest), .upToDate)
  }

  func testReadsTheDigestOfAChecksumFile() {
    let hex = String(repeating: "ab12", count: 16)
    XCTAssertEqual(AppRelease.digest(inChecksumFile: "\(hex)  /Users/runner/work/dist/Forecast-Studio-0.1.9.dmg\n"), hex)
    XCTAssertEqual(AppRelease.digest(inChecksumFile: hex.uppercased()), hex)
    XCTAssertNil(AppRelease.digest(inChecksumFile: "Not Found"))
    XCTAssertNil(AppRelease.digest(inChecksumFile: ""))
    XCTAssertNil(AppRelease.digest(inChecksumFile: String(hex.dropLast())))
  }
}

final class UpdateInstallerTests: XCTestCase {
  func testSHA256OfAFile() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("coglf1-\(UUID().uuidString).txt")
    try Data("abc".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertEqual(try UpdateInstaller.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  func testOnlyAnAppInAWritableFolderReplacesItself() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coglf1-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    XCTAssertTrue(UpdateInstaller.canReplace(dir.appendingPathComponent("Forecast Studio.app")))
    // Run with `swift run`: there is no bundle to replace.
    XCTAssertFalse(UpdateInstaller.canReplace(dir.appendingPathComponent("COGLF1")))
    // Opened straight from the disk image, or from the random folder macOS runs a quarantined app in.
    XCTAssertFalse(UpdateInstaller.canReplace(URL(fileURLWithPath: "/Volumes/Forecast Studio 0.1.9/Forecast Studio.app")))
    XCTAssertFalse(UpdateInstaller.canReplace(URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1B2C/d/Forecast Studio.app")))
  }
}
