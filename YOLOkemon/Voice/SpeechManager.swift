import AVFoundation
import Combine
import Foundation
import Speech

/// Push-to-talk wrapper around `SFSpeechRecognizer`.
///
/// Design:
///   * The user taps a mic button to *begin* listening and taps again
///     (or triggers a silence timeout internal to SFSpeechRecognizer)
///     to stop. We don't keep the mic hot between taps — that would
///     drain battery and feel intrusive.
///   * `requestPermissions()` is called lazily on the first tap, so
///     users see one permission sheet in a clear context, not three
///     back-to-back at app launch.
///   * Both `SFSpeechRecognizer.requestAuthorization` (speech-to-text
///     server permission) *and* `AVCaptureDevice.requestAccess(.audio)`
///     (hardware mic) are required — failing either flips
///     `permissionDenied` so the UI can show a hint.
///
/// The recognizer streams partial results during listening; the final
/// transcript is delivered via `onFinal` when the user stops speaking.
/// Callers (LiveView) typically feed that string into
/// `VoiceCommandParser.parse(_:)` and dispatch on the resulting intent.
///
/// ## Silence detection
///
/// `SFSpeechRecognizer`'s server-side `isFinal` detection is unreliable
/// on iOS 17+ in en-US — it can take 5–15 seconds or never fire — which
/// leaves the overlay hanging after the user stops speaking. So we don't
/// wait for it. Instead the audio tap computes a per-buffer RMS; a
/// timer fires every 0.3 s and stops listening if:
///
///   * we've heard voice at least once AND the last buffer with voice
///     was more than `silenceGraceSeconds` ago  → normal end-of-speech
///   * listening has been open for more than `hardTimeoutSeconds`       → safety net
///
/// When the timer decides to stop, `stopListening()` calls `onFinal(...)`
/// with whatever transcript we have, which funnels into the same
/// LiveView handler as a server-side `isFinal` would.
@MainActor
final class SpeechManager: ObservableObject {

    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var isListening: Bool = false
    /// `true` once the user has denied either the speech or mic
    /// permission; the UI can show a "enable in Settings" hint.
    @Published private(set) var permissionDenied: Bool = false
    /// Last setup error (mic busy, SFSpeechRecognizer unavailable, etc.).
    /// Cleared whenever a new `startListening` call succeeds.
    @Published private(set) var lastError: String? = nil

    /// Invoked with the final transcript after `stopListening()` — the
    /// string is whatever SFSpeechRecognizer gave us, in its raw form.
    /// LiveView hands it off to `VoiceCommandParser.parse(_:)`.
    var onFinal: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // MARK: - Silence detection

    /// RMS value (0…1) above which a buffer counts as "voice". Tuned for
    /// iPhone 11's built-in mic in normal indoor ambient noise. Raise if
    /// background noise (HVAC, camera fan) trips false positives; lower
    /// if quiet speech gets ignored and we always fall through to the
    /// hard timeout.
    private let voiceThreshold: Float = 0.02

    /// How long to wait after the last voice-detected buffer before
    /// declaring the user done. 1.2 s covers normal mid-sentence pauses
    /// without feeling laggy.
    private let silenceGraceSeconds: TimeInterval = 1.2

    /// Absolute upper bound on a single listen session. Even if voice
    /// detection misbehaves, we'll never leave the mic open past this.
    private let hardTimeoutSeconds: TimeInterval = 8.0

    /// How often the silence timer ticks to check the two conditions.
    private let silenceCheckInterval: TimeInterval = 0.3

    /// When the current `startListening()` call began.
    private var startedAt: Date?

    /// Most recent time we saw a buffer whose RMS exceeded
    /// `voiceThreshold`. Nil until the first voiced buffer arrives.
    /// The audio tap writes this from a background thread; we tolerate
    /// the tearing with `nonisolated(unsafe)` because a stale read of a
    /// single `Date` reference only shortens or lengthens the grace
    /// window by 0.3 s in the worst case (timer interval).
    nonisolated(unsafe) private var lastVoiceTime: Date?

    /// Whether we've ever observed voice in this session. Before that
    /// point we deliberately don't let the silence timer end the session
    /// — otherwise the overlay would close 1.2 s after the user taps
    /// the mic button, before they've even started speaking.
    nonisolated(unsafe) private var hasEverHeardVoice: Bool = false

    private var silenceTimer: Timer?

    /// Has `onFinal` already fired for the current session? Guards
    /// against the two (or three) redundant fire paths that can line up
    /// back-to-back on a single utterance:
    ///
    ///   1. `endSessionEarly()` fires onFinal with whatever partial
    ///      transcript we have when the silence timer / Done button
    ///      tears the session down.
    ///   2. Moments later, the recognition task's own callback may
    ///      deliver an `isFinal=true` result with a *different*
    ///      (usually more complete) transcript — a second onFinal.
    ///   3. If the task is cancelled before step 2, the callback arrives
    ///      with an error and takes the error branch below, which also
    ///      calls onFinal.
    ///
    /// Without this flag, the user sees the status bar flicker from
    /// `"Could not understand..."` (partial) to `"unsupported class:
    /// dragon"` (final). We want one verdict per session, so whichever
    /// path fires first wins.
    private var onFinalFired: Bool = false

    // MARK: - Permissions

    /// Request both speech and microphone access. Safe to call multiple
    /// times — iOS caches the answer after the first user response. The
    /// return value is whether we now have both grants; `permissionDenied`
    /// is flipped on a hard denial so the UI can react.
    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let ok = (speech == .authorized) && mic
        if !ok { permissionDenied = true }
        return ok
    }

    // MARK: - Push-to-talk

    /// Begin a new recognition session. Must be called on MainActor; the
    /// audio engine's tap callback runs on a background audio thread but
    /// only hands its buffers to `request`, which is an SFSpeech primitive
    /// designed for concurrent buffer appends.
    func startListening() throws {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "SpeechManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                              "Speech recognizer unavailable"])
        }

        lastError = nil
        lastTranscript = ""

        // Reset silence-detection state for this session.
        startedAt = Date()
        lastVoiceTime = nil
        hasEverHeardVoice = false

        // Reset the onFinal dedup guard so this new session's first
        // verdict is allowed through.
        onFinalFired = false

        // Measurement mode + ducking keeps TFLite-side compute audible to
        // AVAudioSession as a foreground microphone user. `.record` also
        // works but `.playAndRecord` is required if we ever add TTS later.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Install the tap *before* engine.start; removing it later in
        // stopListening() balances this install. Capture `req` as a
        // local so the audio-thread closure doesn't have to reach back
        // into MainActor-isolated state on every buffer — the request
        // object itself is thread-safe for concurrent `append(_:)`.
        //
        // `voiceThreshold` is a MainActor-isolated stored `let`, but the
        // tap runs on the audio thread. Pull the value into a local so
        // the closure never crosses that isolation boundary; the two
        // fields it *does* mutate (`lastVoiceTime`, `hasEverHeardVoice`)
        // are `nonisolated(unsafe) var` — see their declarations for
        // why that's acceptable here.
        let threshold = voiceThreshold
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            req.append(buf)
            guard let self else { return }
            let r = Self.rms(of: buf)
            if r > threshold {
                if !self.hasEverHeardVoice {
                    self.hasEverHeardVoice = true
                    print(String(format: "[Speech] voice detected (rms=%.3f)", r))
                }
                self.lastVoiceTime = Date()
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            // Callback fires on an arbitrary queue. Extract the Sendable
            // values we actually need (a plain String + a Bool) before
            // hopping to MainActor; this avoids having to mark
            // `SFSpeechRecognitionResult` / `Error` as Sendable for the
            // Task capture.
            let transcript: String? = result?.bestTranscription.formattedString
            let isFinal: Bool = result?.isFinal ?? false
            let hasError: Bool = (error != nil)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let transcript {
                    self.lastTranscript = transcript
                    if isFinal {
                        // Extremely rare in en-US, but
                        // still honor it when it arrives.
                        self.stopListening()
                        self.deliverFinal(transcript)
                        return
                    }
                }
                if hasError {
                    // Most recognition errors are "stopped speaking" or
                    // session-teardown noise rather than user-visible
                    // failures; surface the final transcript we do have
                    // and tear down silently.
                    let last = self.lastTranscript
                    self.stopListening()
                    if !last.isEmpty {
                        self.deliverFinal(last)
                    }
                }
            }
        }

        // Silence timer: fires on the main runloop every 0.3 s to check
        // the two termination conditions. Using Timer (not an async
        // Task.sleep loop) is easier to `invalidate()` on teardown and
        // naturally runs on MainActor.
        silenceTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: silenceCheckInterval,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickSilenceCheck()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer

        isListening = true
    }

    /// Tear down the audio tap + recognition task. Safe to call even if
    /// we're not currently listening. Emits `onFinal(lastTranscript)` is
    /// **not** called from here — the caller decides whether this
    /// teardown is end-of-speech or a cancel; the in-recognizer callback
    /// above and the silence tick below each handle it appropriately.
    func stopListening() {
        guard isListening || task != nil || request != nil else { return }

        silenceTimer?.invalidate()
        silenceTimer = nil
        startedAt = nil
        lastVoiceTime = nil
        hasEverHeardVoice = false

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil

        // Best-effort deactivate; failing here isn't actionable for the UI.
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)

        isListening = false
    }

    // MARK: - Silence timer tick

    /// Called every `silenceCheckInterval` while a session is active.
    /// Ends the session (and fires `onFinal`) if we've gone silent after
    /// hearing voice, or if the hard timeout elapsed regardless.
    private func tickSilenceCheck() {
        guard isListening else { return }

        // Hard timeout: absolute upper bound on one listen session.
        if let startedAt,
           Date().timeIntervalSince(startedAt) > hardTimeoutSeconds {
            print("[Speech] hard timeout after \(hardTimeoutSeconds)s → stop")
            endSessionEarly()
            return
        }

        // Normal silence end-of-speech: only valid after we've heard
        // voice at least once. Before then, the hard timeout is the
        // only thing that can end the session.
        if hasEverHeardVoice, let last = lastVoiceTime,
           Date().timeIntervalSince(last) > silenceGraceSeconds {
            print(String(format: "[Speech] silence for %.1fs → stop",
                         silenceGraceSeconds))
            endSessionEarly()
        }
    }

    /// Stop listening and deliver the current transcript to `onFinal`
    /// (if any). Used both by the silence timer's "natural end" exit
    /// and by the overlay's explicit Done button (see `finishEarly()`).
    /// Cancel from the UI calls `stopListening()` directly instead and
    /// doesn't fire `onFinal` unless there is already a transcript.
    private func endSessionEarly() {
        let transcript = lastTranscript
        stopListening()
        if !transcript.isEmpty {
            deliverFinal(transcript)
        }
    }

    /// Single funnel for every `onFinal` invocation in the manager. The
    /// `onFinalFired` guard ensures the subscriber (LiveView's
    /// `handleTranscript`) sees exactly one verdict per session, even
    /// when multiple termination paths race to finish — see the field's
    /// docstring for the race conditions this protects against.
    private func deliverFinal(_ transcript: String) {
        guard !onFinalFired else { return }
        onFinalFired = true
        onFinal?(transcript)
    }

    /// Public cancel path for the Cancel button / background tap in the
    /// listening overlay. Tears the session down without delivering the
    /// current transcript to `onFinal`.
    ///
    /// The subtlety here: just calling `stopListening()` isn't enough
    /// because `task?.cancel()` makes SFSpeechRecognizer fire its
    /// callback with `error != nil`, which our callback handler funnels
    /// into `deliverFinal(lastTranscript)` — so the cancelled session
    /// would end up applying its transcript anyway. We block that by
    /// flipping `onFinalFired = true` *before* the teardown, so any
    /// late callback-driven `deliverFinal(...)` becomes a no-op.
    func cancelListening() {
        guard isListening else {
            // Even if not listening, make sure any in-flight late
            // callbacks can't fire onFinal after a prior cancel request.
            onFinalFired = true
            return
        }
        onFinalFired = true
        stopListening()
    }

    /// Public trigger for the "Done" button in the listening overlay.
    /// Functionally identical to a silence-timer-detected end-of-speech,
    /// but lets the user bypass the 1.2s grace window when they know
    /// they've finished speaking. Funnels through the same path so the
    /// downstream handler (LiveView `handleTranscript`) doesn't need to
    /// distinguish between the two.
    func finishEarly() {
        guard isListening else { return }
        endSessionEarly()
    }

    // MARK: - RMS helper

    /// Root-mean-square amplitude of a float PCM buffer. Returns 0 when
    /// the buffer has no channels or is empty. Called from the audio
    /// thread, so this is deliberately `nonisolated static` and allocates
    /// nothing.
    nonisolated private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        // Sample the first channel only — mono mic on iPhone 11, and
        // even on stereo mics the two channels are tightly correlated
        // for VAD purposes. Summing both would roughly double the RMS
        // with no extra information.
        let ch = channels.pointee
        var sum: Float = 0
        for i in 0..<n {
            let s = ch[i]
            sum += s * s
        }
        return (sum / Float(n)).squareRoot()
    }
}
