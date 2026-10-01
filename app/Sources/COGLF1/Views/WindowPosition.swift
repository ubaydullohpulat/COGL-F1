import AppKit
import SwiftUI

/// Reports the horizontal middle of the view it is behind, in window coordinates.
/// The toolbar and the page are separate hosting views, so SwiftUI's own coordinate spaces can't compare them.
struct WindowMidX: NSViewRepresentable {
  var report: (CGFloat) -> Void

  func makeNSView(context: Context) -> Probe {
    let view = Probe()
    view.report = report
    return view
  }

  func updateNSView(_ view: Probe, context: Context) {
    view.report = report
    view.sendSoon()
  }

  final class Probe: NSView {
    var report: ((CGFloat) -> Void)?
    private var last: CGFloat?
    private var observer: NSObjectProtocol?

    override func layout() {
      super.layout()
      sendSoon()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      guard let window else { return }
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didResizeNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.sendSoon() }
      }
      sendSoon()
    }

    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// After the current layout pass, because a parent may still be moving this view.
    func sendSoon() {
      DispatchQueue.main.async { [weak self] in self?.send() }
    }

    private func send() {
      guard window != nil else { return }
      let x = convert(bounds, to: nil).midX.rounded()
      guard x != last else { return }
      last = x
      report?(x)
    }
  }
}

/// The middle of the part of a page the model bar should sit over.
struct PageCenterKey: PreferenceKey {
  static let defaultValue: CGFloat? = nil
  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    value = nextValue() ?? value
  }
}

extension View {
  /// Marks this view as the one the model bar is centered over.
  func modelBarCenter() -> some View {
    modifier(ModelBarCenter())
  }
}

private struct ModelBarCenter: ViewModifier {
  @State private var midX: CGFloat?

  func body(content: Content) -> some View {
    content
      .background(WindowMidX { midX = $0 })
      .preference(key: PageCenterKey.self, value: midX)
  }
}

/// Puts a toolbar item's middle on `target`, a position in window coordinates.
struct CenteredOver<Content: View>: View {
  var target: CGFloat?
  @ViewBuilder var content: () -> Content

  var body: some View {
    content().background(ToolbarItemShift(target: target))
  }
}

/// Moves the toolbar item this view sits in. The item's own AppKit view moves, not only its picture:
/// an offset draws the bar outside the item, and clicks out there never reach its buttons.
/// Padding is no way out either: the toolbar's width counts towards the narrowest the window can be.
struct ToolbarItemShift: NSViewRepresentable {
  var target: CGFloat?

  func makeNSView(context: Context) -> Mover {
    let view = Mover()
    view.target = target
    return view
  }

  func updateNSView(_ view: Mover, context: Context) {
    view.target = target
    view.place()
  }

  final class Mover: NSView {
    var target: CGFloat?
    /// The toolbar's own view for this item.
    private weak var item: NSView?
    /// Where the toolbar put the item.
    private var natural: CGFloat?
    /// Where this view put it.
    private var placed: CGFloat?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      item = nil
      guard window != nil else { return }
      // After the toolbar has put this view into its item.
      DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func attach() {
      var view: NSView? = self
      while let v = view, v.className != "NSToolbarItemViewer" { view = v.superview }
      // In a toolbar built some other way the item stays where the toolbar put it, fully clickable.
      guard let viewer = view, item == nil else { return }
      item = viewer
      natural = viewer.frame.origin.x
      viewer.postsFrameChangedNotifications = true
      observer = NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: viewer, queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.toolbarMovedItem() }
      }
      place()
    }

    /// The toolbar lays its items out again on every resize and puts this one back.
    private func toolbarMovedItem() {
      guard let item else { return }
      let x = item.frame.origin.x
      if let placed, abs(x - placed) < 0.5 { return }
      natural = x
      place()
    }

    func place() {
      guard let item, let toolbar = item.superview, let natural else { return }
      let frame = item.frame
      let gap = Theme.space
      var free = (toolbar.bounds.minX + gap)...(toolbar.bounds.maxX - gap)
      for sibling in toolbar.subviews where sibling !== item && !sibling.isHidden {
        guard let taken = Self.shown(sibling, in: toolbar) else { continue }
        if taken.midX < frame.midX {
          free = max(free.lowerBound, min(taken.maxX + gap, free.upperBound))...free.upperBound
        } else {
          free = free.lowerBound...min(free.upperBound, max(taken.minX - gap, free.lowerBound))
        }
      }
      let wanted = target.map { toolbar.convert(NSPoint(x: $0, y: 0), from: nil).x }
      let x = ModelBarPlacement.origin(target: wanted, natural: natural, width: frame.width, free: free)
      placed = x
      if abs(frame.origin.x - x) >= 0.5 { item.setFrameOrigin(NSPoint(x: x, y: frame.origin.y)) }
    }

    /// The part of a neighbour in the toolbar that shows something. Spaces and backgrounds show nothing.
    private static func shown(_ sibling: NSView, in toolbar: NSView) -> CGRect? {
      switch sibling.className {
      case "NSToolbarItemViewer":
        return sibling.subviews.contains { $0.className.contains("Space") } ? nil : sibling.frame
      case "NSToolbarTitleView":
        // The title view is wider than its text.
        return sibling.subviews.first.map { sibling.convert($0.frame, to: toolbar) } ?? sibling.frame
      default:
        return nil
      }
    }
  }
}

enum ModelBarPlacement {
  /// Left edge of a bar `width` wide whose middle is on `target`, kept inside `free`: the stretch
  /// of the toolbar between its neighbours. Without a target or without room it stays at `natural`.
  static func origin(target: CGFloat?, natural: CGFloat, width: CGFloat, free: ClosedRange<CGFloat>) -> CGFloat {
    guard let target, free.upperBound - free.lowerBound >= width else { return natural }
    return min(max(target - width / 2, free.lowerBound), free.upperBound - width).rounded()
  }
}

/// Reports the window's width, and grows a window that was restored or tiled below `minSize`.
struct WindowSizing: NSViewRepresentable {
  var minSize: CGSize
  var width: (CGFloat) -> Void

  func makeNSView(context: Context) -> Probe {
    let view = Probe()
    view.minSize = minSize
    view.width = width
    return view
  }

  func updateNSView(_ view: Probe, context: Context) {
    view.minSize = minSize
    view.width = width
    view.apply()
  }

  final class Probe: NSView {
    var minSize = CGSize.zero
    var width: ((CGFloat) -> Void)?
    private var last: CGFloat?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      guard let window else { return }
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didResizeNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.apply() }
      }
      apply()
    }

    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func apply() {
      guard let window else { return }
      // SwiftUI sets the minimum for resizing by hand. This covers a window that was restored or tiled smaller.
      let minSize = CGSize(width: max(minSize.width, window.contentMinSize.width), height: max(minSize.height, window.contentMinSize.height))
      let content = window.contentRect(forFrameRect: window.frame).size
      if !window.styleMask.contains(.fullScreen), content.width < minSize.width || content.height < minSize.height {
        // A window restored or tiled smaller than the minimum: grow it, keeping the top-left corner.
        var frame = window.frame
        let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: CGSize(
          width: max(content.width, minSize.width), height: max(content.height, minSize.height)))).size
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
        return
      }
      guard content.width != last else { return }
      last = content.width
      DispatchQueue.main.async { [weak self] in self?.width?(content.width) }
    }
  }
}
