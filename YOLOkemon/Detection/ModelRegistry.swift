import Foundation

/// Precision formats the app supports. Stored raw strings are reused verbatim
/// in CSV/JSON logs, so keep them lowercase and stable.
///
/// Members are marked `nonisolated` explicitly so they don't get pulled back
/// into MainActor by a stale project-wide default — InferenceCore calls
/// these from a background serial DispatchQueue and needs synchronous access.
enum Precision: String, CaseIterable, Identifiable, Sendable {
    case fp32, fp16, int8
    nonisolated var id: String { rawValue }
    nonisolated var display: String { rawValue.uppercased() }
}

/// Static metadata for one `.tflite` asset. The `inputDType`/`inputScale`
/// fields were dropped after a sanity check confirmed that all three
/// precisions use float32 I/O.
struct ModelSpec: Sendable {
    let precision: Precision
    let filename:  String   // base name without extension
    let inputSize: Int      // 640 (square)
}

enum ModelRegistry {

    /// Bundle resource name → ModelSpec. `filename` has no extension because
    /// `Bundle.main.url(forResource:withExtension:)` takes them separately.
    nonisolated static let all: [Precision: ModelSpec] = [
        .fp32: .init(precision: .fp32, filename: "yolo26n_fp32", inputSize: 640),
        .fp16: .init(precision: .fp16, filename: "yolo26n_fp16", inputSize: 640),
        .int8: .init(precision: .int8, filename: "yolo26n_int8", inputSize: 640),
    ]

    nonisolated static func spec(for p: Precision) -> ModelSpec {
        // Force-unwrap is safe — `all` covers every enum case by construction.
        all[p]!
    }

    nonisolated static func url(for p: Precision) -> URL? {
        let s = spec(for: p)
        return Bundle.main.url(forResource: s.filename, withExtension: "tflite")
    }

    /// Size on disk, used for the dashboard "Model size" column.
    nonisolated static func fileSize(_ p: Precision) -> Int64 {
        guard let url = url(for: p),
              let v   = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let n   = v.fileSize else { return 0 }
        return Int64(n)
    }

    nonisolated static func fileSizeMB(_ p: Precision) -> Double {
        Double(fileSize(p)) / (1024 * 1024)
    }
}

/// Loads the 80 COCO class names from `coco_labels.txt` in the app bundle.
enum LabelLoader {
    nonisolated private static let cache: [String] = {
        guard let url = Bundle.main.url(forResource: "coco_labels",
                                        withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("coco_labels.txt missing from bundle")
            return []
        }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }()

    nonisolated static func coco80() -> [String] { cache }
}
