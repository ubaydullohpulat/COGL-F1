import AppKit
import SwiftUI

struct RuntimeSetupControls: View {
  @Environment(AppState.self) private var state
  /// The line that says which Python is used and where. The welcome page leaves it out.
  var showsDetails = true

  var body: some View {
    let e = state.engine
    VStack(alignment: .leading, spacing: 8) {
      switch e.state {
      case .needsInstall:
        Button {
          Task {
            await e.installRuntime()
            await state.afterEngineStart()
          }
        } label: { Label("Install runtime", systemImage: "arrow.down.circle.fill") }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
        if showsDetails {
          Text("Installs into \(EngineManager.runtimeDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
            .font(.note).foregroundStyle(.secondary)
        }
      case .installing(let msg):
        ProgressView(value: e.installProgress) { Text(msg).font(.text) }
        Text(e.logs.last ?? "").font(.note.monospaced()).foregroundStyle(.secondary).lineLimit(1)
      case .starting, .checking:
        HStack { ProgressView().controlSize(.small); Text("Starting engine…") }
      case .failed(let msg):
        Text(msg).foregroundStyle(.red).font(.text)
        HStack {
          Button("Restart engine") { Task { await e.start(); await state.afterEngineStart() } }
          Button("Reinstall runtime") { Task { await e.installRuntime(); await state.afterEngineStart() } }
        }
      case .stopped:
        Button("Start engine") { Task { await e.start(); await state.afterEngineStart() } }
      case .running:
        Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      }
    }
  }
}

struct ServerView: View {
  @Environment(AppState.self) private var state
  @State private var showLog = false

  var body: some View {
    let e = state.engine
    Form {
      Section {
        HStack(spacing: Theme.space * 2) {
          Image(systemName: statusIcon)
            .font(.badgeIcon)
            .foregroundStyle(statusColor)
            .frame(width: 40)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(statusTitle).font(.rowTitle.weight(.semibold))
            Text("The engine runs the model on this Mac. Nothing leaves your computer.")
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: Theme.space)
          if e.isRunning {
            Button("Restart") { Task { await e.restart(); await state.afterEngineStart() } }
            Button("Stop") { e.stop() }
          }
        }
        .controlSize(.large)
        .padding(.vertical, Theme.space / 2)
        if !e.isRunning {
          RuntimeSetupControls()
        }
      }

      if e.isRunning, let h = e.health {
        Section("Now") {
          LabeledContent("Model", value: loadedName ?? "None loaded")
          if let s = state.status, s.loaded {
            LabeledContent("Runs on", value: Backend(rawValue: s.backend ?? "")?.title ?? "—")
            if let m = s.mlxActiveBytes { LabeledContent("Model memory", value: Fmt.bytes(Int64(m))) }
          }
          if let r = state.status?.peakRssBytes { LabeledContent("Most memory used", value: Fmt.bytes(Int64(r))) }
        }

        Section("This Mac") {
          LabeledContent("Apple GPU", value: available(h.backends["mlx"]))
          LabeledContent("Metal", value: h.backends["torch"]?.mps == true ? "Available" : "Not available")
          LabeledContent("CPU", value: available(h.backends["torch"]))
        }

        Section("Versions") {
          LabeledContent("TimesFM", value: h.timesfmVersion ?? "—")
          LabeledContent("Python", value: h.python)
          LabeledContent("Address") {
            Text(e.baseURL.absoluteString).textSelection(.enabled)
          }
          HStack {
            Button("Refresh") { Task { await state.refreshStatus() } }
            Button("Reinstall…") { Task { await e.installRuntime(); await state.afterEngineStart() } }
              .help("Download and set up the forecasting runtime again")
            Spacer()
          }
        }
      }

      Section("Use it from your own code") {
        APIDocs(base: e.isRunning ? e.baseURL.absoluteString : "http://127.0.0.1:<port>/")
      }

      Section {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) { showLog.toggle() }
        } label: {
          HStack(spacing: Theme.space) {
            Image(systemName: "chevron.right")
              .rotationEffect(.degrees(showLog ? 90 : 0))
              .font(.text.weight(.semibold))
              .frame(width: 28, height: 28)
            Text("Log")
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
          .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }
        .buttonStyle(.plain)
        if showLog {
          LogView(lines: e.logs).frame(height: 280)
          Button("Copy log") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(e.logs.joined(separator: "\n"), forType: .string)
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: 860)
    .frame(maxWidth: .infinity)
    .navigationTitle("Engine")
    .task { await state.refreshStatus() }
  }

  private var loadedName: String? {
    guard let s = state.status, s.loaded, let id = s.modelId else { return nil }
    return state.models.first { $0.id == id }?.displayName ?? id
  }

  private func available(_ b: HealthInfo.Backend?) -> String {
    b?.available == true ? "Available" : "Not available"
  }

  private var statusTitle: String {
    switch state.engine.state {
    case .running: return "Running"
    case .starting, .checking: return "Starting"
    case .installing: return "Installing"
    case .needsInstall: return "Not installed"
    case .failed: return "Something went wrong"
    case .stopped: return "Stopped"
    }
  }

  private var statusIcon: String {
    switch state.engine.state {
    case .running: return "checkmark.circle.fill"
    case .starting, .checking, .installing: return "clock.fill"
    case .needsInstall: return "arrow.down.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .stopped: return "pause.circle.fill"
    }
  }

  private var statusColor: Color {
    switch state.engine.state {
    case .running: return .green
    case .starting, .checking, .installing: return .orange
    case .needsInstall: return .accentColor
    case .failed: return .red
    case .stopped: return .secondary
    }
  }
}

struct APIDocs: View {
  var base: String
  @State private var example = 0

  private var examples: [(title: String, code: String)] {
    [
      ("Forecast", """
      curl -s \(base)v1/forecast -H 'Content-Type: application/json' -d '{
        "inputs": [[1,2,3,4,5,6,7,8,9,10,11,12]],
        "horizon": 6,
        "params": {"use_symmetric_averaging": false, "make_positive": true}
      }'
      """),
      ("With helpers", """
      curl -s \(base)v1/forecast -H 'Content-Type: application/json' -d '{
        "inputs": [[[10,12,13,15], [5,6,6,7]]],
        "past_covariates": [[[20,21,19,22]]],
        "future_covariates": [[[0,1,0,0, 1,0]]],
        "horizon": 2
      }'
      """),
      ("Load a model", """
      curl -s \(base)load -H 'Content-Type: application/json' -d '{"model_id": "google--timesfm-3.0-pytorch", "backend": "mlx"}'
      curl -s \(base)flags -H 'Content-Type: application/json' -d '{"overrides": {"use_linear_detrending": false}}'
      curl -s \(base)status
      """),
      ("Python", """
      import requests
      r = requests.post("\(base)v1/forecast", json={"inputs": [list(range(100))], "horizon": 24})
      out = r.json()["forecasts"][0]   # {"median": [...], "quantiles": [[P10...], ..., [P90...]]}
      """),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.space * 1.5) {
      Text("While the app is open, scripts and notebooks on this Mac can use the loaded model.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Picker("Example", selection: $example) {
          ForEach(Array(examples.enumerated()), id: \.offset) { i, e in Text(e.title).tag(i) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(examples[example].code, forType: .string)
        } label: { Label("Copy", systemImage: "doc.on.doc") }
      }
      ScrollView(.horizontal) {
        Text(examples[example].code)
          .font(.code)
          .textSelection(.enabled)
          .padding(Theme.space * 1.5)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: Theme.shape)
      .overlay(Theme.shape.strokeBorder(Theme.border))
      if let url = URL(string: base + "docs") {
        Link("Open the full reference", destination: url)
      }
    }
    .padding(.vertical, Theme.space / 2)
  }
}

private struct SchemeBox<Content: View>: NSViewRepresentable {
  var scheme: ColorScheme
  var content: Content

  init(scheme: ColorScheme, @ViewBuilder content: () -> Content) {
    self.scheme = scheme
    self.content = content()
  }

  func makeNSView(context: Context) -> NSHostingView<Content> {
    let host = NSHostingView(rootView: content)
    host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
    apply(host)
    return host
  }

  func updateNSView(_ host: NSHostingView<Content>, context: Context) {
    host.rootView = content
    apply(host)
  }

  private func apply(_ host: NSView) {
    host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
  }
}

private struct PreviewRow: Identifiable {
  var id: Int
  var cells: [String]
}

private struct PreviewColumn: Identifiable {
  var id: Int
  var name: String
}

private struct PreviewTable: NSViewRepresentable {
  var columns: [PreviewColumn]
  var rows: [PreviewRow]
  var size: CGFloat
  var role: (String) -> String
  var scheme: ColorScheme?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let table = NSTableView()
    table.style = .inset
    table.usesAlternatingRowBackgroundColors = true
    table.allowsColumnReordering = true
    table.allowsColumnResizing = true
    table.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
    table.headerView = NSTableHeaderView()
    table.dataSource = context.coordinator
    table.delegate = context.coordinator
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.drawsBackground = true
    scroll.autohidesScrollers = true
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let table = scroll.documentView as? NSTableView else { return }
    let ids = columns.map { NSUserInterfaceItemIdentifier("\($0.id)") }
    if table.tableColumns.map(\.identifier) != ids {
      for column in table.tableColumns { table.removeTableColumn(column) }
      for column in columns {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(column.id)"))
        tableColumn.minWidth = 88
        tableColumn.width = max(150, 150 * size / 13)
        tableColumn.resizingMask = .userResizingMask
        table.addTableColumn(tableColumn)
      }
    }
    let headerFont = NSFont.systemFont(ofSize: size, weight: .semibold)
    for column in columns {
      guard let tableColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("\(column.id)")) else { continue }
      tableColumn.title = "\(column.name) · \(role(column.name))"
      tableColumn.headerCell.font = headerFont
    }
    table.rowHeight = size + 14
    table.reloadData()
    switch scheme {
    case .light: scroll.appearance = NSAppearance(named: .aqua)
    case .dark: scroll.appearance = NSAppearance(named: .darkAqua)
    case nil: scroll.appearance = nil
    default: scroll.appearance = nil
    }
  }

  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var parent: PreviewTable
    init(_ parent: PreviewTable) { self.parent = parent }

    func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      guard let tableColumn, let index = Int(tableColumn.identifier.rawValue), parent.rows.indices.contains(row) else { return nil }
      let id = NSUserInterfaceItemIdentifier("cell")
      let field = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? NSTextField(labelWithString: "")
      field.identifier = id
      let cells = parent.rows[row].cells
      field.stringValue = index < cells.count ? cells[index] : ""
      field.font = .monospacedSystemFont(ofSize: parent.size, weight: .regular)
      field.textColor = .labelColor
      field.lineBreakMode = .byTruncatingTail
      field.isEditable = false
      return field
    }
  }
}

struct DataView: View {
  @Environment(AppState.self) private var state
  @Environment(\.colorScheme) private var appScheme
  @State private var zoom: CGFloat = 1
  @State private var zoomAnchor: CGFloat = 1
  @State private var scheme: ColorScheme?

  var body: some View {
    if let sheet = state.sheet {
      viewer(sheet)
        .navigationTitle("Data")
    } else {
      EmptyDataState().navigationTitle("Data")
    }
  }

  private func viewer(_ sheet: SheetInfo) -> some View {
    let columns = sheet.preview.columns.enumerated().map { PreviewColumn(id: $0.offset, name: $0.element) }
    let rows = sheet.preview.rows.enumerated().map { index, row in
      PreviewRow(id: index, cells: row.map(\.description))
    }
    let size = 13 * zoom
    return VStack(alignment: .leading, spacing: Theme.space * 2) {
      HStack(spacing: Theme.space * 2) {
        Text(state.dataset?.name ?? "").font(.sectionTitle.weight(.semibold))
        Text("\(sheet.rows) rows").foregroundStyle(.secondary)
        Spacer()
        HStack(spacing: Theme.space) {
          Button { zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
            .help("Zoom out")
          Button { zoom = 1; zoomAnchor = 1 } label: {
            Text("\(Int((zoom * 100).rounded()))%")
              .monospacedDigit()
              .frame(minWidth: 52)
          }
          .help("Actual size")
          Button { zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
            .help("Zoom in")
        }
        .controlSize(.large)
        .buttonStyle(.borderless)
        Button {
          scheme = tableScheme == .dark ? .light : .dark
        } label: {
          Image(systemName: tableScheme == .dark ? "sun.max" : "moon")
        }
        .controlSize(.large)
        .buttonStyle(.borderless)
        .help(tableScheme == .dark ? "Light table" : "Dark table")
        Button { state.chooseFile() } label: { Label("Open", systemImage: "folder") }
          .controlSize(.large)
      }
      PreviewTable(
        columns: columns,
        rows: rows,
        size: size,
        role: { roleText($0, sheet) },
        scheme: tableScheme
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.background)
      .clipShape(Theme.shape)
      .overlay(Theme.shape.strokeBorder(Theme.border))
      .gesture(
        MagnifyGesture()
          .onChanged { value in
            zoom = min(2, max(0.75, zoomAnchor * value.magnification))
          }
          .onEnded { _ in zoomAnchor = zoom }
      )
      Text("Column statistics").font(.rowTitle.weight(.semibold))
      SchemeBox(scheme: tableScheme) {
        Table(sheet.columns) {
          TableColumn("Column", value: \.name)
          TableColumn("Type") { c in Text(c.numeric ? "numeric" : c.dtype) }
          TableColumn("Missing") { c in Text("\(c.missing)") }
          TableColumn("Unique") { c in Text("\(c.unique)") }
          TableColumn("Min") { c in Text(Fmt.number(c.min)) }
          TableColumn("Mean") { c in Text(Fmt.number(c.mean)) }
          TableColumn("Max") { c in Text(Fmt.number(c.max)) }
          TableColumn("Std") { c in Text(Fmt.number(c.std)) }
        }
        .font(.system(size: size))
        .alternatingRowBackgrounds()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(minHeight: 160, idealHeight: 200, maxHeight: 280)
    }
    .padding(Theme.space * 2)
  }

  private var tableScheme: ColorScheme { scheme ?? appScheme }

  private func zoomIn() {
    zoom = min(2, zoom + 0.1)
    zoomAnchor = zoom
  }

  private func zoomOut() {
    zoom = max(0.75, zoom - 0.1)
    zoomAnchor = zoom
  }

  private func roleText(_ c: String, _ s: SheetInfo) -> String {
    if c == state.timeColumn { return "time" }
    if c == state.idColumn { return "series id" }
    guard let r = state.roles[c], r != .ignore else { return s.columns.first { $0.name == c }?.numeric == true ? "ignored" : "text" }
    return r.title.lowercased()
  }

}

struct SettingsView: View {
  @Environment(AppState.self) private var state
  @State private var token = Keychain.get("hf_token") ?? ""
  @AppStorage("basePython") private var basePython = ""
  @AppStorage("modelsDir") private var modelsDir = ""

  var body: some View {
    @Bindable var updater = state.updater
    Form {
      Section("Updates") {
        Toggle("Check for updates when the app opens", isOn: $updater.checksOnLaunch)
        HStack(spacing: Theme.space) {
          Button("Check for Updates") { Task { await updater.check() } }
            .disabled(updater.phase == .checking || updater.phase == .restarting || updater.isWorking)
          Text(updateStatus).font(.note).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          if case .available(let release) = updater.phase {
            Button("Update") { Task { await updater.install(release) } }
              .buttonStyle(.borderedProminent)
          }
        }
      }
      Section("Hugging Face") {
        SecureField("Access token (optional)", text: $token)
          .onSubmit { Keychain.set("hf_token", token) }
        HStack {
          Button("Save token") { Keychain.set("hf_token", token) }
          Text("Only needed for gated or private repositories. Stored in your Keychain.")
            .font(.note).foregroundStyle(.secondary)
        }
      }
      Section("Runtime") {
        TextField("Base Python for the runtime", text: $basePython, prompt: Text("Automatic"))
        Text("Leave empty and the app downloads its own Python. To use yours, enter the path to Python 3.10–3.13.")
          .font(.note).foregroundStyle(.secondary)
        LabeledContent("Environment", value: EngineManager.venvDir.path)
      }
      Section("Storage") {
        TextField("Models folder", text: $modelsDir, prompt: Text(EngineManager.appSupport.appendingPathComponent("models").path))
        Text("Changing the folder takes effect after restarting the engine.").font(.note).foregroundStyle(.secondary)
        Button("Restart engine now") { Task { await state.engine.restart(); await state.afterEngineStart() } }
      }
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 600)
  }

  private var updateStatus: String {
    let updater = state.updater
    switch updater.phase {
    case .idle: return updater.current.map { "You have version \($0)." } ?? ""
    case .checking: return "Checking…"
    case .upToDate: return "You have the latest version\(updater.current.map { ", \($0)" } ?? "")."
    case .available(let release): return "Version \(release.version) is available."
    case .downloading: return "Downloading…"
    case .installing: return "Installing…"
    case .restarting: return "Restarting…"
    case .failed(let message): return message
    }
  }
}
