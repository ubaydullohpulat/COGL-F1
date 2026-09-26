import AppKit
import SwiftUI

struct ModelsView: View {
  @Environment(AppState.self) private var state
  @State private var customRepo = ""
  @State private var confirmDelete: LocalModel?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header
        DownloadCard(repo: ModelDownloader.defaultRepo, title: "TimesFM 3.0", subtitle: "Google Research · 330M parameters",
                     facts: ["Zero-shot", "Multivariate", "Covariates", "9 quantiles", "Context 15K", "1.32 GB"],
                     featured: true)

        VStack(alignment: .leading, spacing: 8) {
          Text("Other Hugging Face checkpoint").font(.headline)
          Text("Any repository with a TimesFM 3 `config.json` + `model.safetensors` (e.g. your own fine-tunes pushed to the Hub).")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            TextField("owner/repository", text: $customRepo)
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 360)
              .onSubmit(download)
            Button("Download", action: download)
              .disabled(customRepo.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Import folder…") { importFolder() }
              .help("Copy a local checkpoint folder into the library")
          }
          ForEach(Array(state.downloader.progress.keys.filter { $0 != ModelDownloader.defaultRepo }.sorted()), id: \.self) { repo in
            DownloadCard(repo: repo, title: repo, subtitle: "Hugging Face", facts: [], featured: false)
          }
        }

        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("My models").font(.title3.weight(.semibold))
            Spacer()
            Button { NSWorkspace.shared.open(EngineManager.modelsDir) } label: { Label("Show in Finder", systemImage: "folder") }
            Button { Task { await state.refreshModels() } } label: { Image(systemName: "arrow.clockwise") }
          }
          if state.models.isEmpty {
            Text("No models yet. Download TimesFM 3 above.")
              .foregroundStyle(.secondary).padding(.vertical, 20)
          } else {
            ForEach(state.models) { m in
              ModelRow(model: m, onDelete: { confirmDelete = m })
            }
          }
        }
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
    VStack(alignment: .leading, spacing: 4) {
      Text("Models").font(.largeTitle.weight(.semibold))
      Text("Models live in \(EngineManager.modelsDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        .font(.callout).foregroundStyle(.secondary)
    }
  }

  private func download() {
    let repo = customRepo.trimmingCharacters(in: .whitespaces)
    guard repo.contains("/") else { state.alert = "Use the form owner/repository."; return }
    state.downloader.start(repo: repo, token: Keychain.get("hf_token"))
  }

  private func importFolder() {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.message = "Choose a folder containing config.json and model.safetensors"
    if p.runModal() == .OK, let url = p.url { Task { await state.importModelFolder(url) } }
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
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 16) {
        if featured {
          ZStack {
            RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [.blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
          }
          .frame(width: 60, height: 60)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(featured ? .title2.weight(.semibold) : .headline)
          Text(featured ? "\(subtitle) · \(repo)" : subtitle).font(.callout).foregroundStyle(.secondary)
          if !facts.isEmpty {
            HStack(spacing: 6) { ForEach(facts, id: \.self) { Chip(icon: "checkmark", text: $0) } }.padding(.top, 4)
          }
        }
        Spacer()
        action
      }
      if let p = progress, [.listing, .downloading, .verifying].contains(p.phase) {
        VStack(alignment: .leading, spacing: 5) {
          ProgressView(value: p.fraction)
          HStack {
            Text(phaseText(p)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(Fmt.bytes(p.received)) / \(Fmt.bytes(p.total))").font(.caption.monospacedDigit())
            if p.bytesPerSecond > 0 {
              Text("· \(Fmt.bytes(Int64(p.bytesPerSecond)))/s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let eta = p.eta { Text("· \(Fmt.duration(eta)) left").font(.caption).foregroundStyle(.secondary) }
          }
        }
      }
      if case .failed(let msg)? = progress?.phase {
        Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
      }
      if featured {
        Text("Weights are released under the **TimesFM Non-Commercial License v1.0** (research / non-production use). The app and engine code are Apache-2.0.")
          .font(.caption).foregroundStyle(.secondary)
        + Text("  ")
        + Text("[View license](https://huggingface.co/google/timesfm-3.0-pytorch/blob/main/LICENSE)").font(.caption)
      }
    }
    .padding(featured ? 20 : 14)
    .background(
      RoundedRectangle(cornerRadius: 16)
        .fill(featured ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.quaternary.opacity(0.4)))
        .shadow(color: .black.opacity(featured ? 0.08 : 0), radius: 8, y: 2))
    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6)))
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
    HStack(spacing: 14) {
      Image(systemName: model.isFinetuned ? "wand.and.stars" : "cube.fill")
        .font(.title2)
        .foregroundStyle(model.isFinetuned ? Color.purple : Color.accentColor)
        .frame(width: 34)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(model.displayName).font(.headline)
          Text(model.isFinetuned ? "Fine-tuned" : "Base")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((model.isFinetuned ? Color.purple : Color.accentColor).opacity(0.15), in: Capsule())
          if state.loadedModelId == model.id {
            Text("Loaded").font(.caption2.weight(.semibold)).foregroundStyle(.green)
          }
        }
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      Text(Fmt.bytes(model.sizeBytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
      Button(state.loadedModelId == model.id ? "Eject" : "Load") {
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
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
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
