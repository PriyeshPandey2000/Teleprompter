import Foundation

public actor PositionEngine {
    public struct FeedOutcome: Sendable {
        public let position: TrackingPosition?
        public let quality: MatchQuality
        public let reanchored: Bool
        public let missStreak: Int

        public init(position: TrackingPosition?, quality: MatchQuality, reanchored: Bool, missStreak: Int) {
            self.position = position
            self.quality = quality
            self.reanchored = reanchored
            self.missStreak = missStreak
        }
    }

    public enum MatchQuality: Sendable {
        case high
        case medium
        case low
        case none
    }

    private var script: ScriptTokens?
    private var snapshot = MatcherSnapshot()
    private var lastSpokenCount = 0
    private let config: MatcherConfiguration

    public init(config: MatcherConfiguration = .default) {
        self.config = config
    }

    /// Installs the token index for the current script and resets the cursor.
    public func configure(script: ScriptTokens?) async {
        self.script = script
        snapshot = MatcherSnapshot()
        lastSpokenCount = 0
    }

    /// Resets the matching cursor to a flat token index (used for manual jumps
    /// and session starts), discarding any unconsumed spoken backlog so the
    /// cursor stays put and old words are never replayed against the new spot.
    public func reset(toToken token: Int) async {
        snapshot = MatcherSnapshot(cursor: max(0, token), consumedSpokenCount: lastSpokenCount)
    }

    /// Feeds the latest ASR transcript and resolves the matching outcome.
    public func feed(transcript: String) -> FeedOutcome {
        guard let script else {
            return FeedOutcome(position: nil, quality: .none, reanchored: false, missStreak: 0)
        }

        let spoken = ScriptMatcher.tokenizeSpoken(transcript, config: config)
        lastSpokenCount = spoken.count
        let (newSnapshot, result) = ScriptMatcher.advance(
            snapshot: snapshot,
            script: script,
            spoken: spoken,
            config: config
        )
        snapshot = newSnapshot

        switch result.kind {
        case .near, .reanchor:
            guard let cursor = result.cursor else {
                return FeedOutcome(position: nil, quality: .none, reanchored: false, missStreak: result.missStreak)
            }
            let position = position(forToken: cursor - 1, confidence: 0.95)
            return FeedOutcome(
                position: position,
                quality: .high,
                reanchored: result.kind == .reanchor,
                missStreak: result.missStreak
            )

        case .far:
            guard let cursor = result.cursor else {
                return FeedOutcome(position: nil, quality: .none, reanchored: false, missStreak: result.missStreak)
            }
            let position = position(forToken: cursor - 1, confidence: 0.8)
            return FeedOutcome(position: position, quality: .high, reanchored: false, missStreak: result.missStreak)

        case .hold:
            // Aligned and idle (missStreak == 0) or mid-miss-run: the engine decides.
            return FeedOutcome(
                position: nil,
                quality: .none,
                reanchored: false,
                missStreak: result.missStreak
            )

        case .rebased:
            return FeedOutcome(position: nil, quality: .none, reanchored: false, missStreak: result.missStreak)
        }
    }

    private func position(forToken token: Int, confidence: Double) -> TrackingPosition? {
        guard let script, let block = script.blockIndex(forToken: token) else { return nil }
        let word = script.wordIndex(forToken: token, inBlock: block)
        return TrackingPosition(blockIndex: block, wordIndex: word, confidence: confidence)
    }
}