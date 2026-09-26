import Foundation

// MARK: - Arbitrary JSON

enum JSONValue: Codable, Hashable, CustomStringConvertible {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let b = try? c.decode(Bool.self) { self = .bool(b) }
    else if let n = try? c.decode(Double.self) { self = .number(n) }
    else if let s = try? c.decode(String.self) { self = .string(s) }
    else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
    else { self = .object(try c.decode([String: JSONValue].self)) }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
  var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
  var stringValue: String? { if case .string(let s) = self { return s }; return nil }
  subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }

  var description: String {
    switch self {
    case .null: return "—"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(format: "%g", n)
    case .string(let s): return s
    case .array(let a): return "[" + a.map(\.description).joined(separator: ", ") + "]"
    case .object(let o): return "{" + o.keys.sorted().map { "\($0): \(o[$0]!.description)" }.joined(separator: ", ") + "}"
    }
  }
}

// MARK: - Engine / health

struct HealthInfo: Decodable {
  struct Backend: Decodable {
    var available: Bool
    var device: String?
    var version: String?
    var mps: Bool?
    var error: String?
  }
  var ok: Bool
  var version: String
  var python: String
  var platform: String
  var modelsDir: String
  var timesfmVersion: String?
  var backends: [String: Backend]

  enum CodingKeys: String, CodingKey {
    case ok, version, python, platform, backends
    case modelsDir = "models_dir"
    case timesfmVersion = "timesfm_version"
  }
}

struct EngineStatus: Decodable {
  var loaded: Bool
  var modelId: String?
  var backend: String?
  var flags: [String: JSONValue]?
  var supportedFlags: [String]?
  var loadSeconds: Double?
  var peakRssBytes: Double?
  var mlxActiveBytes: Double?

  enum CodingKeys: String, CodingKey {
    case loaded, backend, flags
    case modelId = "model_id"
    case supportedFlags = "supported_flags"
    case loadSeconds = "load_seconds"
    case peakRssBytes = "peak_rss_bytes"
    case mlxActiveBytes = "mlx_active_bytes"
  }
}

// MARK: - Models

struct LocalModel: Decodable, Identifiable, Hashable {
  struct Architecture: Decodable, Hashable {
    var numLayers: Int?
    var modelDims: Int?
    var numHeads: Int?
    var inputPatchLen: Int?
    var outputPatchLen: Int?
    enum CodingKeys: String, CodingKey {
      case numLayers = "num_layers"
      case modelDims = "model_dims"
      case numHeads = "num_heads"
      case inputPatchLen = "input_patch_len"
      case outputPatchLen = "output_patch_len"
    }
  }
  var id: String
  var path: String
  var sizeBytes: Int64
  var kind: String
  var source: String?
  var displayName: String
  var meta: [String: JSONValue]
  var architecture: Architecture
  var flags: [String: JSONValue]

  var isFinetuned: Bool { kind == "finetuned" }

  enum CodingKeys: String, CodingKey {
    case id, path, kind, source, meta, architecture, flags
    case sizeBytes = "size_bytes"
    case displayName = "display_name"
  }
}

struct ModelsResponse: Decodable {
  var models: [LocalModel]
}

// MARK: - Datasets

struct DatasetInfo: Decodable, Identifiable {
  var id: String { datasetId }
  var datasetId: String
  var name: String
  var path: String?
  var sheets: [SheetInfo]
  enum CodingKeys: String, CodingKey {
    case name, path, sheets
    case datasetId = "dataset_id"
  }
}

struct SheetInfo: Decodable, Hashable {
  struct Column: Decodable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var dtype: String
    var numeric: Bool
    var missing: Int
    var unique: Int
    var min: Double?
    var max: Double?
    var mean: Double?
    var std: Double?
  }
  struct Preview: Decodable, Hashable {
    var columns: [String]
    var rows: [[JSONValue]]
  }
  var name: String
  var rows: Int
  var columns: [Column]
  var timeColumn: String?
  var frequency: String?
  var timeRange: [String]?
  var idCandidates: [String]
  var preview: Preview

  enum CodingKeys: String, CodingKey {
    case name, rows, columns, frequency, preview
    case timeColumn = "time_column"
    case timeRange = "time_range"
    case idCandidates = "id_candidates"
  }
}

// MARK: - Forecast

typealias Metrics = [String: Double?]

struct ForecastResult: Decodable, Identifiable {
  var id: String { resultId }
  var resultId: String
  var modelId: String?
  var backend: String?
  var flags: [String: JSONValue]
  var horizon: Int
  var contextLength: Int
  var mode: String
  var backtest: Bool
  var quantileLevels: [Double]
  var elapsedSeconds: Double
  var numQueries: Int
  var groups: [ForecastGroup]
  var metrics: Metrics?
  var warnings: [String]

  enum CodingKeys: String, CodingKey {
    case flags, horizon, mode, backtest, groups, metrics, warnings, backend
    case resultId = "result_id"
    case modelId = "model_id"
    case contextLength = "context_length"
    case quantileLevels = "quantile_levels"
    case elapsedSeconds = "elapsed_seconds"
    case numQueries = "num_queries"
  }
}

struct ForecastGroup: Decodable, Identifiable {
  var id: String { key }
  var key: String
  var frequency: String?
  var nHistory: Int
  var targets: [ForecastTarget]
  enum CodingKeys: String, CodingKey {
    case key, frequency, targets
    case nHistory = "n_history"
  }
}

struct ForecastTarget: Decodable, Identifiable {
  struct History: Decodable {
    var index: [Int]
    var time: [String]?
    var value: [Double?]
  }
  var id: String { name }
  var name: String
  var history: History
  var windows: [ForecastWindow]
  var metrics: Metrics?
}

struct ForecastWindow: Decodable, Identifiable {
  var id: Int { window }
  var window: Int
  var cutoffIndex: Int
  var contextStartIndex: Int
  var index: [Int]
  var time: [String]?
  var median: [Double?]
  var quantiles: [[Double?]]
  var actual: [Double?]?
  var metrics: Metrics?

  enum CodingKeys: String, CodingKey {
    case window, index, time, median, quantiles, actual, metrics
    case cutoffIndex = "cutoff_index"
    case contextStartIndex = "context_start_index"
  }
}

// MARK: - Jobs

struct JobSnapshot: Decodable, Identifiable {
  var id: String
  var kind: String
  var title: String
  var status: String
  var progress: Double
  var message: String
  var logs: [String]
  var metrics: [[String: JSONValue]]
  var result: JSONValue?
  var error: String?

  var isActive: Bool { status == "queued" || status == "running" }
}

struct APIErrorBody: Decodable {
  var detail: JSONValue
}
