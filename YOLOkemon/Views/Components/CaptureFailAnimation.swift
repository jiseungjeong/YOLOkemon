import SwiftUI

/// "Got away!" — late-failure animation.
/// Played only when a capture session's progress was already past
/// `lateFailureThreshold` (0.7) and collapsed back to 0 — early noise
/// shouldn't trigger this. The decision of when to fire lives in
/// `CaptureEngine.onLateFailure`; this view just renders the drama.
///
/// Total ~0.8s: the ball tumbles up-and-to-the-right, a red
/// `"Got away!"` caption flashes once, then both fade.
struct CaptureFailAnimation: View {
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var ballOffset: CGSize = .zero
    @State private var ballRotation: Double = 0
    @State private var ballOpacity: Double = 1
    @State private var textOpacity: Double = 0

    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                PokeballIcon(progress: 0.0, size: 80)
                    .offset(ballOffset)
                    .rotationEffect(.degrees(ballRotation))
                    .opacity(ballOpacity)

                Text("Got away!")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(PokemonColor.pokeballRed)
                    .shadow(color: .black.opacity(0.7), radius: 1, x: 0, y: 1)
                    .opacity(textOpacity)
            }
        }
        .task { await runSequence() }
        .allowsHitTesting(false)
    }

    private func runSequence() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) { textOpacity = 1 }
            try? await Task.sleep(nanoseconds: 400_000_000)
            withAnimation(.easeIn(duration: 0.3)) {
                textOpacity = 0
                ballOpacity = 0
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            onComplete()
            return
        }

        // Tumble up-and-out
        withAnimation(.easeOut(duration: 0.4)) {
            ballOffset = CGSize(width: 80, height: -60)
            ballRotation = 45
        }
        withAnimation(.easeOut(duration: 0.25)) {
            textOpacity = 1
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        withAnimation(.easeIn(duration: 0.4)) {
            textOpacity = 0
            ballOpacity = 0
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        onComplete()
    }
}

#Preview {
    ZStack {
        Color.black
        CaptureFailAnimation { }
    }
}
