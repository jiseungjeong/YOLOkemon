import CoreGraphics
import Foundation
// NOTE: TFLite Swift sources are compiled into this target directly
// (YOLOkemon/TFLiteSwift/*.swift), so no `import TensorFlowLite` is needed.

/// Decodes a `[1, 300, 6]` YOLO26n output tensor into frame-space `Detection`s.
///
/// ## Output layout
///
/// Each of the 300 rows is `[x1, y1, x2, y2, conf, class_id]` with the
/// corner coordinates normalized to `[0, 1]` relative to the 640×640
/// letterboxed input. This is the **xyxy** convention, not the cxcywh
/// convention used by YOLOv8's raw head output. YOLO26 is NMS-free so
/// each row is already a final detection and we only threshold + invert
/// the letterbox transform.
///
/// The xyxy hypothesis was confirmed by matching two independent signals
/// on 2026-04-24 against the earlier cxcywh mis-read:
///   1. `sanity_report.json` column stats: x mean≈0.21 (left-biased, as
///      expected for x1, not a center), y2 max=1.23 (boxes routinely
///      extending past the image bottom, as would happen if y2 were
///      being clamped to the scene edge).
///   2. On-device screenshot ("mouse 95%"): box extending above the
///      image top and across half the frame. Under a cxcywh reader this
///      would mean the model predicted a physically unreasonable box at
///      high confidence; under an xyxy reader the box corresponds to the
///      actual object region once we stop doubling its extent.
///
/// A sanity check also confirmed the class column is already
/// an integer 0..<80, though we still `.rounded()` it because the INT8
/// variant can carry tiny float noise.
final class Yolo26PostProcessor {

    /// Skip rows below this confidence. 0.35 is tuned for a desk
    /// scene — Ultralytics' 0.25 default admitted a lot of weak detections
    /// (`keyboard 27%`, `bottle 31%`, duplicate overlapping `mouse 34%`)
    /// that clutter the overlay without actually improving recall on the
    /// primary objects (monitor / laptop / mouse / keyboard all fired at
    /// 55%+). Drop it to ~0.15 if INT8 recall suffers on harder scenes.
    var confThreshold: Float

    /// One-shot debug dump of the first few raw output rows so we can tell
    /// whether the model returns normalized (0..1) or pixel-space coords
    /// on live camera frames, and so we can visually compare an xyxy vs
    /// cxcywh interpretation side by side.
    private var dumpedOnce = false

    nonisolated init(confThreshold: Float = 0.35) {
        self.confThreshold = confThreshold
    }

    /// - Parameters:
    ///   - outputTensor: the single `[1, 300, 6]` float32 tensor.
    ///   - spec: the active model (used for the 640 input size).
    ///   - letterbox: transform info recorded by `Preprocessor`.
    ///   - labels: COCO 80 class names.
    nonisolated func decode(outputTensor: Tensor,
                            spec: ModelSpec,
                            letterbox: LetterboxInfo,
                            labels: [String]) throws -> [Detection] {

        // All three precisions expose float32 output.
        // If a future export changes this, surface the mismatch loudly.
        guard outputTensor.dataType == .float32 else {
            throw DetectionError.invalidOutput(
                "expected float32 output, got \(outputTensor.dataType)"
            )
        }

        let raw = outputTensor.data.toArray(type: Float.self)
        guard raw.count % 6 == 0 else {
            throw DetectionError.invalidOutput(
                "output length \(raw.count) is not a multiple of 6"
            )
        }
        let numRows = raw.count / 6
        let inputSize = CGFloat(spec.inputSize)
        let inv       = 1.0 / letterbox.scale
        let labelCount = labels.count

        // One-shot sanity dump so we can confirm the coord range on real
        // camera frames (not the synthetic gray tensor used at export time).
        // Print each of the first 5 rows twice — once interpreted as xyxy
        // and once as cxcywh — so a future regression (a new YOLO export
        // flipping the convention) is obvious from the log alone.
        if !dumpedOnce {
            dumpedOnce = true
            let cap = min(numRows, 5)
            print("[PostProc] raw top-\(cap) rows (c0..c3, conf, cls):")
            for i in 0..<cap {
                let b = i * 6
                let c0 = raw[b], c1 = raw[b+1], c2 = raw[b+2], c3 = raw[b+3]
                let conf = raw[b+4], cls = raw[b+5]
                print(String(
                    format: "  #%d  raw=(%.3f, %.3f, %.3f, %.3f)  conf=%.3f  cls=%.0f",
                    i, c0, c1, c2, c3, conf, cls))
                // As xyxy: (x1, y1, x2, y2) → width/height
                let xyxyW = c2 - c0, xyxyH = c3 - c1
                // As cxcywh: (cx, cy, w, h) → center→corners
                let ccX1 = c0 - c2/2, ccY1 = c1 - c3/2
                let ccX2 = c0 + c2/2, ccY2 = c1 + c3/2
                print(String(
                    format: "       as xyxy  → w=%.3f h=%.3f (ok if both >0)",
                    xyxyW, xyxyH))
                print(String(
                    format: "       as cxcywh→ x1=%.3f y1=%.3f x2=%.3f y2=%.3f",
                    ccX1, ccY1, ccX2, ccY2))
            }
            let c0s = stride(from: 0, to: raw.count, by: 6).map { raw[$0] }
            let c2s = stride(from: 2, to: raw.count, by: 6).map { raw[$0] }
            print(String(format: "[PostProc] c0 range [%.3f, %.3f]   c2 range [%.3f, %.3f]",
                         c0s.min() ?? 0, c0s.max() ?? 0,
                         c2s.min() ?? 0, c2s.max() ?? 0))
            print("[PostProc] letterbox scale=\(letterbox.scale) "
                + "pad=(\(letterbox.padX), \(letterbox.padY)) "
                + "orig=\(letterbox.origW)x\(letterbox.origH)")
        }

        var out: [Detection] = []
        out.reserveCapacity(16)
        // Track which (normalized) box footprints we've already emitted. YOLO26
        // sometimes returns the same geometry with several class candidates;
        // we only want the top-confidence one per footprint.
        var seenFootprints = Set<Int>()

        for i in 0..<numRows {
            let base = i * 6
            let conf = raw[base + 4]
            if conf < confThreshold { continue }

            let classFloat = raw[base + 5]
            let cls = Int(classFloat.rounded())
            if cls < 0 || cls >= labelCount { continue }

            // Decode as xyxy normalized. Degenerate rows (x2<=x1 or y2<=y1)
            // skip before we even convert to pixels — they'd just produce
            // empty CGRects downstream.
            let x1n = raw[base + 0]
            let y1n = raw[base + 1]
            let x2n = raw[base + 2]
            let y2n = raw[base + 3]
            if x2n <= x1n || y2n <= y1n { continue }

            // Skip duplicates: hash the corner coords rounded to 3 decimals
            // (~1 pixel granularity on 640×640). Rows come in descending
            // confidence order, so the first one we keep is the top pick.
            let footprint = (
                Int((x1n * 1000).rounded()) &* 1_000_000_000 |
                Int((y1n * 1000).rounded()) &* 1_000_000     |
                Int((x2n * 1000).rounded()) &* 1_000         |
                Int((y2n * 1000).rounded())
            )
            if !seenFootprints.insert(footprint).inserted { continue }

            // Normalized [0, 1] against the 640×640 letterbox canvas →
            // pixels in that canvas.
            let x1Px = CGFloat(x1n) * inputSize
            let y1Px = CGFloat(y1n) * inputSize
            let x2Px = CGFloat(x2n) * inputSize
            let y2Px = CGFloat(y2n) * inputSize
            let wPx  = x2Px - x1Px
            let hPx  = y2Px - y1Px

            // Reject boxes that start above the top padding or end below
            // the bottom padding by more than ~10% of the box's own size.
            // These are phantom detections YOLO makes into the gray border;
            // clamping them would paint a full-width stripe across the
            // viewport (the "ghost box" symptom).
            let imgTopPx    = letterbox.padY
            let imgBottomPx = inputSize - letterbox.padY
            let imgLeftPx   = letterbox.padX
            let imgRightPx  = inputSize - letterbox.padX
            let marginY = hPx * 0.10
            let marginX = wPx * 0.10
            if y1Px < imgTopPx    - marginY { continue }
            if y2Px > imgBottomPx + marginY { continue }
            if x1Px < imgLeftPx   - marginX { continue }
            if x2Px > imgRightPx  + marginX { continue }

            // Invert the letterbox: subtract padding, scale back into the
            // original camera frame's pixel space.
            let x1Orig = (x1Px - letterbox.padX) * inv
            let y1Orig = (y1Px - letterbox.padY) * inv
            let x2Orig = (x2Px - letterbox.padX) * inv
            let y2Orig = (y2Px - letterbox.padY) * inv

            // Clamp to frame bounds (YOLO occasionally predicts slightly
            // outside the image; easier to clamp than to drop).
            let x1 = max(0, x1Orig)
            let y1 = max(0, y1Orig)
            let x2 = min(letterbox.origW, x2Orig)
            let y2 = min(letterbox.origH, y2Orig)
            guard x2 > x1, y2 > y1 else { continue }

            out.append(Detection(
                classId: cls,
                label: labels[cls],
                confidence: conf,
                box: CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
            ))
        }
        return out
    }
}

// MARK: - Data → [T] helper

extension Data {
    /// Reinterpret raw bytes as an array of POD values.
    func toArray<T>(type: T.Type) -> [T] {
        withUnsafeBytes { buf -> [T] in
            let count = buf.count / MemoryLayout<T>.stride
            let ptr   = buf.bindMemory(to: T.self)
            return Array(UnsafeBufferPointer(start: ptr.baseAddress,
                                             count: count))
        }
    }
}
