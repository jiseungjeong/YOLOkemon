import SwiftUI
import UIKit

/// Export the in-memory session log to CSV / JSON, and list previously
/// exported files so they can be pulled off the device
/// via the Files app (UIFileSharingEnabled is on in Info.plist).
///
/// Layout:
///   * AppHeader — matches Live / Dashboard
///   * Export & Analysis — CSV / JSON buttons
///   * Current session — 2x2 grid (frames / success rate / model / saved sessions)
///   * Latest export path — full URL, monospaced
///   * Export history — newest first, tap-to-share via UIActivityViewController
struct ExportView: View {
    @EnvironmentObject var log: SessionLogStore

    // Persisted across tab switches so the most recent export result
    // stays visible even if the user flips between Dashboard and
    // Export. Cleared when a new export runs.
    @State private var lastExportURL: URL?
    @State private var lastExportError: String?

    // Inventory of previous exports. Refreshed on appear and after
    // each successful export; tapping an item shares it.
    @State private var history: [URL] = []
    @State private var shareURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(title: "On-device Object Detection",
                      subtitle: headerSubtitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    exportButtonsCard
                    currentSessionCard
                    if let url = lastExportURL {
                        latestExportCard(url: url)
                    }
                    if let err = lastExportError {
                        errorCard(err)
                    }
                    historyCard
                }
                .padding()
            }
        }
        .onAppear { refreshHistory() }
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
    }

    // MARK: - Header

    private var headerSubtitle: String {
        let total = log.records.count
        if total == 0 {
            return "No frames to export yet."
        }
        return "\(total) frame\(total == 1 ? "" : "s") ready · \(history.count) saved export\(history.count == 1 ? "" : "s")"
    }

    // MARK: - Cards

    @ViewBuilder
    private var exportButtonsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export & Analysis")
                .font(.headline)

            HStack(spacing: 12) {
                Button {
                    runExport(.csv)
                } label: {
                    Label("Export CSV", systemImage: "tablecells")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(log.records.isEmpty)

                Button {
                    runExport(.json)
                } label: {
                    Label("Export JSON", systemImage: "curlybraces")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(log.records.isEmpty)
            }

            if log.records.isEmpty {
                Text("Run at least one inference in Live first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var currentSessionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current session")
                .font(.headline)

            // 2x2 grid matches Dashboard + Live Summary style.
            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .topLeading),
                GridItem(.flexible(), alignment: .topLeading),
            ], alignment: .leading, spacing: 16) {
                metricCell(label: "Frames logged",
                           value: "\(log.records.count)")
                metricCell(label: "Target detection success rate",
                           value: overallSuccessRateString)
                metricCell(label: "Selected model",
                           value: log.currentPrecision.display)
                metricCell(label: "Saved sessions",
                           value: "\(history.count)")
            }

            // Per-precision mini-breakdown so the user knows what they
            // actually have in the export. Quiet (footnote) so it
            // doesn't compete with the 2x2 grid.
            if !log.summary.isEmpty {
                Divider().padding(.vertical, 4)
                ForEach(Precision.allCases) { p in
                    if let s = log.summary[p] {
                        HStack {
                            Text(p.display)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(s.frames) frames · \(String(format: "%.1f ms", s.avgLatency))")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func latestExportCard(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Latest export path")
                .font(.headline)
            Text(url.path)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                shareURL = url
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Error", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Export history")
                    .font(.headline)
                Spacer()
                Button {
                    refreshHistory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .font(.footnote)
            }

            if history.isEmpty {
                Text("No exports yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(spacing: 10) {
                    ForEach(history, id: \.self) { url in
                        Button {
                            shareURL = url
                        } label: {
                            historyRow(url)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func historyRow(_ url: URL) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: url))
                .foregroundStyle(.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.body.monospacedDigit())
                HStack(spacing: 10) {
                    Label("Format",
                          systemImage: "doc.text")
                        .labelStyle(.titleOnly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(url.pathExtension.uppercased())
                        .font(.caption.monospacedDigit())
                    if let created = creationTimeString(url) {
                        Label("Created",
                              systemImage: "clock")
                            .labelStyle(.titleOnly)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(created)
                            .font(.caption.monospacedDigit())
                    }
                    if let size = fileSizeString(url) {
                        Text("· \(size)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    // MARK: - Cells

    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    // MARK: - Actions

    private enum ExportKind { case csv, json }

    private func runExport(_ kind: ExportKind) {
        lastExportError = nil
        do {
            let url: URL
            switch kind {
            case .csv:  url = try LogExporter.exportCSV(log.records)
            case .json: url = try LogExporter.exportJSON(log.records)
            }
            lastExportURL = url
            refreshHistory()
        } catch {
            lastExportURL = nil
            lastExportError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func refreshHistory() {
        history = LogExporter.listExports()
    }

    // MARK: - Display helpers

    /// Union success rate across all recorded precisions. If none had a
    /// target set, returns "—" so the cell isn't misleading.
    private var overallSuccessRateString: String {
        let all = log.summary.values
        let targeted = all.reduce(0) { $0 + $1.targetEvaluated }
        guard targeted > 0 else { return "—" }
        let hits = all.reduce(0) { $0 + $1.targetHits }
        return String(format: "%.0f%%", Double(hits) / Double(targeted) * 100)
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension {
        case "csv":  return "tablecells"
        case "json": return "curlybraces"
        default:     return "doc"
        }
    }

    private func fileSizeString(_ url: URL) -> String? {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey])
                .fileSize else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func creationTimeString(_ url: URL) -> String? {
        guard let created = try? url.resourceValues(forKeys: [.creationDateKey])
                .creationDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: created)
    }
}

// MARK: - URL + Identifiable (so `sheet(item:)` can use it directly)

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - UIKit bridge for the system share sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items,
                                 applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) { }
}

#Preview {
    ExportView()
        .environmentObject(SessionLogStore())
}
