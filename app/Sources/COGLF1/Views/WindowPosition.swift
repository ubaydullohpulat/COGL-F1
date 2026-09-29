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

/// Shifts a toolbar item sideways so its middle lands on `target`.
/// An offset, not padding: the toolbar's width counts towards the narrowest the window can be.
struct CenteredOver<Content: View>: View {
  var target: CGFloat?
  @ViewBuilder var content: () -> Content
  /// Where the toolbar put the item, before the shift.
  @State private var own: CGFloat?

  var body: some View {
    let shift = target.flatMap { t in own.map { t - $0 } } ?? 0
    content()
      .offset(x: shift)
      .background(WindowMidX { own = $0 })
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
