import SwiftUI

/// Siri-style voice-input overlay shown while `SpeechManager.isListening`
/// is true. Lives above the camera preview in `LiveView`'s ZStack — the
/// camera keeps running underneath so object detection doesn't pause
/// while the user is speaking.
///
/// The overlay is deliberately stateless aside from a `pulsing` flag for
/// the mic animation: all user-facing state (`isListening`, the running
/// `lastTranscript`) comes from the `SpeechManager` it observes.
/// Dismissal is handed back to the parent via `onCancel` / `onDone`,
/// both of which typically call into the speech manager — the manager
/// flips `isListening` to `false`, and the parent removes us from its
/// view tree via `if speech.isListening { VoiceListeningOverlay(...) }`.
///
/// Interaction model:
///   * Tap the dark background → `onCancel` (discards transcript).
///   * Tap the explicit "Cancel" button → `onCancel` (discards transcript).
///   * Tap the "Done" button → `onDone` (applies transcript *now*,
///     bypassing the silence-grace wait).
///   * Stay silent → silence detector in `SpeechManager` ends the
///     session on its own.
///
/// Either way the overlay goes away the moment `isListening` flips.
struct VoiceListeningOverlay: View {
    @ObservedObject var speech: SpeechManager
    var onCancel: () -> Void
    var onDone: () -> Void

    @State private var pulsing: Bool = false

    var body: some View {
        ZStack {
            // Full-screen dark scrim. Takes any tap as a cancel so users
            // can dismiss without precisely hitting the Cancel button —
            // this is the convention Siri uses too.
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
                .accessibilityHidden(true)

            VStack(spacing: 24) {
                // Pulsing mic — the universal "I'm listening" affordance.
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.white)
                    .scaleEffect(pulsing ? 1.15 : 1.0)
                    .opacity(pulsing ? 1.0 : 0.85)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: pulsing
                    )
                    .onAppear { pulsing = true }
                    .accessibilityHidden(true)

                Text("Listening…")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))

                // Partial transcript area. Reserve vertical space with a
                // minHeight so the layout doesn't jump when the first
                // word arrives.
                transcriptView
                    .frame(minHeight: 72)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)

                Text("Try: \"find the cup\" · \"find the bottle\" · \"find the book\"")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Two-button confirm row. Cancel discards the current
                // transcript (what the user said is forgotten); Done
                // applies it immediately via `speech.finishEarly()` so
                // the user doesn't have to wait out the 1.2 s silence
                // grace when they *know* they're finished.
                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Label("Cancel", systemImage: "xmark")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityLabel("Cancel voice input")

                    Button(action: onDone) {
                        Label("Done", systemImage: "checkmark")
                            .font(.callout)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(speech.lastTranscript.isEmpty)
                    .accessibilityLabel("Apply voice command")
                }
            }
            .padding(.vertical, 32)
        }
    }

    @ViewBuilder
    private var transcriptView: some View {
        if speech.lastTranscript.isEmpty {
            Text("Say something…")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.3))
        } else {
            // Run the transcript through the same alias substitution
            // the parser uses so the user sees the *corrected* form in
            // real time — e.g. SFSpeechRecognizer giving us "find the
            // cop" becomes "find the cup" on screen, matching what the
            // app will actually act on. Without this the UX is
            // confusing: the overlay shows "cop" and the user has to
            // trust that the parser silently rewrites it.
            let display = VoiceCommandParser.displayNormalized(speech.lastTranscript)
            Text(display)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                // Fade each transcript update so the "find" → "find the"
                // → "find the cup" progression feels continuous rather
                // than flashing.
                .transition(.opacity)
                .id(display)
        }
    }
}

#Preview {
    // Preview helper — the real SpeechManager needs mic permission, so
    // we fake the observable state by driving it manually.
    struct PreviewHost: View {
        @StateObject var speech = SpeechManager()
        var body: some View {
            VoiceListeningOverlay(speech: speech, onCancel: { }, onDone: { })
                .onAppear {
                    // Can't actually flip @Published private(set), so the
                    // preview just shows the empty state.
                }
        }
    }
    return PreviewHost()
}
