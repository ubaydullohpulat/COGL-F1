import Charts
import SwiftUI

/// X values the forecast chart can use: real timestamps or step indices.
protocol ChartX: Plottable, Comparable {
  var numeric: Double { get }
}

extension Date: ChartX { var numeric: Double { timeIntervalSince1970 } }
extension Int: ChartX { var numeric: Double { Double(self) } }

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

  var body: some View {
    let useDates = target.history.time != nil && windows.allSatisfy { $0.time != nil }
    if useDates {
      SeriesChart<Date>(model: build { t, _ in t.flatMap(Fmt.date) }, display: display)
    } else {
      SeriesChart<Int>(model: build { _, i in i }, display: display)
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
    var hist: [(X, Double)] = []
    for i in start..<n {
      guard let v = h.value[i], let x = xOf(h.time?[i], h.index[i]) else { continue }
      hist.append((x, v))
    }
    // Downsample very long histories for drawing speed.
    if hist.count > 3000 {
      let step = Double(hist.count) / 3000
      hist = stride(from: 0.0, to: Double(hist.count), by: step).map { hist[Int($0)] }
    }
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
    return SeriesModel(history: hist, windows: ws)
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
}

private struct SeriesChart<X: ChartX>: View {
  var model: SeriesModel<X>
  var display: ChartDisplay
  @State private var hoverX: X?

  var body: some View {
    Chart {
      historyMarks
      ForEach(model.windows, id: \.window) { w in
        windowMarks(w)
      }
      hoverMarks
    }
    .chartYScale(domain: .automatic(includesZero: false))
    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
    .chartLegend(.hidden)
    .chartOverlay { proxy in
      GeometryReader { geo in
        Rectangle().fill(.clear).contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
              guard let plot = proxy.plotFrame else { return }
              let x = loc.x - geo[plot].origin.x
              if let v: X = proxy.value(atX: x, as: X.self) { hoverX = nearest(to: v) }
            case .ended:
              hoverX = nil
            }
          }
      }
    }
  }

  @ChartContentBuilder private var historyMarks: some ChartContent {
    ForEach(Array(model.history.enumerated()), id: \.offset) { _, p in
      LineMark(x: .value("Time", p.0), y: .value("Value", p.1), series: .value("Series", "History"))
        .foregroundStyle(Color.primary.opacity(0.75))
        .lineStyle(StrokeStyle(lineWidth: 1.4))
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
    if let a = w.anchor {
      LineMark(x: .value("Time", a.0), y: .value("Value", a.1), series: .value("Series", "F\(w.window)"))
        .foregroundStyle(Color.accentColor.opacity(fade))
        .lineStyle(StrokeStyle(lineWidth: 2))
    }
    ForEach(Array(w.steps.enumerated()), id: \.offset) { _, s in
      LineMark(x: .value("Time", s.x), y: .value("Value", s.median), series: .value("Series", "F\(w.window)"))
        .foregroundStyle(Color.accentColor.opacity(fade))
        .lineStyle(StrokeStyle(lineWidth: 2))
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
    ForEach(Array(w.steps.enumerated()), id: \.offset) { _, s in
      AreaMark(
        x: .value("Time", s.x),
        yStart: .value("Low", s.q[band.lower]),
        yEnd: .value("High", s.q[band.upper]),
        series: .value("Band", key))
        .foregroundStyle(style)
    }
  }

  @ChartContentBuilder private func actualMarks(_ w: WindowModel<X>) -> some ChartContent {
    let pts: [(X, Double)] = w.steps.compactMap { s in s.actual.map { (s.x, $0) } }
    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
      LineMark(x: .value("Time", p.0), y: .value("Value", p.1), series: .value("Series", "A\(w.window)"))
        .foregroundStyle(Color.green)
        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
      PointMark(x: .value("Time", p.0), y: .value("Value", p.1))
        .symbolSize(14)
        .foregroundStyle(Color.green)
    }
  }

  @ChartContentBuilder private var hoverMarks: some ChartContent {
    if let hx = hoverX {
      RuleMark(x: .value("Hover", hx))
        .foregroundStyle(Color.secondary.opacity(0.6))
        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
          tooltip(at: hx)
        }
    }
  }

  private var allXs: [X] { model.history.map(\.0) + model.windows.flatMap { $0.steps.map(\.x) } }

  private func nearest(to v: X) -> X? {
    allXs.min { abs($0.numeric - v.numeric) < abs($1.numeric - v.numeric) }
  }

  @ViewBuilder private func tooltip(at x: X) -> some View {
    let hist = model.history.first { $0.0 == x }?.1
    let steps = model.windows.compactMap { w in w.steps.first { $0.x == x }.map { (w.window, $0) } }
    VStack(alignment: .leading, spacing: 3) {
      Text(label(x)).font(.caption.weight(.semibold))
      if let hist { row("Observed", hist, .primary) }
      ForEach(steps, id: \.0) { w, s in
        if steps.count > 1 { Text("Window \(w + 1)").font(.caption2).foregroundStyle(.secondary) }
        row("Median", s.median, .accentColor)
        row("P10 – P90", nil, .secondary, text: "\(Fmt.number(s.q[0])) – \(Fmt.number(s.q[8]))")
        if let a = s.actual { row("Actual", a, .green) }
      }
    }
    .padding(8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .shadow(radius: 2)
  }

  private func row(_ name: String, _ v: Double?, _ c: Color, text: String? = nil) -> some View {
    HStack(spacing: 6) {
      Circle().fill(c).frame(width: 6, height: 6)
      Text(name).font(.caption2).foregroundStyle(.secondary)
      Spacer(minLength: 10)
      Text(text ?? Fmt.number(v)).font(.caption.monospacedDigit())
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
