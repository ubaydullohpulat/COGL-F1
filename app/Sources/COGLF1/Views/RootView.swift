import SwiftUI

struct RootView: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state
    NavigationSplitView {
      List(selection: $state.section) {
        Section {
          ForEach(SidebarSection.allCases) { s in
            // A plain row, because the sidebar resizes a Label to the compact system size.
            HStack(spacing: Theme.space * 1.5) {
              Image(systemName: s.icon)
                .font(.sectionTitle.weight(.medium))
                .frame(width: 26, height: 26)
              Text(s.title).font(.rowTitle)
              Spacer(minLength: 0)
            }
            .frame(minHeight: 36)
            .badge(badge(for: s))
            .tag(s)
          }
        }
      }
      .environment(\.defaultMinListRowHeight, 48)
      .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
      .safeAreaInset(edge: .bottom) { EngineFooter().padding(8) }
    } detail: {
      Group {
        switch state.section {
        case .forecast: ForecastView()
        case .data: DataView()
        case .finetune: FinetuneView()
        case .models: ModelsView()
        case .server: ServerView()
        }
      }
      .toolbar {
        // The toolbar centers this over the data column too; push it over the page content.
        if #available(macOS 26.0, *) {
          // The system bubble would stretch over the padding, so the bar draws its own.
          ToolbarItem(placement: .principal) {
            ModelBar()
              // Room around the buttons, so their hover shape doesn't touch the edge.
              .controlSize(.small)
              .font(.text)
              .padding(.vertical, 4)
              .glassEffect(.regular, in: Capsule())
              .padding(.leading, dataColumnShown ? DataPanel.width : 0)
          }
          .sharedBackgroundVisibility(.hidden)
        } else {
          ToolbarItem(placement: .principal) {
            ModelBar().padding(.leading, dataColumnShown ? DataPanel.width : 0)
          }
        }
      }
    }
    .alert("Something went wrong", isPresented: Binding(get: { state.alert != nil }, set: { if !$0 { state.alert = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(state.alert ?? "")
    }
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      guard let p = providers.first else { return false }
      _ = p.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in
          await state.openFile(url)
          if state.section == .models || state.section == .server { state.section = .forecast }
        }
      }
      return true
    }
  }

  private var dataColumnShown: Bool {
    switch state.section {
    case .forecast: return state.dataset != nil
    case .finetune: return true
    default: return false
    }
  }

  private func badge(for s: SidebarSection) -> Text? {
    switch s {
    case .models where !state.hasModel: return Text("!")
    case .finetune where state.ftJob?.isActive == true: return Text("\(Int((state.ftJob?.progress ?? 0) * 100))%")
    case .server where !state.engine.isRunning: return Text("!")
    default: return nil
    }
  }
}

struct EngineFooter: View {
  @Environment(AppState.self) private var state

  var body: some View {
    Button {
      state.section = .server
    } label: {
      HStack(spacing: Theme.space * 1.5) {
        Circle().fill(color).frame(width: 9, height: 9)
          .frame(width: 26)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.text.weight(.medium))
          if let s = state.status, s.loaded, let id = s.modelId {
            Text(state.models.first { $0.id == id }?.displayName ?? id)
              .font(.note).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.space).padding(.vertical, Theme.space)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .background(Theme.fill, in: Theme.shape)
      .contentShape(Theme.shape)
    }
    .buttonStyle(.plain)
    .help("Open the engine page")
  }

  private var title: String {
    switch state.engine.state {
    case .running: return state.status?.loaded == true ? "Model loaded" : "Ready"
    case .starting: return "Starting engine…"
    case .checking: return "Checking runtime…"
    case .installing: return "Installing runtime…"
    case .needsInstall, .needsPython: return "Runtime not installed"
    case .failed: return "Engine error"
    case .stopped: return "Engine stopped"
    }
  }

  private var color: Color {
    switch state.engine.state {
    case .running: return state.status?.loaded == true ? .green : .blue
    case .starting, .checking, .installing: return .orange
    default: return .red
    }
  }
}
