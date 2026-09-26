import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum SidebarSection: String, CaseIterable, Identifiable {
  case forecast, data, finetune, models, server
  var id: String { rawValue }
  var title: String {
    switch self {
    case .forecast: return "Forecast"
    case .data: return "Data"
    case .finetune: return "Fine-tune"
    case .models: return "Models"
    case .server: return "Engine & API"
    }
  }
  var icon: String {
    switch self {
    case .forecast: return "chart.xyaxis.line"
    case .data: return "tablecells"
    case .finetune: return "slider.horizontal.below.square.and.square.filled"
    case .models: return "shippingbox"
    case .server: return "server.rack"
    }
  }
}

enum ColumnRole: String, CaseIterable, Identifiable {
  case ignore, target, past, future
  var id: String { rawValue }
  var title: String {
    switch self {
    case .ignore: return "Ignore"
    case .target: return "Target"
    case .past: return "Past covariate"
    case .future: return "Future covariate"
    }
  }
  var short: String {
    switch self {
    case .ignore: return "—"
    case .target: return "Target"
    case .past: return "Past"
    case .future: return "Future"
    }
  }
  var help: String {
    switch self {
    case .ignore: return "Not used."
    case .target: return "Forecast this column."
    case .past: return "Known only up to now (e.g. last week's temperature)."
    case .future: return "Known in advance for the horizon too (e.g. planned promotions, holidays). Put the future values in rows after the last target value."
    }
  }
}

enum Backend: String, CaseIterable, Identifiable {
  case mlx = "mlx"
  case torchMPS = "torch-mps"
  case torchCPU = "torch-cpu"
  var id: String { rawValue }
  var title: String {
    switch self {
    case .mlx: return "MLX · Apple GPU"
    case .torchMPS: return "PyTorch · Metal"
    case .torchCPU: return "PyTorch · CPU"
    }
  }
  var short: String {
    switch self {
    case .mlx: return "MLX"
    case .torchMPS: return "Torch MPS"
    case .torchCPU: return "Torch CPU"
    }
  }
}

struct ForecastParams: Codable, Equatable {
  var horizon: Int = 32
  var contextLength: Int? = nil
  var mode: String = "joint"
  var useSymmetricAveraging = false
  var useZnorm = false
  var makePositive = false
  var sortQuantiles = true
  var paddingMode = "none"
  var backtest = false
  var backtestWindows = 1
  var backtestStep: Int? = nil

  enum CodingKeys: String, CodingKey {
    case horizon, mode, backtest
    case contextLength = "context_length"
    case useSymmetricAveraging = "use_symmetric_averaging"
    case useZnorm = "use_znorm"
    case makePositive = "make_positive"
    case sortQuantiles = "sort_quantiles"
    case paddingMode = "padding_mode"
    case backtestWindows = "backtest_windows"
    case backtestStep = "backtest_step"
  }
}

struct LoadSettings: Codable, Equatable {
  var compile = true
  var perCoreBatchSize = 32
  var maxContextLength = 15360
  var overrides: [String: JSONValue] = [:]
}

/// Model flags that can be changed on a loaded model (see engine/runtime.py RUNTIME_FLAGS).
struct ModelFlags: Equatable {
  var useStitching = true
  var useLinearDetrending = true
  var linearDetrendingThreshold = 0.5
  var useIterativeCpmRevin = true
  var valueClip = 1e20
  var useFrozenRunningStats = false

  var dict: [String: JSONValue] {
    [
      "use_stitching": .bool(useStitching),
      "use_linear_detrending": .bool(useLinearDetrending),
      "linear_detrending_threshold": .number(linearDetrendingThreshold),
      "use_iterative_cpm_revin": .bool(useIterativeCpmRevin),
      "value_clip": .number(valueClip),
      "use_frozen_running_stats": .bool(useFrozenRunningStats),
    ]
  }

  init() {}
  /// Keeps defaults for flags the backend doesn't report.
  init(_ d: [String: JSONValue]) {
    useStitching = d["use_stitching"]?.boolValue ?? true
    useLinearDetrending = d["use_linear_detrending"]?.boolValue ?? true
    linearDetrendingThreshold = d["linear_detrending_threshold"]?.doubleValue ?? 0.5
    useIterativeCpmRevin = d["use_iterative_cpm_revin"]?.boolValue ?? true
    valueClip = d["value_clip"]?.doubleValue ?? 1e20
    useFrozenRunningStats = d["use_frozen_running_stats"]?.boolValue ?? false
  }
}

struct FinetuneSettings: Codable, Equatable {
  var baseModelId = ""
  var outputName = ""
  var contextLength = 512
  var horizon = 64
  var mode = "joint"
  var method = "lora"
  var loraRank = 8
  var loraAlpha = 16.0
  var loraDropout = 0.05
  var loraTargets = ["attention", "feedforward"]
  var trainLastLayers = 4
  var epochs = 5
  var windowsPerEpoch = 1024
  var batchSize = 16
  var learningRate = 1e-4
  var weightDecay = 0.0
  var warmupRatio = 0.05
  var gradClip = 1.0
  var loss = "quantile"
  var valFraction = 0.2
  var earlyStoppingPatience = 3
  var device = "mps"
  var seed = 42

  enum CodingKeys: String, CodingKey {
    case mode, method, epochs, loss, device, seed, horizon
    case baseModelId = "base_model_id"
    case outputName = "output_name"
    case contextLength = "context_length"
    case loraRank = "lora_rank"
    case loraAlpha = "lora_alpha"
    case loraDropout = "lora_dropout"
    case loraTargets = "lora_targets"
    case trainLastLayers = "train_last_layers"
    case windowsPerEpoch = "windows_per_epoch"
    case batchSize = "batch_size"
    case learningRate = "learning_rate"
    case weightDecay = "weight_decay"
    case warmupRatio = "warmup_ratio"
    case gradClip = "grad_clip"
    case valFraction = "val_fraction"
    case earlyStoppingPatience = "early_stopping_patience"
  }
}

struct SeriesSelection: Encodable {
  var datasetId: String
  var sheet: String?
  var timeColumn: String?
  var idColumn: String?
  var targets: [String]
  var pastCovariates: [String]
  var futureCovariates: [String]
  var fillMethod: String

  enum CodingKeys: String, CodingKey {
    case sheet, targets
    case datasetId = "dataset_id"
    case timeColumn = "time_column"
    case idColumn = "id_column"
    case pastCovariates = "past_covariates"
    case futureCovariates = "future_covariates"
    case fillMethod = "fill_method"
  }
}

@Observable @MainActor
final class AppState {
  let engine = EngineManager()
  let downloader = ModelDownloader()

  var section: SidebarSection = .forecast
  var alert: String?

  // Models
  var models: [LocalModel] = []
  var status: EngineStatus?
  var selectedModelId: String? = UserDefaults.standard.string(forKey: "selectedModelId") {
    didSet { UserDefaults.standard.set(selectedModelId, forKey: "selectedModelId") }
  }
  var backend: Backend = Backend(rawValue: UserDefaults.standard.string(forKey: "backend") ?? "") ?? .mlx {
    didSet { UserDefaults.standard.set(backend.rawValue, forKey: "backend") }
  }
  var loadSettings = LoadSettings()
  var isLoadingModel = false
  var modelFlags = ModelFlags()

  // Data
  var dataset: DatasetInfo?
  var sheetName: String?
  var timeColumn: String?
  var idColumn: String?
  var roles: [String: ColumnRole] = [:]
  var fillMethod = "interpolate"
  var isOpeningFile = false

  // Forecast
  var params = ForecastParams()
  var results: [ForecastResult] = []
  var currentResultId: String?
  var isForecasting = false

  // Fine-tuning
  var ftSettings = FinetuneSettings()
  var ftJob: JobSnapshot?
  private var ftPoll: Task<Void, Never>?

  var currentResult: ForecastResult? { results.first { $0.resultId == currentResultId } ?? results.first }
  var sheet: SheetInfo? { dataset?.sheets.first { $0.name == sheetName } ?? dataset?.sheets.first }
  var loadedModelId: String? { status?.loaded == true ? status?.modelId : nil }
  var hasModel: Bool { !models.isEmpty }
  var targets: [String] { orderedColumns(.target) }
  var pastCovariates: [String] { orderedColumns(.past) }
  var futureCovariates: [String] { orderedColumns(.future) }

  private func orderedColumns(_ role: ColumnRole) -> [String] {
    (sheet?.columns ?? []).map(\.name).filter { roles[$0] == role }
  }

  init() {
    downloader.onFinished = { [weak self] repo in
      Task { @MainActor in
        await self?.refreshModels()
        if self?.selectedModelId == nil { self?.selectedModelId = ModelDownloader.modelId(for: repo) }
      }
    }
  }

  var client: EngineClient { engine.client }

  // MARK: Engine

  func boot() async {
    await engine.bootstrap()
    await afterEngineStart()
  }

  func afterEngineStart() async {
    guard engine.isRunning else { return }
    await refreshModels()
    await refreshStatus()
    // Re-open the dataset after an engine restart.
    if let path = dataset?.path { await openFile(URL(fileURLWithPath: path), keepSelection: true) }
  }

  func refreshModels() async {
    guard engine.isRunning else {
      models = Self.scanModelsLocally()
      return
    }
    do {
      models = try await client.get("models", as: ModelsResponse.self).models
    } catch {
      models = Self.scanModelsLocally()
    }
    if selectedModelId == nil || !models.contains(where: { $0.id == selectedModelId }) {
      selectedModelId = models.first(where: { !$0.isFinetuned })?.id ?? models.first?.id
    }
    if ftSettings.baseModelId.isEmpty || !models.contains(where: { $0.id == ftSettings.baseModelId }) {
      ftSettings.baseModelId = models.first(where: { !$0.isFinetuned })?.id ?? models.first?.id ?? ""
    }
  }

  /// Minimal listing used before the engine runs (so downloads show up immediately).
  static func scanModelsLocally() -> [LocalModel] {
    let fm = FileManager.default
    let dir = EngineManager.modelsDir
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
    return names.sorted().compactMap { name in
      let p = dir.appendingPathComponent(name)
      let w = p.appendingPathComponent("model.safetensors")
      guard !name.hasPrefix("."), fm.fileExists(atPath: p.appendingPathComponent("config.json").path),
            let size = try? fm.attributesOfItem(atPath: w.path)[.size] as? Int64 else { return nil }
      var meta: [String: JSONValue] = [:]
      if let d = try? Data(contentsOf: p.appendingPathComponent("cogl_meta.json")),
         let m = try? JSONDecoder().decode([String: JSONValue].self, from: d) { meta = m }
      return LocalModel(
        id: name, path: p.path, sizeBytes: size, kind: meta["kind"]?.stringValue ?? "base",
        source: meta["source"]?.stringValue, displayName: meta["display_name"]?.stringValue ?? name,
        meta: meta, architecture: .init(), flags: [:])
    }
  }

  func refreshStatus() async {
    guard engine.isRunning else { status = nil; return }
    if let s = try? await client.get("status", as: EngineStatus.self) {
      status = s
      if let f = s.flags { modelFlags = ModelFlags(f) }
    }
  }

  // MARK: Model loading

  func loadSelectedModel() async {
    guard let id = selectedModelId else { alert = "Download a model first (Models page)."; return }
    guard engine.isRunning else { alert = "The engine isn't running yet."; return }
    isLoadingModel = true
    defer { isLoadingModel = false }
    struct Body: Encodable {
      var model_id: String
      var backend: String
      var compile: Bool
      var per_core_batch_size: Int
      var max_context_length: Int
      var overrides: [String: JSONValue]
    }
    let body = Body(
      model_id: id, backend: backend.rawValue, compile: loadSettings.compile,
      per_core_batch_size: loadSettings.perCoreBatchSize, max_context_length: loadSettings.maxContextLength,
      overrides: loadSettings.overrides)
    do {
      status = try await client.post("load", body: body, as: EngineStatus.self)
      if let f = status?.flags { modelFlags = ModelFlags(f) }
    } catch {
      alert = error.localizedDescription
      await refreshStatus()
    }
  }

  func unloadModel() async {
    status = try? await client.post("unload", as: EngineStatus.self)
  }

  func applyModelFlags() async {
    guard status?.loaded == true else { return }
    var flags = modelFlags.dict
    if let supported = status?.supportedFlags { flags = flags.filter { supported.contains($0.key) } }
    do {
      status = try await client.post("flags", body: ["overrides": flags], as: EngineStatus.self)
    } catch {
      alert = error.localizedDescription
      await refreshStatus()
    }
  }

  func deleteModel(_ m: LocalModel) async {
    do {
      if engine.isRunning {
        struct R: Decodable { var deleted: String }
        _ = try await client.delete("models/\(m.id)", as: R.self)
      } else {
        try FileManager.default.removeItem(atPath: m.path)
      }
    } catch {
      alert = error.localizedDescription
    }
    await refreshModels()
    await refreshStatus()
  }

  func importModelFolder(_ url: URL) async {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.appendingPathComponent("config.json").path),
          fm.fileExists(atPath: url.appendingPathComponent("model.safetensors").path) else {
      alert = "That folder isn't a TimesFM 3 checkpoint (needs config.json and model.safetensors)."
      return
    }
    var dest = EngineManager.modelsDir.appendingPathComponent(url.lastPathComponent)
    var i = 2
    while fm.fileExists(atPath: dest.path) {
      dest = EngineManager.modelsDir.appendingPathComponent("\(url.lastPathComponent)-\(i)")
      i += 1
    }
    do {
      try fm.createDirectory(at: EngineManager.modelsDir, withIntermediateDirectories: true)
      try await Task.detached { try fm.copyItem(at: url, to: dest) }.value
      let metaURL = dest.appendingPathComponent("cogl_meta.json")
      if !fm.fileExists(atPath: metaURL.path) {
        let meta = ["kind": "base", "source": "local", "display_name": url.lastPathComponent]
        try JSONSerialization.data(withJSONObject: meta).write(to: metaURL)
      }
    } catch {
      alert = "Import failed: \(error.localizedDescription)"
    }
    await refreshModels()
  }

  // MARK: Data

  func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText] +
      ["xlsx", "xlsm", "xls", "csv", "tsv"].compactMap { UTType(filenameExtension: $0) }
    panel.allowsMultipleSelection = false
    panel.message = "Choose a CSV or Excel file with your time series"
    if panel.runModal() == .OK, let url = panel.url {
      Task { await openFile(url) }
    }
  }

  func openFile(_ url: URL, keepSelection: Bool = false) async {
    guard engine.isRunning else { alert = "Start the engine first (Engine & API)."; return }
    isOpeningFile = true
    defer { isOpeningFile = false }
    do {
      let ds = try await client.post("datasets/open", body: ["path": url.path], as: DatasetInfo.self)
      let previous = (sheetName, timeColumn, idColumn, roles)
      dataset = ds
      if keepSelection, ds.sheets.contains(where: { $0.name == previous.0 }) {
        (sheetName, timeColumn, idColumn, roles) = previous
      } else {
        selectSheet(ds.sheets.first?.name)
      }
    } catch {
      alert = error.localizedDescription
    }
  }

  func openSample(_ name: String) async {
    guard let url = Self.sampleURL(name) else { alert = "Sample not found."; return }
    await openFile(url)
  }

  static func sampleURL(_ name: String) -> URL? {
    if let u = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "samples") { return u }
    if let dir = EngineManager.engineDir?.deletingLastPathComponent().appendingPathComponent("samples/\(name)"),
       FileManager.default.fileExists(atPath: dir.path) { return dir }
    return nil
  }

  func selectSheet(_ name: String?) {
    sheetName = name
    guard let s = sheet else { return }
    timeColumn = s.timeColumn
    idColumn = nil
    var r: [String: ColumnRole] = [:]
    let numeric = s.columns.filter { $0.numeric && $0.name != s.timeColumn }
    for c in numeric { r[c.name] = .ignore }
    // Sensible default: the first numeric column is the target.
    if let first = numeric.first { r[first.name] = .target }
    roles = r
    results.removeAll()
    currentResultId = nil
  }

  func selection() -> SeriesSelection? {
    guard let ds = dataset else { return nil }
    return SeriesSelection(
      datasetId: ds.datasetId, sheet: sheet?.name, timeColumn: timeColumn, idColumn: idColumn,
      targets: targets, pastCovariates: pastCovariates, futureCovariates: futureCovariates, fillMethod: fillMethod)
  }

  // MARK: Forecast

  func runForecast() async {
    guard let sel = selection() else { alert = "Open a CSV or Excel file first."; return }
    guard !sel.targets.isEmpty else { alert = "Mark at least one column as Target."; return }
    if status?.loaded != true {
      await loadSelectedModel()
      guard status?.loaded == true else { return }
    }
    isForecasting = true
    defer { isForecasting = false }
    struct Body: Encodable { var data: SeriesSelection; var params: ForecastParams }
    do {
      let r = try await client.post("forecast", body: Body(data: sel, params: params), as: ForecastResult.self)
      results.insert(r, at: 0)
      if results.count > 25 { results.removeLast() }
      currentResultId = r.resultId
    } catch {
      alert = error.localizedDescription
      await refreshStatus()
    }
  }

  func export(_ result: ForecastResult) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "xlsx")!, .commaSeparatedText]
    panel.nameFieldStringValue = "forecast-\(result.resultId).xlsx"
    panel.message = "Export forecast (choose .xlsx or .csv)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        struct R: Decodable { var path: String }
        let r = try await client.post("export", body: ["result_id": result.resultId, "path": url.path], as: R.self)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)])
      } catch {
        alert = error.localizedDescription
      }
    }
  }

  // MARK: Fine-tuning

  func startFinetune() async {
    guard let sel = selection() else { alert = "Open a data file first."; return }
    guard !sel.targets.isEmpty else { alert = "Mark at least one column as Target in the data panel."; return }
    guard !ftSettings.baseModelId.isEmpty else { alert = "Download a base model first."; return }
    struct Body: Encodable { var data: SeriesSelection; var config: FinetuneSettings }
    do {
      ftJob = try await client.post("finetune", body: Body(data: sel, config: ftSettings), as: JobSnapshot.self)
      pollFinetune()
    } catch {
      alert = error.localizedDescription
    }
  }

  private func pollFinetune() {
    ftPoll?.cancel()
    ftPoll = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let id = self.ftJob?.id else { return }
        if let snap = try? await self.client.get("jobs/\(id)?log_tail=400", as: JobSnapshot.self) {
          self.ftJob = snap
          if !snap.isActive {
            await self.refreshModels()
            return
          }
        }
        try? await Task.sleep(for: .milliseconds(700))
      }
    }
  }

  func stopFinetune(save: Bool) async {
    guard let id = ftJob?.id else { return }
    _ = try? await client.post("jobs/\(id)/\(save ? "finish" : "cancel")", as: JobSnapshot.self)
  }
}
