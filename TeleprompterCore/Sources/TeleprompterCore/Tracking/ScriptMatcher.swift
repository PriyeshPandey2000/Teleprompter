import Foundation

/// Tunable constants for the position matcher.
///
/// Values reflect the production consensus (ShayneP/local-teleprompter and
/// lihogloglo/Teleprompter SPEC): a short forward lookahead, unconfirmed near
/// jumps, bigram-gated far jumps, and a global re-anchor only after a run of
/// unmatched words.
public struct MatcherConfiguration: Sendable, Equatable {
    /// How far past the cursor a match must be before bigram confirmation is required.
    public var nearJump: Int
    /// How many spoken words may remain unmatched before a global re-anchor is attempted.
    public var reanchorMissThreshold: Int
    /// Number of recent spoken words consulted when looking for a re-anchor target.
    public var reanchorWindow: Int
    /// Minimum aligned words required to commit a global re-anchor.
    public var reanchorMinMatches: Int
    /// Look-behind size used to confirm far matches; also the script-gap allowance.
    public var bigramWindow: Int
    /// Maximum token distance from the cursor that is searched for a forward match.
    public var lookahead: Int
    /// Words at least this long may match fuzzily.
    public var fuzzMinLength: Int
    /// Maximum edit distance allowed for fuzzy matches.
    public var fuzzyEdits: Int
    /// Whether the homophone table is applied on both sides.
    public var applyHomophones: Bool

    public init(
        nearJump: Int = 2,
        reanchorMissThreshold: Int = 4,
        reanchorWindow: Int = 6,
        reanchorMinMatches: Int = 3,
        bigramWindow: Int = 3,
        lookahead: Int = 18,
        fuzzMinLength: Int = 5,
        fuzzyEdits: Int = 1,
        applyHomophones: Bool = true
    ) {
        self.nearJump = nearJump
        self.reanchorMissThreshold = reanchorMissThreshold
        self.reanchorWindow = reanchorWindow
        self.reanchorMinMatches = reanchorMinMatches
        self.bigramWindow = bigramWindow
        self.lookahead = lookahead
        self.fuzzMinLength = fuzzMinLength
        self.fuzzyEdits = fuzzyEdits
        self.applyHomophones = applyHomophones
    }

    public static let `default` = MatcherConfiguration()
}

/// Mutable cursor state for one matching session (one recording run).
public struct MatcherSnapshot: Sendable, Equatable {
    /// Index of the next expected script token.
    public var cursor: Int
    /// Number of spoken tokens already consumed (never re-processed).
    public var consumedSpokenCount: Int
    /// Consecutive unmatched spoken words since the last confirmed advance.
    public var missStreak: Int

    public init(cursor: Int = 0, consumedSpokenCount: Int = 0, missStreak: Int = 0) {
        self.cursor = cursor
        self.consumedSpokenCount = consumedSpokenCount
        self.missStreak = missStreak
    }
}

/// Result of feeding one ASR transcript batch through the matcher.
public struct MatcherAdvancement: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Advanced within the near window (unconfirmed but very likely).
        case near
        /// Advanced past the near window; confirmed by a bigram look-behind.
        case far
        /// Global re-anchor committed (forward skip, rewind, or recovery).
        case reanchor
        /// No movement; either aligned and idle, or mid-miss-run.
        case hold
        /// Transcript shrank (ASR revision); consumed count was rebased.
        case rebased
    }

    public let kind: Kind
    /// New cursor when advanced or re-anchored; nil otherwise.
    public let cursor: Int?
    public let missStreak: Int
    /// Near/far re-anchor matches only; excludes rebased events.
    public let reanchored: Bool

    public init(kind: Kind, cursor: Int?, missStreak: Int, reanchored: Bool = false) {
        self.kind = kind
        self.cursor = cursor
        self.missStreak = missStreak
        self.reanchored = reanchored
    }
}

/// Pure, deterministic word-position matcher.
///
/// Modeled on production implementations: a forward-only greedy cursor over
/// normalized tokens, fuzzy (edit-distance) near matches, bigram-confirmed far
/// matches, and a locality-blind global re-anchor after a miss streak.
public enum ScriptMatcher: Sendable {
    // MARK: - Tokenization

    public static func tokenizeSpoken(
        _ transcript: String,
        config: MatcherConfiguration = .default
    ) -> [String] {
        transcript.split { !wordCharacter($0) }.map {
            TextNormalizer.normalize(String($0), applyHomophones: config.applyHomophones)
        }.filter { !$0.isEmpty }
    }

    private static func wordCharacter(_ scalar: Character) -> Bool {
        guard let first = scalar.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(first)
    }

    // MARK: - Word matching

    /// Exact, then edit-distance within a tight limit for longer words.
    public static func wordsMatch(_ a: String, _ b: String, config: MatcherConfiguration = .default) -> Bool {
        if a == b { return true }
        guard a.count >= config.fuzzMinLength, b.count >= config.fuzzMinLength else { return false }
        return editDistanceAtMost(a, b, limit: config.fuzzyEdits)
    }

    /// Levenshtein distance with an early-exit band (limit must be ≥ 1).
    public static func editDistanceAtMost(_ a: String, _ b: String, limit: Int) -> Bool {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if abs(n - m) > limit { return false }

        if n == 0 { return m <= limit }
        if m == 0 { return n <= limit }

        var prev = Array(0...m)
        var curr = [Int](repeating: 0, count: m + 1)

        for i in 1...n {
            curr[0] = i
            var rowMin = Int.max
            for j in 1...m {
                let substitution = prev[j - 1] + (aChars[i - 1] == bChars[j - 1] ? 0 : 1)
                let insertion = prev[j] + 1
                let deletion = curr[j - 1] + 1
                let cell = min(substitution, insertion, deletion)
                curr[j] = cell
                rowMin = min(rowMin, cell)
            }
            // Band pruning: if the entire row already exceeds the limit and
            // can only grow, the limit is unreachable.
            if rowMin > limit && i < n { return false }
            swap(&prev, &curr)
        }
        return prev[m] <= limit
    }

    // MARK: - Advance

    /// Processes newly appended spoken words and returns an updated snapshot.
    ///
    /// - Parameters:
    ///   - spoken: The FULL transcript token array for the session (all words
    ///     recognized so far). Words before `snapshot.consumedSpokenCount` are
    ///     never re-evaluated.
    public static func advance(
        snapshot: MatcherSnapshot,
        script: ScriptTokens,
        spoken: [String],
        config: MatcherConfiguration = .default
    ) -> (snapshot: MatcherSnapshot, result: MatcherAdvancement) {
        var snap = snapshot

        // ASR transcript revisions: never reprocess words we already consumed.
        if spoken.count < snap.consumedSpokenCount {
            snap.consumedSpokenCount = spoken.count
            return (snap, MatcherAdvancement(kind: .rebased, cursor: nil, missStreak: snap.missStreak))
        }

        let N = script.count
        guard N > 0, spoken.count > snap.consumedSpokenCount else {
            return (snap, MatcherAdvancement(kind: .hold, cursor: nil, missStreak: snap.missStreak))
        }

        let batch = Array(spoken[snap.consumedSpokenCount..<spoken.count])
        var cursor = snap.cursor
        var missStreak = snap.missStreak

        var matchedAny = false
        var lastScope: MatchScope = .none
        var didReanchor = false

        for (offset, word) in batch.enumerated() {
            let prevSpoken: String? = offset > 0
                ? batch[offset - 1]
                : (snap.consumedSpokenCount > 0 ? spoken[snap.consumedSpokenCount - 1] : nil)

            switch advanceOneWord(
                word: word,
                prevSpoken: prevSpoken,
                script: script,
                cursor: &cursor,
                missStreak: missStreak,
                config: config
            ) {
            case .near:
                matchedAny = true
                missStreak = 0
                lastScope = .near
            case .far:
                matchedAny = true
                missStreak = 0
                lastScope = .far
            case .none:
                missStreak += 1
            }

            // Global re-anchor when the miss run crosses the threshold.
            if missStreak >= config.reanchorMissThreshold, !didReanchor {
                let recent = Array(spoken.suffix(config.reanchorWindow))
                if let target = globalAnchor(
                    recent: recent,
                    script: script,
                    cursor: cursor,
                    config: config
                ) {
                    cursor = target + 1
                    missStreak = 0
                    didReanchor = true
                }
            }
        }

        snap.consumedSpokenCount = spoken.count

        if didReanchor {
            snap.cursor = cursor
            snap.missStreak = 0
            return (snap, MatcherAdvancement(kind: .reanchor, cursor: cursor, missStreak: 0, reanchored: true))
        }

        if matchedAny {
            snap.cursor = cursor
            snap.missStreak = missStreak
            let kind: MatcherAdvancement.Kind = lastScope == .near ? .near : .far
            return (snap, MatcherAdvancement(kind: kind, cursor: cursor, missStreak: missStreak))
        }

        snap.cursor = cursor
        snap.missStreak = missStreak
        return (snap, MatcherAdvancement(kind: .hold, cursor: nil, missStreak: missStreak))
    }

    private enum MatchScope {
        case near
        case far
        case none
    }

    /// Attempts to consume one spoken word: near match first, then a
    /// bigram-confirmed far match inside the lookahead window.
    ///
    /// `missStreak` is the miss count accumulated BEFORE this word. A far jump
    /// is only allowed while `missStreak > 0`: when the previous word just
    /// matched near, a lone far word is more likely an ad-lib (or a repeat of a
    /// just-finished phrase) than a legitimate skip, so it must not move the
    /// cursor. Legit skips simply pay a one-word deferral before they unlock.
    private static func advanceOneWord(
        word: String,
        prevSpoken: String?,
        script: ScriptTokens,
        cursor: inout Int,
        missStreak: Int,
        config: MatcherConfiguration
    ) -> MatchScope {
        let N = script.count
        guard cursor < N else {
            // Script finished; tolerate ad-libbed trailing words.
            return .none
        }

        let nearEnd = min(cursor + config.nearJump, N)
        for j in cursor..<nearEnd {
            if wordsMatch(script.items[j].norm, word, config: config) {
                cursor = j + 1
                return .near
            }
        }

        let farStart = nearEnd
        let farEnd = min(cursor + config.lookahead, N)
        if farEnd > farStart, missStreak > 0 {
            for j in farStart..<farEnd {
                guard wordsMatch(script.items[j].norm, word, config: config) else { continue }
                if let prevSpoken, bigramConfirmed(prevSpoken, before: j, cursor: cursor, script: script, config: config) {
                    cursor = j + 1
                    return .far
                }
            }
        }

        return .none
    }

    /// True when the previous spoken word appears among the `bigramWindow`
    /// script tokens in `[cursor, j)` — i.e. tokens the reader has NOT already
    /// consumed. Requiring the confirming word to sit ahead of the cursor keeps
    /// a stray word from leaping into the next occurrence of a repeated phrase
    /// (its confirming bigram would otherwise come from just-read history).
    private static func bigramConfirmed(
        _ prevSpoken: String,
        before j: Int,
        cursor: Int,
        script: ScriptTokens,
        config: MatcherConfiguration
    ) -> Bool {
        let lo = max(cursor, j - config.bigramWindow)
        guard lo < j else { return false }
        for k in lo..<j {
            if wordsMatch(script.items[k].norm, prevSpoken, config: config) {
                return true
            }
        }
        return false
    }

    /// Searches the whole script for a region aligned with `recent` spoken
    /// words, preferring matches near the cursor. Returns the token index whose
    /// following token becomes the new cursor, or nil when nothing commits.
    public static func globalAnchor(
        recent: [String],
        script: ScriptTokens,
        cursor: Int,
        config: MatcherConfiguration
    ) -> Int? {
        guard !recent.isEmpty else { return nil }
        let N = script.count
        guard N > 0 else { return nil }

        let lastWord = recent[recent.count - 1]
        var best: (score: Int, distance: Int, anchor: Int)?

        // Walk candidates outward from the cursor: forward first, then backward,
        // so a forward re-anchor beats an equally-scoring rewind.
        func consider(_ j: Int) {
            guard wordsMatch(script.items[j].norm, lastWord, config: config) else { return }
            let score = alignmentScore(
                recent: recent,
                script: script,
                anchor: j,
                config: config
            )
            guard score >= config.reanchorMinMatches else { return }
            let distance = abs(j - cursor)
            if best == nil
                || score > best!.score
                || (score == best!.score && distance < best!.distance) {
                best = (score: score, distance: distance, anchor: j)
            }
        }

        // Forward sweep from cursor.
        for j in cursor..<N {
            consider(j)
        }
        // Backward sweep from cursor - 1.
        if cursor > 0 {
            for j in stride(from: cursor - 1, through: 0, by: -1) {
                consider(j)
            }
        }

        return best?.anchor
    }

    /// Counts how many of `recent`'s tail words align with the script tokens
    /// ending at `anchor`, tolerating spoken insertions and small script gaps.
    private static func alignmentScore(
        recent: [String],
        script: ScriptTokens,
        anchor: Int,
        config: MatcherConfiguration
    ) -> Int {
        var score = 0
        var p = anchor
        var k = recent.count - 1
        var gapAllowance = config.bigramWindow

        while p >= 0 && k >= 0 {
            if wordsMatch(script.items[p].norm, recent[k], config: config) {
                score += 1
                p -= 1
                k -= 1
                gapAllowance = config.bigramWindow
            } else if k > 0 {
                // Try bridging a small script gap first.
                var jumped = 0
                while jumped < gapAllowance && p >= 0 && !wordsMatch(script.items[p].norm, recent[k], config: config) {
                    p -= 1
                    jumped += 1
                }
                if p >= 0 && wordsMatch(script.items[p].norm, recent[k], config: config) {
                    score += 1
                    p -= 1
                    k -= 1
                    gapAllowance = config.bigramWindow
                } else {
                    // Spoken insertion: skip this recent word.
                    k -= 1
                    gapAllowance -= 1
                }
            } else {
                k -= 1
            }
        }
        return score
    }
}