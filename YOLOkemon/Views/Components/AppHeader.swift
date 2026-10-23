import SwiftUI

/// Shared top bar for all three tabs (Live / Dashboard / Export),
/// modeled after the reference demo screenshots. A constant title
/// (`On-device Object Detection`) and a tab-specific subtitle that
/// reflects the current app state:
///
///   * Live: `FP32 active. 4 objects detected.`,
///     `Looking for cup with INT8...`, `book found with FP16.`,
///     `book not found in current frame.`, `Paused.`, etc.
///   * Dashboard/Export: a short description of the tab.
///
/// Kept as a plain VStack rather than using `.navigationTitle` so we
/// have full control over the subtitle styling and over how tall the
/// header takes up — the reference demo has a distinctive teal band
/// that isn't what NavigationStack would give us by default.
struct AppHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            // `minHeight` on the subtitle line keeps the overall
            // header height stable even when the subtitle is momentarily
            // empty (e.g. between a model switch and the first new
            // metric tick).
            Text(subtitle.isEmpty ? " " : subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

#Preview {
    VStack(spacing: 0) {
        AppHeader(title: "On-device Object Detection",
                  subtitle: "FP32 active. 4 objects detected.")
        Spacer()
    }
}
