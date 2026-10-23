import CoreGraphics
import Foundation

/// A single object detection produced by YOLO26n, expressed in the
/// coordinate space of the original camera frame (not the 640×640 letterbox).
/// `Sendable` so results can cross the InferenceCore ↔ MainActor boundary
/// without tripping Swift 6 strict concurrency checks.
struct Detection: Hashable, Sendable {
    let classId: Int
    let label: String
    let confidence: Float
    let box: CGRect
}

/// Remembers how the incoming frame was scaled and padded into the 640×640
/// model input so the post-processor can invert it when decoding boxes.
struct LetterboxInfo: Sendable {
    let scale: CGFloat    // source pixel → 640 pixel
    let padX:  CGFloat    // left padding inside the 640 canvas (pixels)
    let padY:  CGFloat    // top padding
    let origW: CGFloat    // original frame width (pixels)
    let origH: CGFloat    // original frame height
}

/// Returned from `DetectionEngine.infer(...)` so the caller can surface
/// latency stats to the UI without doing its own timing.
struct InferenceResult: Sendable {
    let detections: [Detection]
    let preprocessMs:  Double
    let inferenceMs:   Double   // TFLite invoke only
    let postprocessMs: Double
    /// Convenience for logging.
    nonisolated var totalMs: Double { preprocessMs + inferenceMs + postprocessMs }
}

enum DetectionError: Error, CustomStringConvertible {
    case modelNotFound(String)
    case preprocessFailed
    case notReady
    case invalidOutput(String)

    var description: String {
        switch self {
        case .modelNotFound(let n): return "Model file not found: \(n)"
        case .preprocessFailed:     return "Preprocessor failed to build input tensor"
        case .notReady:             return "Interpreter has not been created yet"
        case .invalidOutput(let m): return "Unexpected TFLite output: \(m)"
        }
    }
}
