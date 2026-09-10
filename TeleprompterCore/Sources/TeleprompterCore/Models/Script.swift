import Foundation

public struct Script: Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var rawContent: String
    public var formattedContent: FormattedScript?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "Untitled",
        rawContent: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.rawContent = rawContent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct FormattedScript: Sendable {
    public let blocks: [ScriptBlock]
    public let plainText: String
    public let wordCount: Int
    public let estimatedDuration: TimeInterval
    /// Flat, per-block token index used by the position matcher.
    public let tokens: ScriptTokens
}

public enum ScriptBlock: Sendable, Identifiable {
    case heading(meta: BlockMeta, text: String)
    case paragraph(meta: BlockMeta, text: String)
    case bullet(meta: BlockMeta, text: String)
    case numberedItem(meta: BlockMeta, number: Int, text: String)

    public struct BlockMeta: Sendable {
        public let id: UUID
        public let sourceRange: Range<String.Index>?

        public init(id: UUID = UUID(), sourceRange: Range<String.Index>? = nil) {
            self.id = id
            self.sourceRange = sourceRange
        }
    }

    public var id: UUID {
        switch self {
        case .heading(let meta, _), .paragraph(let meta, _), .bullet(let meta, _), .numberedItem(let meta, _, _):
            return meta.id
        }
    }

    public var plainText: String {
        switch self {
        case .heading(_, let text),
             .paragraph(_, let text),
             .bullet(_, let text):
            return text
        case .numberedItem(_, let number, let text):
            return "\(number). \(text)"
        }
    }

    public var wordCount: Int {
        plainText.split(separator: " ").count
    }
}

public struct WordTiming: Sendable, Identifiable {
    public let id = UUID()
    public let word: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let blockIndex: Int
    public let wordIndex: Int

    public init(word: String, startTime: TimeInterval, endTime: TimeInterval, blockIndex: Int, wordIndex: Int) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.blockIndex = blockIndex
        self.wordIndex = wordIndex
    }
}
