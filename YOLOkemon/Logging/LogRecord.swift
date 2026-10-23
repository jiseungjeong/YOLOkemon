import CoreGraphics
import Foundation

/// A single detection serialized for CSV/JSON export. Keeps a flat set of
/// primitive fields so JSON stays readable by spreadsheet
/// tooling without any custom decoder.
struct Prediction: Codable, Sendable {
    let cls: Int
    let label: String
    let confidence: Float
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double

    init(from d: Detection) {
        self.cls        = d.classId
        self.label      = d.label
        self.confidence = d.confidence
        self.x1 = d.box.minX
        self.y1 = d.box.minY
        self.x2 = d.box.maxX
        self.y2 = d.box.maxY
    }
}

/// One row per processed camera frame. Intentionally self-describing —
/// every column a downstream analyst might want is here
/// up front so we never have to go back and re-log a session.
///
/// The `delegate` column is always `"cpu"` in this build, but we keep the
/// column so future runs with
/// different delegates plug in without a migration.
struct LogRecord: Codable, Sendable {
    let timestampMs:    Int64
    let frameIndex:     Int
    let precision:      String      // "fp32" | "fp16" | "int8"
    let modelSizeBytes: Int64
    let delegate:       String      // "cpu" (fixed)
    let inputW:         Int
    let inputH:         Int
    let preprocessMs:   Double
    let inferenceMs:    Double
    let postprocessMs:  Double
    let totalMs:        Double
    let fpsRolling:     Double
    let targetClass:    String?
    let targetHit:      Bool
    let numDetections:  Int
    let predictions:    [Prediction]
    let batteryLevel:   Float       // 0…1, iOS proxy for current draw
    let batteryState:   String      // "unplugged" | "charging" | "full" | "unknown"
    let thermalState:   String      // "nominal" | "fair" | "serious" | "critical"
    let memoryResidentMb: Double

    // YOLOkémon additions. Optional so pre-3-C rows decode
    // cleanly and old log files on disk can still be re-exported.
    /// Capture progress at the moment this frame was logged, ∈ [0, 1].
    /// `nil` when no capture session was active.
    let captureProgress: Double?
    /// Frame-to-frame IoU of the target bbox (0 if target missing this
    /// frame, `nil` when no capture session is running). The 30 fps
    /// suffix in the name documents the assumption that
    /// `CaptureEngine`'s gain constants are tuned for — downstream
    /// plots that divide progress by IoU should bear it in mind.
    let meanIoU30fps: Double?
}
