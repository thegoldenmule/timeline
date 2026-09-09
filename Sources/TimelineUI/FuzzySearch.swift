import Foundation

/// The filename matcher behind the library panel's search field: a left-to-right subsequence scan that
/// rewards prefixes, runs, and word starts, so typing "bm" finds "band mix.wav" and "cam" ranks
/// "cam.mov" above "webcam.mov". Pure and allocation-light, because the panel rescores every row on
/// every keystroke rather than maintaining an index (`docs/plans/media-library.md` section 2.5).
public enum FuzzyMatch {
    /// The scoring weights, in one value so no tunable is loose in the code (`conventions.md`).
    public struct Weights: Hashable, Sendable {
        /// Per matched character.
        public var matched = 16
        /// Extra for a character matched right after the previous match.
        public var contiguous = 24
        /// Extra for a character at the start of a word.
        public var wordBoundary = 18
        /// Per unmatched character before the first match, and its cap.
        public var leading = 4
        public var maximumLeading = 40
        /// Per gap between matched runs.
        public var gap = 6
        /// Per unmatched character after the last match, and its cap, so a shorter name wins a tie.
        public var trailing = 1
        public var maximumTrailing = 20

        public init() {}

        public static let `default` = Weights()
    }

    /// The characters `-`, `_`, `.`, `/` and whitespace start a new word, as does a lower-to-upper
    /// camel-case transition.
    static let separators: Set<Character> = [" ", "-", "_", ".", "/", "\t"]

    /// How well `candidate` matches `query`, or nil when some query character is missing or out of
    /// order. An empty query matches everything with zero, so an empty search field filters nothing.
    /// Scores are comparable only between candidates scored with the same weights.
    public static func score(_ query: String, in candidate: String, weights: Weights = .default) -> Int? {
        let needle = Array(normalized(query).lowercased())
        guard !needle.isEmpty else { return 0 }
        // Boundaries are read from the case-preserving fold so camelCase still reads as separate words.
        let display = Array(normalized(candidate))
        let haystack = Array(normalized(candidate).lowercased())
        guard needle.count <= haystack.count else { return nil }

        var score = 0
        var runs = 0
        var index = 0
        var first: Int?
        var previous: Int?
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }
            score += weights.matched
            if let previous, found == previous + 1 {
                score += weights.contiguous
            } else {
                runs += 1
            }
            if isWordStart(at: found, in: display) { score += weights.wordBoundary }
            if first == nil { first = found }
            previous = found
            index = found + 1
        }
        guard let first, let last = previous else { return nil }
        score -= min(first * weights.leading, weights.maximumLeading)
        score -= max(0, runs - 1) * weights.gap
        score -= min((haystack.count - 1 - last) * weights.trailing, weights.maximumTrailing)
        return score
    }

    private static func isWordStart(at index: Int, in characters: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if separators.contains(previous) || previous.isWhitespace { return true }
        return previous.isLowercase && characters[index].isUppercase
    }

    /// Diacritics and full-width forms folded away once, so "Café" and "Cafe" are the same word.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
