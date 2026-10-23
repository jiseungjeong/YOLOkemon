import SwiftUI

/// Camera preview + bounding box overlay + runtime precision
/// switching, plus the voice target selection UI (push-to-talk
/// mic + Clear button) and green/orange highlight integration.
///
/// Frame loop:
///   1. `CameraManager.captureOutput` runs on `frameQueue`
///      (userInitiated). It flips its local `busy` flag and calls
///      `onFrame` on the same queue.
///   2. `onFrame` is a closure set in `setup()` that spawns a `Task` to
///      await the inference actor (`engine.core.infer(...)`).
///   3. The Task hops onto MainActor only to push detections + rolling
///      latency stats into @State. Then it calls `camera.markFrameDone()`
///      to unblock the next frame.
///
/// The main thread is no longer holding inference — that is now on the
/// Swift concurrency cooperative pool — so camera preview and SwiftUI
/// rendering can stay smooth even while a frame is mid-inference.
struct LiveView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var engine = DetectionEngine()
    @StateObject private var speech = SpeechManager()
    @StateObject private var targetStore = TargetStore()

    // YOLOkémon capture engine. Lives with
    // LiveView because the capture session is inherently tied to the
    // camera feed — no other tab produces detections or needs to drive
    // progress. When the user leaves Live we keep it in memory so a
    // quick Dashboard → Live hop doesn't reset a running capture.
    @StateObject private var captureEngine = CaptureEngine()

    // TabView selection, shared with ContentView so voice command
    // `.openPokedex` and the Pokédex toggle can
    // write to the same state.
    @Binding var selectedTab: Tab

    // Shared across tabs — owned by YOLOkemonApp and injected via
    // `.environmentObject(...)`. We append one record per frame from
    // `handleResult`; the Dashboard/Export tabs subscribe.
    @EnvironmentObject private var sessionLog: SessionLogStore

    // YOLOkémon Pokédex catalog. Populated by LiveView
    // whenever a capture succeeds; the Pokédex tab reads it.
    @EnvironmentObject private var pokedexStore: PokedexStore

    // Latest inference output, owned by the view so SwiftUI can animate it.
    @State private var detections: [Detection] = []
    @State private var frameSize: CGSize = .zero

    // User-driven precision toggle. Mirrored from the engine's current
    // state so the picker stays in sync after a setup-time load.
    @State private var selectedPrecision: Precision = .fp32

    // Two-row status bar. `statusText` now owns
    // inference-metrics + transient lifecycle messages only (loading,
    // permission denied, switch errors, etc.). `targetStatusText` carries
    // target-specific state — "Looking for cup…", "cup found with FP32.",
    // "cup not found in current frame.", plus parser errors like
    // "unsupported class: dragon". Empty string means "render nothing"
    // so the row collapses when no target is active.
    @State private var statusText: String = "Requesting camera permission..."
    @State private var targetStatusText: String = ""
    @State private var firstResultLogged = false
    @State private var lastStatusUpdate: CFTimeInterval = 0

    // Rolling pre/inf/post window used to show a stable cost breakdown on
    // the status bar. A single first-frame
    // log wasn't enough to distinguish Preprocessor cost from inference
    // cost when diagnosing the 4 fps ceiling — we need the running average
    // to tell if a change actually moved the Preprocessor number down.
    @State private var rollingPre:  [Double] = []
    @State private var rollingInf:  [Double] = []
    @State private var rollingPost: [Double] = []
    private static let rollingWindow = 30

    // Target-presence tracking for the "found / not found" status bar
    // messages. We keep running counters of how many of
    // the last few frames contained the target, and surface a summary
    // to the status bar at the same 2-second cadence as the latency row.
    @State private var targetFoundStreak: Int = 0    // consecutive hits
    @State private var targetMissStreak:  Int = 0    // consecutive misses
    private static let targetFoundThreshold = 3      // frames in a row
    private static let targetMissThreshold  = 30     // ~1 s @ 30 fps

    // `true` once `speech.requestPermissions()` has been invoked. We
    // call that lazily on the first mic-button tap, not at app launch.
    @State private var speechPermissionRequested: Bool = false

    // `true` once setup() has completed its first successful run. SwiftUI
    // re-fires `.task { await setup() }` every time LiveView re-appears
    // (e.g. after a Dashboard → Live tab switch). The camera/engine
    // @StateObjects persist across those re-appearances, so re-running
    // `setup()` would uselessly reload the precision we're already on
    // (5 s stall) and re-wire closures that are already wired. Guard
    // with this flag so the second .task invocation is a no-op.
    @State private var didSetup: Bool = false

    // Pause inference button state.
    // When paused, the frame closure skips `core.infer(...)` entirely —
    // camera preview keeps rendering (AVCaptureSession stays running)
    // and the last set of detections stays drawn, so the user sees the
    // freeze rather than a blank overlay.
    @State private var isInferencePaused: Bool = false

    // Last raw transcript the speech recognizer delivered for this
    // session — used by the Live Summary card's "Voice" field so the
    // user keeps seeing what they just said even after the overlay
    // closes. Shows the raw SFSpeechRecognizer string (e.g. "find the
    // cop") rather than the alias-normalized form; the metrics row and
    // green target status row already show the normalized intent.
    @State private var lastUtterance: String = ""

    // YOLOkémon transition animations. Gotcha! fires from
    // `handleCaptureSuccess`; Got away! fires from
    // `captureEngine.onLateFailure`. Each animation's `onComplete`
    // sets its flag back to false.
    @State private var showSuccessAnimation: Bool = false
    @State private var showFailAnimation: Bool = false
    @State private var caughtClass: String = ""

    var body: some View {
        // Outer ZStack so the VoiceListeningOverlay can float above the
        // camera + controls layer without interrupting the underlying
        // frame loop. The overlay is only inserted when
        // `speech.isListening` is true, and fades in/out via the animation
        // on the containing ZStack.
        ZStack {
            VStack(spacing: 0) {
                AppHeader(title: "On-device Object Detection",
                          subtitle: buildHeaderSubtitle())

                ZStack {
                    Color.black
                    if camera.isRunning {
                        CameraPreview(session: camera.session)
                        LiveOverlayView(detections: detections,
                                        sourceSize: frameSize,
                                        targetLabel: targetStore.target,
                                        captureEngine: captureEngine)
                    } else {
                        ProgressView().tint(.white)
                    }

                    // Transition animations. These sit on top
                    // of the overlay (so they read against the preview
                    // rather than the controls below). Each animation
                    // toggles itself off via the onComplete callback.
                    if showSuccessAnimation {
                        CaptureSuccessAnimation(className: caughtClass) {
                            showSuccessAnimation = false
                        }
                    }
                    if showFailAnimation {
                        CaptureFailAnimation {
                            showFailAnimation = false
                        }
                    }
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipped()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        controlPanel
                        liveSummaryCard
                    }
                    .padding()
                }
            }

            if speech.isListening {
                VoiceListeningOverlay(
                    speech: speech,
                    // Cancel (button OR background tap) must discard
                    // whatever transcript we have. Plain stopListening()
                    // isn't enough — task.cancel() triggers a
                    // recognitionTask error callback that funnels into
                    // deliverFinal(lastTranscript), which would apply
                    // the cancelled utterance anyway. cancelListening()
                    // flips onFinalFired=true first so any late
                    // callback becomes a no-op.
                    onCancel: { speech.cancelListening() },
                    // Done bypasses the 1.2s silence grace. finishEarly
                    // funnels through the same path as a normal silence
                    // end-of-speech — stopListening + onFinal(transcript)
                    // — so LiveView's handleTranscript runs as if the
                    // user had just stopped speaking. Overlay disables
                    // Done while lastTranscript is empty, so by the time
                    // this fires we always have something to parse.
                    onDone: { speech.finishEarly() }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: speech.isListening)
        .task { await setup() }
        .onDisappear {
            camera.stop()
            // Tab/scene disappearance is treated as a cancel: we don't
            // want a stale half-utterance to fire target selection
            // after the user navigated away.
            speech.cancelListening()
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrecisionToggle(selection: $selectedPrecision,
                            disabled: engine.isLoadingModel) { newPrec in
                applySwitch(precision: newPrec)
            }

            // Row 1: metrics + transient lifecycle messages. Always
            // visible — this row carries pre/inf/post/fps even when a
            // target is selected.
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Row 2: target-specific status. Only rendered when
            // non-empty so the column collapses to zero height when no
            // target is active. Green tint matches the bounding-box
            // highlight color so the two signals reinforce each other.
            if !targetStatusText.isEmpty {
                Text(targetStatusText)
                    .font(.footnote)
                    .foregroundStyle(.green)
            }

            // `active:` row — precision + delegate. Dropped the old
            // `· target: cup` badge now that the target status row
            // above carries that information more prominently.
            Text("active: \(engine.currentPrecision.display) · cpu"
               + (engine.isLoadingModel ? "  (loading…)" : ""))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let err = engine.lastError {
                Text("⚠️ \(err)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if speech.permissionDenied {
                Text("⚠️ mic/speech permission denied — enable in Settings")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button {
                    isInferencePaused.toggle()
                } label: {
                    Label(isInferencePaused ? "Resume inference" : "Pause inference",
                          systemImage: isInferencePaused ? "play.circle" : "pause.circle")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .tint(isInferencePaused ? .green : .accentColor)

                Button(action: toggleListening) {
                    Label(speech.isListening ? "Listening..." : "Voice target",
                          systemImage: speech.isListening
                                       ? "waveform.circle.fill"
                                       : "mic.circle")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .tint(speech.isListening ? .red : .accentColor)

                if targetStore.target != nil {
                    Button {
                        targetStore.clear()
                        captureEngine.giveUp()
                        targetFoundStreak = 0
                        targetMissStreak = 0
                        // Clear the green target row so it collapses to
                        // zero height; the metrics row above stays as
                        // the rolling timer last wrote it.
                        targetStatusText = ""
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }

                // Poké Ball toggle — start a capture on the
                // current target, or cancel one that's already running.
                // Renders the ball itself (no bordered button chrome)
                // so the controlPanel has one "hero" affordance that
                // also doubles as a live progress gauge. The tap area
                // is expanded via `.contentShape` because the ball's
                // visible hit area (32pt) is below HIG's 44pt target.
                // Disabled while the camera is paused since capture
                // progress only moves on new detections.
                Button(action: togglePokeball) {
                    PokeballIcon(progress: captureEngine.captureProgress,
                                 size: 36)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isInferencePaused)
                .opacity(isInferencePaused ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Voice push-to-talk

    /// Mic button handler. First tap requests permissions (lazily);
    /// subsequent taps just flip listening state.
    /// Re-tapping while already listening is treated as a cancel — the
    /// user explicitly interrupted, so any partial transcript is
    /// discarded instead of applied.
    private func toggleListening() {
        if speech.isListening {
            speech.cancelListening()
            return
        }
        Task {
            if !speechPermissionRequested {
                speechPermissionRequested = true
                let ok = await speech.requestPermissions()
                guard ok else {
                    statusText = "Mic/speech permission denied."
                    return
                }
            } else if speech.permissionDenied {
                statusText = "Mic/speech permission denied — enable in Settings."
                return
            }
            do {
                try speech.startListening()
                // Intentionally don't overwrite statusText here —
                // VoiceListeningOverlay takes over the "I'm listening"
                // feedback while isListening is true. Once it flips back
                // off, handleTranscript() updates `targetStatusText`
                // (the green row) with the parse result
                // ("Looking for cup..." / "unsupported class: …").
            } catch {
                statusText = "Speech failed: \(error.localizedDescription)"
            }
        }
    }

    /// Parser dispatch. Called on MainActor from `speech.onFinal`.
    /// All target-related feedback lands in `targetStatusText` (green
    /// row) so the metrics row above stays untouched.
    private func handleTranscript(_ transcript: String) {
        // Persist the raw utterance for the Live Summary card's Voice
        // field. Use the alias-normalized form so
        // "find the cop" shows as "find the cup" — matches what was
        // actually acted on.
        lastUtterance = VoiceCommandParser.displayNormalized(transcript)
        let intent = VoiceCommandParser.parse(transcript)
        switch intent {
        case .highlight(let label):
            targetStore.set(label)
            targetFoundStreak = 0
            targetMissStreak = 0
            targetStatusText = "Looking for \(label) with "
                             + "\(engine.currentPrecision.display)..."
        case .unsupported(let noun):
            targetStatusText = "unsupported class: \(noun)"
        case .unparseable:
            targetStatusText = "Could not understand. Try \"find the cup\"."
        case .capture(let label):
            // `"I choose the cup"` / `"catch cup"` — start the
            // YOLOkémon capture loop on `label`. Also set the target
            // so the green highlight in LiveOverlayView activates and
            // the Live Summary card reflects the new target class.
            targetStore.set(label)
            targetFoundStreak = 0
            targetMissStreak = 0
            captureEngine.startCapture(targetClass: label)
            targetStatusText = "Capturing \(label) with "
                             + "\(engine.currentPrecision.display)..."
        case .stopCapture:
            // `"give up"` / `"stop"`. Stops the capture loop but keeps
            // the highlight target in place — a natural "nevermind I'll
            // just look at it" flow. The user can say `"find the cup"`
            // again to clear, or tap the Clear button.
            captureEngine.giveUp()
            targetStatusText = "Capture stopped."
        case .openPokedex:
            // `"open pokedex"` / `"show pokedex"`. Switches to the
            // Pokédex tab and shows the caught count in the status bar.
            selectedTab = .pokedex
            targetStatusText = "Pokédex — \(pokedexStore.caughtCount) caught."
        }
    }

    /// Start or stop a YOLOkémon capture from the Live controlPanel
    /// Poké Ball toggle. No target set → hint the user via
    /// the green status row; already capturing → give up; otherwise
    /// kick off a new session on the current target.
    private func togglePokeball() {
        if captureEngine.isCapturing {
            captureEngine.giveUp()
            targetStatusText = "Capture stopped."
            return
        }
        guard let target = targetStore.target else {
            targetStatusText = "Set a target first (\"find the cup\")."
            return
        }
        captureEngine.startCapture(targetClass: target)
        targetStatusText = "Capturing \(target) with "
                         + "\(engine.currentPrecision.display)..."
    }

    /// Called on MainActor from `captureEngine.onCaptured`. Writes to
    /// the persistent Pokédex and records the session-level capture
    /// event so the temporal-stability stats show up on
    /// the Dashboard and in the exported JSON.
    private func handleCaptureSuccess(className: String,
                                      seconds: Double,
                                      attempts: Int) {
        let entry = PokedexEntry(
            className: className,
            caughtAt: Int64(Date().timeIntervalSince1970 * 1000),
            usedModel: engine.currentPrecision.display,
            captureTimeSeconds: seconds,
            attemptCount: attempts,
            thumbnailFilename: nil)
        pokedexStore.record(entry)
        sessionLog.recordCapture(entry)
        showSuccessAnimation = true
        caughtClass = className
        targetStatusText = String(format: "Gotcha! %@ caught in %.1fs.",
                                  className, seconds)
    }

    // MARK: - Setup & frame handling

    private func setup() async {
        // Tab revisits re-fire `.task`; skip the full setup path the
        // second time. The camera/engine/speech @StateObjects persist
        // across the revisit, so CameraManager's session is already
        // configured and the engine has a loaded interpreter — we just
        // need the preview to resume (CameraManager.start() is already
        // idempotent via `!session.isRunning` guard).
        if didSetup {
            camera.start()
            return
        }

        let granted = await camera.requestPermission()
        guard granted else {
            statusText = "Camera permission denied. Enable it in Settings."
            return
        }

        // Plug the speech manager's final-transcript hook into the
        // intent dispatcher. Declared here (after permissions) so the
        // closure is installed before the user can possibly tap the
        // mic button.
        speech.onFinal = { transcript in
            Task { @MainActor in handleTranscript(transcript) }
        }

        // Capture success → write a PokedexEntry and surface a friendly
        // status line. Route through `handleCaptureSuccess(...)` on a
        // fresh MainActor hop so we mutate `@State` on the struct's
        // live instance, not a captured copy — same pattern
        // `speech.onFinal` uses for `handleTranscript(...)`.
        captureEngine.onCaptured = { className, seconds, attempts in
            Task { @MainActor in
                handleCaptureSuccess(className: className,
                                     seconds: seconds,
                                     attempts: attempts)
            }
        }

        // Got-away! animation. The engine only fires this
        // when progress collapsed from ≥ 0.7, so we can trust it here
        // and skip any extra gate.
        captureEngine.onLateFailure = {
            Task { @MainActor in
                showFailAnimation = true
            }
        }

        do {
            try camera.configure()
            selectedPrecision = .fp32
            await engine.switchPrecision(to: selectedPrecision)

            // Frame handler runs on the camera's frameQueue. Capture only
            // what the async Task needs (the inference actor, the camera
            // for markFrameDone). LiveView is bound to MainActor, so any
            // @State / @StateObject read happens after the MainActor hop.
            let core = engine.core
            let camRef = camera
            camera.onFrame = { @Sendable box in
                // This closure runs on the camera's frameQueue. Kick off
                // an async Task that drives the inference actor and then
                // hops back to MainActor for the UI mutation. The final
                // `box.release()` balances the `Unmanaged.passRetained`
                // that PixelBufferBox's init did — exactly one release
                // per box, regardless of error path.
                Task { @Sendable in
                    defer {
                        box.release()
                        camRef.markFrameDone()
                    }
                    // Pause check: read the @State on MainActor (no
                    // race). When paused we skip inference entirely —
                    // the last frame's detections stay drawn on the
                    // overlay, and the camera preview continues since
                    // AVCaptureSession isn't stopped. Resume = next
                    // frame gets processed normally.
                    let paused = await MainActor.run { isInferencePaused }
                    if paused { return }

                    let result: InferenceResult
                    do {
                        result = try await core.infer(box)
                    } catch {
                        await MainActor.run {
                            handleInferenceError(error)
                        }
                        return
                    }
                    await MainActor.run {
                        handleResult(result: result, box: box)
                    }
                }
            }
            camera.start()
            sessionLog.setCurrentPrecision(selectedPrecision)
            let mb = ModelRegistry.fileSizeMB(selectedPrecision)
            statusText = String(format: "Loaded %@ model (%.2f MB). Streaming...",
                                selectedPrecision.display, mb)

            // Only mark the setup as complete on the happy path. If
            // something threw above, we want the next .task invocation
            // to retry from scratch rather than jump straight to the
            // `camera.start()` fast path.
            didSetup = true
        } catch {
            statusText = "Setup failed: \(error)"
        }
    }

    private func applySwitch(precision p: Precision) {
        // Drop the currently displayed boxes so the overlay is empty while
        // the interpreter swap is in progress — stale boxes on a fresh
        // model can look jarring.
        detections = []
        // Reset rolling latency window so the new precision doesn't show
        // numbers that still carry ms from the previous interpreter.
        rollingPre.removeAll(keepingCapacity: true)
        rollingInf.removeAll(keepingCapacity: true)
        rollingPost.removeAll(keepingCapacity: true)
        statusText = "Loading \(p.display) model..."
        Task {
            await engine.switchPrecision(to: p)
            if engine.lastError == nil {
                sessionLog.setCurrentPrecision(p)
                let mb = ModelRegistry.fileSizeMB(p)
                statusText = String(format: "Loaded %@ model (%.2f MB) on cpu.",
                                    p.display, mb)
            } else if let err = engine.lastError {
                statusText = "Switch failed: \(err)"
            }
        }
    }

    private func handleInferenceError(_ error: Error) {
        statusText = "Inference failed: \(error)"
    }

    /// Called on MainActor after the inference actor produced a result.
    /// Updates detections, frame size, rolling latency stats, and the
    /// target-presence streaks.
    private func handleResult(result: InferenceResult,
                              box: PixelBufferBox) {
        let buf = box.readBuffer()
        let w = CGFloat(CVPixelBufferGetWidth(buf))
        let h = CGFloat(CVPixelBufferGetHeight(buf))
        if frameSize.width != w || frameSize.height != h {
            frameSize = CGSize(width: w, height: h)
        }
        detections = result.detections

        // Drive the YOLOkémon capture loop. Safe to call every frame;
        // the engine short-circuits when no capture is active.
        captureEngine.onDetections(result.detections,
                                   frameTimeMs: result.totalMs)

        if !firstResultLogged {
            firstResultLogged = true
            print("[LiveView] source frame: \(Int(w))x\(Int(h))")
            print("[LiveView] first inference: "
                + "pre \(fmt(result.preprocessMs)) ms, "
                + "inf \(fmt(result.inferenceMs)) ms, "
                + "post \(fmt(result.postprocessMs)) ms, "
                + "\(result.detections.count) detections")
            for d in result.detections.prefix(10) {
                print(String(format: "  - %@  %.0f%%  "
                           + "x=%.0f y=%.0f w=%.0f h=%.0f",
                             d.label, d.confidence * 100,
                             d.box.minX, d.box.minY,
                             d.box.width, d.box.height))
            }
        }

        // Rolling breakdown: keep the last N frames' pre/inf/post so
        // the status bar can show averages rather than a noisy instant.
        rollingPre.append(result.preprocessMs)
        rollingInf.append(result.inferenceMs)
        rollingPost.append(result.postprocessMs)
        if rollingPre.count  > Self.rollingWindow { rollingPre.removeFirst()  }
        if rollingInf.count  > Self.rollingWindow { rollingInf.removeFirst()  }
        if rollingPost.count > Self.rollingWindow { rollingPost.removeFirst() }

        // Persist the frame into the shared session log. Dashboard and
        // Export tabs observe the store via @Published; there's no
        // active subscribing view cost per frame because SwiftUI diffs
        // the read-only summary rollup, not the full records array.
        //
        // YOLOkémon capture signals piggy-back on the same
        // append — `captureProgress` and the per-frame IoU are only
        // non-nil while a capture session is live, so the log stays
        // sparse when the feature isn't in use.
        let captureProgressVal: Double? = captureEngine.isCapturing
            ? captureEngine.captureProgress : nil
        sessionLog.append(result: result,
                          precision: engine.currentPrecision,
                          targetClass: targetStore.target,
                          captureProgress: captureProgressVal,
                          captureIoU: captureEngine.lastIoU)

        // Target-presence streak update. Only meaningful when the user
        // has actually asked for a target; otherwise we just idle the
        // counters so they're ready for the next `targetStore.set(...)`.
        updateTargetStreaks(detections: result.detections)

        let now = CACurrentMediaTime()
        if now - lastStatusUpdate > 2 {
            lastStatusUpdate = now
            statusText = buildMetricsText(result: result)
            // `targetStatusText` is set *every* tick even when empty,
            // so clearing the target (via the Clear button) promptly
            // blanks the row at the next update instead of sticking on
            // "cup found…". Parser results ("unsupported class: …")
            // set this field directly via handleTranscript and survive
            // one tick window before the streaks catch up.
            //
            // While a YOLOkémon capture is running we hand the row over
            // to a live progress readout (`Capturing cup… 42%`) instead
            // of the generic "found/not found" summary. Without this
            // guard the 2-second tick wipes the "Capturing…" line that
            // `handleTranscript(.capture)` just set, so the user never
            // sees any feedback that the capture started.
            //
            // After a successful catch we also leave `targetStatusText`
            // alone for a short celebration window so the "Gotcha!"
            // line set by `handleCaptureSuccess(...)` has time to read
            // instead of getting stomped on the next tick.
            if captureEngine.isCapturing,
               let cls = captureEngine.targetClass {
                let pct = Int((captureEngine.captureProgress * 100)
                                .rounded())
                targetStatusText = "Capturing \(cls) with "
                                 + "\(engine.currentPrecision.display)"
                                 + "... \(pct)%"
            } else if captureEngine.isCelebrating {
                // Hold the "Gotcha!" line in place.
            } else {
                let targetLine = buildTargetStatusText()
                if !targetLine.isEmpty || targetStore.target != nil {
                    targetStatusText = targetLine
                }
            }
        }
    }

    /// Track how many consecutive frames contained the active target
    /// class, and how many consecutive frames missed it. Reset on
    /// target change (handled in `handleTranscript` / `Clear` button).
    private func updateTargetStreaks(detections: [Detection]) {
        guard let target = targetStore.target else {
            targetFoundStreak = 0
            targetMissStreak  = 0
            return
        }
        let seen = detections.contains { $0.label == target }
        if seen {
            targetFoundStreak += 1
            targetMissStreak = 0
        } else {
            targetMissStreak += 1
            targetFoundStreak = 0
        }
    }

    /// Always-on metrics row. Renders the same
    /// `precision · N objs · pre/inf/post · fps` summary regardless of
    /// whether a target is set, so the user can watch latency while a
    /// target highlight is active.
    private func buildMetricsText(result: InferenceResult) -> String {
        let avgPre  = rollingPre.reduce(0, +)  / Double(max(rollingPre.count, 1))
        let avgInf  = rollingInf.reduce(0, +)  / Double(max(rollingInf.count, 1))
        let avgPost = rollingPost.reduce(0, +) / Double(max(rollingPost.count, 1))
        let totalMs = avgPre + avgInf + avgPost
        let fps     = 1000.0 / max(totalMs, 1)
        let precision = engine.currentPrecision.display

        return String(
            format: "%@ · %d objs · pre %.0f · inf %.0f · post %.0f · %.1f fps",
            precision, result.detections.count,
            avgPre, avgInf, avgPost, fps
        )
    }

    /// Target-specific status line. Returns `""` when no
    /// target is active so the caller can conditionally hide the row.
    /// State precedence: found > not-found > looking.
    private func buildTargetStatusText() -> String {
        guard let target = targetStore.target else { return "" }
        let precision = engine.currentPrecision.display
        if targetFoundStreak >= Self.targetFoundThreshold {
            return "\(target) found with \(precision)."
        }
        if targetMissStreak >= Self.targetMissThreshold {
            return "\(target) not found in current frame."
        }
        return "Looking for \(target) with \(precision)..."
    }

    private func fmt(_ ms: Double) -> String { String(format: "%.1f", ms) }

    // MARK: - Header subtitle

    /// Pick the most informative one-liner for the AppHeader subtitle
    ///. Priority (top = wins):
    ///   1. Paused         — explicit state, most important to see
    ///   2. Loading model  — user asked for a switch; show progress
    ///   3. Target status  — user-driven search ("cup found…")
    ///   4. Active snapshot — `FP32 active. 4 objects detected.`
    ///   5. Fallback to statusText (permission / setup messages)
    private func buildHeaderSubtitle() -> String {
        if isInferencePaused {
            return "Paused. Inference frozen."
        }
        if engine.isLoadingModel {
            return "Loading \(selectedPrecision.display) model..."
        }
        if !targetStatusText.isEmpty {
            return targetStatusText
        }
        // Active snapshot — only meaningful once we've produced at
        // least one frame (detections has been assigned). Before that,
        // fall through to whatever statusText has (usually
        // "Requesting camera permission..." / "Loaded FP32 model…").
        if !detections.isEmpty || !rollingInf.isEmpty {
            let count = detections.count
            return "\(engine.currentPrecision.display) active. \(count) object\(count == 1 ? "" : "s") detected."
        }
        return statusText
    }

    // MARK: - Live Summary card

    @ViewBuilder
    private var liveSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Summary")
                .font(.headline)

            // 2x2 grid of key metrics. Adaptive sizing keeps the labels
            // from truncating on iPhone SE while leaving room for the
            // values to breathe on 6.7" screens.
            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .topLeading),
                GridItem(.flexible(), alignment: .topLeading),
            ], alignment: .leading, spacing: 16) {
                summaryCell(label: "Target",
                            value: targetStore.target ?? "Not set")
                summaryCell(label: "Voice",
                            value: lastUtterance.isEmpty ? "—" : lastUtterance)
                summaryCell(label: "Avg latency",
                            value: String(format: "%.2f ms", sessionLog.avgLatencyMs))
                summaryCell(label: "FPS",
                            value: String(format: "%.2f", sessionLog.rollingFps))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }

    private func summaryCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }
}

#Preview {
    LiveView(selectedTab: .constant(.live))
        .environmentObject(SessionLogStore())
        .environmentObject(PokedexStore())
}
