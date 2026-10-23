import SwiftUI

/// "Your Pokédex" — a gallery of every COCO 80 class, with caught
/// entries coloured and uncaught ones shown as silhouettes.
///
/// Reads from `PokedexStore`, which owns persistent state across app
/// relaunches. The Clear button is gated behind a confirmation alert
/// because dropping the dex is irreversible.
struct PokedexView: View {
    @EnvironmentObject private var pokedex: PokedexStore

    @State private var showClearConfirm = false
    @State private var allClasses: [String] = LabelLoader.coco80()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    grid
                    clearButton
                }
                .padding()
            }
        }
        .background(PokemonColor.lilacBG.ignoresSafeArea(edges: .bottom))
        .alert("Clear Pokédex?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) { pokedex.clear() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes every caught YOLOkémon. This can't be undone.")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Pokédex")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("\(pokedex.caughtCount) / \(allClasses.count) caught")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PokemonColor.pokeballRed)
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        let cols = [GridItem(.adaptive(minimum: 96), spacing: 12)]
        LazyVGrid(columns: cols, spacing: 12) {
            ForEach(Array(allClasses.enumerated()), id: \.offset) { idx, cls in
                cell(index: idx + 1, className: cls)
            }
        }
    }

    @ViewBuilder
    private func cell(index: Int, className: String) -> some View {
        let entry = pokedex.entries[className]
        let caught = entry != nil
        VStack(spacing: 6) {
            Text(String(format: "%03d", index))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(caught
                                 ? PokemonColor.pokedexBlue
                                 : PokemonColor.slateDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
            Image(systemName: symbol(for: className))
                .font(.system(size: 32))
                .foregroundStyle(caught
                                 ? PokemonColor.pokeballRed
                                 : PokemonColor.slateDim.opacity(0.5))
                .frame(height: 40)
            Text(className)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(caught
                                 ? Color.primary
                                 : PokemonColor.slateDim)

            // Precision badges — one dot per precision, tinted only if
            // the user has caught this class with that model. Always
            // renders three slots so every cell has the same footprint
            // (prevents the grid from jittering as badges light up).
            precisionBadges(caughtWith: entry?.caughtWith ?? [])
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(caught
                        ? PokemonColor.softNeonPurple
                        : Color.clear,
                        lineWidth: 2)
        )
        .overlay(alignment: .topTrailing) {
            if caught {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(PokemonColor.pokedexYellow)
                    .padding(6)
            }
        }
    }

    // MARK: - Precision badges

    /// Renders FP32 / FP16 / INT8 capsules side by side. Each capsule
    /// is either coloured (the user has caught this class with that
    /// precision at least once) or a neutral outline (not yet). The
    /// slot stays reserved either way so the grid geometry is stable
    /// as captures trickle in during a session.
    @ViewBuilder
    private func precisionBadges(caughtWith: Set<String>) -> some View {
        HStack(spacing: 3) {
            badge("FP32", tint: PokemonColor.pokedexBlue,
                  lit: caughtWith.contains("FP32"))
            badge("FP16", tint: PokemonColor.pokedexYellow,
                  lit: caughtWith.contains("FP16"))
            badge("INT8", tint: PokemonColor.pokeballRed,
                  lit: caughtWith.contains("INT8"))
        }
    }

    @ViewBuilder
    private func badge(_ label: String, tint: Color, lit: Bool) -> some View {
        Text(label)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(lit ? .white : PokemonColor.slateDim)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(lit ? tint : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(lit ? Color.clear
                                 : PokemonColor.slateDim.opacity(0.4),
                            lineWidth: 0.8)
            )
    }

    // MARK: - Clear

    // NOTE: Best catch / Hardest catch summary card was removed
    // (2026-04-25) — the precision badges in each grid cell now
    // carry the same progress signal, and the card duplicated the
    // `usedModel` value already visible there. `PokedexStore`
    // keeps `sortedByCaptureTime` / `sortedByAttempts` helpers for
    // possible future reuse (JSON export, etc.).

    @ViewBuilder
    private var clearButton: some View {
        Button(role: .destructive) {
            showClearConfirm = true
        } label: {
            Label("Clear Pokédex", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(PokemonColor.pokeballRed)
        .disabled(pokedex.caughtCount == 0)
    }

    // MARK: - SF Symbol mapping

    /// Maps COCO class names to an SF Symbol that vaguely represents
    /// them. Every class falls back to `questionmark.circle` so the
    /// grid never renders an empty box — the fallback is visible
    /// evidence that we need to add a mapping when a new class starts
    /// getting caught in demos.
    private func symbol(for className: String) -> String {
        switch className {
        case "person":        return "figure.stand"
        case "bicycle":       return "bicycle"
        case "car":           return "car.fill"
        case "motorcycle":    return "motorcycle.fill"
        case "airplane":      return "airplane"
        case "bus":           return "bus.fill"
        case "train":         return "tram.fill"
        case "truck":         return "truck.box.fill"
        case "boat":          return "sailboat.fill"
        case "traffic light": return "light.beacon.max.fill"
        case "fire hydrant":  return "flame.fill"
        case "stop sign":     return "octagon.fill"
        case "parking meter": return "parkingsign"
        case "bench":         return "figure.seated.seatbelt"
        case "bird":          return "bird.fill"
        case "cat":           return "cat.fill"
        case "dog":           return "dog.fill"
        case "horse":         return "hare.fill"
        case "sheep":         return "pawprint.fill"
        case "cow":           return "pawprint.fill"
        case "elephant":      return "tortoise.fill"
        case "bear":          return "pawprint.fill"
        case "zebra":         return "pawprint.fill"
        case "giraffe":       return "pawprint.fill"
        case "backpack":      return "backpack.fill"
        case "umbrella":      return "umbrella.fill"
        case "handbag":       return "bag.fill"
        case "tie":           return "tshirt.fill"
        case "suitcase":      return "suitcase.fill"
        case "frisbee":       return "circle.fill"
        case "skis":          return "figure.skiing.downhill"
        case "snowboard":     return "figure.snowboarding"
        case "sports ball":   return "soccerball"
        case "kite":          return "wind"
        case "baseball bat":  return "baseball.fill"
        case "baseball glove":return "baseball.fill"
        case "skateboard":    return "figure.skating"
        case "surfboard":     return "figure.surfing"
        case "tennis racket": return "tennisball.fill"
        case "bottle":        return "waterbottle.fill"
        case "wine glass":    return "wineglass.fill"
        case "cup":           return "cup.and.saucer.fill"
        case "fork":          return "fork.knife"
        case "knife":         return "fork.knife"
        case "spoon":         return "fork.knife"
        case "bowl":          return "bowl.fill"
        case "banana":        return "leaf.fill"
        case "apple":         return "apple.logo"
        case "sandwich":      return "takeoutbag.and.cup.and.straw.fill"
        case "orange":        return "circle.fill"
        case "broccoli":      return "leaf.fill"
        case "carrot":        return "leaf.fill"
        case "hot dog":       return "takeoutbag.and.cup.and.straw.fill"
        case "pizza":         return "circle.grid.cross.fill"
        case "donut":         return "circle.dotted"
        case "cake":          return "birthday.cake.fill"
        case "chair":         return "chair.fill"
        case "sofa", "couch": return "sofa.fill"
        case "potted plant":  return "leaf.fill"
        case "bed":           return "bed.double.fill"
        case "dining table":  return "table.furniture.fill"
        case "toilet":        return "toilet.fill"
        case "tv":            return "tv.fill"
        case "laptop":        return "laptopcomputer"
        case "mouse":         return "computermouse.fill"
        case "remote":        return "av.remote.fill"
        case "keyboard":      return "keyboard.fill"
        case "cell phone":    return "iphone"
        case "microwave":     return "microwave.fill"
        case "oven":          return "oven.fill"
        case "toaster":       return "oven.fill"
        case "sink":          return "sink.fill"
        case "refrigerator":  return "refrigerator.fill"
        case "book":          return "book.fill"
        case "clock":         return "clock.fill"
        case "vase":          return "drop.fill"
        case "scissors":      return "scissors"
        case "teddy bear":    return "teddybear.fill"
        case "hair drier":    return "wind"
        case "toothbrush":    return "mouth.fill"
        default:              return "questionmark.circle"
        }
    }
}

#Preview {
    PokedexView()
        .environmentObject({
            let s = PokedexStore(autoload: false)
            // cup caught across all three precisions — shows a fully
            // lit badge row.
            s.record(PokedexEntry(className: "cup", caughtAt: 0,
                                  usedModel: "FP32",
                                  captureTimeSeconds: 8.2,
                                  attemptCount: 1,
                                  thumbnailFilename: nil,
                                  caughtWith: ["FP32", "FP16", "INT8"]))
            // laptop only caught with INT8 — single red badge lit.
            s.record(PokedexEntry(className: "laptop", caughtAt: 0,
                                  usedModel: "INT8",
                                  captureTimeSeconds: 12.4,
                                  attemptCount: 3,
                                  thumbnailFilename: nil,
                                  caughtWith: ["INT8"]))
            return s
        }())
}
