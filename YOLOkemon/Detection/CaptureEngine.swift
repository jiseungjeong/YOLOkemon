import Combine
import CoreGraphics
import Foundation
import QuartzCore

/// Drives the YOLOkémon capture mechanic.
///
/// Every frame the LiveView receives detections and passes them to
/// `onDetections(...)`. The engine looks up the box belonging to the
/// active `targetClass`, measures its frame-to-frame IoU against the
/// previous frame's box, and moves `captureProgress` accordingly:
///
///   * IoU > 0.85 (target is still)         → progress += 1 / 75
///   * IoU > 0.60 (target is drifting a bit) → progress += 0.3 / 75
///   * else (missing or moving fast)         → progress -= 0.5 / 75
///
/// The denominators are sized for 30 fps so a perfectly still target
/// captures in ~2.5 s. Progress is clamped to [0, 1]; when it hits 1.0
/// the engine notifies `onCaptured` and stops the session.
///
/// `attemptCount` increments whenever a running capture falls back to 0
/// — useful for the "hard to catch" metric and the Pokédex
/// "Hardest catch" summary.
@MainActor
final class CaptureEngine: ObservableObject {

    // MARK: - Published state (LiveView / overlay subscribe)

    @Published private(set) var captureProgress: Double = 0
    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var targetClass: String? = nil

    /// IoU between the target box in the previous frame and the current
    /// one, recorded on every `onDetections` tick while a capture is
    /// active. `nil` outside capture sessions; `0` if the target was
    /// missing this frame. Exposed so `SessionLogStore` can persist
    /// per-frame stability data.
    @Published private(set) var lastIoU: Double? = nil

    /// Time of the most recent successful capture. Non-nil for a short
    /// window after `finishCaptureSuccess()` so the UI can keep the
    /// "Gotcha!" status line visible instead of the per-frame status
    /// refresh immediately overwriting it with "found/not found".
    /// Consumers check `isCelebrating` rather than reading this
    /// directly so the window length lives in one place.
    @Published private(set) var lastCaptureAt: CFTimeInterval? = nil

    /// How long "Gotcha!" sticks around before the generic per-frame
    /// status line takes over again. 3 s is long enough to read and
    /// register the catch without dragging down the demo pacing.
    static let celebrationDuration: CFTimeInterval = 3.0

    /// True if we're within the celebration window of a recent success.
    /// `CaptureEngine` never self-clears `lastCaptureAt`, so this query
    /// is purely time-based — callers don't need to poll or reset.
    var isCelebrating: Bool {
        guard let t = lastCaptureAt else { return false }
        return CACurrentMediaTime() - t < Self.celebrationDuration
    }

    // MARK: - Callbacks

    /// Fired on the main actor when progress reaches 1.0.
    /// Fields match `PokedexEntry` so the call
    /// site can forward them without this file depending on the store.
    var onCaptured: ((_ className: String,
                      _ captureTimeSeconds: Double,
                      _ attemptCount: Int) -> Void)?

    /// Fired on the main actor when the current attempt had peaked at or
    /// above `lateFailureThreshold` and then collapsed back to 0. Lets the
    /// UI play the "Got away!" animation only for near-misses — early
    /// 0→0.1 jitter stays silent.
    var onLateFailure: (() -> Void)?

    // MARK: - Tuning

    // Tuning targets a ~2.5 s full capture at 30 fps when the target
    // box is rock-still (IoU > 0.85 every frame). Started at 10 s,
    // dropped to 5 s, then halved again to 2.5 s after demo runs felt
    // the bar still dragged. Each step shrinks the denominator while
    // keeping all three rates in proportion, so "stable / drifting /
    // missing" balance is preserved — only the
    // absolute timing changes. `lateFailureThreshold` stays at 0.7
    // because it's a ratio of `captureProgress`, not an absolute count.
    //
    // Note: at 30 fps the capture window is now ~75 frames, which is
    // close to the lower bound of where IoU averaging is meaningful.
    // Don't push this much further without also raising the iouHigh
    // threshold, otherwise hand jitter on a still target reads as
    // "stable" too easily.
    private let gainHigh: Double = 1.0 / 75.0      // IoU > 0.85
    private let gainLow:  Double = 0.3 / 75.0      // IoU > 0.60
    private let decay:    Double = 0.5 / 75.0      // otherwise
    private let iouHigh:  Double = 0.85
    private let iouLow:   Double = 0.60

    /// Threshold above which a collapse-to-zero triggers `onLateFailure`.
    /// Kept high so we only surface near-misses.
    private let lateFailureThreshold: Double = 0.7

    // MARK: - Internal tracking

    private var prevTargetBox: CGRect? = nil
    private var attemptCount: Int = 0
    /// Highest progress reached in the current attempt. Decay steps are
    /// only 0.5/75, so the value right before a collapse is always tiny;
    /// the near-miss check has to look at the peak instead.
    private var peakProgress: Double = 0
    private var captureStartedAt: CFTimeInterval? = nil

    // MARK: - Session control

    /// Begin a capture session for `targetClass`. Resets progress and
    /// attempt counter. Idempotent — calling again while a session is
    /// active re-targets onto the new class instead of stacking.
    func startCapture(targetClass: String) {
        self.targetClass = targetClass
        isCapturing = true
        captureProgress = 0
        prevTargetBox = nil
        attemptCount = 0
        peakProgress = 0
        captureStartedAt = CACurrentMediaTime()
        // Starting a fresh attempt ends any lingering celebration from
        // a previous catch — we're in capturing-mode again.
        lastCaptureAt = nil
    }

    /// User cancelled. Clears progress and target.
    func giveUp() {
        isCapturing = false
        captureProgress = 0
        targetClass = nil
        prevTargetBox = nil
        attemptCount = 0
        peakProgress = 0
        captureStartedAt = nil
        lastCaptureAt = nil
    }

    // MARK: - Per-frame update

    /// Called by LiveView whenever a fresh inference result arrives.
    /// `frameTimeMs` is the total frame latency — reserved for future
    /// stability metrics (e.g. normalising gain by actual frame time
    /// rather than assuming 30 fps). Currently unused.
    func onDetections(_ detections: [Detection], frameTimeMs: Double) {
        guard isCapturing, let cls = targetClass else {
            lastIoU = nil
            return
        }

        let matches = detections.filter { $0.label == cls }
        guard let currentBox = bestBox(matches) else {
            // Target absent this frame — treat as flicker.
            lastIoU = 0
            applyDelta(-decay)
            prevTargetBox = nil
            return
        }

        let stability: Double
        if let prev = prevTargetBox {
            stability = iou(prev, currentBox)
        } else {
            // First frame with the target — no prior box to compare,
            // assume stable so progress starts accumulating instead of
            // bouncing off zero.
            stability = iouHigh + 0.01
        }
        lastIoU = stability

        if stability > iouHigh {
            applyDelta(gainHigh)
        } else if stability > iouLow {
            applyDelta(gainLow)
        } else {
            applyDelta(-decay)
        }

        prevTargetBox = currentBox
    }

    // MARK: - Progress mutation + success detection

    private func applyDelta(_ delta: Double) {
        let prevProgress = captureProgress
        let wasPositive = prevProgress > 0
        let next = (prevProgress + delta).clamped(to: 0...1)
        peakProgress = max(peakProgress, next)

        // Reset-to-zero from a running attempt counts as one failure.
        if wasPositive && next == 0 && delta < 0 {
            attemptCount += 1
            // Only fire the "Got away!" drama when this attempt had
            // reached real progress (≥ lateFailureThreshold). Everything
            // below is early-session jitter — letting those trigger would
            // make the animation feel spammy.
            if peakProgress >= lateFailureThreshold {
                onLateFailure?()
            }
            peakProgress = 0
        }

        captureProgress = next

        if next >= 1.0 {
            finishCaptureSuccess()
        }
    }

    private func finishCaptureSuccess() {
        guard let cls = targetClass else { return }
        let elapsed = captureStartedAt.map { CACurrentMediaTime() - $0 } ?? 0
        let attempts = attemptCount + 1 // the successful one counts too

        lastCaptureAt = CACurrentMediaTime()
        onCaptured?(cls, elapsed, attempts)

        // End the session. Caller may `startCapture(...)` again for a
        // fresh attempt (different target, or retry).
        isCapturing = false
        targetClass = nil
        prevTargetBox = nil
        captureStartedAt = nil
        // `captureProgress` intentionally held at 1.0 so the overlay
        // can render a final full bar for the animation window before
        // `giveUp()` or the next `startCapture` resets it.
    }

    // MARK: - Geometry helpers

    /// Pick the highest-confidence box among `matches`. Falls back to
    /// `nil` on an empty array.
    private func bestBox(_ matches: [Detection]) -> CGRect? {
        matches.max(by: { $0.confidence < $1.confidence })?.box
    }

    /// Intersection-over-union of two axis-aligned rects. Returns 0
    /// for disjoint or zero-area inputs so the callers don't need to
    /// guard against division by zero.
    private func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        let interArea = Double(inter.width * inter.height)
        let unionArea = Double(a.width * a.height)
                      + Double(b.width * b.height)
                      - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
