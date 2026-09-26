import Charts
import SwiftUI

struct FinetuneView: View {
  @Environment(AppState.self) private var state

  var body: some View {
    HStack(spacing: 0) {
      DataPanel().frame(width: 300)
      Divider()
      if !state.engine.isRunning || !state.hasModel {
        SetupChecklist()
      } else {
        FinetuneForm()
          .frame(width: 400)
          .frame(maxHeight: .infinity)
        Divider()
        FinetuneMonitor()
          .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
    }
    .navigationTitle("Fine-tune")
  }
}

struct FinetuneForm: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state
    let running = state.ftJob?.isActive == true
    Form {
      Section {
        Picker("Base model", selection: $state.ftSettings.baseModelId) {
          ForEach(state.models) { m in Text(m.displayName).tag(m.id) }
        }
        TextField("Save as", text: $state.ftSettings.outputName, prompt: Text("\(state.ftSettings.baseModelId)-ft"))
        HStack {
          Text("Preset").foregroundStyle(.secondary)
          Spacer()
          Button("Quick") { preset(.quick) }
          Button("Balanced") { preset(.balanced) }
          Button("Thorough") { preset(.thorough) }
        }
      } header: {
        Text("Model")
      } footer: {
        Text("Targets and covariates come from the data panel. The result is saved as a new model you can load like the base one.")
      }

      Section("Method") {
        Picker("Method", selection: $state.ftSettings.method) {
          Text("LoRA").tag("lora")
          Text("Last layers").tag("last_layers")
          Text("Head only").tag("head")
          Text("Full").tag("full")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text(methodHelp).font(.caption).foregroundStyle(.secondary)
        if state.ftSettings.method == "lora" {
          Stepper(value: $state.ftSettings.loraRank, in: 1...256) { LabeledContent("Rank r", value: "\(state.ftSettings.loraRank)") }
          LabeledContent("Alpha") { TextField("", value: $state.ftSettings.loraAlpha, format: .number).frame(width: 70) }
          LabeledContent("Dropout") { TextField("", value: $state.ftSettings.loraDropout, format: .number).frame(width: 70) }
          HStack {
            Text("Adapt").foregroundStyle(.secondary)
            Spacer()
            ForEach([("attention", "Attention"), ("feedforward", "Feed-forward"), ("head", "Head"), ("input", "Input")], id: \.0) { key, name in
              Toggle(name, isOn: Binding(
                get: { state.ftSettings.loraTargets.contains(key) },
                set: { on in
                  state.ftSettings.loraTargets.removeAll { $0 == key }
                  if on { state.ftSettings.loraTargets.append(key) }
                }))
                .toggleStyle(.button)
                .controlSize(.small)
            }
          }
        }
        if state.ftSettings.method == "last_layers" {
          Stepper(value: $state.ftSettings.trainLastLayers, in: 1...20) {
            LabeledContent("Trainable layers", value: "last \(state.ftSettings.trainLastLayers) of 20")
          }
        }
      }

      Section("Windows") {
        LabeledContent("Context length") { intField($state.ftSettings.contextLength, 32...15360) }
        LabeledContent("Horizon") { intField($state.ftSettings.horizon, 1...4096) }
        Picker("Series layout", selection: $state.ftSettings.mode) {
          Text("Joint (multivariate)").tag("joint")
          Text("Independent").tag("independent")
        }
        LabeledContent("Validation tail") {
          HStack {
            Slider(value: $state.ftSettings.valFraction, in: 0.05...0.5, step: 0.05)
            Text("\(Int(state.ftSettings.valFraction * 100))%").monospacedDigit().frame(width: 36)
          }
        }
        .help("The last part of every series is held out; the zero-shot model is scored on it first, then after every epoch.")
      }

      Section("Optimization") {
        Stepper(value: $state.ftSettings.epochs, in: 1...200) { LabeledContent("Epochs", value: "\(state.ftSettings.epochs)") }
        LabeledContent("Windows / epoch") { intField($state.ftSettings.windowsPerEpoch, 8...1_000_000) }
        Stepper(value: $state.ftSettings.batchSize, in: 1...512) { LabeledContent("Batch size", value: "\(state.ftSettings.batchSize)") }
        LabeledContent("Learning rate") {
          TextField("", value: $state.ftSettings.learningRate, format: .number.notation(.scientific)).frame(width: 90)
        }
        LabeledContent("Weight decay") { TextField("", value: $state.ftSettings.weightDecay, format: .number).frame(width: 90) }
        LabeledContent("Warmup ratio") { TextField("", value: $state.ftSettings.warmupRatio, format: .number).frame(width: 90) }
        LabeledContent("Grad clip") { TextField("", value: $state.ftSettings.gradClip, format: .number).frame(width: 90) }
        Picker("Loss", selection: $state.ftSettings.loss) {
          Text("Quantile (pinball)").tag("quantile")
          Text("MSE on median").tag("mse")
        }
        Stepper(value: $state.ftSettings.earlyStoppingPatience, in: 0...50) {
          LabeledContent("Early stop patience", value: state.ftSettings.earlyStoppingPatience == 0 ? "off" : "\(state.ftSettings.earlyStoppingPatience) epochs")
        }
        Picker("Device", selection: $state.ftSettings.device) {
          Text("Apple GPU (Metal)").tag("mps")
          Text("CPU").tag("cpu")
        }
        LabeledContent("Seed") { intField($state.ftSettings.seed, 0...1_000_000) }
      }

      Section {
        HStack {
          Button {
            Task { await state.startFinetune() }
          } label: {
            Label("Start fine-tuning", systemImage: "play.fill").frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(running || state.targets.isEmpty || state.dataset == nil)
        }
        if state.dataset == nil || state.targets.isEmpty {
          Text("Open a file and mark target columns in the data panel.").font(.caption).foregroundStyle(.secondary)
        }
      } footer: {
        Text("Fine-tuned weights inherit the base model's license. Full fine-tuning of 330M parameters needs ≈ 6–10 GB of unified memory.")
      }
    }
    .formStyle(.grouped)
    .disabled(running)
  }

  private func intField(_ b: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
    TextField("", value: Binding(get: { b.wrappedValue }, set: { b.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }), format: .number)
      .frame(width: 90)
  }

  private var methodHelp: String {
    switch state.ftSettings.method {
    case "lora": return "Low-rank adapters on the chosen layers; merged into the weights when saved. Fast, memory-light, hard to overfit."
    case "last_layers": return "Unfreeze the last transformer layers and the output head."
    case "head": return "Train only the output projection. Fastest; small, careful adaptation."
    default: return "Train all 330M parameters. Most capacity; needs more data to avoid overfitting."
    }
  }

  private enum Preset { case quick, balanced, thorough }
  private func preset(_ p: Preset) {
    switch p {
    case .quick:
      state.ftSettings.method = "lora"; state.ftSettings.loraRank = 4; state.ftSettings.epochs = 3
      state.ftSettings.windowsPerEpoch = 512; state.ftSettings.learningRate = 3e-4; state.ftSettings.batchSize = 16
    case .balanced:
      state.ftSettings.method = "lora"; state.ftSettings.loraRank = 8; state.ftSettings.epochs = 8
      state.ftSettings.windowsPerEpoch = 2048; state.ftSettings.learningRate = 1e-4; state.ftSettings.batchSize = 16
    case .thorough:
      state.ftSettings.method = "last_layers"; state.ftSettings.trainLastLayers = 6; state.ftSettings.epochs = 20
      state.ftSettings.windowsPerEpoch = 4096; state.ftSettings.learningRate = 3e-5; state.ftSettings.batchSize = 32
      state.ftSettings.earlyStoppingPatience = 4
    }
  }
}

struct FinetuneMonitor: View {
  @Environment(AppState.self) private var state

  var body: some View {
    if let job = state.ftJob {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(job.title).font(.title3.weight(.semibold))
            Text(statusText(job)).font(.callout).foregroundStyle(job.status == "failed" ? .red : .secondary)
          }
          Spacer()
          if job.isActive {
            Button("Stop & save") { Task { await state.stopFinetune(save: true) } }
              .help("Finish now and save the best weights so far")
            Button("Cancel", role: .destructive) { Task { await state.stopFinetune(save: false) } }
          }
        }
        ProgressView(value: job.progress)
        if job.status == "completed", let r = job.result { resultCard(r) }
        if let e = job.error { Text(e).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
        charts(job)
        LogView(lines: job.logs)
      }
      .padding(18)
    } else {
      ContentUnavailableView {
        Label("Adapt TimesFM 3 to your data", systemImage: "wand.and.stars")
      } description: {
        Text("Fine-tuning trains on sliding windows of your series and checks every epoch against a held-out tail, so you can see whether it beats the zero-shot model.")
      }
    }
  }

  private func statusText(_ j: JobSnapshot) -> String {
    switch j.status {
    case "completed": return "Completed"
    case "cancelled": return "Cancelled"
    case "failed": return "Failed"
    default: return j.message.isEmpty ? "Starting…" : j.message
    }
  }

  @ViewBuilder private func resultCard(_ r: JSONValue) -> some View {
    let id = r["model_id"]?.stringValue ?? ""
    HStack(spacing: 14) {
      Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(.green)
      VStack(alignment: .leading, spacing: 3) {
        Text("Saved as \(id)").font(.headline)
        if let imp = r["improvement_percent"]?.doubleValue {
          Text(imp > 0 ? String(format: "Validation loss %.1f%% lower than zero-shot (best epoch %d)", imp, Int(r["best_epoch"]?.doubleValue ?? 0))
                       : "Did not beat the zero-shot model on validation; weights saved unchanged.")
            .font(.callout).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button("Load & forecast") {
        state.selectedModelId = id
        state.section = .forecast
        Task {
          await state.loadSelectedModel()
          state.params.backtest = true
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(12)
    .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder private func charts(_ job: JobSnapshot) -> some View {
    let train = job.metrics.filter { $0["kind"]?.stringValue == "train" }
      .compactMap { m -> (Int, Double)? in
        guard let s = m["step"]?.doubleValue, let l = m["loss"]?.doubleValue else { return nil }
        return (Int(s), l)
      }
    let val = job.metrics.filter { $0["kind"]?.stringValue == "val" }
      .compactMap { m -> (Int, Double, Double?)? in
        guard let e = m["epoch"]?.doubleValue, let l = m["val_loss"]?.doubleValue else { return nil }
        return (Int(e), l, m["val_mae"]?.doubleValue)
      }
    HStack(spacing: 14) {
      VStack(alignment: .leading) {
        Text("Training loss").font(.caption).foregroundStyle(.secondary)
        Chart {
          ForEach(train, id: \.0) { s, l in
            LineMark(x: .value("Step", s), y: .value("Loss", l)).foregroundStyle(Color.accentColor)
          }
        }
        .chartYScale(domain: .automatic(includesZero: false))
      }
      VStack(alignment: .leading) {
        Text("Validation loss per epoch (0 = zero-shot)").font(.caption).foregroundStyle(.secondary)
        Chart {
          if let base = val.first(where: { $0.0 == 0 }) {
            RuleMark(y: .value("Zero-shot", base.1))
              .foregroundStyle(.secondary)
              .lineStyle(StrokeStyle(dash: [4, 3]))
              .annotation(position: .top, alignment: .leading) { Text("zero-shot").font(.caption2).foregroundStyle(.secondary) }
          }
          ForEach(val, id: \.0) { e, l, _ in
            LineMark(x: .value("Epoch", e), y: .value("Val loss", l)).foregroundStyle(.purple)
            PointMark(x: .value("Epoch", e), y: .value("Val loss", l)).foregroundStyle(.purple)
          }
        }
        .chartYScale(domain: .automatic(includesZero: false))
      }
    }
    .frame(height: 190)
  }
}

struct LogView: View {
  var lines: [String]
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 1) {
          ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
            Text(l).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(8)
      }
      .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
      .onChange(of: lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
    }
  }
}
