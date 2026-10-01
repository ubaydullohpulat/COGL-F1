import AppKit
import SwiftUI
import XCTest

@testable import COGLF1

/// The model bar sits over the page, not where the toolbar would put it. Its Load, Switch and Unload
/// buttons once stopped answering, because only the picture of the bar had moved.
final class ModelBarPlacementTests: XCTestCase {
  func testMiddleLandsOnTarget() {
    let x = ModelBarPlacement.origin(target: 800, natural: 500, width: 360, free: 300...1400)
    XCTAssertEqual(x + 180, 800)
  }

  func testStaysBetweenItsNeighbours() {
    // The Parameters button starts at 1400: the bar stops before it.
    XCTAssertEqual(ModelBarPlacement.origin(target: 1350, natural: 500, width: 360, free: 300...1400), 1040)
    // The page title ends at 300: the bar stops after it.
    XCTAssertEqual(ModelBarPlacement.origin(target: 320, natural: 500, width: 360, free: 300...1400), 300)
  }

  func testNeverLeavesTheFreeStretch() {
    for target in stride(from: -200.0, through: 2000, by: 37) {
      for width in [200.0, 366, 480] {
        let x = ModelBarPlacement.origin(target: target, natural: 500, width: width, free: 280...1440)
        XCTAssertGreaterThanOrEqual(x, 280)
        XCTAssertLessThanOrEqual(x + width, 1440)
      }
    }
  }

  func testStaysPutWithoutTargetOrRoom() {
    XCTAssertEqual(ModelBarPlacement.origin(target: nil, natural: 500, width: 360, free: 300...1400), 500)
    XCTAssertEqual(ModelBarPlacement.origin(target: 800, natural: 500, width: 360, free: 600...900), 500)
  }
}

/// The same thing in a real window: AppKit must send a click on any part of the moved bar to the bar.
@MainActor
final class ModelBarClickTests: XCTestCase {
  func testEveryPartOfTheMovedBarTakesClicks() throws {
    _ = NSApplication.shared
    let target: CGFloat = 850
    let root = NavigationSplitView {
      Text("Sidebar").navigationSplitViewColumnWidth(220)
    } detail: {
      Text("Page")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
          ToolbarItem(placement: .principal) {
            CenteredOver(target: target) {
              HStack {
                Text("Model").frame(width: 180)
                Button("Load") {}
              }
            }
          }
        }
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0  // laid out like a visible window, without flashing on screen
    window.contentViewController = NSHostingController(rootView: root)
    window.setContentSize(NSSize(width: 1200, height: 700))
    window.orderFrontRegardless()
    defer { window.close() }

    // The toolbar and the mover both settle over a few turns of the run loop.
    var mover: NSView?
    var item: NSView?
    for _ in 0..<40 {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      mover = window.contentView?.superview.flatMap { Self.find(ToolbarItemShift.Mover.self, in: $0) }
      item = mover.flatMap(Self.toolbarItem)
      if let item, abs(item.convert(item.bounds, to: nil).midX - target) <= 1 { break }
    }
    guard let frame = window.contentView?.superview, let mover, let item else {
      throw XCTSkip("This system builds toolbars differently; the bar then stays where the toolbar puts it.")
    }

    let itemRect = item.convert(item.bounds, to: nil)
    XCTAssertEqual(itemRect.midX, target, accuracy: 1, "the bar is centered on its target")
    let barRect = mover.convert(mover.bounds, to: nil)
    XCTAssertTrue(itemRect.insetBy(dx: -0.5, dy: -0.5).contains(barRect), "the bar is drawn inside its own toolbar item")
    for part in [0.05, 0.5, 0.95] {
      let point = NSPoint(x: barRect.minX + barRect.width * part, y: barRect.midY)
      let hit = frame.hitTest(frame.convert(point, from: nil))
      XCTAssertTrue(hit?.isDescendant(of: item) == true, "a click \(Int(part * 100))% along the bar reaches \(String(describing: hit))")
    }
  }

  private static func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
    if let match = view as? V { return match }
    for sub in view.subviews {
      if let match = find(type, in: sub) { return match }
    }
    return nil
  }

  private static func toolbarItem(of view: NSView) -> NSView? {
    var v: NSView? = view
    while let x = v, x.className != "NSToolbarItemViewer" { v = x.superview }
    return v
  }
}
