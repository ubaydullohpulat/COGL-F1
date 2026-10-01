import XCTest

@testable import COGLF1

/// What the app reads from the engine, and how it words it.
final class EngineTypesTests: XCTestCase {
  func testStatusOfALoadedModel() throws {
    let json = """
      {"loaded": true, "peak_rss_bytes": 4347658240, "model_id": "google--timesfm-3.0-pytorch", "backend": "mlx",
       "options": {"model_id": "google--timesfm-3.0-pytorch", "compile": true},
       "flags": {"use_stitching": true, "linear_detrending_threshold": 0.5, "value_clip": 1e+20},
       "supported_flags": ["use_stitching", "value_clip"], "load_seconds": 1.8, "mlx_active_bytes": 1322844494}
      """
    let status = try JSONDecoder().decode(EngineStatus.self, from: Data(json.utf8))
    XCTAssertTrue(status.loaded)
    XCTAssertEqual(status.modelId, "google--timesfm-3.0-pytorch")
    XCTAssertEqual(status.backend, Backend.mlx.rawValue)
    XCTAssertEqual(status.supportedFlags, ["use_stitching", "value_clip"])
  }

  /// After Unload the engine answers with almost nothing. The model bar goes back to Load on this.
  func testStatusAfterUnload() throws {
    let json = #"{"loaded": false, "peak_rss_bytes": 275300352, "mlx_active_bytes": 0}"#
    let status = try JSONDecoder().decode(EngineStatus.self, from: Data(json.utf8))
    XCTAssertFalse(status.loaded)
    XCTAssertNil(status.modelId)
    XCTAssertNil(status.backend)
  }

  func testModelFlagsKeepDefaultsForWhatTheBackendDoesNotReport() {
    let flags = ModelFlags(["use_stitching": .bool(false), "value_clip": .number(100)])
    XCTAssertFalse(flags.useStitching)
    XCTAssertEqual(flags.valueClip, 100)
    XCTAssertTrue(flags.useLinearDetrending)
    XCTAssertTrue(flags.useIterativeCpmRevin)
    XCTAssertEqual(ModelFlags(flags.dict), flags)
  }

  func testJSONValueReadsEveryKind() throws {
    let json = #"{"a": null, "b": true, "c": 1.5, "d": "x", "e": [1, "y"], "f": {"g": 2}}"#
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    XCTAssertEqual(value["a"], .null)
    XCTAssertEqual(value["b"]?.boolValue, true)
    XCTAssertEqual(value["c"]?.doubleValue, 1.5)
    XCTAssertEqual(value["d"]?.stringValue, "x")
    XCTAssertEqual(value["e"], .array([.number(1), .string("y")]))
    XCTAssertEqual(value["f"]?["g"]?.doubleValue, 2)
    let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    XCTAssertEqual(again, value)
  }

  func testEngineErrorsAreShownInTheirOwnWords() throws {
    let body = try JSONDecoder().decode(APIErrorBody.self, from: Data(#"{"detail": "No model loaded."}"#.utf8))
    XCTAssertEqual(body.detail.stringValue, "No model loaded.")
  }

  func testFinetunedModelsGetAReadableName() {
    func model(_ id: String, kind: String, stored: String? = nil) -> LocalModel {
      LocalModel(id: id, path: "/m/\(id)", sizeBytes: 1, kind: kind, source: nil, storedName: stored ?? id,
                 meta: [:], architecture: .init(), flags: [:])
    }
    XCTAssertEqual(model("google--timesfm-3.0-pytorch-ft-20260929-2105", kind: "finetuned").displayName,
                   "Fine-tuned · 29 Sep 2026, 21:05")
    XCTAssertEqual(model("my-model", kind: "finetuned", stored: "Shop model").displayName, "Shop model")
    XCTAssertEqual(model("google--timesfm-3.0-pytorch", kind: "base", stored: "TimesFM 3.0").displayName, "TimesFM 3.0")
  }

  func testForecastParametersUseTheEngineNames() throws {
    var params = ForecastParams()
    params.contextLength = 512
    params.backtest = true
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any]
    XCTAssertEqual(object?["context_length"] as? Int, 512)
    XCTAssertEqual(object?["backtest"] as? Bool, true)
    XCTAssertEqual(object?["sort_quantiles"] as? Bool, true)
    XCTAssertNotNil(object?["use_symmetric_averaging"])
  }

  func testFinetuneSettingsUseTheEngineNames() throws {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FinetuneSettings())) as? [String: Any]
    for key in ["base_model_id", "output_name", "context_length", "lora_rank", "windows_per_epoch", "batch_size",
                "learning_rate", "val_fraction", "early_stopping_patience", "device"] {
      XCTAssertNotNil(object?[key], key)
    }
  }
}

final class FormatTests: XCTestCase {
  func testDurations() {
    XCTAssertEqual(Fmt.duration(0.057), "57 ms")
    XCTAssertEqual(Fmt.duration(2.5), "2.5 s")
    XCTAssertEqual(Fmt.duration(125), "2m 5s")
    XCTAssertEqual(Fmt.duration(3720), "1h 2m")
  }

  func testNumbersThatAreMissingShowADash() {
    XCTAssertEqual(Fmt.number(nil), "—")
    XCTAssertEqual(Fmt.number(.nan), "—")
    XCTAssertEqual(Fmt.number(.infinity), "—")
  }

  func testDates() {
    XCTAssertNotNil(Fmt.date("2025-02-04T00:00:00"))
    XCTAssertNotNil(Fmt.date("2025-02-04"))
    XCTAssertNil(Fmt.date("yesterday"))
    XCTAssertEqual(Fmt.shortDate("2025-02-04T00:00:00"), "2025-02-04")
    XCTAssertEqual(Fmt.shortDate("2025-02-04T13:30:00"), "2025-02-04 13:30")
    XCTAssertEqual(Fmt.friendlyDate("2025-03-01T00:00:00"), "1 Mar 2025")
  }

  func testFrequencyWords() {
    XCTAssertEqual(Freq.name("D"), "Daily")
    XCTAssertEqual(Freq.name("W-SUN"), "Weekly")
    XCTAssertEqual(Freq.unit("MS", count: 1), "month")
    XCTAssertEqual(Freq.unit("h", count: 3), "hours")
    XCTAssertEqual(Freq.unit(nil, count: 2), "steps")
    XCTAssertEqual(Freq.presets("D").map(\.steps), [7, 30, 90])
    XCTAssertTrue(Freq.presets("17min-odd").isEmpty || Freq.presets("17min-odd").count == 3)
  }

  func testChartBandsPairQuantilesAroundTheMedian() {
    for band in Band.allCases {
      XCTAssertEqual(band.lower + band.upper, 8)
      XCTAssertLessThan(band.lower, 4)
    }
    XCTAssertEqual(Band.p10p90.lower, 0)
    XCTAssertEqual(Band.p40p60.upper, 5)
  }
}
