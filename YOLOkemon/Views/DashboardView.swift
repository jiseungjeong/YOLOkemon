import Combine
import SwiftUI
import UIKit

/// Per-precision benchmark view. Reads from a shared `SessionLogStore` that
/// LiveView populates frame by frame; this tab is purely observational.
///
/// Sections:
///   * AppHeader — matches Live/Export for a consistent shell
///   * Per-model summary — 2-col grid cards, one per precision
///   * Runtime — delegate + input size (CPU / XNNPACK / 640×640)
///   * System — thermal / battery / memory / Last updated
struct DashboardView: View {
    @EnvironmentObject var log: SessionLogStore

    // Drive a tick so the System section re-reads thermal / memory /
    // battery regularly even when no inference is happening (e.g. the
    // user is sitting on this tab and waiting). 2 s matches the
    // LiveView status-bar cadence.
    @State private var systemTick: Date = Date()
    private let systemTimer = Timer.publish(every: 2, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(title: "On-device Object Detection",
                      subtitle: headerSubtitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sessionTotalsSection
                    perPrecisionSection
                    temporalStabilitySection
                    runtimeSection
                    systemSection
                }
                .padding()
            }
        }
        .onReceive(systemTimer) { systemTick = $0 }
    }

    // MARK: - Header

    private var headerSubtitle: String {
        let total = log.records.count
        if total == 0 {
            return "No frames logged yet."
        }
        return "\(total) frame\(total == 1 ? "" : "s") logged · \(log.summary.count) precision\(log.summary.count == 1 ? "" : "s") exercised"
    }

    // MARK: - Sections

    @ViewBuilder
    private var sessionTotalsSection: some View {
        sectionCard(title: "Session totals") {
            HStack {
                Text("Total frames logged")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(log.records.count)")
                    .font(.body.monospacedDigit())
            }
            HStack {
                Text("Precisions exercised")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(log.summary.count) of \(Precision.allCases.count)")
                    .font(.body.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private var perPrecisionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Per-model summary")
                .font(.headline)

            if log.summary.isEmpty {
                Text("No inference data yet. Open Live to warm up a model.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(12)
            } else {
                // Iterate in the canonical Precision order (fp32, fp16,
                // int8) so the cards are stable across toggles rather
                // than sorted by whichever one we hit first.
                ForEach(Precision.allCases) { p in
                    if let s = log.summary[p] {
                        precisionCard(s)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func precisionCard(_ s: PrecisionSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(s.precision.display)
                .font(.title3.bold())

            // 2-col grid matches the reference demo — each cell is a
            // label + value pair, same as Live Summary's 2x2.
            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .topLeading),
                GridItem(.flexible(), alignment: .topLeading),
            ], alignment: .leading, spacing: 16) {
                metricCell(label: "Frames",
                           value: "\(s.frames)")
                metricCell(label: "Avg latency",
                           value: String(format: "%.2f ms", s.avgLatency))
                metricCell(label: "Avg FPS",
                           value: String(format: "%.2f", s.avgFps))
                metricCell(label: "Target detection success rate",
                           value: s.targetEvaluated > 0
                               ? String(format: "%.0f%%", s.successRate * 100)
                               : "—")
                metricCell(label: "Mean conf",
                           value: String(format: "%.0f%%", s.meanConf * 100))
                metricCell(label: "Model size",
                           value: String(format: "%.2f MB", s.modelSizeMb))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }

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

    @ViewBuilder
    private var temporalStabilitySection: some View {
        // Only show once some capture data exists — an empty table
        // before the first catch is just noise.
        let hasAnyCaptureData = log.summary.values
            .contains(where: { $0.iouFrames > 0 || $0.captureCount > 0 })
        if hasAnyCaptureData {
            sectionCard(title: "Temporal stability (YOLOkémon)") {
                HStack(spacing: 16) {
                    Text("").frame(maxWidth: .infinity)
                    Text("Mean IoU")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Text("Avg capture")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Text("Failure %")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Precision.allCases) { p in
                    if let s = log.summary[p],
                       s.iouFrames > 0 || s.captureCount > 0 {
                        HStack(spacing: 16) {
                            Text(p.display)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(s.iouFrames > 0
                                 ? String(format: "%.2f", s.meanIoU)
                                 : "—")
                                .font(.body.monospacedDigit())
                                .frame(maxWidth: .infinity)
                            Text(s.captureCount > 0
                                 ? String(format: "%.1fs", s.avgCaptureTime)
                                 : "—")
                                .font(.body.monospacedDigit())
                                .frame(maxWidth: .infinity)
                            Text(s.captureCount > 0
                                 ? String(format: "%.0f%%", s.captureFailureRate * 100)
                                 : "—")
                                .font(.body.monospacedDigit())
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var runtimeSection: some View {
        sectionCard(title: "Runtime") {
            HStack {
                Text("Delegate")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("CPU (XNNPACK)")
            }
            HStack {
                Text("Input size")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("640 × 640")
                    .font(.body.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private var systemSection: some View {
        // Reading `systemTick` inline forces SwiftUI to re-evaluate this
        // section when the 2-second timer fires, so the thermal /
        // memory / battery numbers refresh even if `log.records` isn't
        // ticking (user is sitting on the Dashboard tab).
        let _ = systemTick
        sectionCard(title: "System") {
            HStack {
                Text("Thermal state")
                    .foregroundStyle(.secondary)
                Spacer()
                // Color coding: iOS hides absolute
                // temperature, so we use the enum bucket's color to
                // signal rising thermal pressure at a glance.
                let thermal = ProcessInfo.processInfo.thermalState
                Text(thermal.csvLabel)
                    .foregroundStyle(Self.thermalColor(thermal))
            }
            HStack {
                Text("Battery")
                    .foregroundStyle(.secondary)
                Spacer()
                let lvl = UIDevice.current.batteryLevel
                // batteryLevel is -1 when monitoring isn't enabled,
                // shouldn't happen because YOLOkemonApp turns it on at init.
                if lvl < 0 {
                    Text("n/a")
                } else {
                    Text("\(Int((lvl * 100).rounded()))% · \(UIDevice.current.batteryState.csvLabel)")
                        .font(.body.monospacedDigit())
                }
            }
            HStack {
                Text("Resident memory")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f MB", MetricsCollector.residentMemoryMb()))
                    .font(.body.monospacedDigit())
            }
            // Battery drain proxy: iOS won't tell us the
            // current draw, so we surface the observed delta since the
            // session began. Reads "n/a" when monitoring is off or a
            // charger was plugged in mid-session (level rose above
            // baseline). Time suffix gives the number a unit.
            HStack {
                Text("Battery drop")
                    .foregroundStyle(.secondary)
                Spacer()
                if let drop = log.batteryDropSinceStart {
                    Text(String(format: "−%.1f %% over %@",
                                drop, Self.formatElapsed(log.elapsedSeconds)))
                        .font(.body.monospacedDigit())
                } else {
                    Text("n/a")
                        .foregroundStyle(.secondary)
                }
            }
            // Live "freshness" indicator. Thermal/battery/memory rarely
            // change between ticks, so without this it's impossible to
            // tell at a glance whether the 2-second system timer is
            // actually firing. The clock here jumps every 2s as long as
            // `systemTick` keeps updating — the same signal drives the
            // three rows above, so if this is moving they're live too.
            // Kept in the shipped build as a "Dashboard is live" cue
            // rather than removed after verification.
            HStack {
                Text("Last updated")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Self.clockFormatter.string(from: systemTick))
                    .font(.body.monospacedDigit())
            }
        }
    }

    // MARK: - Card scaffold helper

    @ViewBuilder
    private func sectionCard<Content: View>(title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(spacing: 8) {
                content()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Static helpers

    /// Locale-independent `HH:mm:ss` so the clock reads the same on any
    /// test device and the "did it change?" check isn't thrown off by a
    /// 12-hour AM/PM label flipping.
    /// Render a wall-clock duration as `Xm YYs` so the battery-drop
    /// row reads `−1.2 % over 4m 12s` instead of a raw second count.
    /// Sub-minute sessions stay as `Xs` for compactness.
    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        return "\(m)m \(s)s"
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Enum → SwiftUI color mapping for the thermal row. iOS hides the
    /// absolute temperature; the enum bucket's color is the most
    /// specific signal we can give the user.
    private static func thermalColor(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal:   return .secondary
        case .fair:      return .yellow
        case .serious:   return .orange
        case .critical:  return .red
        @unknown default: return .secondary
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(SessionLogStore())
}
