import Foundation

/// Result of parsing a voice utterance, covering all intents the app
/// understands — even the ones we only *wire up* later.
///
/// 3-A (highlight + error paths) implements the `.highlight`, `.unsupported`,
/// and `.unparseable` cases end-to-end. The remaining three cases —
/// `.capture`, `.stopCapture`, `.openPokedex` — are defined here now so
/// that:
///   1. The `switch` in `LiveView.speech.onFinal` is already exhaustive
///      with placeholder `break`s, and
///   2. When 3-C (YOLOkémon) lands, VoiceCommandParser can start emitting
///      them without touching this enum or every call site — only the
///      parser logic and the existing `switch` branches need to grow.
///
/// Kept `Sendable` so it can cross the speech queue ↔ MainActor boundary
/// without tripping Swift 6 concurrency checks.
enum VoiceIntent: Equatable, Sendable {
    /// `"find the cup"` — toggle the green target highlight on matching
    /// detections. Parsed in 3-A.
    case highlight(String)

    /// `"I choose the cup"`, `"catch cup"`, `"freeze cup"` — start a
    /// YOLOkémon capture on the given class. Wired in 3-C.
    case capture(String)

    /// `"give up"`, `"stop"` — abort the active capture. Wired in 3-C.
    case stopCapture

    /// `"open pokedex"`, `"show pokedex"` — switch the TabView to the
    /// Pokédex tab. Wired in 3-C.
    case openPokedex

    /// Noun was extracted but the speaker asked for a class COCO 80
    /// doesn't cover (e.g. "dragon"). The payload is what they said, so
    /// the status bar can echo it back ("unsupported class: dragon").
    case unsupported(String)

    /// No recognizable noun at all (only stopwords, silence, or
    /// gibberish).
    case unparseable
}
