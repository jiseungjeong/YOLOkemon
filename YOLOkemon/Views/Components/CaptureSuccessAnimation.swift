import SwiftUI

/// "Gotcha!" — success animation that plays once when
/// `CaptureEngine` reports a catch.
///
/// 4-phase sequence, no SpriteKit:
///   1. Drop   (0.0–0.6s) — Poké Ball spring-drops from off-screen top.
///   2. Shake  (0.6–0.9s) — Two small rotations to simulate "struggle".
///   3. Flash  (0.9–1.2s) — PokedexYellow radial glow + "Gotcha!" text.
///   4. Fade   (1.2–1.8s) — Everything fades, then `onComplete` fires.
///
/// When `UIAccessibility.isReduceMotionEnabled` is on we skip the
/// drop+shake phases and just play the flash+fade.
struct CaptureSuccessAnimation: View {
    let className: String
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var ballY: CGFloat = -600
    @State private var ballRotation: Double = 0
    @State private var flashOpacity: Double = 0
    @State private var textScale: Double = 0.6
    @State private var rootOpacity: Double = 1

    var body: some View {
        ZStack {
            // Radial flash — sits behind the ball.
            RadialGradient(
                gradient: Gradient(colors: [
                    PokemonColor.pokedexYellow.opacity(0.9),
                    PokemonColor.pokedexYellow.opacity(0)
                ]),
                center: .center,
                startRadius: 10,
                endRadius: 260
            )
            .opacity(flashOpacity)
            .blendMode(.plusLighter)

            VStack(spacing: 18) {
                PokeballIcon(progress: 1.0, size: 120)
                    .rotationEffect(.degrees(ballRotation))
                    .offset(y: ballY)

                Text("Gotcha!")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(PokemonColor.pokedexYellow)
                    .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
                    .scaleEffect(textScale)
                    .opacity(flashOpacity)

                Text("\(className) caught!")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(PokemonColor.pokeballCenter.opacity(0.7))
                    .clipShape(Capsule())
                    .opacity(flashOpacity)
            }
        }
        .opacity(rootOpacity)
        .task { await runSequence() }
        .allowsHitTesting(false)
    }

    private func runSequence() async {
        if reduceMotion {
            // Condensed: flash + fade only.
            withAnimation(.easeOut(duration: 0.3)) {
                flashOpacity = 1
                textScale = 1
                ballY = 0
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            withAnimation(.easeIn(duration: 0.5)) {
                rootOpacity = 0
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            onComplete()
            return
        }

        // Phase 1 — Drop
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            ballY = 0
        }
        try? await Task.sleep(nanoseconds: 600_000_000)

        // Phase 2 — Shake (two rocks)
        withAnimation(.easeInOut(duration: 0.1)) { ballRotation = -12 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        withAnimation(.easeInOut(duration: 0.1)) { ballRotation = 12 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        withAnimation(.easeInOut(duration: 0.1)) { ballRotation = 0 }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Phase 3 — Flash
        withAnimation(.easeOut(duration: 0.3)) {
            flashOpacity = 1
            textScale = 1
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Phase 4 — Fade
        withAnimation(.easeIn(duration: 0.6)) {
            rootOpacity = 0
        }
        try? await Task.sleep(nanoseconds: 600_000_000)

        onComplete()
    }
}

#Preview {
    ZStack {
        Color.black
        CaptureSuccessAnimation(className: "laptop") { }
    }
}
