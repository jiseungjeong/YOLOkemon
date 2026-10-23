import Foundation

/// CSV + JSON writers for a session's `LogRecord` array.
///
/// Both formats land in `Documents/yolokemon_logs/session_YYYYMMDD_HHMMSS.{csv,json}`,
/// so they show up under the YOLOkémon entry of the iOS Files app (the
/// app's Info.plist has `UIFileSharingEnabled = YES`, confirmed in
/// pbxproj). The CSV is Excel-friendly (quote-escaped, LF line endings)
/// and the JSON is pretty-printed for readability.
enum LogExporter {

    /// Encode every `LogRecord` as a single-row-per-frame CSV. The
    /// per-frame `predictions` list is serialized into one column as a
    /// JSON-encoded string — this keeps the CSV rectangular while still
    /// letting a downstream script reconstruct the full detection set.
    static func exportCSV(_ records: [LogRecord]) throws -> URL {
        let header = [
            "timestamp_ms", "frame_idx", "precision", "model_size_bytes",
            "delegate", "input_w", "input_h",
            "preprocess_ms", "inference_ms", "postprocess_ms",
            "total_ms", "fps_rolling",
            "target_class", "target_hit", "num_detections",
            "predictions_json",
            "battery_level", "battery_state", "thermal", "memory_mb",
            "capture_progress", "capture_iou",
        ].joined(separator: ",") + "\n"

        // Reuse one encoder for all rows — it's a tiny object but we
        // allocate enough strings per frame that this is measurable on
        // a 6000-row session.
        let predEncoder = JSONEncoder()

        var body = ""
        body.reserveCapacity(records.count * 256)
        for r in records {
            let predJSON: String = {
                guard let data = try? predEncoder.encode(r.predictions),
                      let s = String(data: data, encoding: .utf8) else {
                    return "[]"
                }
                return s
            }()
            // Standard CSV escape: any embedded quote is doubled, and
            // the whole field is wrapped in quotes because the JSON
            // array contains commas.
            let predEscaped = "\"\(predJSON.replacingOccurrences(of: "\"", with: "\"\""))\""
            let targetCell = r.targetClass.map { csvEscape($0) } ?? ""
            let row = [
                "\(r.timestampMs)", "\(r.frameIndex)",
                r.precision, "\(r.modelSizeBytes)",
                r.delegate, "\(r.inputW)", "\(r.inputH)",
                fmt(r.preprocessMs), fmt(r.inferenceMs), fmt(r.postprocessMs),
                fmt(r.totalMs), fmt(r.fpsRolling),
                targetCell, "\(r.targetHit)", "\(r.numDetections)",
                predEscaped,
                fmtFloat(r.batteryLevel), r.batteryState, r.thermalState,
                fmt(r.memoryResidentMb),
                r.captureProgress.map(fmt) ?? "",
                r.meanIoU30fps.map(fmt) ?? "",
            ].joined(separator: ",") + "\n"
            body.append(row)
        }

        let url = try destinationURL(ext: "csv")
        try (header + body).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Encode every `LogRecord` as a pretty-printed JSON array.
    static func exportJSON(_ records: [LogRecord]) throws -> URL {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(records)
        let url = try destinationURL(ext: "json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// List previously exported files (newest first). Used by the
    /// Export tab's "Export history" section.
    static func listExports() -> [URL] {
        let dir = logDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { ["csv", "json"].contains($0.pathExtension) }
            .sorted { (a, b) in
                let ad = (try? a.resourceValues(forKeys: [.creationDateKey])
                    .creationDate) ?? Date.distantPast
                let bd = (try? b.resourceValues(forKeys: [.creationDateKey])
                    .creationDate) ?? Date.distantPast
                return ad > bd
            }
    }

    // MARK: - Helpers

    private static func logDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("yolokemon_logs", isDirectory: true)
        // Create-on-demand — cheap and idempotent so every writer / lister
        // can call it without coordinating.
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    private static func destinationURL(ext: String) throws -> URL {
        let stamp = DateFormatter.compactTimestamp.string(from: Date())
        return logDirectory().appendingPathComponent("session_\(stamp).\(ext)")
    }

    /// Compact double → string. `%.3f` is more than enough for ms /
    /// MB resolution and keeps files small.
    private static func fmt(_ d: Double) -> String {
        String(format: "%.3f", d)
    }

    /// Battery level is a Float — keep 2 decimals (iOS increments by
    /// 0.01 anyway).
    private static func fmtFloat(_ f: Float) -> String {
        String(format: "%.2f", f)
    }

    /// Quote-escape a CSV cell if it contains any of `,`, `"`, or a
    /// newline. Simple targets (like COCO labels, which are ASCII
    /// without commas) round-trip unchanged.
    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }
}
