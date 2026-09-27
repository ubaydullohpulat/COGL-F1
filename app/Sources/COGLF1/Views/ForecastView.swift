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
  @AppStorage("forecast.showBottom") private var showBottom = true
  /// Share of the result area that the table takes, so it keeps its proportion when the window resizes.
  @AppStorage("forecast.bottomShare") private var bottomShare = 0.3
  @State private var dragStartShare: Double?
  @State private var chartZoom: Double = 1

  var body: some View {
    HStack(spacing: 0) {
      if state.dataset != nil {
        DataPanel().frame(width: DataPanel.width)
        Divider()
      }
      center.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }
    .inspector(isPresented: inspectorPresented) {
      ForecastInspector(display: $display)
        .inspectorColumnWidth(min: 290, ideal: 320, max: 400)
    }
    .toolbar {
      if state.dataset != nil {
        ToolbarItem(placement: .primaryAction) {
          Button { showInspector.toggle() } label: { Label("Parameters", systemImage: "sidebar.right") }
            .help("Show or hide forecast parameters")
        }
      }
    }
    .navigationTitle("Forecast")
  }

  private var inspectorPresented: Binding<Bool> {
    Binding(
      get: { showInspector && state.dataset != nil },
      set: { showInspector = $0 }
    )
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
                 ? "Set a column to Predict on the left."
                 : "Predicting \(state.targets.joined(separator: ", ")) for the next \(state.params.horizon) \(Freq.unit(state.sheet?.frequency, count: state.params.horizon)).")
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
    HStack(spacing: 12) {
      if let r = state.currentResult {
        Text("\(r.modelId ?? "") · \(Backend(rawValue: r.backend ?? "")?.short ?? "") · \(Fmt.duration(r.elapsedSeconds)) · \(r.numQueries) quer\(r.numQueries == 1 ? "y" : "ies")")
          .font(.note).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      if let r = state.currentResult {
        Button { state.export(r) } label: { Label("Export", systemImage: "square.and.arrow.up") }
          .controlSize(.large)
          .help("Save forecasts with all quantiles to Excel or CSV")
      }
      Button {
        Task { await state.runForecast() }
      } label: {
        HStack(spacing: 8) {
          if state.isForecasting { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
          Text(state.params.backtest ? "Compare" : "Run")
        }
        .frame(minWidth: 120)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .keyboardShortcut("r")
      .disabled(state.isForecasting || state.targets.isEmpty)
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
  }

  @ViewBuilder private func resultView(_ r: ForecastResult) -> some View {
    let group = r.groups.first { $0.key == groupKey } ?? r.groups.first
    let target = group?.targets.first { $0.name == targetName } ?? group?.targets.first
    GeometryReader { area in
    VStack(spacing: 0) {
      if !r.warnings.isEmpty {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
          Text(r.warnings.prefix(3).joined(separator: "\n")).font(.note)
          Spacer()
        }
        .padding(8).background(.yellow.opacity(0.1))
      }
      HStack(spacing: 8) {
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
          Text(t.name).font(.rowTitle.weight(.semibold))
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
      .padding(.horizontal, 16).padding(.top, 8)
      HStack {
        Legend(backtest: r.backtest, bands: display.bands).fixedSize()
        Spacer()
        HStack(spacing: Theme.space) {
          Button { chartZoom = max(1, chartZoom / 1.4); } label: { Image(systemName: "minus.magnifyingglass") }
            .help("Zoom out")
          Button { chartZoom = 1 } label: {
            Text("\(Int((chartZoom * 100).rounded()))%")
              .monospacedDigit()
              .frame(minWidth: 44)
          }
          .help("Back to 100%. Scroll sideways to see earlier history.")
          Button { chartZoom = min(12, chartZoom * 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
            .help("Zoom in")
        }
        .buttonStyle(.borderless)
        Button {
          copyChart(r: r, target: target)
        } label: {
          Label("Copy chart", systemImage: "doc.on.doc").font(.note)
        }
        .buttonStyle(.borderless)
        .help("Copy the chart as an image")
      }
      .padding(.horizontal, 16).padding(.top, 8)

      if let t = target {
        let ws = t.windows.filter { windowFilter == nil || $0.window == windowFilter }
        ForecastChart(target: t, windows: ws, display: display, horizon: r.horizon, zoom: $chartZoom)
          .padding(.horizontal, 16).padding(.vertical, 8)
          .frame(minHeight: 160)
        if let m = (windowFilter.flatMap { wf in t.windows.first { $0.window == wf }?.metrics }) ?? t.metrics {
          MetricsStrip(metrics: m).padding(.horizontal, 16).padding(.bottom, 8)
        }
      }
      resizeHandle(total: area.size.height)
      Picker("", selection: Binding(get: { bottomTab }, set: { bottomTab = $0; showBottom = true })) {
        Text("Forecast table").tag(0)
        Text("Run history (\(state.results.count))").tag(1)
        Text("Run details").tag(2)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 440)
      .frame(maxWidth: .infinity)
      .overlay(alignment: .trailing) {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) { showBottom.toggle() }
        } label: {
          Image(systemName: showBottom ? "chevron.down" : "chevron.up")
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(showBottom ? "Hide the table" : "Show the table")
      }
      .padding(8)
      if showBottom {
        Group {
          switch bottomTab {
          case 0:
            if let t = target { ForecastTable(target: t, windowFilter: windowFilter, levels: r.quantileLevels) }
          case 1: RunHistory()
          default: RunDetails(result: r)
          }
        }
        .frame(height: bottomHeight(total: area.size.height))
      }
    }
    }
    .onChange(of: r.resultId) { _, _ in
      windowFilter = nil
      chartZoom = 1
    }
  }

  /// The table never squeezes the chart below a readable height, and never shrinks to nothing.
  private func bottomHeight(total: CGFloat) -> CGFloat {
    let most = max(120, total - 320)
    return min(max(CGFloat(bottomShare) * total, 120), most)
  }

  /// The line between chart and table. Drag it to give either one more room.
  private func resizeHandle(total: CGFloat) -> some View {
    ZStack {
      Divider()
      if showBottom {
        Capsule().fill(.tertiary).frame(width: 36, height: 4)
      }
    }
    .frame(height: 12)
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .onHover { inside in
      guard showBottom else { return }
      if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    }
    .gesture(
      DragGesture(minimumDistance: 1, coordinateSpace: .global)
        .onChanged { value in
          guard showBottom, total > 0 else { return }
          if dragStartShare == nil { dragStartShare = Double(bottomHeight(total: total) / total) }
          let share = (dragStartShare ?? bottomShare) - Double(value.translation.height / total)
          bottomShare = min(max(share, Double(120 / total)), Double(max(120, total - 320) / total))
        }
        .onEnded { _ in dragStartShare = nil }
    )
    .help(showBottom ? "Drag to resize" : "")
  }

  @MainActor private func copyChart(r: ForecastResult, target: ForecastTarget?) {
    guard let t = target else { return }
    let view = ForecastChart(target: t, windows: t.windows.filter { windowFilter == nil || $0.window == windowFilter }, display: display, horizon: r.horizon, scrollable: false)
      .frame(width: 1200, height: 520)
      .padding(16)
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
          Text("P\(50 - widest.rawValue / 2)–P\(50 + widest.rawValue / 2)").font(.note).foregroundStyle(.secondary)
        }
      }
      if backtest { item(.green, "Actual") }
    }
  }
  private func item(_ c: Color, _ t: String) -> some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 14, height: 2.5)
      Text(t).font(.note).foregroundStyle(.secondary)
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
          Text(name).font(.note).foregroundStyle(.secondary).lineLimit(1)
          Text(value(key, pct)).font(.text.weight(.semibold).monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(Theme.fill, in: Theme.shape)
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
    .font(.text)
  }
}

struct RunHistory: View {
  @Environment(AppState.self) private var state
  var body: some View {
    List(state.results, selection: Binding(get: { state.currentResultId }, set: { state.currentResultId = $0 })) { r in
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(r.backtest ? "Backtest" : "Forecast") · h=\(r.horizon) · ctx=\(r.contextLength) · \(r.mode)")
            .font(.text.weight(.medium))
          Text("\(r.modelId ?? "") · \(r.backend ?? "") · \(flagSummary(r))")
            .font(.note).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        if let m = r.metrics {
          Text("MAE \(Fmt.number(m["mae"] ?? nil)) · WQL \(Fmt.number(m["wql"] ?? nil))")
            .font(.note.monospacedDigit())
        }
        Text(Fmt.duration(r.elapsedSeconds)).font(.note).foregroundStyle(.secondary)
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
      .font(.text.monospaced())
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
  @State private var showAdvanced = false

  var body: some View {
    @Bindable var state = state
    let freq = state.sheet?.frequency
    Form {
      Section("Forecast") {
        LabeledContent("How far ahead") {
          HStack(spacing: Theme.space) {
            TextField("", value: $state.params.horizon, format: .number).frame(width: 56)
            Stepper("", value: $state.params.horizon, in: 1...4096).labelsHidden()
            Text(Freq.unit(freq, count: state.params.horizon)).foregroundStyle(.secondary)
            HintButton(text: "How much of the future to predict. Shorter forecasts are more reliable.")
          }
        }
        let presets = Freq.presets(freq)
        if !presets.isEmpty {
          HStack(spacing: Theme.space) {
            ForEach(presets, id: \.steps) { p in
              Button(p.title) { state.params.horizon = p.steps }
                .frame(maxWidth: .infinity)
            }
          }
        }
        if state.targets.count > 1 || state.idColumn != nil {
          HStack(spacing: Theme.space) {
            Picker("Predict them", selection: $state.params.mode) {
              Text("Together").tag("joint")
              Text("Separately").tag("independent")
            }
            HintButton(text: "Together uses how the series move with each other. Separately forecasts each one on its own.")
          }
        }
      }

      Section {
        HStack(spacing: Theme.space) {
          Toggle("Test on recent data", isOn: $state.params.backtest)
          HintButton(text: "Hides the latest stretch, predicts it, and shows how close the forecast was to what really happened.")
        }
      }

      Section("Chart") {
        HStack(spacing: Theme.space) {
          Picker("Likely range", selection: rangeChoice) {
            Text("Hidden").tag(0)
            Text("Narrow").tag(1)
            Text("Wide").tag(2)
            Text("Both").tag(3)
          }
          HintButton(text: "The shaded area is where the real value will probably fall. Wide covers about 8 cases in 10, narrow about 4 in 10.")
        }
        Picker("History on screen", selection: $display.historyPoints) {
          Text("Automatic").tag(0)
          ForEach([100, 250, 500, 1000, 2500, 5000], id: \.self) { Text("\($0) points").tag($0) }
        }
      }

      Section {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() }
        } label: {
          HStack(spacing: Theme.space) {
            Image(systemName: "chevron.right")
              .rotationEffect(.degrees(showAdvanced ? 90 : 0))
              .font(.text.weight(.semibold))
              .frame(width: 28, height: 28)
            Text("More options")
              .font(.text)
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
          .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }
        .buttonStyle(.plain)
        if showAdvanced {
          Toggle("Learn from all history", isOn: $autoContext)
            .onChange(of: autoContext) { _, v in state.params.contextLength = v ? nil : (state.params.contextLength ?? 1024) }
          if !autoContext {
            LabeledContent("Points to learn from") {
              HStack {
                TextField("", value: Binding(get: { state.params.contextLength ?? 1024 }, set: { state.params.contextLength = max(8, min($0, 15360)) }), format: .number)
                  .frame(width: 72)
                Stepper("", value: Binding(get: { state.params.contextLength ?? 1024 }, set: { state.params.contextLength = max(32, min($0, 15360)) }), in: 32...15360, step: 32)
                  .labelsHidden()
              }
            }
          }
          if state.params.backtest {
            Stepper(value: $state.params.backtestWindows, in: 1...50) {
              LabeledContent("Number of tests", value: "\(state.params.backtestWindows)")
            }
            if state.params.backtestWindows >= 2 {
              Toggle("Tests follow one another", isOn: Binding(
                get: { state.params.backtestStep == nil },
                set: { state.params.backtestStep = $0 ? nil : max(1, state.params.horizon) }
              ))
              if let step = state.params.backtestStep {
                Stepper(value: Binding(
                  get: { step },
                  set: { state.params.backtestStep = max(1, $0) }
                ), in: 1...4096) {
                  LabeledContent("Gap between tests", value: "\(step)")
                }
              }
            }
            Toggle("Show real values", isOn: $display.showActuals)
          }
          Toggle("Show dots on history", isOn: $display.showPoints)
          LabeledContent("Shaded ranges") {
            HStack {
              ForEach(Band.allCases) { b in
                Toggle(b.label, isOn: Binding(
                  get: { display.bands.contains(b) },
                  set: { if $0 { display.bands.insert(b) } else { display.bands.remove(b) } }))
                  .toggleStyle(.button)
              }
            }
          }
          hintedToggle("Average both directions", "Also forecast the flipped series and average the two. Often steadier, and slower.", $state.params.useSymmetricAveraging)
          hintedToggle("Standardize the data", "Scale each series before forecasting, then scale the result back.", $state.params.useZnorm)
          hintedToggle("Keep results at zero or above", "For sales and counts that never go below zero.", $state.params.makePositive)
          hintedToggle("Keep the ranges in order", "Makes the lower estimate stay below the upper one.", $state.params.sortQuantiles)
          HStack(spacing: Theme.space) {
            Picker("If future values run short", selection: $state.params.paddingMode) {
              Text("Leave empty").tag("none")
              Text("Repeat last").tag("edge")
            }
            HintButton(text: "When known future values stop early, leave the rest empty or repeat the last value.")
          }
          if state.status?.loaded == true {
            ModelFlagsEditor()
          }
          Button("Reset to defaults") {
            state.params = ForecastParams()
            autoContext = true
            display = ChartDisplay()
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { autoContext = state.params.contextLength == nil }
  }

  /// The everyday choice behind the four shaded-range toggles.
  private var rangeChoice: Binding<Int> {
    Binding(
      get: {
        if display.bands.isEmpty { return 0 }
        if display.bands == [.p30p70] { return 1 }
        if display.bands == [.p10p90] { return 2 }
        return 3
      },
      set: { display.bands = [[], [.p30p70], [.p10p90], [.p10p90, .p30p70]][$0] }
    )
  }

  private func hintedToggle(_ title: String, _ hint: String, _ isOn: Binding<Bool>) -> some View {
    HStack(spacing: Theme.space) {
      Toggle(title, isOn: isOn)
      HintButton(text: hint)
    }
  }
}

// MARK: - Empty states

struct EmptyDataState: View {
  @Environment(AppState.self) private var state
  var body: some View {
    EmptyState(title: "Drop a CSV or Excel file", systemImage: "square.and.arrow.down.on.square") {
      Button { state.chooseFile() } label: { Label("Open file", systemImage: "folder") }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      let recent = state.recentFiles.filter { FileManager.default.fileExists(atPath: $0) }
      if !recent.isEmpty {
        VStack(spacing: Theme.space) {
          HStack {
            Text("Recent").font(.text).foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { state.clearRecentFiles() }
              .buttonStyle(.borderless)
          }
          VStack(spacing: 0) {
            ForEach(Array(recent.enumerated()), id: \.element) { i, path in
              if i > 0 { Divider().padding(.leading, 44) }
              RecentFileRow(path: path) {
                Task { await state.openFile(URL(fileURLWithPath: path)) }
              }
            }
          }
          .background(Theme.fill, in: Theme.shape)
        }
        .frame(maxWidth: 640)
      }
      VStack(spacing: Theme.space) {
        Text("Samples")
          .font(.text)
          .foregroundStyle(.secondary)
        HStack(spacing: Theme.space * 2) {
          ForEach(Samples.all) { s in
            ChoiceCard(title: s.title, systemImage: s.icon) {
              Task { await state.openSample(s.file) }
            }
          }
        }
      }
      .frame(maxWidth: 640)
    }
  }
}

struct RecentFileRow: View {
  var path: String
  var action: () -> Void

  var body: some View {
    let url = URL(fileURLWithPath: path)
    Button(action: action) {
      HStack(spacing: Theme.space * 1.5) {
        Image(systemName: ["csv", "tsv", "txt"].contains(url.pathExtension.lowercased()) ? "doc.text" : "tablecells")
          .font(.rowTitle)
          .foregroundStyle(.tint)
          .frame(width: 20)
        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: Theme.space)
        Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      .font(.text)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(path)
  }
}

enum Samples {
  struct Sample: Identifiable {
    var file: String
    var title: String
    var icon: String
    var id: String { file }
  }
  static let all: [Sample] = [
    .init(file: "retail_sales.csv", title: "Retail sales", icon: "cart"),
    .init(file: "energy_load.csv", title: "Energy load", icon: "bolt"),
    .init(file: "store_revenue.xlsx", title: "Store revenue", icon: "building.2"),
  ]
}

#Preview("Empty forecast") {
  EmptyDataState()
    .environment(AppState())
    .frame(width: 980, height: 680)
}

#Preview("Parameters") {
  ForecastInspector(display: .constant(ChartDisplay()))
    .environment(AppState())
    .frame(width: 340, height: 720)
}

struct SetupChecklist: View {
  @Environment(AppState.self) private var state
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Welcome to COGL-F1").font(.pageTitle.weight(.semibold))
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
    HStack(alignment: .top, spacing: 16) {
      ZStack {
        Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15)).frame(width: 30, height: 30)
        if done { Image(systemName: "checkmark").foregroundStyle(.white).font(.text.bold()) }
        else { Text("\(n)").font(.text.bold()).foregroundStyle(.tint) }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.text.weight(.semibold))
        Text(detail).font(.text).foregroundStyle(.secondary)
        if !done { action() }
      }
      Spacer()
    }
    .padding(16)
    .background(Theme.fill, in: Theme.shape)
  }
}
