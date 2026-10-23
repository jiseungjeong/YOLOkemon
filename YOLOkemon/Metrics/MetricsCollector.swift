import Darwin
import Foundation
import UIKit

/// Namespaced helpers for the on-device system metrics we log per frame.
///
/// These are the three axes tracked beyond the
/// core latency/FPS/size numbers:
///   * Resident memory usage — via `mach_task_basic_info`.
///   * Battery level + charging state — `UIDevice.current`.
///   * Thermal state — `ProcessInfo.processInfo.thermalState`.
///
/// iOS deliberately hides the raw mA/μA "battery current" value Android
/// exposes via `BatteryManager.BATTERY_PROPERTY_CURRENT_NOW`. We surface
/// the 0.01-step `batteryLevel` and log it per frame instead; an approximate
/// drain rate can be derived from the session start/end delta.
enum MetricsCollector {

    /// Resident set size in MB. Returns 0 on the rare failure path so
    /// callers can still emit a row.
    nonisolated static func residentMemoryMb() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self,
                                      capacity: Int(count)) { ptr in
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          ptr,
                          &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }
}

// MARK: - Enum label extensions (CSV/JSON friendly)

extension UIDevice.BatteryState {
    /// Short lowercase label for the CSV/JSON row.
    var csvLabel: String {
        switch self {
        case .charging:  return "charging"
        case .full:      return "full"
        case .unplugged: return "unplugged"
        case .unknown:   return "unknown"
        @unknown default: return "unknown"
        }
    }
}

extension ProcessInfo.ThermalState {
    /// Short lowercase label for the CSV/JSON row.
    var csvLabel: String {
        switch self {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Compact date formatter (shared across logging)

extension DateFormatter {
    /// `20260424_150612` — filename-safe, sorts lexicographically by time.
    static let compactTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}
