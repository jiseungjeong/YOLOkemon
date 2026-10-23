import Foundation

/// Converts a free-form speech transcript into a `VoiceIntent`.
///
/// 3-C (YOLOkémon) turns on every case the enum exposes:
///   * `.highlight`         — `"find the cup"`, `"show the laptop"`, ...
///   * `.capture(class)`    — `"I choose the cup"`, `"catch cup"`, `"freeze cup"`
///   * `.stopCapture`       — `"give up"`, `"stop"`
///   * `.openPokedex`       — `"open pokedex"`, `"show pokedex"`
///   * `.unsupported(noun)` — parseable noun, not a COCO 80 class
///   * `.unparseable`       — empty/gibberish input
///
/// Matching strategy:
///   1. Lowercase, split on non-alphanumerics.
///   2. Check verb-only phrases first (`stop`, `give up`, `open pokedex`,
///      `show pokedex`) — those carry no class noun, so if we saw one of
///      them we return the matching intent immediately.
///   3. Drop stopwords for the remaining passes.
///   4. If the first token is a capture verb (`choose`, `catch`,
///      `freeze`, `capture`) or a highlight verb (`find`, `target`,
///      `show`, ...), remember which family it belonged to and skip it
///      so `"find the cup"` doesn't try to match a class named `"find"`.
///   5. Walk n-grams from 3 down to 1 (so `"cell phone"` beats
///      `"phone"` when both would match), preferring the longest
///      official COCO label first, then falling back to the alias
///      dictionary. The matched class is packaged into `.capture` or
///      `.highlight` based on step 4's verb family.
///
/// The alias list is intentionally small — just enough to cover the
/// common mismatches between everyday speech and COCO's label names
/// (`phone`→`cell phone`, `tv` already exists, `bike`→`bicycle`,
/// etc.). We can extend it later if the demo scenes need it.
enum VoiceCommandParser {

    // Cache the COCO label set once; `LabelLoader.coco80()` is a nonisolated
    // static getter backed by a lazily-initialized Swift `static let`.
    nonisolated private static let cocoLabels: Set<String> =
        Set(LabelLoader.coco80())

    /// Everyday words that map to COCO 80 labels. Keep this list short
    /// and demo-scene-focused; adding entries indiscriminately dilutes
    /// the matcher (every extra alias widens the "unsupported" blast
    /// radius for lookalike nouns).
    nonisolated private static let aliases: [String: String] = [
        "phone":      "cell phone",
        "mobile":     "cell phone",
        "cellphone":  "cell phone",
        "mug":        "cup",
        // SFSpeechRecognizer's en-US model regularly mishears "cup" as
        // "cop" (and occasionally "cap") on iPhone 11's front-facing
        // mic — both land with higher priors than "cup" since they're
        // more common English words. Remap them so the demo cup on the
        // desk still gets picked up. These two are *homophone*
        // corrections, not semantic aliases, so keeping them narrow
        // (single-word, no compound variants) avoids surprising the
        // user when they legitimately say something else.
        "cop":        "cup",
        "cap":        "cup",
        "television": "tv",
        "bike":       "bicycle",
        "couch":      "sofa",
        "auto":       "car",
        "automobile": "car",

        // Capture-verb variants. The recognizer often returns
        // past-tense / contracted forms ("I chose a laptop",
        // "I'll choose…") for the demo line "I choose the X". Normalize
        // them to "choose" so (1) the visible transcript on the Live
        // Summary card reads as the user intended, and (2) the verb
        // check in parse(...) still fires (`captureVerbs` contains
        // "choose", not "chose"). Same rationale as the cop→cup fix.
        "chose":      "choose",
        "chosen":     "choose",
        "choosing":   "choose",
        // "catches" / "caught" → "catch" — similar pattern for the
        // alternate capture verb.
        "catches":    "catch",
        "caught":     "catch",
        "catching":   "catch",
    ]

    /// Verbs that introduce a highlight command. Anything else with a
    /// noun after it is still accepted (`"the cup"` alone works too).
    nonisolated private static let highlightVerbs: Set<String> = [
        "find", "target", "detect", "look",
        "show", "highlight", "locate", "where",
    ]

    /// Verbs that start a YOLOkémon capture. `choose` covers the demo
    /// line `"I choose the cup"` (SFSpeechRecognizer strips `"I"` as a
    /// filler anyway thanks to the stopword list — but leaving it in
    /// stopwords keeps the pronoun out of the n-gram walk).
    nonisolated private static let captureVerbs: Set<String> = [
        "choose", "catch", "freeze", "capture",
    ]

    /// SFSpeechRecognizer on en-US consistently mangles `"give up"` as
    /// a music-genre word salad — `"k-pop"`, `"keep up"`, `"hip-hop"`,
    /// or some mix of those. These substring fingerprints let us
    /// recover the original intent. Kept as whole-phrase matches
    /// (multi-token) so a legitimate `"pop the cup"` style utterance
    /// isn't hijacked. The corresponding `displayNormalized` path
    /// rewrites the visible transcript back to `"give up"` so the UI
    /// and the parser agree on what was said.
    nonisolated private static let giveUpMishears: [String] = [
        "keep up",
        "k pop",
        "kpop",
        "hip hop",
        "hiphop",
    ]

    /// `"capture the cup"` is regularly recognized as `"capture.com"` /
    /// `"capture com"` (the recognizer's en-US LM has a strong prior for
    /// the domain suffix). These fingerprints fold the variants back to
    /// the canonical capture command. Match is tied to a leading
    /// `capture` verb so unrelated `".com"` mentions in a different
    /// command shape (unlikely but possible) don't get hijacked.
    nonisolated private static let captureCupMishears: [String] = [
        "capture com",
        "capture the com",
    ]

    /// Filler words that carry no class information. Removing them up
    /// front lets the n-gram walk pretend the input is just nouns. `"i"`
    /// is in here so `"I choose the cup"` reduces to `[choose, cup]`
    /// before the verb-family check runs.
    nonisolated private static let stopwords: Set<String> = [
        "the", "a", "an", "is", "are",
        "please", "for", "me", "at", "my", "to", "i",
    ]

    /// Apply the alias dictionary to a raw transcript so the *display*
    /// string matches what the parser will actually act on. The main
    /// motivation is the iOS en-US mishear of "cup" as "cop" / "cap":
    /// without normalization the user sees "find the cop" in the
    /// overlay and wonders if the app is really going to pick up the
    /// cup, even though our `parse(_:)` would resolve it correctly.
    /// By running the same alias substitution on the visible transcript
    /// the overlay reads "find the cup" and the UX feels coherent.
    ///
    /// Whole-word substitution only (case-insensitive) so we don't
    /// accidentally rewrite part of an unrelated word like "copy" →
    /// "cup y". Keeps the original casing of untouched tokens.
    nonisolated static func displayNormalized(_ utterance: String) -> String {
        // Fast path: empty in, empty out.
        guard !utterance.isEmpty else { return utterance }

        // Phrase-level rewrites — same shape for every mishear family:
        //   1. normalize the input (lowercase + non-alphanumeric → space),
        //   2. check fingerprints, return canonical phrase on match.
        // Done before the token-level alias walk so downstream logic
        // doesn't have to chase partial matches. We match against a
        // normalized copy so hyphenated / dotted forms like `"K-pop"`
        // or `"capture.com"` fold onto the same fingerprint as their
        // space-separated equivalents.
        let normalized = normalizeForPhraseMatch(utterance)
        if giveUpMishears.contains(where: { normalized.contains($0) }) {
            return "give up"
        }
        if captureCupMishears.contains(where: { normalized.contains($0) }) {
            return "capture the cup"
        }

        // Walk the string, rebuilding it token-by-token. We split on
        // whitespace only (punctuation stays with its token) so that
        // round-tripping empty input or trailing spaces is stable.
        let parts = utterance.split(separator: " ", omittingEmptySubsequences: false)
        let rewritten = parts.map { part -> String in
            let raw = String(part)
            // Strip punctuation at the edges for the lookup, but keep
            // it for reassembly so "cop." still reads "cup." on screen.
            let trimmed = raw.trimmingCharacters(in: .punctuationCharacters)
            let key = trimmed.lowercased()
            if !key.isEmpty, let mapped = aliases[key] {
                // Preserve leading/trailing punctuation from `raw`
                // around the replacement.
                let lead = raw.prefix { $0.isPunctuation }
                let tail = raw.reversed().prefix { $0.isPunctuation }.reversed()
                return "\(lead)\(mapped)\(String(tail))"
            }
            return raw
        }
        return rewritten.joined(separator: " ")
    }

    /// Parse a raw transcript into a `VoiceIntent`.
    nonisolated static func parse(_ utterance: String) -> VoiceIntent {
        // 1) Normalize + tokenize. `components(separatedBy:)` with the
        //    inverted alphanumerics set acts as a cheap word splitter
        //    that also strips punctuation. We keep the *raw* lowercase
        //    tokens here (stopwords still in) so verb-only phrases like
        //    `"give up"` survive the stopword filter — `"up"` happens
        //    not to be a stopword, but `"give up stop"` shouldn't have
        //    its `stop` checked before `give up`, and keeping the
        //    ordered raw list lets us do that.
        let rawTokens = utterance
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !rawTokens.isEmpty else { return .unparseable }

        // 2) Verb-only phrases with no class noun. Check these before
        //    the stopword filter so `"stop"` alone still works, and
        //    before the greedy match so `"show pokedex"` doesn't fall
        //    through to a highlight attempt on the (non-COCO) noun
        //    `"pokedex"`.
        //    - `give up` / `stop` → `.stopCapture`
        //    - `open pokedex` / `show pokedex` → `.openPokedex`
        let joined = rawTokens.joined(separator: " ")
        if joined == "stop"
            || joined.contains("give up")
            || giveUpMishears.contains(where: { joined.contains($0) }) {
            return .stopCapture
        }
        if joined.contains("open pokedex")
            || joined.contains("show pokedex")
            || joined.contains("open pokédex")
            || joined.contains("show pokédex") {
            return .openPokedex
        }

        // 2a) Capture-cup mishear family (`"capture.com"`, `"capture com"`,
        //     etc.). Caught here before the n-gram walk so the recognizer's
        //     domain-suffix mishear ("com") doesn't get classified as an
        //     unsupported class. Routes to .capture("cup") directly.
        if captureCupMishears.contains(where: { joined.contains($0) }) {
            return .capture("cup")
        }

        // 3) Strip stopwords for the noun-bearing passes.
        let tokens = rawTokens.filter { !stopwords.contains($0) }
        guard !tokens.isEmpty else { return .unparseable }

        // 4) Note which verb family (capture vs highlight) opened the
        //    phrase, then drop that verb token so the n-gram walk sees
        //    only nouns. Capture takes precedence over highlight when
        //    the first two tokens are both verbs (shouldn't happen in
        //    practice, but guards against `"find choose cup"` style
        //    ambiguity). The first token is also run through `aliases`
        //    so recognizer variants like `chose` / `caught` are treated
        //    as `choose` / `catch` — same normalization `displayNormalized`
        //    uses on the visible transcript.
        var body = tokens
        var wantsCapture = false
        if let first = body.first {
            let firstNorm = aliases[first] ?? first
            if captureVerbs.contains(firstNorm) {
                wantsCapture = true
                body.removeFirst()
            } else if highlightVerbs.contains(firstNorm) {
                body.removeFirst()
            }
        }

        guard !body.isEmpty else { return .unparseable }

        // 5) Greedy longest-n-gram match. `min(3, body.count)` caps at
        //    trigrams which covers every COCO label (no class has 4
        //    words).
        let maxN = min(3, body.count)
        if maxN >= 1 {
            for n in stride(from: maxN, through: 1, by: -1) {
                guard body.count >= n else { continue }
                for i in 0...(body.count - n) {
                    let cand = body[i..<(i + n)].joined(separator: " ")
                    if let cls = resolveClass(cand) {
                        return wantsCapture ? .capture(cls)
                                            : .highlight(cls)
                    }
                }
            }
        }

        // Nothing matched a COCO class or an alias — echo back the
        // user's best-guess noun so the status bar can say
        // "unsupported class: dragon".
        return .unsupported(body.joined(separator: " "))
    }

    /// Lowercase + collapse every non-alphanumeric run to a single
    /// space + trim. Used by both `displayNormalized` and any
    /// phrase-level matcher that needs hyphenated forms (`"K-pop"`)
    /// to fold into the same fingerprint as the space-separated form
    /// (`"k pop"`).
    nonisolated private static func normalizeForPhraseMatch(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : " "
        }
        let collapsed = String(mapped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed
    }

    /// Return the canonical COCO label for a candidate token, via
    /// direct hit or alias. `nil` means the candidate isn't a class
    /// the app knows about. Factored out so the `parse` n-gram loop
    /// and any future caller (e.g. a text-based test harness) share
    /// identical matching rules.
    nonisolated private static func resolveClass(_ candidate: String) -> String? {
        if cocoLabels.contains(candidate) { return candidate }
        if let mapped = aliases[candidate], cocoLabels.contains(mapped) {
            return mapped
        }
        return nil
    }
}
