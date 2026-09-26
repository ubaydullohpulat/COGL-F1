import AppKit
import Charts
import SwiftUI

struct ForecastView: View {
  @Environment(AppState.self) private var state
  @State private var showInspector = true
  @State private var display = ChartDisplay()
  @State private var groupKey: String?
  @State private var targetName: String?
  @State private var windowFilter: Int? = nil  // nil = all windows
  @State private var bottomTab = 0

  var body: some View {
    HStack(spacing: 0) {
      DataPanel().frame(width: 300)
      Divider()
      center.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }
    .inspector(isPresented: $showInspector) {
      ForecastInspector(display: $display)
        .inspectorColumnWidth(min: 290, ideal: 320, max: 400)
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { showInspector.toggle() } label: { Label("Parameters", systemImage: "sidebar.right") }
          .help("Show or hide forecast parameters")
      }
    }
    .navigationTitle("Forecast")
  }

  @ViewBuilder private var center: some View {
    if !state.engine.isRunning || !state.hasModel {
      SetupChecklist()
    } else if state.dataset == nil {
      EmptyDataState()
    } else {
      VStack(spacing: 0) {
        runBar
        Divider()
        if let r = state.currentResult {
          resultView(r)
        } else {
          ContentUnavailableView {
            Label("Ready to forecast", systemImage: "chart.line.uptrend.xyaxis")
          } description: {
            Text(state.targets.isEmpty
                 ? "Mark at least one column as Target on the left."
                 : "Forecasting \(state.targets.joined(separator: ", ")) \(state.params.horizon) steps ahead. Press Run (⌘R).")
          } actions: {
            Button("Run forecast") { Task { await state.runForecast() } }
              .buttonStyle(.borderedProminent)
              .disabled(state.targets.isEmpty || state.isForecasting)
          }
          .frame(maxHeight: .infinity)
        }
      }
    }
  }

  private var runBar: some View {
    @Bindable var state = state
    return HStack(spacing: 12) {
      Button {
        Task { await state.runForecast() }
      } label: {
        HStack(spacing: 6) {
          if state.isForecasting { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
          Text(state.params.backtest ? "Run backtest" : "Run forecast")
        }
        .frame(minWidth: 120)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .keyboardShortcut("r")
      .disabled(state.isForecasting || state.targets.isEmpty)

      HStack(spacing: 6) {
        Text("Horizon").foregroundStyle(.secondary)
        TextField("", value: $state.params.horizon, format: .number)
          .frame(width: 60)
          .textFieldStyle(.roundedBorder)
        Stepper("", value: $state.params.horizon, in: 1...4096).labelsHidden()
      }
      Toggle("Backtest", isOn: $state.params.backtest)
        .toggleStyle(.switch)
        .fixedSize()
        .help("Hide the last horizon of history, forecast it, and score against what actually happened.")

      Spacer()
      if let r = state.currentResult {
        Text("\(r.modelId ?? "") · \(Backend(rawValue: r.backend ?? "")?.short ?? "") · \(Fmt.duration(r.elapsedSeconds)) · \(r.numQueries) quer\(r.numQueries == 1 ? "y" : "ies")")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Button { state.export(r) } label: { Label("Export", systemImage: "square.and.arrow.up") }
          .help("Save forecasts with all quantiles to Excel or CSV")
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
  }

  @ViewBuilder private func resultView(_ r: ForecastResult) -> some View {
    let group = r.groups.first { $0.key == groupKey } ?? r.groups.first
    let target = group?.targets.first { $0.name == targetName } ?? group?.targets.first
    VStack(spacing: 0) {
      if !r.warnings.isEmpty {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
          Text(r.warnings.prefix(3).joined(separator: "\n")).font(.caption)
          Spacer()
        }
        .padding(8).background(.yellow.opacity(0.1))
      }
      HStack(spacing: 10) {
        if r.groups.count > 1 {
          Picker("Series", selection: Binding(get: { group?.key ?? "" }, set: { groupKey = $0 })) {
            ForEach(r.groups) { Text($0.key).tag($0.key) }
          }
          .frame(maxWidth: 220)
        }
        if (group?.targets.count ?? 0) > 1 {
          Picker("Target", selection: Binding(get: { target?.name ?? "" }, set: { targetName = $0 })) {
            ForEach(group?.targets ?? []) { Text($0.name).tag($0.name) }
          }
          .pickerStyle(.segmented)
          .frame(maxWidth: 420)
        } else if let t = target {
          Text(t.name).font(.title3.weight(.semibold))
        }
        if r.backtest && (target?.windows.count ?? 0) > 1 {
          Picker("Window", selection: $windowFilter) {
            Text("All windows").tag(Int?.none)
            ForEach(target?.windows ?? []) { w in Text("Window \(w.window + 1)").tag(Int?.some(w.window)) }
          }
          .frame(maxWidth: 170)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16).padding(.top, 10)
      HStack {
        Legend(backtest: r.backtest, bands: display.bands).fixedSize()
        Spacer()
        Button {
          copyChart(r: r, target: target)
        } label: {
          Label("Copy chart", systemImage: "doc.on.doc").font(.caption)
        }
        .buttonStyle(.borderless)
        .help("Copy the chart as an image")
      }
      .padding(.horizontal, 16).padding(.top, 6)

      if let t = target {
        let ws = t.windows.filter { windowFilter == nil || $0.window == windowFilter }
        ForecastChart(target: t, windows: ws, display: display, horizon: r.horizon)
          .padding(.horizontal, 16).padding(.vertical, 10)
          .frame(minHeight: 280)
        if let m = (windowFilter.flatMap { wf in t.windows.first { $0.window == wf }?.metrics }) ?? t.metrics {
          MetricsStrip(metrics: m).padding(.horizontal, 16).padding(.bottom, 8)
        }
      }
      Divider()
      Picker("", selection: $bottomTab) {
        Text("Forecast table").tag(0)
        Text("Run history (\(state.results.count))").tag(1)
        Text("Run details").tag(2)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 440)
      .padding(8)
      Group {
        switch bottomTab {
        case 0:
          if let t = target { ForecastTable(target: t, windowFilter: windowFilter, levels: r.quantileLevels) }
        case 1: RunHistory()
        default: RunDetails(result: r)
        }
      }
      .frame(height: 220)
    }
    .onChange(of: r.resultId) { _, _ in windowFilter = nil }
  }

  @MainActor private func copyChart(r: ForecastResult, target: ForecastTarget?) {
    guard let t = target else { return }
    let view = ForecastChart(target: t, windows: t.windows.filter { windowFilter == nil || $0.window == windowFilter }, display: display, horizon: r.horizon)
      .frame(width: 1200, height: 520)
      .padding(20)
      .background(Color.white)
      .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    if let img = renderer.nsImage {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([img])
    }
  }
}

struct Legend: View {
  var backtest: Bool
  var bands: Set<Band>
  var body: some View {
    HStack(spacing: 12) {
      item(Color.primary.opacity(0.75), "History")
      item(.accentColor, "Median")
      if let widest = Band.allCases.first(where: { bands.contains($0) }) {
        HStack(spacing: 4) {
          RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.25)).frame(width: 14, height: 9)
          Text("P\(50 - widest.rawValue / 2)–P\(50 + widest.rawValue / 2)").font(.caption2).foregroundStyle(.secondary)
        }
      }
      if backtest { item(.green, "Actual") }
    }
  }
  private func item(_ c: Color, _ t: String) -> some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 14, height: 2.5)
      Text(t).font(.caption2).foregroundStyle(.secondary)
    }
  }
}

struct MetricsStrip: View {
  var metrics: Metrics
  private let items: [(String, String, String, Bool)] = [
    ("mae", "MAE", "Mean absolute error of the median forecast", false),
    ("rmse", "RMSE", "Root mean squared error", false),
    ("mape", "MAPE", "Mean absolute percentage error (%)", true),
    ("smape", "sMAPE", "Symmetric MAPE (%)", true),
    ("mase", "MASE", "MAE scaled by the in-sample one-step naive error (<1 beats naive)", false),
    ("wql", "WQL", "Weighted quantile loss over all 9 quantiles (probabilistic accuracy)", false),
    ("coverage_80", "Cover 80", "% of actuals inside P10–P90 (ideal ≈ 80)", true),
    ("skill_vs_naive", "Skill", "1 − MAE / MAE of repeating the last value (higher is better)", false),
  ]
  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
      ForEach(items, id: \.0) { key, name, help, pct in
        VStack(alignment: .leading, spacing: 2) {
          Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
          Text(value(key, pct)).font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .help(help)
      }
    }
  }
  private func value(_ k: String, _ pct: Bool) -> String {
    guard let v = metrics[k] ?? nil else { return "—" }
    return pct ? String(format: "%.1f%%", v) : Fmt.number(v, digits: abs(v) >= 100 ? 1 : 3)
  }
}

struct ForecastTable: View {
  var target: ForecastTarget
  var windowFilter: Int?
  var levels: [Double]

  struct Row: Identifiable {
    var id: String
    var window: Int
    var step: Int
    var time: String
    var median: Double?
    var q: [Double?]
    var actual: Double?
  }

  var rows: [Row] {
    target.windows.filter { windowFilter == nil || $0.window == windowFilter }.flatMap { w in
      w.index.indices.map { i in
        Row(id: "\(w.window)-\(i)", window: w.window + 1, step: i + 1,
            time: w.time.map { Fmt.shortDate($0[i]) } ?? "#\(w.index[i])",
            median: w.median[i], q: w.quantiles.map { $0[i] }, actual: w.actual?[i] ?? nil)
      }
    }
  }

  var body: some View {
    let hasActual = target.windows.contains { $0.actual != nil }
    let multi = target.windows.count > 1
    Table(rows) {
      TableColumn("W") { r in Text(multi ? "\(r.window)" : "") }.width(multi ? 24 : 0)
      TableColumn("Step") { r in Text("\(r.step)").monospacedDigit() }.width(40)
      TableColumn("Time") { r in Text(r.time) }.width(min: 90, ideal: 130)
      TableColumn("P10") { r in Text(Fmt.number(r.q[0])).monospacedDigit().foregroundStyle(.secondary) }
      TableColumn("P30") { r in Text(Fmt.number(r.q[2])).monospacedDigit().foregroundStyle(.secondary) }
      TableColumn("Median") { r in Text(Fmt.number(r.median)).monospacedDigit().fontWeight(.semibold) }
      TableColumn("P70") { r in Text(Fmt.number(r.q[6])).monospacedDigit().foregroundStyle(.secondary) }
      TableColumn("P90") { r in Text(Fmt.number(r.q[8])).monospacedDigit().foregroundStyle(.secondary) }
      TableColumn("Actual") { r in Text(hasActual ? Fmt.number(r.actual) : "").monospacedDigit().foregroundStyle(.green) }
    }
    .font(.callout)
  }
}

struct RunHistory: View {
  @Environment(AppState.self) private var state
  var body: some View {
    List(state.results, selection: Binding(get: { state.currentResultId }, set: { state.currentResultId = $0 })) { r in
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(r.backtest ? "Backtest" : "Forecast") · h=\(r.horizon) · ctx=\(r.contextLength) · \(r.mode)")
            .font(.callout.weight(.medium))
          Text("\(r.modelId ?? "") · \(r.backend ?? "") · \(flagSummary(r))")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        if let m = r.metrics {
          Text("MAE \(Fmt.number(m["mae"] ?? nil)) · WQL \(Fmt.number(m["wql"] ?? nil))")
            .font(.caption.monospacedDigit())
        }
        Text(Fmt.duration(r.elapsedSeconds)).font(.caption).foregroundStyle(.secondary)
      }
      .tag(r.resultId)
    }
  }

  private func flagSummary(_ r: ForecastResult) -> String {
    let off = r.flags.filter { $0.value.boolValue == false && $0.key != "use_frozen_running_stats" }.map { $0.key.replacingOccurrences(of: "use_", with: "") }
    return off.isEmpty ? "default flags" : "off: " + off.sorted().joined(separator: ", ")
  }
}

struct RunDetails: View {
  var result: ForecastResult
  var body: some View {
    ScrollView {
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
        row("Model", result.modelId ?? "—")
        row("Backend", result.backend ?? "—")
        row("Horizon", "\(result.horizon)")
        row("Context length", "\(result.contextLength)")
        row("Mode", result.mode)
        row("Elapsed", Fmt.duration(result.elapsedSeconds))
        ForEach(result.flags.keys.sorted(), id: \.self) { k in row(k, result.flags[k]!.description) }
      }
      .font(.callout.monospaced())
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .textSelection(.enabled)
    }
  }
  private func row(_ k: String, _ v: String) -> some View {
    GridRow {
      Text(k).foregroundStyle(.secondary)
      Text(v)
    }
  }
}

// MARK: - Inspector

struct ForecastInspector: View {
  @Environment(AppState.self) private var state
  @Binding var display: ChartDisplay
  @State private var autoContext = true

  var body: some View {
    @Bindable var state = state
    Form {
      Section("Forecast") {
        LabeledContent("Horizon") {
          HStack {
            TextField("", value: $state.params.horizon, format: .number).frame(width: 64)
            Stepper("", value: $state.params.horizon, in: 1...4096).labelsHidden()
          }
        }
        .help("How many future steps to predict (TimesFM 3 decodes the whole horizon in one pass).")
        Toggle("Use all available history", isOn: $autoContext)
          .onChange(of: autoContext) { _, v in state.params.contextLength = v ? nil : (state.params.contextLength ?? 1024) }
        if !autoContext {
          LabeledContent("Context length") {
            HStack {
              TextField("", value: Binding(get: { state.params.contextLength ?? 1024 }, set: { state.params.contextLength = max(8, min($0, 15360)) }), format: .number)
                .frame(width: 70)
              Stepper("", value: Binding(get: { state.params.contextLength ?? 1024 }, set: { state.params.contextLength = max(32, min($0, 15360)) }), in: 32...15360, step: 32)
                .labelsHidden()
            }
          }
          .help("Most recent points fed to the model (≤ 15,360). Longer context helps with long seasonality.")
        }
        Picker("Mode", selection: $state.params.mode) {
          Text("Joint (multivariate)").tag("joint")
          Text("Independent").tag("independent")
        }
        .help("Joint lets TimesFM 3's variate attention learn cross-series structure between targets. Independent forecasts each target alone.")
      }

      Section("Backtest") {
        Toggle("Hold out & score", isOn: $state.params.backtest)
        Stepper(value: $state.params.backtestWindows, in: 1...50) {
          LabeledContent("Windows", value: "\(state.params.backtestWindows)")
        }
        .disabled(!state.params.backtest)
        .help("Number of rolling-origin windows, each one horizon apart. Metrics are averaged.")
        LabeledContent("Step") {
          TextField("", value: $state.params.backtestStep, format: .number, prompt: Text("horizon"))
            .frame(width: 90)
            .fixedSize()
        }
        .disabled(!state.params.backtest || state.params.backtestWindows < 2)
      }

      Section("Inference flags") {
        Toggle("Symmetric averaging", isOn: $state.params.useSymmetricAveraging)
          .help("use_symmetric_averaging: also forecast the negated series and average. Often more robust, 2× compute.")
        Toggle("Z-normalize inputs", isOn: $state.params.useZnorm)
          .help("use_znorm: standardize each series (and covariates) before the model, then undo on the output.")
        Toggle("Force non-negative", isOn: $state.params.makePositive)
          .help("make_positive: clamp forecasts at 0 for series whose history is non-negative (sales, counts).")
        Toggle("Sort quantiles", isOn: $state.params.sortQuantiles)
          .help("sort_quantiles: guarantee P10 ≤ … ≤ P90 (fixes quantile crossing).")
        Picker("Covariate padding", selection: $state.params.paddingMode) {
          Text("None").tag("none")
          Text("Edge (repeat last)").tag("edge")
        }
        .help("padding_mode: 'edge' extends future covariates that are shorter than the horizon by repeating their last value.")
      }

      Section("Model flags") {
        if state.status?.loaded == true {
          ModelFlagsEditor()
        } else {
          Text("Load a model to change its flags.").foregroundStyle(.secondary)
        }
      }

      Section("Display") {
        HStack {
          ForEach(Band.allCases) { b in
            Toggle(b.label, isOn: Binding(
              get: { display.bands.contains(b) },
              set: { if $0 { display.bands.insert(b) } else { display.bands.remove(b) } }))
              .toggleStyle(.button)
          }
        }
        .help("Prediction intervals to shade: 80% = P10–P90, 60% = P20–P80, 40% = P30–P70, 20% = P40–P60.")
        LabeledContent("History shown") {
          Picker("", selection: $display.historyPoints) {
            Text("Auto").tag(0)
            ForEach([100, 250, 500, 1000, 2500, 5000], id: \.self) { Text("\($0)").tag($0) }
          }
          .labelsHidden()
          .frame(width: 90)
        }
        Toggle("Show actuals", isOn: $display.showActuals)
        Toggle("Show history points", isOn: $display.showPoints)
      }

      Section {
        Button("Reset parameters") {
          state.params = ForecastParams()
          autoContext = true
          display = ChartDisplay()
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { autoContext = state.params.contextLength == nil }
  }
}

// MARK: - Empty states

struct EmptyDataState: View {
  @Environment(AppState.self) private var state
  var body: some View {
    VStack(spacing: 22) {
      Image(systemName: "square.and.arrow.down.on.square")
        .font(.system(size: 54, weight: .light))
        .foregroundStyle(.tint)
      VStack(spacing: 6) {
        Text("Drop a CSV or Excel file").font(.title2.weight(.semibold))
        Text("One column per series (wide) or one row per id and date (long). A date column is detected automatically.")
          .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
      }
      Button { state.chooseFile() } label: { Label("Open file…", systemImage: "folder") }
        .buttonStyle(.borderedProminent).controlSize(.large)
      VStack(spacing: 8) {
        Text("Or try a sample").font(.caption).foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 230))], spacing: 10) {
          ForEach(Samples.all, id: \.file) { s in
            Button {
              Task { await state.openSample(s.file) }
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Label(s.title, systemImage: s.icon).font(.callout.weight(.medium))
                Text(s.subtitle).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
          }
        }
        .frame(maxWidth: 720)
      }
    }
    .padding(24)
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
  }
}

enum Samples {
  struct Sample { var file: String; var title: String; var subtitle: String; var icon: String }
  static let all: [Sample] = [
    .init(file: "retail_sales.csv", title: "Retail sales", subtitle: "Daily sales & visits, temperature, planned promos", icon: "cart"),
    .init(file: "energy_load.csv", title: "Energy load", subtitle: "Hourly load with a weather forecast covariate", icon: "bolt"),
    .init(file: "store_revenue.xlsx", title: "Store revenue", subtitle: "Monthly revenue for 5 stores (long format, Excel)", icon: "building.2"),
  ]
}

struct SetupChecklist: View {
  @Environment(AppState.self) private var state
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Welcome to COGL-F1").font(.largeTitle.weight(.semibold))
      Text("Zero-shot forecasting with Google's TimesFM 3, running locally on your Mac.")
        .foregroundStyle(.secondary)
      step(1, "Install the forecasting runtime", done: state.engine.isRunning,
           detail: "Python environment with TimesFM 3, MLX and PyTorch (one-time, ≈ 1 GB).") {
        RuntimeSetupControls()
      }
      step(2, "Download the TimesFM 3 model", done: state.hasModel,
           detail: "330M parameters · 1.32 GB from Hugging Face (google/timesfm-3.0-pytorch).") {
        Button("Go to Models") { state.section = .models }.buttonStyle(.borderedProminent)
      }
      step(3, "Open your data and forecast", done: false, detail: "CSV or Excel, then press Run.") { EmptyView() }
    }
    .frame(maxWidth: 620)
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func step<C: View>(_ n: Int, _ title: String, done: Bool, detail: String, @ViewBuilder action: () -> C) -> some View {
    HStack(alignment: .top, spacing: 14) {
      ZStack {
        Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15)).frame(width: 30, height: 30)
        if done { Image(systemName: "checkmark").foregroundStyle(.white).font(.callout.bold()) }
        else { Text("\(n)").font(.callout.bold()).foregroundStyle(.tint) }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary)
        if !done { action() }
      }
      Spacer()
    }
    .padding(14)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }
}
