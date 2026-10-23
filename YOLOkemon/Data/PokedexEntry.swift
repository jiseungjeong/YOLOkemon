import Foundation

/// One caught YOLOkémon. Persisted in `Documents/pokedex.json` so the
/// dex survives app relaunches.
///
/// `className` is the COCO label (e.g. `"cup"`) and also the dictionary
/// key in `PokedexStore.entries`; exposing it via `Identifiable.id`
/// keeps `ForEach`/`List` happy without a separate UUID field.
///
/// ## Multi-precision capture
///
/// Catching a class with FP32 and then with INT8 used to collapse into
/// one entry — the slower INT8 capture was simply discarded. That hid
/// the YOLOkémon narrative ("INT8 is harder to capture") at the dex
/// level, so `caughtWith` was added: a set of every precision that has
/// ever successfully captured this class. `usedModel`,
/// `captureTimeSeconds`, and `attemptCount` continue to describe the
/// **best** (fastest) capture so the "Best catch" summary keeps
/// working; the set gives the UI enough information to render one
/// badge per precision achieved.
struct PokedexEntry: Codable, Identifiable, Sendable, Hashable {
    let className: String
    let caughtAt: Int64               // epoch ms
    let usedModel: String             // "FP32" | "FP16" | "INT8" — best catch
    let captureTimeSeconds: Double
    let attemptCount: Int
    let thumbnailFilename: String?    // always nil for now

    /// Every precision label this class has been caught with at least
    /// once. Always includes `usedModel`. Decoded as-absent on older
    /// JSON files; `decode(from:)` below synthesizes `[usedModel]` in
    /// that case so pre-2026-04-24 dex files keep loading.
    var caughtWith: Set<String>

    var id: String { className }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case className, caughtAt, usedModel, captureTimeSeconds
        case attemptCount, thumbnailFilename, caughtWith
    }

    init(className: String,
         caughtAt: Int64,
         usedModel: String,
         captureTimeSeconds: Double,
         attemptCount: Int,
         thumbnailFilename: String?,
         caughtWith: Set<String>? = nil) {
        self.className = className
        self.caughtAt = caughtAt
        self.usedModel = usedModel
        self.captureTimeSeconds = captureTimeSeconds
        self.attemptCount = attemptCount
        self.thumbnailFilename = thumbnailFilename
        // Default: at least the best catch's model is always in the set.
        self.caughtWith = caughtWith ?? [usedModel]
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.className          = try c.decode(String.self,  forKey: .className)
        self.caughtAt           = try c.decode(Int64.self,   forKey: .caughtAt)
        self.usedModel          = try c.decode(String.self,  forKey: .usedModel)
        self.captureTimeSeconds = try c.decode(Double.self,  forKey: .captureTimeSeconds)
        self.attemptCount       = try c.decode(Int.self,     forKey: .attemptCount)
        self.thumbnailFilename  = try c.decodeIfPresent(String.self,
                                                        forKey: .thumbnailFilename)
        // Backwards compatibility: older JSON files (pre-2026-04-24) have
        // no `caughtWith` field. Seed it with the best-catch model so
        // every entry has at least one badge.
        let legacySet = try c.decodeIfPresent(Set<String>.self,
                                              forKey: .caughtWith)
        self.caughtWith = legacySet ?? [self.usedModel]
    }
}
