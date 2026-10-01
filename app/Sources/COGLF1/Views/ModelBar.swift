import SwiftUI

/// Top-center model picker, in the spirit of LM Studio: pick → load → unload.
struct ModelBar: View {
  @Environment(AppState.self) private var state
  @State private var showOptions = false

  var body: some View {
    @Bindable var state = state
    HStack(spacing: 12) {
      Menu {
        if state.models.isEmpty {
          Button("Download TimesFM 3…") { state.section = .models }
        }
        ForEach(state.models) { m in
          Button {
            state.selectedModelId = m.id
          } label: {
            Label("\(m.displayName)  ·  \(Fmt.bytes(m.sizeBytes))", systemImage: m.isFinetuned ? "wand.and.stars" : "cube")
          }
        }
        Divider()
        Button("Manage models…") { state.section = .models }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: selected?.isFinetuned == true ? "wand.and.stars" : "cube.fill")
            .foregroundStyle(.tint)
          Text(selected?.displayName ?? "Select a model to load")
            .lineLimit(1)
        }
        .frame(minWidth: 220, alignment: .leading)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      Picker("Backend", selection: $state.backend) {
        ForEach(Backend.allCases) { b in Text(b.title).tag(b) }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .fixedSize()
      .help("Inference backend. MLX runs natively on the Apple GPU and is usually fastest.")

      Button {
        showOptions.toggle()
      } label: {
        Image(systemName: "slider.horizontal.3")
      }
      .help("Load options and model flags")
      .popover(isPresented: $showOptions, arrowEdge: .bottom) {
        LoadOptionsView().environment(state).frame(width: 380).padding()
      }

      if state.isLoadingModel {
        ProgressView().controlSize(.small).frame(width: 60)
      } else if isLoadedSelection {
        Button("Unload") { Task { await state.unloadModel() } }
          .fixedSize()
          .help("Unload the model and free memory (⇧⌘E)")
      } else {
        // Not a prominent button: in a toolbar that turns every label in the bar white.
        Button { Task { await state.loadSelectedModel() } } label: {
          Text(state.status?.loaded == true ? "Switch" : "Load")
            .fontWeight(.semibold)
            .foregroundStyle(canLoad ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
          .fixedSize()
          .disabled(!canLoad)
          .help("Load the model into memory (⌘L)")
      }

      if state.status?.loaded == true {
        HStack(spacing: 4) {
          Circle().fill(.green).frame(width: 7, height: 7)
          Text("Ready")
            .font(.text)
            .foregroundStyle(.secondary)
            .fixedSize()
        }
      }
    }
    .padding(.horizontal, Theme.space * 2)
    .fixedSize(horizontal: true, vertical: true)
  }

  private var selected: LocalModel? { state.models.first { $0.id == state.selectedModelId } }
  private var canLoad: Bool { state.selectedModelId != nil && state.engine.isRunning }
  private var isLoadedSelection: Bool {
    state.status?.loaded == true && state.status?.modelId == state.selectedModelId && state.status?.backend == state.backend.rawValue
  }
}

struct LoadOptionsView: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state
    VStack(alignment: .leading, spacing: 16) {
      Text("Load options").font(.text.weight(.semibold))
      Form {
        Toggle("Compile graph (MLX)", isOn: $state.loadSettings.compile)
          .help("mx.compile fuses kernels: faster repeated forecasts, slower first run.")
        Stepper(value: $state.loadSettings.perCoreBatchSize, in: 1...512, step: 1) {
          LabeledContent("Batch size", value: "\(state.loadSettings.perCoreBatchSize)")
        }
        .help("per_core_batch_size: how many series are decoded per forward pass.")
        Stepper(value: $state.loadSettings.maxContextLength, in: 32...15360, step: 512) {
          LabeledContent("Max context", value: "\(state.loadSettings.maxContextLength)")
        }
        .help("Longest history fed to the model (TimesFM 3 supports up to 15,360 points).")
      }
      .formStyle(.columns)
      Divider()
      Text("Model flags").font(.text.weight(.semibold))
      Text("Changed flags apply to the loaded model immediately and are kept on reload.")
        .font(.note).foregroundStyle(.secondary)
      ModelFlagsEditor()
      HStack {
        Button("Reset flags to checkpoint defaults") {
          state.modelFlags = ModelFlags()
          state.loadSettings.overrides = [:]
          Task { await state.applyModelFlags() }
        }
        Spacer()
      }
    }
  }
}

struct ModelFlagsEditor: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state
    let supported = Set(state.status?.supportedFlags ?? ModelFlags().dict.keys.map { $0 })
    let why = "This engine cannot change this setting."
    VStack(alignment: .leading, spacing: Theme.space) {
      flag("Smooth long forecasts", "Overlaps the forecast pieces so a long horizon does not jump.", $state.modelFlags.useStitching)
      flag("Remove a straight trend", "Takes out a straight line when the series is mostly that line.", $state.modelFlags.useLinearDetrending)
      if state.modelFlags.useLinearDetrending {
        HStack {
          Text("Trend strength")
          Slider(value: $state.modelFlags.linearDetrendingThreshold, in: 0...1, step: 0.05)
          Text(String(format: "%.2f", state.modelFlags.linearDetrendingThreshold)).monospacedDigit().frame(width: 36)
        }
      }
      flag("Refine the scale", supported.contains("use_iterative_cpm_revin") ? "A second pass that steadies the size of the forecast." : why, $state.modelFlags.useIterativeCpmRevin, enabled: supported.contains("use_iterative_cpm_revin"))
      flag("Freeze the scale", supported.contains("use_frozen_running_stats") ? "Keep the scale fixed at the last known point." : why, $state.modelFlags.useFrozenRunningStats, enabled: supported.contains("use_frozen_running_stats"))
      HStack(spacing: Theme.space) {
        Text("Limit extreme values")
        TextField("", value: $state.modelFlags.valueClip, format: .number.notation(.scientific))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .frame(width: 100)
        HintButton(text: "Cuts off values larger than this, so a wild number cannot dominate the forecast.")
      }
    }
    .onChange(of: state.modelFlags) { _, new in
      state.loadSettings.overrides = new.dict.filter { supported.contains($0.key) }
      Task { await state.applyModelFlags() }
    }
  }

  private func flag(_ title: String, _ hint: String, _ isOn: Binding<Bool>, enabled: Bool = true) -> some View {
    HStack(spacing: Theme.space) {
      Toggle(title, isOn: isOn)
        .disabled(!enabled)
      HintButton(text: hint)
    }
  }
}
