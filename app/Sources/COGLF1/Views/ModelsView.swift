import AppKit
import SwiftUI

struct ModelsView: View {
  @Environment(AppState.self) private var state
  @State private var confirmDelete: LocalModel?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        DownloadCard(repo: ModelDownloader.defaultRepo, title: "TimesFM 3.0", subtitle: "Google Research · 330M parameters",
                     facts: ["Zero-shot", "Multivariate", "Covariates", "9 quantiles", "Context 15K", "1.32 GB"],
                     featured: true)

        VStack(alignment: .leading, spacing: Theme.space * 1.5) {
          HStack {
            Text("My models").font(.sectionTitle.weight(.semibold))
            Spacer()
            Button { NSWorkspace.shared.open(EngineManager.modelsDir) } label: { Label("Show in Finder", systemImage: "folder") }
            Button { Task { await state.refreshModels() } } label: { Image(systemName: "arrow.clockwise") }
          }
          if state.models.isEmpty {
            Text("No models yet. Download TimesFM 3 above.")
              .foregroundStyle(.secondary).padding(.vertical, 16)
          } else {
            ForEach(state.models) { m in
              ModelRow(model: m, onDelete: { confirmDelete = m })
            }
          }
        }

        CatalogSection(importFolder: importFolder)
      }
      .padding(24)
      .frame(maxWidth: 980, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Models")
    .task { await state.refreshModels() }
    .confirmationDialog("Delete \(confirmDelete?.displayName ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
      Button("Delete \(Fmt.bytes(confirmDelete?.sizeBytes ?? 0))", role: .destructive) {
        if let m = confirmDelete { Task { await state.deleteModel(m) } }
      }
    } message: {
      Text("The model files are removed from disk. You can download or fine-tune it again later.")
    }
  }

  private var header: some View {
    Text("Models").font(.pageTitle.weight(.semibold))
  }

  private func importFolder() {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.message = "Choose a folder containing config.json and model.safetensors"
    if p.runModal() == .OK, let url = p.url { Task { await state.importModelFolder(url) } }
  }
}

/// Other checkpoints on Hugging Face, with the ones this engine can run first.
struct CatalogSection: View {
  @Environment(AppState.self) private var state
  var importFolder: () -> Void
  @FocusState private var searchFocused: Bool

  var body: some View {
    @Bindable var catalog = state.catalog
    VStack(alignment: .leading, spacing: Theme.space * 1.5) {
      HStack {
        HuggingFaceLogo()
        Text("More on Hugging Face").font(.sectionTitle.weight(.semibold))
        Spacer()
        Button(action: importFolder) { Label("Import folder…", systemImage: "folder") }
          .help("Copy a model folder from this Mac into the library")
      }

      HStack(spacing: Theme.space) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField("Search models, or type owner/name", text: $catalog.query)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .onSubmit(submit)
        if catalog.isSearching {
          ProgressView().controlSize(.small)
        } else if !catalog.query.isEmpty {
          Button {
            catalog.query = ""
            searchFocused = true
            Task { await catalog.search() }
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("Clear")
        }
      }
      .font(.text)
      .padding(.horizontal, 12)
      .frame(height: 36)
      .background(Theme.fill, in: Theme.shape)
      .overlay(Theme.shape.strokeBorder(searchFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
      .contentShape(Theme.shape)
      .onTapGesture { searchFocused = true }

      if let error = catalog.error, !catalog.isSearching {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
      } else if catalog.searched && catalog.results.isEmpty && !catalog.isSearching {
        Text("Nothing found. Press Return to search again.").foregroundStyle(.secondary)
      }

      // Downloads started by name, which a search may not list.
      let listed = Set(catalog.results.map(\.repo))
      ForEach(Array(state.downloader.progress.keys.filter { $0 != ModelDownloader.defaultRepo && !listed.contains($0) }.sorted()), id: \.self) { repo in
        DownloadCard(repo: repo, title: repo, subtitle: "Hugging Face", facts: [], featured: false)
      }
      ForEach(catalog.results) { entry in
        if entry.compatible {
          DownloadCard(repo: entry.repo, title: entry.name, subtitle: subtitle(entry), facts: [], featured: false)
        } else {
          HStack(spacing: Theme.space * 1.5) {
            VStack(alignment: .leading, spacing: 4) {
              Text(entry.name).font(.text.weight(.semibold))
              Text(subtitle(entry)).font(.text).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Not supported yet").foregroundStyle(.secondary)
              .help("This is a different kind of model. The app runs TimesFM 3 checkpoints.")
          }
          .card()
          .opacity(0.6)
        }
      }
      if !catalog.results.isEmpty {
        Text("These are uploaded by other people. COGL-F1 checks that a model can run, not who made it or how good it is.")
          .font(.note).foregroundStyle(.secondary)
      }
    }
    .onAppear {
      // Not tied to the page, so switching pages doesn't cancel it halfway.
      if !catalog.searched { Task { await catalog.search() } }
    }
  }

  /// "owner/name" downloads that model directly; anything else is a search.
  private func submit() {
    let catalog = state.catalog
    let q = catalog.query.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.split(separator: "/").count == 2, !q.contains(" ") {
      state.downloader.start(repo: q, token: Keychain.get("hf_token"))
    } else {
      Task { await catalog.search() }
    }
  }

  private func subtitle(_ e: ModelCatalog.Entry) -> String {
    "\(e.owner) · \(e.downloads.formatted(.number.notation(.compactName))) downloads"
  }
}

struct DownloadCard: View {
  @Environment(AppState.self) private var state
  var repo: String
  var title: String
  var subtitle: String
  var facts: [String]
  var featured: Bool

  private var installed: LocalModel? { state.models.first { $0.id == ModelDownloader.modelId(for: repo) } }
  private var progress: ModelDownloader.Progress? { state.downloader.progress[repo] }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 16) {
        if featured {
          ZStack {
            Theme.shape.fill(LinearGradient(colors: [.blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "chart.line.uptrend.xyaxis").font(.badgeIcon).foregroundStyle(.white)
          }
          .frame(width: 60, height: 60)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(featured ? .sectionTitle.weight(.semibold) : .text.weight(.semibold))
          Text(featured ? "\(subtitle) · \(repo)" : subtitle).font(.text).foregroundStyle(.secondary)
          if !facts.isEmpty {
            HStack(spacing: 8) { ForEach(facts, id: \.self) { Chip(icon: "checkmark", text: $0) } }.padding(.top, 4)
          }
        }
        Spacer()
        action
      }
      if let p = progress, [.listing, .downloading, .verifying].contains(p.phase) {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: p.fraction)
          HStack {
            Text(phaseText(p)).font(.note).foregroundStyle(.secondary)
            Spacer()
            Text("\(Fmt.bytes(p.received)) / \(Fmt.bytes(p.total))").font(.note.monospacedDigit())
            if p.bytesPerSecond > 0 {
              Text("· \(Fmt.bytes(Int64(p.bytesPerSecond)))/s").font(.note.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let eta = p.eta { Text("· \(Fmt.duration(eta)) left").font(.note).foregroundStyle(.secondary) }
          }
        }
      }
      if case .failed(let msg)? = progress?.phase {
        Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.text)
      }
      if featured {
        Text("Weights are released under the **TimesFM Non-Commercial License v1.0** (research / non-production use). The app and engine code are Apache-2.0.")
          .font(.note).foregroundStyle(.secondary)
        + Text("  ")
        + Text("[View license](https://huggingface.co/google/timesfm-3.0-pytorch/blob/main/LICENSE)").font(.note)
      }
    }
    .card()
  }

  @ViewBuilder private var action: some View {
    if state.downloader.isActive(repo) {
      Button("Cancel") { state.downloader.cancel(repo: repo) }
        .controlSize(.large)
    } else if let m = installed {
      HStack {
        Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        Button(state.loadedModelId == m.id ? "Loaded" : "Load") {
          state.selectedModelId = m.id
          Task { await state.loadSelectedModel() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.loadedModelId == m.id || !state.engine.isRunning)
      }
      .controlSize(.large)
    } else {
      Button {
        state.downloader.start(repo: repo, token: Keychain.get("hf_token"))
      } label: {
        Label(resumeLabel, systemImage: "arrow.down.circle.fill")
          .frame(minWidth: featured ? 150 : 100)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(featured ? .extraLarge : .large)
    }
  }

  private var resumeLabel: String {
    switch progress?.phase {
    case .cancelled?, .failed?: return "Resume download"
    default: return featured ? "Download model" : "Download"
    }
  }

  private func phaseText(_ p: ModelDownloader.Progress) -> String {
    switch p.phase {
    case .listing: return "Contacting Hugging Face…"
    case .verifying: return "Verifying SHA-256 of \(p.file)…"
    default: return "Downloading \(p.file)"
    }
  }
}

struct ModelRow: View {
  @Environment(AppState.self) private var state
  var model: LocalModel
  var onDelete: () -> Void

  var body: some View {
    HStack(spacing: 16) {
      Image(systemName: model.isFinetuned ? "wand.and.stars" : "cube.fill")
        .font(.sectionTitle)
        .foregroundStyle(model.isFinetuned ? Color.purple : Color.accentColor)
        .frame(width: 34)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(model.displayName).font(.text.weight(.semibold))
          Text(model.isFinetuned ? "Fine-tuned" : "Base")
            .font(.note.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background((model.isFinetuned ? Color.purple : Color.accentColor).opacity(0.15), in: Capsule())
          if state.loadedModelId == model.id {
            Text("Loaded").font(.note.weight(.semibold)).foregroundStyle(.green)
          }
        }
        Text(detail).font(.note).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      Text(Fmt.bytes(model.sizeBytes)).font(.text.monospacedDigit()).foregroundStyle(.secondary)
      Button(state.loadedModelId == model.id ? "Unload" : "Load") {
        if state.loadedModelId == model.id {
          Task { await state.unloadModel() }
        } else {
          state.selectedModelId = model.id
          Task { await state.loadSelectedModel() }
        }
      }
      .disabled(!state.engine.isRunning)
      Menu {
        Button("Use as fine-tune base") {
          state.ftSettings.baseModelId = model.id
          state.section = .finetune
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.path)]) }
        Divider()
        Button("Delete…", role: .destructive, action: onDelete)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(12)
    .background(Theme.fill, in: Theme.shape)
  }

  private var detail: String {
    var parts: [String] = []
    if let a = model.architecture.numLayers, let d = model.architecture.modelDims {
      parts.append("\(a) layers · d=\(d)")
    }
    if model.isFinetuned {
      if let base = model.meta["base_model"]?.stringValue { parts.append("from \(base)") }
      if let method = model.meta["config"]?["method"]?.stringValue { parts.append(method.uppercased()) }
      if let z = model.meta["zero_shot_val"]?["val_loss"]?.doubleValue, let b = model.meta["best_val_loss"]?.doubleValue, z > 0 {
        parts.append(String(format: "val loss %.4f → %.4f (%+.1f%%)", z, b, (b / z - 1) * 100))
      }
      if let files = model.meta["dataset"]?["file"]?.stringValue { parts.append("on \(files)") }
    } else if let repo = model.meta["repo"]?.stringValue {
      parts.append(repo)
      if let rev = model.meta["revision"]?.stringValue { parts.append("rev \(rev.prefix(7))") }
    }
    return parts.joined(separator: " · ")
  }
}
