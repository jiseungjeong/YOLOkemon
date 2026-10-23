import Combine
import Foundation
import UIKit

/// Per-precision rollup the Dashboard reads from. Values are accumulated
/// lazily as `SessionLogStore.append` runs — summaries are never
/// recomputed from scratch so adding a frame stays O(1).
struct PrecisionSummary: Sendable {
    let precision: Precision
    var frames: Int = 0
    var sumLatency: Double = 0        // sum of inferenceMs
    var latencies: [Double] = []      // retained for p95 percentile
    var targetEvaluated: Int = 0      // frames with a target set
    var targetHits: Int = 0           // frames where target was detected
    var sumConf: Double = 0           // sum of (mean conf per frame)

    // YOLOkémon temporal stability rollup.
    var iouFrames: Int = 0            // frames contributing to sumIoU
    var sumIoU: Double = 0            // cumulative IoU across capture frames
    var captureCount: Int = 0         // successful catches this session
    var sumCaptureTime: Double = 0    // seconds spent on successful catches
    var sumCaptureAttempts: Int = 0

    var avgLatency: Double { frames > 0 ? sumLatency / Double(frames) : 0 }
    var avgFps: Double     { avgLatency > 0 ? 1000.0 / avgLatency : 0 }
    var p95: Double {
        guard !latencies.isEmpty else { return 0 }
        let s = latencies.sorted()
        let idx = min(s.count - 1, Int(Double(s.count) * 0.95))
        return s[idx]
    }
    var successRate: Double {
        targetEvaluated > 0 ? Double(targetHits) / Double(targetEvaluated) : 0
    }
    var meanConf: Double { frames > 0 ? sumConf / Double(frames) : 0 }
    var modelSizeMb: Double {
        Double(ModelRegistry.fileSize(precision)) / (1024 * 1024)
    }

    /// Mean frame-to-frame IoU of the target box, averaged over the
    /// frames where a capture was actively running.
    var meanIoU: Double {
        iouFrames > 0 ? sumIoU / Double(iouFrames) : 0
    }
    /// Average wall-clock seconds per successful catch.
    var avgCaptureTime: Double {
        captureCount > 0 ? sumCaptureTime / Double(captureCount) : 0
    }
    /// Catches counted as `failed` if they took more than one attempt
    /// to finish. A scale-free proxy for capture difficulty, suitable
    /// for the Dashboard "failure rate" cell.
    var captureFailureRate: Double {
        guard captureCount > 0 else { return 0 }
        let failed = sumCaptureAttempts - captureCount
        return max(0, Double(failed)) / Double(captureCount)
    }
}

/// Owns the in-memory log buffer + per-precision rollup that the
/// Dashboard, Export tab, and (later) YOLOkémon stats all read from.
///
/// One store is shared across tabs via `.environmentObject(...)` at the
/// app root. Writes happen from `LiveView.handleResult` after each
/// inference frame; reads are Combine-driven so SwiftUI re-renders when
/// a new frame lands.
///
/// Memory note: one `LogRecord` ~= a few hundred bytes (the per-frame
/// `predictions` array is the biggest variable). 10 minutes at 10 fps
/// ≈ 6000 records ≈ 1–2 MB — well inside the iPhone 11 budget. If
/// sessions grow much longer we'll add a fixed-size ring buffer; for
/// demo / benchmark sessions the current unbounded list is fine.
@MainActor
final class SessionLogStore: ObservableObject {

    /// Every processed frame, oldest first. `ExportView` serializes this
    /// straight to CSV/JSON.
    @Published private(set) var records: [LogRecord] = []

    /// Per-precision rollup shown on the Dashboard.
    @Published private(set) var summary: [Precision: PrecisionSummary] = [:]

    /// Live summary values that also appear on the Live tab.
    @Published private(set) var avgLatencyMs: Double = 0
    @Published private(set) var rollingFps: Double = 0

    /// Mirror of the currently selected precision — written by LiveView
    /// whenever the user toggles the picker. Consumers (ExportView's
    /// "Selected model" line, future demo overlays) read this without
    /// needing a direct reference to DetectionEngine.
    @Published private(set) var currentPrecision: Precision = .fp32

    /// YOLOkémon capture events — one entry per successful catch this
    /// session. Drives the JSON export's capture block and
    /// the Dashboard's "Temporal Stability" row. Separate from
    /// `PokedexStore.entries` (which is persistent and deduplicates
    /// per class) because a single session can catch the same class
    /// twice to exercise different precisions.
    @Published private(set) var captures: [PokedexEntry] = []

    /// Rolling window for the live latency / FPS read-out. Small enough
    /// (30 frames ≈ 1–3 s) that the number reacts quickly when precision
    /// changes without jittering on every frame.
    private var recentLatencies: [Double] = []
    private static let rollingWindow = 30

    /// Session start timestamp — used by Export to name the file and by
    /// the battery drain proxy below.
    let sessionStart: Date = Date()

    /// Battery level captured at session start. iOS only updates
    /// `batteryLevel` in 1 % increments and only when monitoring is on
    /// (we enable it from `YOLOkemonApp.init`). Snapshotting once at startup
    /// gives the Dashboard a stable baseline to subtract the live
    /// reading from — instead of trying to "guess" current draw, we
    /// surface the **observed drop since the session began**, which is
    /// the only meaningful battery proxy iOS exposes.
    /// `nil` if monitoring wasn't actually granted (returns -1 in that
    /// case).
    let sessionStartBatteryLevel: Float? = {
        let lvl = UIDevice.current.batteryLevel
        return lvl >= 0 ? lvl : nil
    }()

    /// Battery percentage drop since session start, or `nil` if we
    /// don't have a clean baseline (monitoring disabled or charging
    /// kicked in mid-session). Returns `0` when no measurable drop
    /// yet — callers should treat that as "session too short to tell"
    /// rather than "0 % consumed forever".
    var batteryDropSinceStart: Double? {
        guard let start = sessionStartBatteryLevel else { return nil }
        let now = UIDevice.current.batteryLevel
        guard now >= 0 else { return nil }
        // Charger plugged in mid-session? `now` would rise above the
        // baseline. Don't pretend that's negative drain — bail.
        if now > start { return nil }
        return Double(start - now) * 100.0
    }

    /// Wall-clock elapsed time since session start, in seconds.
    /// Convenience for the Dashboard to render `Battery: -2.4 %
    /// over 4 m 12 s` so the drop number has a unit attached.
    var elapsedSeconds: TimeInterval {
        Date().timeIntervalSince(sessionStart)
    }

    /// Append a frame result. Must be called on MainActor (enforced by
    /// the class's `@MainActor` annotation). `captureProgress` and
    /// `captureIoU` are the YOLOkémon stability signals — pass
    /// `nil` for both when no capture session is active, otherwise the
    /// store records them on the `LogRecord` and rolls them into the
    /// per-precision summary.
    func append(result: InferenceResult,
                precision: Precision,
                targetClass: String?,
                captureProgress: Double? = nil,
                captureIoU: Double? = nil) {
        let total = result.preprocessMs + result.inferenceMs + result.postprocessMs

        // Rolling window — independent of per-precision summary so the
        // live read-out always reflects "the last N frames I just saw"
        // rather than "the whole session-so-far in this precision".
        recentLatencies.append(result.inferenceMs)
        if recentLatencies.count > Self.rollingWindow {
            recentLatencies.removeFirst()
        }
        let avg = recentLatencies.reduce(0, +) / Double(max(recentLatencies.count, 1))
        avgLatencyMs = avg
        rollingFps = 1000.0 / max(total, 1)

        // Assemble the durable row.
        let targetHit: Bool = {
            guard let tc = targetClass else { return false }
            return result.detections.contains(where: { $0.label == tc })
        }()
        let meanConfThisFrame: Double = {
            guard !result.detections.isEmpty else { return 0 }
            let sum = result.detections.reduce(0.0) { $0 + Double($1.confidence) }
            return sum / Double(result.detections.count)
        }()
        let inputSize = ModelRegistry.spec(for: precision).inputSize

        let rec = LogRecord(
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            frameIndex: records.count,
            precision: precision.rawValue,
            modelSizeBytes: ModelRegistry.fileSize(precision),
            delegate: "cpu",
            inputW: inputSize,
            inputH: inputSize,
            preprocessMs: result.preprocessMs,
            inferenceMs: result.inferenceMs,
            postprocessMs: result.postprocessMs,
            totalMs: total,
            fpsRolling: rollingFps,
            targetClass: targetClass,
            targetHit: targetHit,
            numDetections: result.detections.count,
            predictions: result.detections.map(Prediction.init(from:)),
            batteryLevel: UIDevice.current.batteryLevel,
            batteryState: UIDevice.current.batteryState.csvLabel,
            thermalState: ProcessInfo.processInfo.thermalState.csvLabel,
            memoryResidentMb: MetricsCollector.residentMemoryMb(),
            captureProgress: captureProgress,
            meanIoU30fps: captureIoU
        )
        records.append(rec)
        updateSummary(precision: precision,
                      inferenceMs: result.inferenceMs,
                      targetClass: targetClass,
                      targetHit: targetHit,
                      meanConfThisFrame: meanConfThisFrame,
                      captureIoU: captureIoU)
    }

    /// Record a successful capture event. Kept separate from
    /// `append(...)` because a catch is a session-level event, not a
    /// per-frame row — calling this appends to `captures` and also
    /// tracks the per-precision catch count for the Dashboard's
    /// "Temporal Stability" block.
    func recordCapture(_ entry: PokedexEntry) {
        captures.append(entry)
        if let p = Precision(rawValue: entry.usedModel.lowercased()) {
            var s = summary[p] ?? PrecisionSummary(precision: p)
            s.captureCount += 1
            s.sumCaptureTime += entry.captureTimeSeconds
            s.sumCaptureAttempts += entry.attemptCount
            summary[p] = s
        }
    }

    /// Called from LiveView whenever the picker changes — keeps
    /// `currentPrecision` in sync without exposing DetectionEngine
    /// outside the Live tab.
    func setCurrentPrecision(_ p: Precision) {
        currentPrecision = p
    }

    /// Drop every record + summary + rolling stat. Currently unused by
    /// the UI (we record continuously across precision toggles) but
    /// exposed for the Day-4 benchmark script and future "New session"
    /// button.
    func reset() {
        records.removeAll()
        summary.removeAll()
        recentLatencies.removeAll()
        avgLatencyMs = 0
        rollingFps = 0
        captures.removeAll()
    }

    // MARK: - Private

    private func updateSummary(precision: Precision,
                               inferenceMs: Double,
                               targetClass: String?,
                               targetHit: Bool,
                               meanConfThisFrame: Double,
                               captureIoU: Double?) {
        var s = summary[precision] ?? PrecisionSummary(precision: precision)
        s.frames += 1
        s.sumLatency += inferenceMs
        s.latencies.append(inferenceMs)
        if targetClass != nil {
            s.targetEvaluated += 1
            if targetHit { s.targetHits += 1 }
        }
        s.sumConf += meanConfThisFrame
        if let iou = captureIoU {
            s.iouFrames += 1
            s.sumIoU += iou
        }
        summary[precision] = s
    }
}
