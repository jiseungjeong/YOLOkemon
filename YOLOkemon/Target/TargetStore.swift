import Combine
import Foundation

/// Single source of truth for "which COCO class is the user currently
/// asking us to highlight?".
///
/// Deliberately *minimal*. The status bar text,
/// per-frame "found / not found" messages, and YOLOkémon capture
/// state are all owned by other types:
///
///   * `LiveView` computes the status bar string from (current target,
///     current detections, precision) so there's no stateful message
///     backlog to manage here.
///   * `CaptureEngine` owns capture progress and
///     subscribes to `target` like any other observer.
///
/// Keeping this store single-purpose lets other stores sit
/// alongside it (`PokedexStore`, `CaptureEngine`) without collapsing
/// responsibilities into a god-object.
@MainActor
final class TargetStore: ObservableObject {
    /// The COCO label we're currently looking for, or `nil` if the user
    /// hasn't set one (initial state + after `clear()`).
    @Published var target: String? = nil

    func set(_ label: String) { target = label }
    func clear()              { target = nil }
}
