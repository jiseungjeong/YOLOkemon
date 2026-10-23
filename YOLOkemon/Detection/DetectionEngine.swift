import Combine
import CoreVideo
import Foundation
import QuartzCore
// NOTE: The TFLite Swift API lives in this app's target (YOLOkemon/TFLiteSwift/*.swift),
// not in an external module, so no `import TensorFlowLite` is needed.

/// Owns the active TFLite `Interpreter` and runs the full preprocess →
/// invoke → postprocess path for one frame at a time.
///
/// ## Runtime topology
///
/// The engine is split into two layers:
///   * `InferenceCore` — an **actor** that owns the `Interpreter` and
///     executes `prepare → invoke → decode`. Being an actor means all
///     model loads and per-frame inferences serialize automatically, so
///     there is no race between a precision switch and an in-flight
///     inference without any manual locking.
///   * `DetectionEngine` — an **@MainActor ObservableObject** facade that
///     SwiftUI subscribes to. It holds the `@Published` UI state
///     (current precision, loading flag, last error) and exposes async
///     methods that forward to the inference actor.
///
/// Before C-1 the engine itself was `@MainActor`, so every `infer()` hop
/// blocked the main thread for ~110 ms per frame — camera preview,
/// SwiftUI rendering, and user input all stalled in lockstep with the
/// inference cycle. With the actor, inference runs on the Swift
/// concurrency cooperative pool instead, freeing the main thread for
/// UI work even when a frame is mid-flight.
///
/// ## Delegate policy
///
/// Runs on **CPU (XNNPACK) only**. Metal/CoreML delegates were measured on
/// iPhone 11 (2026-04-23) and only accept 28/685 (Metal) and 48/685 (CoreML)
/// of YOLO26n's ops; the resulting CPU↔accelerator round-trips are slower
/// than pure CPU and Metal additionally triggers GPU address faults. The
/// app compares precisions (FP32/FP16/INT8), not delegates, so we fix
/// the delegate axis to CPU and keep the precision
/// axis as the single runtime knob. All three precisions use float32 I/O
/// so there is no per-precision branching in
/// preprocess or postprocess either.
///
/// ## Threading / XNNPACK
///
/// `Interpreter.Options.isXNNPackEnabled` defaults to `false` in the
/// TFLite 2.14 Swift bindings — which means the prior build was running
/// the reference float kernels, not XNNPACK. We enable it explicitly
/// here. `threadCount` is set to 4 to let XNNPACK spread work across
/// A13's two performance + some efficiency cores; 2 threads leaves the
/// efficiency cores idle for most of the ~108 ms inference window.

/// The in-memory inference worker. Owns the interpreter and runs
/// preprocess → invoke → decode on a background serial queue.
///
/// Implementation note (2026-04-24): originally an `actor`, but the
/// project is compiled with Swift 6's project-wide MainActor default —
/// which means `ModelRegistry`, `Preprocessor`, `Interpreter`, and the
/// TFLite Swift bindings themselves all inherit `@MainActor`. Calling
/// any of them from an actor produces "main actor-isolated ... in a
/// synchronous actor-isolated context" errors; fixing that would mean
/// annotating the whole TFLite binding layer as nonisolated, which is
/// intrusive and fragile.
///
/// Instead, `InferenceCore` is a plain `nonisolated final class` that
/// funnels all work through a private serial `DispatchQueue`. That
/// gives us:
///   * the same serialization guarantee an actor would (single-reader,
///     single-writer, FIFO on the queue),
///   * no global-actor contamination on the call sites, so
///     `Preprocessor.prepare(...)`, `Interpreter.invoke()`, etc. just
///     work as non-isolated synchronous calls,
///   * an async bridge via `withCheckedContinuation` so the facade
///     above and the LiveView frame handler can still `await`.
///
/// Members are mutated only on `queue`, which is enforced by the
/// `dispatchPrecondition(condition: .onQueue(queue))` checks inside
/// the internal helpers — plus the class is marked `@unchecked Sendable`
/// so the captured `self` is valid inside the `@Sendable` queue closures.
final class InferenceCore: @unchecked Sendable {
    // `nonisolated` is illegal on mutable stored properties. These are
    // only mutated inside `switchPrecisionOnQueue(...)` / `inferOnQueue(...)`,
    // both of which run on `queue` and are annotated nonisolated at the
    // method level — that's what actually keeps the call sites callable
    // from the serial-queue closure.
    private var interpreter: Interpreter?
    private var spec: ModelSpec
    nonisolated private let postProcessor: Yolo26PostProcessor
    nonisolated private let labels: [String]

    /// Serial queue that owns all mutable state. Created with
    /// `.userInitiated` so preprocess+invoke+decode gets roughly the
    /// priority of camera frame delivery.
    nonisolated private let queue = DispatchQueue(label: "yolokemon.inference",
                                                  qos: .userInitiated)

    nonisolated init() {
        self.spec          = ModelRegistry.spec(for: .fp32)
        self.postProcessor = Yolo26PostProcessor(confThreshold: 0.35)
        self.labels        = LabelLoader.coco80()
    }

    /// Load or reload the interpreter for a given precision. The queue
    /// serializes this against any outstanding `infer(...)` so the
    /// caller never sees a torn-down interpreter.
    nonisolated func switchPrecision(to p: Precision) async throws -> ModelSpec {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let spec = try self.switchPrecisionOnQueue(to: p)
                    cont.resume(returning: spec)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Run one frame end-to-end. Returns per-phase timings so callers can
    /// log them without redundant `CACurrentMediaTime()` reads. Takes a
    /// `PixelBufferBox` rather than a raw `CVPixelBuffer` because CVBuffer
    /// is non-Sendable and would otherwise block the async boundary in
    /// Swift 6 strict concurrency.
    nonisolated func infer(_ box: PixelBufferBox) async throws -> InferenceResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    // Opaque unmanaged read; LiveView's MainActor.run
                    // block is responsible for the eventual `box.release()`
                    // after it has pulled frame width/height too.
                    let result = try self.inferOnQueue(pixelBuffer: box.readBuffer())
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Queue-local helpers

    nonisolated private func switchPrecisionOnQueue(to p: Precision) throws -> ModelSpec {
        dispatchPrecondition(condition: .onQueue(queue))

        // Release the previous interpreter explicitly before allocating a
        // new one so peak memory does not double during a switch.
        interpreter = nil

        let newSpec = ModelRegistry.spec(for: p)
        guard let url = ModelRegistry.url(for: p) else {
            throw DetectionError.modelNotFound(newSpec.filename)
        }

        var options = Interpreter.Options()
        // Enable XNNPACK and use 4 threads. The Swift
        // binding's default is isXNNPackEnabled=false, so before this
        // change TFLite was running reference float kernels — measured
        // at ~108 ms FP32 / ~109 ms INT8 on iPhone 11 (A13). XNNPACK
        // vectorizes f32 convs via NEON and will scale with threadCount
        // up to the number of performance/efficiency cores we're happy
        // to burn. 4 is the chosen sweet spot for A13's 2P + 4E layout.
        options.isXNNPackEnabled = true
        options.threadCount = 4

        let itp = try Interpreter(modelPath: url.path, options: options)
        try itp.allocateTensors()

        self.interpreter = itp
        self.spec        = newSpec
        return newSpec
    }

    nonisolated private func inferOnQueue(pixelBuffer: CVPixelBuffer) throws -> InferenceResult {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let interpreter else { throw DetectionError.notReady }

        let t0 = CACurrentMediaTime()
        let (input, letterbox) = try Preprocessor.prepare(pixelBuffer: pixelBuffer,
                                                          spec: spec)
        let t1 = CACurrentMediaTime()

        _ = try interpreter.copy(input, toInputAt: 0)
        try interpreter.invoke()
        let output = try interpreter.output(at: 0)
        let t2 = CACurrentMediaTime()

        let detections = try postProcessor.decode(outputTensor: output,
                                                  spec: spec,
                                                  letterbox: letterbox,
                                                  labels: labels)
        let t3 = CACurrentMediaTime()

        return InferenceResult(
            detections: detections,
            preprocessMs:  (t1 - t0) * 1000,
            inferenceMs:   (t2 - t1) * 1000,
            postprocessMs: (t3 - t2) * 1000
        )
    }
}

/// MainActor-bound facade that SwiftUI observes. Holds the @Published UI
/// state and forwards work to the `InferenceCore` actor.
@MainActor
final class DetectionEngine: ObservableObject {

    @Published private(set) var currentPrecision: Precision = .fp32
    @Published private(set) var isLoadingModel = false
    @Published private(set) var lastError: String?

    /// Expose the underlying inference actor so a caller (e.g. the
    /// CameraManager frame handler) can await `infer(...)` directly
    /// without round-tripping through MainActor. The facade still
    /// provides `switchPrecision` and handles @Published updates.
    nonisolated let core = InferenceCore()

    /// Load or reload the interpreter for a given precision. This is
    /// async so the ~2–5 s TFLite `allocateTensors` cost does not
    /// block the main thread / camera preview.
    func switchPrecision(to p: Precision) async {
        isLoadingModel = true
        lastError = nil
        do {
            _ = try await core.switchPrecision(to: p)
            currentPrecision = p
        } catch {
            lastError = "\(error)"
        }
        isLoadingModel = false
    }
}
