import SwiftUI

struct RootView: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state
    NavigationSplitView {
      List(selection: $state.section) {
        Section {
          ForEach(SidebarSection.allCases) { s in
            Label(s.title, systemImage: s.icon)
              .badge(badge(for: s))
              .tag(s)
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
      .safeAreaInset(edge: .bottom) { EngineFooter().padding(10) }
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
        ToolbarItem(placement: .principal) { ModelBar() }
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
    HStack(spacing: 8) {
      Circle().fill(color).frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.caption.weight(.medium))
        if let s = state.status, s.loaded, let id = s.modelId {
          Text(state.models.first { $0.id == id }?.displayName ?? id)
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer()
    }
    .padding(8)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    .onTapGesture { state.section = .server }
  }

  private var title: String {
    switch state.engine.state {
    case .running: return state.status?.loaded == true ? "Model loaded" : "Engine ready"
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
