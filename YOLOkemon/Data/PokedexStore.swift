import Combine
import Foundation

/// Persistent catalog of caught YOLOkémon. MainActor so SwiftUI views
/// can bind to `entries` directly; JSON I/O runs on the current task
/// since the file is a few KB at most (one entry per COCO class, ≤80).
///
/// File layout:
///   * `Documents/pokedex.json` — `[String: PokedexEntry]` encoded
///   * `Documents/pokedex_thumbs/<className>.jpg` — optional thumbnails
///     (not written yet)
///
/// Write policy: every `record(...)` triggers an immediate save. The
/// dictionary is tiny and writes are rare (at most once per capture),
/// so debouncing would add complexity without measurable benefit.
@MainActor
final class PokedexStore: ObservableObject {

    @Published private(set) var entries: [String: PokedexEntry] = [:]

    // MARK: - Paths

    private static let fileName = "pokedex.json"

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName)
    }

    // MARK: - Init

    init(autoload: Bool = true) {
        if autoload { load() }
    }

    // MARK: - Queries

    /// Progress shown at the top of the Pokédex tab ("12 / 80").
    var caughtCount: Int { entries.count }

    /// Convenience for the "Best catch" / "Hardest catch" footer.
    var sortedByCaptureTime: [PokedexEntry] {
        entries.values.sorted { $0.captureTimeSeconds < $1.captureTimeSeconds }
    }

    var sortedByAttempts: [PokedexEntry] {
        entries.values.sorted { $0.attemptCount > $1.attemptCount }
    }

    // MARK: - Mutations

    /// Add or upgrade an entry.
    ///
    /// Two orthogonal things happen here — don't collapse them:
    ///   * `caughtWith` is a **union**: every precision that's ever
    ///     caught this class accumulates, so a user who grinds FP32
    ///     then FP16 then INT8 ends up with all three badges in the
    ///     Pokédex cell.
    ///   * The "best catch" scalar fields (`captureTimeSeconds`,
    ///     `usedModel`, `attemptCount`, `caughtAt`, `thumbnailFilename`)
    ///     only update when the new attempt is **faster** than the
    ///     existing record, so the summary cards keep pointing at the
    ///     user's personal best.
    ///
    /// A class never seen before installs `entry` as-is, which seeds
    /// `caughtWith = [entry.usedModel]` via `PokedexEntry`'s default.
    func record(_ entry: PokedexEntry) {
        guard let existing = entries[entry.className] else {
            entries[entry.className] = entry
            save()
            return
        }

        // Union the precision set and only touch the best-catch scalars
        // if we actually beat the previous time.
        var merged = existing
        merged.caughtWith.formUnion(entry.caughtWith)

        if entry.captureTimeSeconds < existing.captureTimeSeconds {
            merged = PokedexEntry(
                className: entry.className,
                caughtAt: entry.caughtAt,
                usedModel: entry.usedModel,
                captureTimeSeconds: entry.captureTimeSeconds,
                attemptCount: entry.attemptCount,
                thumbnailFilename: entry.thumbnailFilename,
                caughtWith: merged.caughtWith)
        }

        entries[entry.className] = merged
        save()
    }

    /// Wipe all entries and the persisted file. Used by the
    /// "[Clear Pokédex]" button on the dex tab.
    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    // MARK: - Persistence

    func load() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries = [:]
            return
        }
        do {
            let data = try Data(contentsOf: url)
            entries = try JSONDecoder().decode([String: PokedexEntry].self,
                                                from: data)
        } catch {
            print("[PokedexStore] load failed: \(error)")
            entries = [:]
        }
    }

    private func save() {
        let url = Self.fileURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[PokedexStore] save failed: \(error)")
        }
    }
}
