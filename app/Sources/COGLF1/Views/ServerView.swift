import AppKit
import SwiftUI

struct RuntimeSetupControls: View {
  @Environment(AppState.self) private var state

  var body: some View {
    let e = state.engine
    VStack(alignment: .leading, spacing: 8) {
      switch e.state {
      case .needsPython:
        Text("No Python 3.10–3.13 or uv was found. Install one, then press Check again:")
          .font(.callout)
        Text("brew install python@3.12   (or install uv, or Python from python.org)")
          .font(.callout.monospaced()).textSelection(.enabled)
        Button("Check again") { Task { await state.boot() } }
      case .needsInstall:
        Button {
          Task {
            await e.installRuntime()
            await state.afterEngineStart()
          }
        } label: { Label("Install runtime", systemImage: "arrow.down.circle.fill") }
          .buttonStyle(.borderedProminent)
        Text("Uses \(e.findUV().map { "uv (\($0))" } ?? e.findBasePython() ?? "python3") → \(EngineManager.venvDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
          .font(.caption).foregroundStyle(.secondary)
      case .installing(let msg):
        ProgressView(value: e.installProgress) { Text(msg).font(.callout) }
        Text(e.logs.last ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
      case .starting, .checking:
        HStack { ProgressView().controlSize(.small); Text("Starting engine…") }
      case .failed(let msg):
        Text(msg).foregroundStyle(.red).font(.callout)
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
  @State private var tab = 0

  var body: some View {
    let e = state.engine
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 18) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Engine").font(.title2.weight(.semibold))
          RuntimeSetupControls()
          if e.isRunning, let h = e.health {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
              info("Address", e.baseURL.absoluteString)
              info("TimesFM", h.timesfmVersion ?? "?")
              info("Python", h.python)
              info("MLX", h.backends["mlx"].map { $0.available ? ($0.device ?? "available") : "unavailable" } ?? "—")
              info("PyTorch", h.backends["torch"].map { $0.available ? "\($0.version ?? "") · MPS \($0.mps == true ? "yes" : "no")" : "unavailable" } ?? "—")
              if let s = state.status {
                info("Loaded model", s.loaded ? "\(s.modelId ?? "") (\(s.backend ?? ""))" : "none")
                if let m = s.mlxActiveBytes { info("MLX memory", Fmt.bytes(Int64(m))) }
                if let r = s.peakRssBytes { info("Peak RSS", Fmt.bytes(Int64(r))) }
              }
            }
            .font(.callout)
            .textSelection(.enabled)
            HStack {
              Button("Restart") { Task { await e.restart(); await state.afterEngineStart() } }
              Button("Stop") { e.stop() }
              Button("Refresh") { Task { await state.refreshStatus() } }
              Button("Reinstall runtime…") { Task { await e.installRuntime(); await state.afterEngineStart() } }
            }
          }
        }
        .frame(maxWidth: 460, alignment: .leading)
        Spacer()
      }

      Picker("", selection: $tab) {
        Text("Local API").tag(0)
        Text("Engine log").tag(1)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 260)

      if tab == 0 { APIDocs(base: e.isRunning ? e.baseURL.absoluteString : "http://127.0.0.1:<port>/") }
      else {
        LogView(lines: e.logs)
        HStack {
          Spacer()
          Button("Copy log") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(e.logs.joined(separator: "\n"), forType: .string)
          }
        }
      }
    }
    .padding(24)
    .navigationTitle("Engine & API")
    .task { await state.refreshStatus() }
  }

  private func info(_ k: String, _ v: String) -> some View {
    GridRow {
      Text(k).foregroundStyle(.secondary)
      Text(v)
    }
  }
}

struct APIDocs: View {
  var base: String
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("While the app is open, the engine serves an HTTP API on localhost, so notebooks and scripts can use the same loaded model.")
          .foregroundStyle(.secondary)
        snippet("Forecast raw arrays (univariate or variates × time)", """
        curl -s \(base)v1/forecast -H 'Content-Type: application/json' -d '{
          "inputs": [[1,2,3,4,5,6,7,8,9,10,11,12]],
          "horizon": 6,
          "params": {"use_symmetric_averaging": false, "make_positive": true}
        }'
        """)
        snippet("With past-only and future-known covariates", """
        curl -s \(base)v1/forecast -H 'Content-Type: application/json' -d '{
          "inputs": [[[10,12,13,15], [5,6,6,7]]],
          "past_covariates": [[[20,21,19,22]]],
          "future_covariates": [[[0,1,0,0, 1,0]]],
          "horizon": 2
        }'
        """)
        snippet("Load a model / change flags / status", """
        curl -s \(base)load -H 'Content-Type: application/json' -d '{"model_id": "google--timesfm-3.0-pytorch", "backend": "mlx"}'
        curl -s \(base)flags -H 'Content-Type: application/json' -d '{"overrides": {"use_linear_detrending": false}}'
        curl -s \(base)status
        """)
        snippet("Python", """
        import requests
        r = requests.post("\(base)v1/forecast", json={"inputs": [list(range(100))], "horizon": 24})
        out = r.json()["forecasts"][0]   # {"median": [...], "quantiles": [[P10...], ..., [P90...]]}
        """)
        Text("Interactive schema: \(base)docs").font(.callout)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func snippet(_ title: String, _ code: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code, forType: .string)
        } label: { Image(systemName: "doc.on.doc") }
          .buttonStyle(.borderless)
      }
      Text(code)
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
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
        Text(state.dataset?.name ?? "").font(.title2.weight(.semibold))
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
      .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(.separator))
      .gesture(
        MagnifyGesture()
          .onChanged { value in
            zoom = min(2, max(0.75, zoomAnchor * value.magnification))
          }
          .onEnded { _ in zoomAnchor = zoom }
      )
      Text("Column statistics").font(.title3.weight(.semibold))
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
    Form {
      Section("Hugging Face") {
        SecureField("Access token (optional)", text: $token)
          .onSubmit { Keychain.set("hf_token", token) }
        HStack {
          Button("Save token") { Keychain.set("hf_token", token) }
          Text("Only needed for gated or private repositories. Stored in your Keychain.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Runtime") {
        TextField("Base Python for the runtime", text: $basePython, prompt: Text(state.engine.findBasePython() ?? "auto"))
        Text("Python 3.10–3.13 used to create the private environment. Leave empty to auto-detect (uv is preferred when installed).")
          .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Environment", value: EngineManager.venvDir.path)
      }
      Section("Storage") {
        TextField("Models folder", text: $modelsDir, prompt: Text(EngineManager.appSupport.appendingPathComponent("models").path))
        Text("Changing the folder takes effect after restarting the engine.").font(.caption).foregroundStyle(.secondary)
        Button("Restart engine now") { Task { await state.engine.restart(); await state.afterEngineStart() } }
      }
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 440)
  }
}
