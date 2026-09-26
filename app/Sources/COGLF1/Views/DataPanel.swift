import SwiftUI

/// Left-hand panel shared by Forecast and Fine-tune: file, sheet, time/id columns and column roles.
struct DataPanel: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        fileHeader

        if let ds = state.dataset, let sheet = state.sheet {
          if ds.sheets.count > 1 {
            PanelSection("Sheet") {
              Picker("Sheet", selection: Binding(get: { state.sheetName ?? sheet.name }, set: { state.selectSheet($0) })) {
                ForEach(ds.sheets, id: \.name) { s in Text("\(s.name)  (\(s.rows) rows)").tag(s.name) }
              }
              .labelsHidden()
            }
          }

          PanelSection("Time & series") {
            LabeledPicker("Time column", selection: $state.timeColumn, options: sheet.columns.map(\.name), none: "None (row order)")
            LabeledPicker("Series ID", selection: $state.idColumn,
                          options: sheet.columns.filter { !$0.numeric && $0.name != state.timeColumn }.map(\.name),
                          none: "None (wide table)")
              .help("For long-format files (one row per id and date), pick the column that names each series. Every id is forecast in one batch.")
            HStack(spacing: 10) {
              Chip(icon: "calendar", text: sheet.frequency.map(freqName) ?? "No frequency")
              Chip(icon: "number", text: "\(sheet.rows) rows")
            }
            if let r = sheet.timeRange, r.count == 2 {
              Text("\(Fmt.shortDate(r[0])) → \(Fmt.shortDate(r[1]))")
                .font(.caption).foregroundStyle(.secondary)
            }
          }

          PanelSection("Columns") {
            VStack(spacing: 2) {
              ForEach(sheet.columns.filter { $0.numeric && $0.name != state.timeColumn }) { col in
                ColumnRoleRow(column: col, role: Binding(
                  get: { state.roles[col.name] ?? .ignore },
                  set: { state.roles[col.name] = $0 }))
              }
            }
            HStack(spacing: 8) {
              RoleLegend(role: .target, count: state.targets.count)
              RoleLegend(role: .past, count: state.pastCovariates.count)
              RoleLegend(role: .future, count: state.futureCovariates.count)
            }
            .padding(.top, 4)
            if state.targets.count > 1 {
              Text("Multiple targets are forecast jointly (multivariate) unless you switch Mode to Independent.")
                .font(.caption).foregroundStyle(.secondary)
            }
            if !state.futureCovariates.isEmpty {
              Label("Future covariates need values in rows after the last target value, one row per forecast step.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
            }
          }

          PanelSection("Missing values") {
            Picker("Fill", selection: $state.fillMethod) {
              Text("Interpolate").tag("interpolate")
              Text("Forward fill").tag("ffill")
              Text("Zero").tag("zero")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
          }
        }
      }
      .padding(14)
    }
    .background(.background.secondary)
  }

  @ViewBuilder private var fileHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let ds = state.dataset {
        HStack(spacing: 10) {
          Image(systemName: ds.name.hasSuffix(".csv") || ds.name.hasSuffix(".tsv") ? "doc.text" : "tablecells")
            .font(.title2).foregroundStyle(.tint)
          VStack(alignment: .leading, spacing: 2) {
            Text(ds.name).font(.headline).lineLimit(1).truncationMode(.middle)
            if let p = ds.path {
              Text((p as NSString).deletingLastPathComponent).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
          }
          Spacer()
        }
      }
      HStack {
        Button {
          state.chooseFile()
        } label: {
          Label(state.dataset == nil ? "Open CSV / Excel…" : "Open another…", systemImage: "folder")
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(!state.engine.isRunning)
        if state.isOpeningFile { ProgressView().controlSize(.small) }
      }
      if state.dataset == nil {
        Text("or drop a file anywhere in the window").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func freqName(_ f: String) -> String {
    let map = ["D": "Daily", "B": "Business daily", "h": "Hourly", "H": "Hourly", "min": "Minutely", "T": "Minutely",
               "W": "Weekly", "MS": "Monthly (start)", "ME": "Monthly (end)", "M": "Monthly", "QS": "Quarterly", "QE": "Quarterly",
               "YS": "Yearly", "YE": "Yearly", "s": "Secondly"]
    if let v = map[f] { return v }
    if let k = map.keys.first(where: { f.hasPrefix($0 + "-") }) { return map[k]! }
    return "Every \(f)"
  }
}

struct PanelSection<Content: View>: View {
  var title: String
  @ViewBuilder var content: Content
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
      content
    }
  }
}

struct LabeledPicker: View {
  var label: String
  @Binding var selection: String?
  var options: [String]
  var none: String
  init(_ label: String, selection: Binding<String?>, options: [String], none: String) {
    self.label = label
    self._selection = selection
    self.options = options
    self.none = none
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Picker(label, selection: $selection) {
        Text(none).tag(String?.none)
        ForEach(options, id: \.self) { Text($0).tag(String?.some($0)) }
      }
      .labelsHidden()
    }
  }
}

struct Chip: View {
  var icon: String
  var text: String
  var body: some View {
    Label(text, systemImage: icon)
      .font(.caption)
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(.quaternary.opacity(0.6), in: Capsule())
  }
}

extension ColumnRole {
  var color: Color {
    switch self {
    case .ignore: return .secondary
    case .target: return .accentColor
    case .past: return .orange
    case .future: return .purple
    }
  }
}

struct RoleLegend: View {
  var role: ColumnRole
  var count: Int
  var body: some View {
    HStack(spacing: 4) {
      Circle().fill(role.color).frame(width: 7, height: 7)
      Text("\(role.short) \(count)").font(.caption2).foregroundStyle(.secondary)
    }
  }
}

struct ColumnRoleRow: View {
  var column: SheetInfo.Column
  @Binding var role: ColumnRole

  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 2).fill(role == .ignore ? Color.clear : role.color).frame(width: 3, height: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(column.name).font(.callout).lineLimit(1)
        Text(stats).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      Menu {
        ForEach(ColumnRole.allCases) { r in
          Button {
            role = r
          } label: {
            if r == role { Label(r.title, systemImage: "checkmark") } else { Text(r.title) }
          }
          .help(r.help)
        }
      } label: {
        Text(role.short)
          .font(.caption.weight(.medium))
          .foregroundStyle(role == .ignore ? Color.secondary : role.color)
          .frame(width: 52)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(.vertical, 3).padding(.horizontal, 6)
    .background(role == .ignore ? Color.clear : role.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    .contentShape(Rectangle())
  }

  private var stats: String {
    var parts = ["μ \(Fmt.number(column.mean, digits: 2))", "σ \(Fmt.number(column.std, digits: 2))"]
    if column.missing > 0 { parts.append("\(column.missing) missing") }
    return parts.joined(separator: " · ")
  }
}
