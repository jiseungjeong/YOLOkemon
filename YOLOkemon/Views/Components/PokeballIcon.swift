import SwiftUI

/// A Poké Ball drawn entirely in SwiftUI — no image assets.
/// `progress` ∈ [0, 1] fills the top hemisphere
/// so the same view can double as an icon (progress=1) and as the
/// capture gauge (progress=captureEngine.captureProgress).
///
/// Geometry is scaled off `size` so a single call site can render the
/// same shape at both 44pt (button) and 120pt (Gotcha! overlay).
struct PokeballIcon: View {
    var progress: Double = 1.0
    var size: CGFloat = 44

    var body: some View {
        let ringStroke = max(size * 0.06, 2)
        let beltHeight = max(size * 0.14, 4)
        let centerDia  = size * 0.34
        let innerDia   = centerDia * 0.55

        ZStack {
            // Bottom hemisphere is always the "unfilled" white.
            Circle()
                .fill(Color.white)

            // Top hemisphere — clipped to upper half, fill amount
            // driven by progress.
            PokeballTopFill(progress: progress)
                .fill(PokemonColor.pokeballRed)

            // Outer stroke
            Circle()
                .stroke(PokemonColor.pokeballCenter, lineWidth: ringStroke)

            // Horizontal belt splitting the two hemispheres.
            Rectangle()
                .fill(PokemonColor.pokeballCenter)
                .frame(height: beltHeight)

            // Center button — outer dark ring, inner white, small grey dot.
            ZStack {
                Circle()
                    .fill(PokemonColor.pokeballCenter)
                    .frame(width: centerDia, height: centerDia)
                Circle()
                    .fill(Color.white)
                    .frame(width: centerDia - ringStroke * 1.6,
                           height: centerDia - ringStroke * 1.6)
                Circle()
                    .stroke(PokemonColor.pokeballCenter.opacity(0.35),
                            lineWidth: 1)
                    .frame(width: innerDia, height: innerDia)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.3), value: progress)
    }
}

/// Half-moon shape that reveals from the belt upward in proportion to
/// `progress`. At 0 it's empty, at 1 it's the full upper hemisphere.
private struct PokeballTopFill: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return Path() }

        // Full upper hemisphere mask = top half of the circle.
        let topHalf = CGRect(x: rect.minX,
                             y: rect.minY,
                             width: rect.width,
                             height: rect.height / 2)
        var circlePath = Path(ellipseIn: rect)
        // Grow a revealing rectangle from the belt (middle) upward.
        let revealHeight = topHalf.height * clamped
        let reveal = CGRect(x: topHalf.minX,
                            y: topHalf.maxY - revealHeight,
                            width: topHalf.width,
                            height: revealHeight)
        circlePath = circlePath.intersection(Path(reveal))
        return circlePath
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            PokeballIcon(progress: 0.0, size: 60)
            PokeballIcon(progress: 0.3, size: 60)
            PokeballIcon(progress: 0.7, size: 60)
            PokeballIcon(progress: 1.0, size: 60)
        }
        PokeballIcon(progress: 1.0, size: 120)
    }
    .padding()
    .background(PokemonColor.lilacBG)
}
