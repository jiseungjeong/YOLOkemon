import AVFoundation
import Combine
import CoreVideo
import Foundation
import UIKit

enum CameraError: Error {
    case noDevice
    case cannotAddInput
    case cannotAddOutput
    case permissionDenied
}

/// CVPixelBuffer is reference-typed and not declared Sendable by the SDK.
/// For our pipeline the buffer is produced by AVFoundation, handed off
/// to the inference actor via an async Task, and only read there — no
/// concurrent mutation happens.
///
/// The Swift 6 strict concurrency checker refuses to accept a struct
/// that *names* a non-Sendable property (`CVPixelBuffer`) even when the
/// struct itself is declared `@unchecked Sendable`, because it tries to
/// follow the property access chain. To hide the CVBuffer from the
/// checker entirely we hold it as an `Unmanaged<CVPixelBuffer>` (a
/// COpaquePointer-ish wrapper that is trivially Sendable) plus a
/// retain/release pair: `Unmanaged.passRetained(pb)` when boxing, and
/// `takeRetainedValue()` when the consumer is ready to read. The
/// `.timestamp` is a `CMTime` which is already a POD value.
struct PixelBufferBox: @unchecked Sendable {
    private let unmanaged: Unmanaged<CVPixelBuffer>
    let timestamp: CMTime

    init(buffer: CVPixelBuffer, timestamp: CMTime) {
        // `passRetained` bumps the CFRetain count; `take()` later
        // returns without releasing, `takeRetainedValue()` both
        // returns and decrements the count.
        self.unmanaged = Unmanaged.passRetained(buffer)
        self.timestamp = timestamp
    }

    /// Non-consuming read — increments the retain count so the caller
    /// owns a separate reference. Use this when the box may be accessed
    /// more than once (e.g. LiveView wants the buffer on MainActor to
    /// pull width/height after inference finished).
    func readBuffer() -> CVPixelBuffer {
        unmanaged.takeUnretainedValue()
    }

    /// Release the held retain count once we're sure the box will no
    /// longer be read. Must be called exactly once per box, otherwise
    /// we leak a CFRetain.
    func release() {
        unmanaged.release()
    }
}

/// Owns the AVCaptureSession and pushes back-camera frames to the detection
/// pipeline. Uses `alwaysDiscardsLateVideoFrames` + a `busy` flag so that a
/// slow inference never stacks up frames in the queue.
///
/// Frame delivery topology:
///   * `captureOutput(...)` runs on `frameQueue` (userInitiated) — the
///     AVFoundation-owned delivery queue.
///   * We read/flip the `busy` flag on that same queue (no actor hop)
///     and hand the boxed pixel buffer straight to whoever registered
///     `onFrame`. The consumer is expected to kick off an async Task
///     that awaits the inference actor and then hops to MainActor only
///     for UI updates.
///   * This replaces the earlier path that bounced through
///     `Task { @MainActor in ... }` — that path forced every frame onto
///     the main thread and capped the whole pipeline at ~main-thread
///     latency when inference itself ran on MainActor too (pre-C-1).
@MainActor
final class CameraManager: NSObject, ObservableObject {

    let session = AVCaptureSession()
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: CameraError?

    /// Delivered on the frame-processing queue (not main). Handler must
    /// be fast; push heavy work (inference) to an actor via `Task`.
    /// The box provides the CVPixelBuffer + timestamp as a Sendable unit
    /// so the consumer can safely capture it into an async Task without
    /// tripping Swift 6 strict concurrency.
    ///
    /// Marked `nonisolated(unsafe)` so `captureOutput` (which is
    /// `nonisolated` to satisfy the AVFoundation delegate protocol) can
    /// read it without hopping onto MainActor. The write pattern is
    /// "set once in setup() before `camera.start()`, then read-only on
    /// the frame queue," so there is no actual data race — we just need
    /// to tell the Swift 6 concurrency checker that we know.
    nonisolated(unsafe) var onFrame: (@Sendable (PixelBufferBox) -> Void)?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let frameQueue  = DispatchQueue(label: "yolokemon.camera.frame",
                                            qos: .userInitiated)
    /// Guarded by `frameQueue` — read/flipped inside `captureOutput` and
    /// cleared by `markFrameDone()` which hops back onto `frameQueue`.
    private nonisolated(unsafe) var busy = false

    /// Tracks whether `configure()` has already attached input+output to
    /// `session`. SwiftUI's `.task { await setup() }` modifier fires
    /// every time LiveView reappears (e.g. after a Dashboard → Live tab
    /// switch), so `configure()` can be called multiple times on the
    /// same CameraManager instance. Without this flag the second call
    /// would throw `cannotAddInput` because `session.canAddInput(...)`
    /// returns false for an input that's already attached.
    private var isConfigured: Bool = false

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            lastError = .permissionDenied
            return false
        }
    }

    /// Idempotent: safe to call on tab revisits. The first invocation
    /// attaches input + output to `session`; subsequent ones short-
    /// circuit and leave the already-configured session intact, so
    /// `start()` alone is enough to resume preview.
    func configure() throws {
        guard !isConfigured else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720

        // Use the 1× wide-angle lens (26 mm equivalent) so the captured
        // frame matches COCO's training distribution — YOLO26n loses a
        // lot of recall on ultra-wide frames because the barrel distortion
        // pushes objects out of its training manifold, and small objects
        // shrink further in pixel footprint after letterboxing. Do not
        // pick .builtInDual/TripleCamera either: those auto-switch lenses
        // at runtime depending on zoom, which would contaminate latency
        // benchmarks with one-off focus/exposure hiccups.
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            lastError = .noDevice
            throw CameraError.noDevice
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            lastError = .cannotAddInput
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(videoOutput) else {
            lastError = .cannotAddOutput
            throw CameraError.cannotAddOutput
        }
        session.addOutput(videoOutput)

        // Rotate the capture output to portrait (90°) so the CVPixelBuffer
        // delivered to Preprocessor is already upright. Without this, the
        // buffer is in raw sensor orientation (landscape) and the user
        // holding the phone vertically gets a sideways image — YOLO then
        // predicts on a rotated scene and the boxes end up meaningless.
        if let conn = videoOutput.connection(with: .video) {
            let portraitAngle: CGFloat = 90
            if conn.isVideoRotationAngleSupported(portraitAngle) {
                conn.videoRotationAngle = portraitAngle
            }
        }

        // Mark configured only on the success path — if we threw above,
        // we want the next configure() call to retry from scratch.
        isConfigured = true
    }

    func start() {
        guard !session.isRunning else { return }
        // AVCaptureSession.startRunning blocks — run off the main actor.
        Task.detached { [session = self.session] in
            session.startRunning()
            await MainActor.run { self.isRunning = session.isRunning }
        }
    }

    func stop() {
        guard session.isRunning else { return }
        Task.detached { [session = self.session] in
            session.stopRunning()
            await MainActor.run { self.isRunning = false }
        }
    }

    /// Detection pipeline calls this when it has finished processing the
    /// current frame so the next one can be accepted. Must hop onto
    /// `frameQueue` to synchronize with `captureOutput`.
    nonisolated func markFrameDone() {
        frameQueue.async { [weak self] in
            self?.busy = false
        }
    }
}

// MARK: - Sample buffer delivery

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // captureOutput already runs on `frameQueue`, so read/write the
        // busy flag without hopping actors. The handler itself is expected
        // to kick off a Task that awaits the inference actor — by then
        // we've already returned to AVFoundation and it's free to deliver
        // the next frame (which we'll drop until markFrameDone fires).
        if busy { return }
        busy = true
        onFrame?(PixelBufferBox(buffer: pb, timestamp: ts))
    }
}
