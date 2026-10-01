import AppKit
import Charts
import SwiftUI

/// X values the forecast chart can use: real timestamps or step indices.
protocol ChartX: Plottable, Comparable {
  var numeric: Double { get }
  init(numeric: Double)
}

extension Date: ChartX {
  var numeric: Double { timeIntervalSince1970 }
  init(numeric: Double) { self.init(timeIntervalSince1970: numeric) }
}
extension Int: ChartX {
  var numeric: Double { Double(self) }
  init(numeric: Double) { self = Int(numeric.rounded()) }
}

/// Two-finger swipes and the mouse wheel. SwiftUI has no scroll event, and the hover layer
/// on top of the chart keeps them from reaching the chart's own scrolling.
private final class ScrollWheelMonitor {
  var onScroll: ((NSEvent) -> Bool)?
  private var token: Any?

  func start() {
    guard token == nil else { return }
    token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      self?.onScroll?(event) == true ? nil : event
    }
  }

  func stop() {
    if let token { NSEvent.removeMonitor(token) }
    token = nil
  }

  deinit { stop() }
}

/// Which quantile bands to shade. Pairs of quantile indices into the 9-quantile output.
enum Band: Int, CaseIterable, Identifiable {
  case p10p90 = 80, p20p80 = 60, p30p70 = 40, p40p60 = 20
  var id: Int { rawValue }
  var lower: Int { [80: 0, 60: 1, 40: 2, 20: 3][rawValue]! }
  var upper: Int { 8 - lower }
  var label: String { "\(rawValue)%" }
  var opacity: Double { [80: 0.12, 60: 0.14, 40: 0.16, 20: 0.2][rawValue]! }
}

struct ChartDisplay: Equatable {
  var bands: Set<Band> = [.p10p90, .p30p70]
  var historyPoints: Int = 0  // 0 = automatic
  var showActuals = true
  var showPoints = false
}

struct ForecastChart: View {
  var target: ForecastTarget
  var windows: [ForecastWindow]
  var display: ChartDisplay
  var horizon: Int
  var zoom: Binding<Double> = .constant(1)
  /// Scrollable charts hold the whole history and open on the latest stretch. Off for image export.
  var scrollable = true

  var body: some View {
    let useDates = target.history.time != nil && windows.allSatisfy { $0.time != nil }
    if useDates {
      SeriesChart<Date>(model: build { t, _ in t.flatMap(Fmt.date) }, display: display, scrollable: scrollable, zoom: zoom)
    } else {
      SeriesChart<Int>(model: build { _, i in i }, display: display, scrollable: scrollable, zoom: zoom)
    }
  }

  private func build<X: ChartX>(_ xOf: (String?, Int) -> X?) -> SeriesModel<X> {
    let h = target.history
    let n = h.index.count
    let lastIndex = h.index.last ?? 0
    let heldOut = windows.map { lastIndex - $0.cutoffIndex }.max() ?? 0
    let auto = max(horizon * 4, 120) + heldOut
    let keep = display.historyPoints > 0 ? display.historyPoints : auto
    let start = max(0, n - keep)
    func points(_ range: Range<Int>) -> [(X, Double)] {
      var out: [(X, Double)] = []
      for i in range {
        guard let v = h.value[i], let x = xOf(h.time?[i], h.index[i]) else { continue }
        out.append((x, v))
      }
      // Downsample very long histories for drawing speed.
      if out.count > 3000 {
        let step = Double(out.count) / 3000
        out = stride(from: 0.0, to: Double(out.count), by: step).map { out[Int($0)] }
      }
      return out
    }
    let recent = points(start..<n)
    let hist = scrollable ? points(0..<start) + recent : recent
    let ws: [WindowModel<X>] = windows.map { w in
      var pts: [WindowModel<X>.Step] = []
      for i in w.index.indices {
        guard let x = xOf(w.time?[i], w.index[i]), let m = w.median[i] else { continue }
        pts.append(.init(x: x, median: m, q: w.quantiles.map { $0[i] ?? m }, actual: w.actual?[i] ?? nil))
      }
      // Anchor the forecast line to the last observed point so it doesn't float.
      var anchor: (X, Double)?
      let ci = w.cutoffIndex - 1
      if let pos = h.index.firstIndex(of: ci), let v = h.value[pos], let x = xOf(h.time?[pos], ci) { anchor = (x, v) }
      return WindowModel(window: w.window, steps: pts, anchor: anchor)
    }
    return SeriesModel(history: hist, windows: ws, openAt: recent.first?.0)
  }
}

struct WindowModel<X: ChartX> {
  struct Step {
    var x: X
    var median: Double
    var q: [Double]
    var actual: Double?
  }
  var window: Int
  var steps: [Step]
  var anchor: (X, Double)?
}

struct SeriesModel<X: ChartX> {
  var history: [(X, Double)]
  var windows: [WindowModel<X>]
  /// Left edge of the stretch shown at 100%. Older history sits to the left of it.
  var openAt: X?
}

private struct SeriesChart<X: ChartX>: View {
  var model: SeriesModel<X>
  var display: ChartDisplay
  var scrollable: Bool
  @Binding var zoom: Double
  @State private var hoverX: X?
  @State private var hoverPoint: CGPoint?
  @State private var zoomAnchor: Double = 1
  /// Left edge of what is on screen. Nil until the chart is moved, so it opens on the latest stretch.
  @State private var scrollX: X?
  @State private var dragOrigin: Double?
  @State private var plotWidth: CGFloat = 1
  @State private var wheel = ScrollWheelMonitor()
  /// With a mouse the system keeps scroll bars on screen. With a trackpad they show only while scrolling.
  @State private var scrollBarStays = NSScroller.preferredScrollerStyle == .legacy

  var body: some View {
    if let openAt = model.openAt ?? allXs.first {
      chart(openAt: openAt)
        .onChange(of: model.openAt?.numeric) { _, _ in scrollX = nil }
        .onChange(of: zoom) { old, new in keepRightEdge(from: old, to: new, openAt: openAt) }
        .onAppear {
          guard scrollable else { return }
          wheel.onScroll = { event in
            guard hoverPoint != nil else { return false }
            let dx = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            let points = event.hasPreciseScrollingDeltas ? dx : dx * 10
            move(from: (scrollX ?? openAt).numeric, by: points)
            return true
          }
          wheel.start()
        }
        .onDisappear { wheel.stop() }
    }
  }

  /// Moves the view by a distance in screen points. Content follows the pointer or fingers.
  private func move(from origin: Double, by points: CGFloat) {
    guard let range = scrollRange else { return }
    // The plot frame is the whole scrollable strip, so it maps to the whole x range.
    let values = allXs.map(\.numeric)
    let span = (values.max() ?? 0) - (values.min() ?? 0)
    let shifted = origin - Double(points) / Double(max(plotWidth, 1)) * span
    scrollX = X(numeric: min(max(shifted, range.lowerBound), range.upperBound))
  }

  /// Zooming keeps the newest data in place instead of the oldest.
  private func keepRightEdge(from old: Double, to new: Double, openAt: X) {
    guard let range = scrollRange, old > 0, new > 0 else { return }
    let span = Double(visibleLength) * new
    let right = (scrollX ?? openAt).numeric + span / old
    scrollX = X(numeric: min(max(right - span / new, range.lowerBound), range.upperBound))
  }

  /// Allowed positions of the left edge.
  private var scrollRange: ClosedRange<Double>? {
    let values = allXs.map(\.numeric)
    guard let lo = values.min(), let hi = values.max(), hi > lo else { return nil }
    return lo...max(lo, hi - Double(visibleLength))
  }

  private func chart(openAt: X) -> some View {
    let length = visibleLength
    return Chart {
      historyMarks
      ForEach(model.windows, id: \.window) { w in
        windowMarks(w)
      }
      hoverMarks
    }
    .chartYScale(domain: .automatic(includesZero: false))
    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
    .chartLegend(.hidden)
    .chartScrollableAxes(scrollable ? .horizontal : [])
    .chartXVisibleDomain(length: length)
    .chartScrollPosition(x: Binding(get: { scrollX ?? openAt }, set: { scrollX = $0 }))
    .chartOverlay { proxy in
      GeometryReader { geo in
        Rectangle().fill(.clear).contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
              hoverPoint = loc
              guard let plot = proxy.plotFrame else { return }
              plotWidth = geo[plot].width
              let x = loc.x - geo[plot].origin.x
              if let v: X = proxy.value(atX: x, as: X.self) { hoverX = nearest(to: v) }
            case .ended:
              hoverX = nil
              hoverPoint = nil
            }
          }
          .simultaneousGesture(
            MagnifyGesture()
              .onChanged { value in
                zoom = min(12, max(1, zoomAnchor * value.magnification))
              }
              .onEnded { _ in zoomAnchor = zoom }
          )
          .gesture(
            DragGesture(minimumDistance: 2)
              .onChanged { value in
                guard scrollable else { return }
                if dragOrigin == nil {
                  dragOrigin = (scrollX ?? openAt).numeric
                  hoverX = nil
                  NSCursor.closedHand.push()
                }
                move(from: dragOrigin ?? 0, by: value.translation.width)
              }
              .onEnded { _ in
                if dragOrigin != nil { NSCursor.pop() }
                dragOrigin = nil
              }
          )
        if let hoverX, let hoverPoint {
          tooltip(at: hoverX)
            .fixedSize()
            .position(tooltipPosition(hoverPoint, in: geo.size))
            .allowsHitTesting(false)
        }
      }
    }
    // The chart draws its scroll bar below its own frame, on top of whatever comes next.
    .padding(.bottom, scrollable && scrollBarStays ? Theme.space * 2 : 0)
    .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
      scrollBarStays = NSScroller.preferredScrollerStyle == .legacy
    }
  }

  /// How much of the x axis stays on screen. Dates are seconds; steps are counts.
  private var visibleLength: Int {
    let values = allXs.map(\.numeric)
    guard let first = values.min(), let hi = values.max(), hi > first else { return 1 }
    let lo = min(max(model.openAt?.numeric ?? first, first), hi - 1)
    return max(1, Int(((hi - lo) / zoom).rounded()))
  }

  /// Smooth curve that still passes through every point and never overshoots them.
  private static var curve: InterpolationMethod { .monotone }

  @ChartContentBuilder private var historyMarks: some ChartContent {
    ForEach(Array(model.history.enumerated()), id: \.offset) { _, p in
      LineMark(x: .value("Time", p.0), y: .value("Value", p.1), series: .value("Series", "History"))
        .foregroundStyle(Color.primary.opacity(0.75))
        .lineStyle(StrokeStyle(lineWidth: 1.4))
        .interpolationMethod(Self.curve)
    }
    if display.showPoints {
      ForEach(Array(model.history.enumerated()), id: \.offset) { _, p in
        PointMark(x: .value("Time", p.0), y: .value("Value", p.1))
          .symbolSize(8)
          .foregroundStyle(Color.primary.opacity(0.6))
      }
    }
  }

  @ChartContentBuilder private func windowMarks(_ w: WindowModel<X>) -> some ChartContent {
    let fade = w.window == 0 ? 1.0 : 0.55
    ForEach(Band.allCases.filter { display.bands.contains($0) }) { band in
      bandMarks(w, band: band, fade: fade)
    }
    // The forecast grows out of the last observed point, so it doesn't float.
    if let a = w.anchor {
      LineMark(x: .value("Time", a.0), y: .value("Value", a.1), series: .value("Series", "F\(w.window)"))
        .foregroundStyle(Color.accentColor.opacity(fade))
        .lineStyle(StrokeStyle(lineWidth: 2))
        .interpolationMethod(Self.curve)
    }
    ForEach(Array(w.steps.enumerated()), id: \.offset) { _, s in
      LineMark(x: .value("Time", s.x), y: .value("Value", s.median), series: .value("Series", "F\(w.window)"))
        .foregroundStyle(Color.accentColor.opacity(fade))
        .lineStyle(StrokeStyle(lineWidth: 2))
        .interpolationMethod(Self.curve)
    }
    if display.showActuals {
      actualMarks(w)
    }
    if let x = w.anchor?.0 ?? w.steps.first?.x {
      RuleMark(x: .value("Cutoff", x))
        .foregroundStyle(Color.secondary.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }
  }

  @ChartContentBuilder private func bandMarks(_ w: WindowModel<X>, band: Band, fade: Double) -> some ChartContent {
    let key = "b\(band.rawValue)-w\(w.window)"
    let style = Color.accentColor.opacity(band.opacity * fade)
    if let a = w.anchor {
      AreaMark(
        x: .value("Time", a.0),
        yStart: .value("Low", a.1),
        yEnd: .value("High", a.1),
        series: .value("Band", key))
        .foregroundStyle(style)
        .interpolationMethod(Self.curve)
    }
    ForEach(Array(w.steps.enumerated()), id: \.offset) { _, s in
      AreaMark(
        x: .value("Time", s.x),
        yStart: .value("Low", s.q[band.lower]),
        yEnd: .value("High", s.q[band.upper]),
        series: .value("Band", key))
        .foregroundStyle(style)
        .interpolationMethod(Self.curve)
    }
  }

  @ChartContentBuilder private func actualMarks(_ w: WindowModel<X>) -> some ChartContent {
    let pts: [(X, Double)] = w.steps.compactMap { s in s.actual.map { (s.x, $0) } }
    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
      LineMark(x: .value("Time", p.0), y: .value("Value", p.1), series: .value("Series", "A\(w.window)"))
        .foregroundStyle(Color.green)
        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
        .interpolationMethod(Self.curve)
      PointMark(x: .value("Time", p.0), y: .value("Value", p.1))
        .symbolSize(14)
        .foregroundStyle(Color.green)
    }
  }

  @ChartContentBuilder private var hoverMarks: some ChartContent {
    if let hx = hoverX {
      RuleMark(x: .value("Hover", hx))
        .foregroundStyle(Color.secondary.opacity(0.6))
    }
  }

  private var allXs: [X] { model.history.map(\.0) + model.windows.flatMap { $0.steps.map(\.x) } }

  private func tooltipPosition(_ point: CGPoint, in size: CGSize) -> CGPoint {
    CGPoint(
      x: min(max(point.x, 120), max(120, size.width - 120)),
      y: point.y < 100 ? point.y + 72 : point.y - 64
    )
  }

  private func nearest(to v: X) -> X? {
    allXs.min { abs($0.numeric - v.numeric) < abs($1.numeric - v.numeric) }
  }

  @ViewBuilder private func tooltip(at x: X) -> some View {
    let hist = model.history.first { $0.0 == x }?.1
    let steps = model.windows.compactMap { w in w.steps.first { $0.x == x }.map { (w.window, $0) } }
    VStack(alignment: .leading, spacing: 4) {
      Text(label(x)).font(.note.weight(.semibold))
      if let hist { row("Observed", hist, .primary) }
      ForEach(steps, id: \.0) { w, s in
        if steps.count > 1 { Text("Window \(w + 1)").font(.note).foregroundStyle(.secondary) }
        row("Median", s.median, .accentColor)
        row("P10 – P90", nil, .secondary, text: "\(Fmt.number(s.q[0])) – \(Fmt.number(s.q[8]))")
        if let a = s.actual { row("Actual", a, .green) }
      }
    }
    .padding(8)
    .background(.regularMaterial, in: Theme.shape)
    .shadow(radius: 2)
  }

  private func row(_ name: String, _ v: Double?, _ c: Color, text: String? = nil) -> some View {
    HStack(spacing: 8) {
      Circle().fill(c).frame(width: 6, height: 6)
      Text(name).font(.note).foregroundStyle(.secondary)
      Spacer(minLength: 10)
      Text(text ?? Fmt.number(v)).font(.note.monospacedDigit())
    }
    .frame(minWidth: 170)
  }

  private func label(_ x: X) -> String {
    if let d = x as? Date {
      let f = DateFormatter()
      f.timeZone = TimeZone(identifier: "UTC")
      f.dateFormat = Calendar.current.dateComponents(in: TimeZone(identifier: "UTC")!, from: d).hour == 0 ? "EEE d MMM yyyy" : "d MMM yyyy HH:mm"
      return f.string(from: d)
    }
    return "Step \(x)"
  }
}
