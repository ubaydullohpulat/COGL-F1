import SwiftUI

/// Left-hand panel shared by Forecast and Fine-tune: file, sheet, time/id columns and column roles.
struct DataPanel: View {
  @Environment(AppState.self) private var state
  @State private var showDetails = false
  static let width: CGFloat = 300

  var body: some View {
    @Bindable var state = state
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.space * 2) {
        fileHeader

        if let ds = state.dataset, let sheet = state.sheet {
          Text(summary(sheet))
            .font(.text).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if ds.sheets.count > 1 {
            HStack {
              Text("Sheet")
              Spacer(minLength: Theme.space)
              Picker("Sheet", selection: Binding(get: { state.sheetName ?? sheet.name }, set: { state.selectSheet($0) })) {
                ForEach(ds.sheets, id: \.name) { s in Text(s.name).tag(s.name) }
              }
              .labelsHidden()
              .fixedSize()
            }
          }

          let numeric = sheet.columns.filter { $0.numeric && $0.name != state.timeColumn }
          PanelSection("Columns", hint: "Choose Predict for what you want to forecast. Other columns can help it: Helper uses their past values, Known ahead is for values the file already has for the future, such as holidays or planned promotions.") {
            ForEach(numeric) { col in
              HStack {
                Text(col.name).lineLimit(1)
                Spacer(minLength: Theme.space)
                Picker(col.name, selection: Binding(
                  get: { state.roles[col.name] ?? .ignore },
                  set: { state.roles[col.name] = $0 })) {
                  Text("Predict").tag(ColumnRole.target)
                  Text("Helper").tag(ColumnRole.past)
                  Text("Known ahead").tag(ColumnRole.future)
                  Divider()
                  Text("Not used").tag(ColumnRole.ignore)
                }
                .labelsHidden()
                .frame(width: 124)
              }
            }
          }

          Divider()
          Button {
            withAnimation(.easeInOut(duration: 0.2)) { showDetails.toggle() }
          } label: {
            HStack(spacing: Theme.space) {
              Image(systemName: "chevron.right")
                .rotationEffect(.degrees(showDetails ? 90 : 0))
                .font(.note.weight(.semibold))
                .frame(width: 12)
              Text("File settings")
              Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)

          if showDetails || state.timeColumn == nil {
            let idOptions = sheet.columns.filter { !$0.numeric && $0.name != state.timeColumn }.map(\.name)
            VStack(spacing: Theme.space) {
              LabeledPicker("Dates", selection: $state.timeColumn, options: sheet.columns.map(\.name), none: "Row order")
              if !idOptions.isEmpty || state.idColumn != nil {
                LabeledPicker("Names", selection: $state.idColumn, options: idOptions, none: "None")
                  .help("If each row says which shop, product or sensor it belongs to, pick that column.")
              }
              HStack {
                Text("Empty cells")
                Spacer(minLength: Theme.space)
                Picker("Empty cells", selection: $state.fillMethod) {
                  Text("Fill smoothly").tag("interpolate")
                  Text("Repeat last value").tag("ffill")
                  Text("Count as zero").tag("zero")
                }
                .labelsHidden()
                .fixedSize()
              }
            }
          }
        }
      }
      .padding(Theme.space * 2)
    }
    .background(.background.secondary)
  }

  @ViewBuilder private var fileHeader: some View {
    if let ds = state.dataset {
      HStack(spacing: Theme.space) {
        Image(systemName: ds.name.hasSuffix(".csv") || ds.name.hasSuffix(".tsv") ? "doc.text" : "tablecells")
          .font(.rowTitle).foregroundStyle(.tint)
        Text(ds.name).font(.text.weight(.semibold)).lineLimit(1).truncationMode(.middle)
          .help(ds.path ?? ds.name)
        Spacer(minLength: Theme.space)
        if state.isOpeningFile { ProgressView().controlSize(.small) }
        Button("Change…") { state.chooseFile() }
          .disabled(!state.engine.isRunning)
      }
    } else {
      Button {
        state.chooseFile()
      } label: {
        Label("Open file", systemImage: "folder").frame(maxWidth: .infinity)
      }
      .controlSize(.large)
      .disabled(!state.engine.isRunning)
    }
  }

  private func summary(_ sheet: SheetInfo) -> String {
    var parts: [String] = []
    if let f = sheet.frequency { parts.append(Freq.name(f)) }
    if let r = sheet.timeRange, r.count == 2 {
      parts.append("\(Fmt.friendlyDate(r[0])) – \(Fmt.friendlyDate(r[1]))")
    } else {
      parts.append("\(sheet.rows) rows")
    }
    return parts.joined(separator: " · ")
  }
}

struct PanelSection<Content: View>: View {
  var title: String
  var hint: String?
  @ViewBuilder var content: Content
  init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.hint = hint
    self.content = content()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: Theme.space) {
      HStack(spacing: 0) {
        Text(title).font(.text.weight(.semibold))
        if let hint { HintButton(text: hint) }
      }
      .frame(minHeight: 28)
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
    HStack {
      Text(label)
      Spacer(minLength: Theme.space)
      Picker(label, selection: $selection) {
        Text(none).tag(String?.none)
        ForEach(options, id: \.self) { Text($0).tag(String?.some($0)) }
      }
      .labelsHidden()
      .fixedSize()
    }
  }
}

struct Chip: View {
  var icon: String
  var text: String
  var body: some View {
    Label(text, systemImage: icon)
      .font(.note)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(Theme.fill, in: Capsule())
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
