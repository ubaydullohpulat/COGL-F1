import XCTest

@testable import COGLF1

/// A fine-tune once froze on screen: the engine could not answer for the job any more, the app kept
/// waiting without a word, and Stop & save and Cancel did nothing anyone could see.
final class FinetuneJobTests: XCTestCase {
  private struct Timeout: LocalizedError {
    var errorDescription: String? { "Engine error 500" }
  }

  func testOneMissedPollIsNotALostJob() {
    for misses in 1..<FinetunePolling.patience {
      XCTAssertNil(FinetunePolling.lostJob(misses: misses, engineRunning: true, error: Timeout()))
    }
  }

  func testAJobThatStopsAnsweringIsReported() {
    let message = FinetunePolling.lostJob(misses: FinetunePolling.patience, engineRunning: true, error: Timeout())
    XCTAssertEqual(message, "Lost contact with the fine-tuning job. Engine error 500")
  }

  func testAStoppedEngineIsReportedAtOnce() {
    let message = FinetunePolling.lostJob(misses: 1, engineRunning: false, error: Timeout())
    XCTAssertEqual(message, "The engine stopped while fine-tuning. Start it again on the Engine page.")
  }

  /// The engine sends null for a number it could not compute. That must not break the whole snapshot.
  func testSnapshotWithMissingNumbersDecodes() throws {
    let json = """
      {"id": "abc", "kind": "finetune", "title": "Fine-tune tiny", "status": "running", "progress": 0.4,
       "message": "Epoch 1/5", "created": 1.0, "started": 2.0, "finished": null, "logs": ["a", "b"],
       "metrics": [{"kind": "val", "epoch": 0, "val_loss": 0.15, "val_mae": 19.7},
                   {"kind": "val", "epoch": 1, "val_loss": null, "val_mae": null, "train_loss": 0.12}],
       "result": null, "error": null}
      """
    let snap = try JSONDecoder().decode(JobSnapshot.self, from: Data(json.utf8))
    XCTAssertTrue(snap.isActive)
    XCTAssertEqual(snap.metrics.count, 2)
    XCTAssertEqual(snap.metrics[0]["val_loss"]?.doubleValue, 0.15)
    XCTAssertEqual(snap.metrics[1]["val_loss"], .null)
    XCTAssertNil(snap.metrics[1]["val_loss"]?.doubleValue)
  }

  func testFinishedStatesAreNotActive() throws {
    for status in ["completed", "failed", "cancelled"] {
      let json = """
        {"id": "x", "kind": "finetune", "title": "t", "status": "\(status)", "progress": 1, "message": "",
         "logs": [], "metrics": [], "result": {"model_id": "tiny-ft", "improvement_percent": null}, "error": null}
        """
      let snap = try JSONDecoder().decode(JobSnapshot.self, from: Data(json.utf8))
      XCTAssertFalse(snap.isActive, status)
      XCTAssertEqual(snap.result?["model_id"]?.stringValue, "tiny-ft")
    }
  }
}
