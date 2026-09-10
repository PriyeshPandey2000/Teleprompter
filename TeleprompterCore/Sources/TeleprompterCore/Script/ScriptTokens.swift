import Foundation

/// Normalizes raw spoken/script words into a comparable, canonical form.
///
/// Matching happens on normalized tokens so that obvious pronunciation
/// variants (lowercase, punctuation, and a small homophone table) do not
/// defeat the position tracker. Homophones are normalized on BOTH the
/// script side and the spoken side so the equality is faithful to sound.
public enum TextNormalizer: Sendable {
    /// Noticeable English homophone groups that SFSpeechRecognizer frequently
    /// swaps around without changing pronunciation. Applied after punctuation
    /// stripping, so keys are already in normalized (apostrophe-free) form.
    public static let homophoneMap: [String: String] = [
        "two": "to",
        "too": "to",
        "their": "there",
        "an": "a",
        "whos": "whose",
        "won": "one",
    ]

    /// Lowercases a word, strips non-alphanumeric characters, and folds
    /// common homophones into a canonical form.
    public static func normalize(_ word: String, applyHomophones: Bool = true) -> String {
        let lowered = word.lowercased()
        let alnumSet = CharacterSet.alphanumerics
        let alnum = lowered.unicodeScalars.filter { alnumSet.contains($0) }
        let cleaned = alnum.map(String.init).joined()
        guard applyHomophones else { return cleaned }
        return homophoneMap[cleaned] ?? cleaned
    }
}

/// A single matchable token in a formatted script.
public struct ScriptToken: Sendable, Equatable {
    /// The raw word as it appears in the script.
    public let raw: String
    /// The normalized, comparable form.
    public let norm: String
    /// Flat index within the whole script's token stream.
    public let index: Int

    public init(raw: String, norm: String, index: Int) {
        self.raw = raw
        self.norm = norm
        self.index = index
    }
}

/// The flat, per-block token index of a formatted script.
///
/// `blockStart[i]` is the token index where block `i` begins
/// (with a trailing sentinel equal to the total token count), so a flat
/// token index can be mapped back to a (block, word) position in O(log n).
public struct ScriptTokens: Sendable, Equatable {
    public let items: [ScriptToken]
    public let blockStart: [Int]
    public let applyHomophones: Bool

    public init(items: [ScriptToken], blockStart: [Int], applyHomophones: Bool = true) {
        self.items = items
        self.blockStart = blockStart
        self.applyHomophones = applyHomophones
    }

    public var count: Int { items.count }

    /// Builds the token index from the script's display blocks.
    ///
    /// Every block's `plainText` is tokenized in order, so display order and
    /// match order are guaranteed identical.
    public static func make(from blocks: [ScriptBlock], applyHomophones: Bool = true) -> ScriptTokens {
        var items: [ScriptToken] = []
        var blockStart: [Int] = []
        blockStart.reserveCapacity(blocks.count + 1)

        for block in blocks {
            blockStart.append(items.count)
            for word in rawWords(in: block.plainText) {
                let raw = String(word)
                let norm = TextNormalizer.normalize(raw, applyHomophones: applyHomophones)
                guard !norm.isEmpty else { continue }
                items.append(ScriptToken(raw: raw, norm: norm, index: items.count))
            }
        }
        blockStart.append(items.count)
        return ScriptTokens(items: items, blockStart: blockStart, applyHomophones: applyHomophones)
    }

    /// Splits raw text into matchable word runs — maximal alphanumeric
    /// sequences, dropping everything else. This is the exact boundary rule
    /// `make(from:)` tokenizes on; it's public so display-layer code (e.g.
    /// per-word highlighting) can map a matcher word index back onto
    /// substrings of the original display text without re-deriving the
    /// splitting rule and risking drift from the matcher's own tokenization.
    public static func rawWords(in text: String) -> [Substring] {
        text.split { !wordCharacter($0) }
    }

    private static func wordCharacter(_ scalar: Character) -> Bool {
        guard let first = scalar.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(first)
    }

    /// Maps a flat token index to its block index, or nil if out of range.
    public func blockIndex(forToken token: Int) -> Int? {
        guard token >= 0, token < items.count else { return nil }
        var lo = 0
        var hi = blockStart.count - 2
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if blockStart[mid] <= token {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    /// Maps a flat token index to a word index within its block.
    public func wordIndex(forToken token: Int, inBlock block: Int) -> Int {
        token - blockStart[block]
    }

    /// Maps a (block, word) display position to a flat token index.
    public func tokenIndex(block: Int, word: Int) -> Int? {
        guard block >= 0, block < blockStart.count - 1 else { return nil }
        let token = blockStart[block] + max(0, word)
        guard token < items.count else { return nil }
        return token
    }
}