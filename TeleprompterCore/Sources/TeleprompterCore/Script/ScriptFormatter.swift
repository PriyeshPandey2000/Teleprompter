import Foundation

public actor ScriptFormatter {
    public struct FormattingOptions: Sendable {
        public var targetWordsPerLine: Int
        public var maxLineLength: Int
        public var paragraphSpacing: Double
        public var preserveOriginalText: Bool

        public init(
            targetWordsPerLine: Int = 8,
            maxLineLength: Int = 60,
            paragraphSpacing: Double = 1.5,
            preserveOriginalText: Bool = true
        ) {
            self.targetWordsPerLine = targetWordsPerLine
            self.maxLineLength = maxLineLength
            self.paragraphSpacing = paragraphSpacing
            self.preserveOriginalText = preserveOriginalText
        }
    }

    private let options: FormattingOptions

    public init(options: FormattingOptions = FormattingOptions()) {
        self.options = options
    }

    public func format(_ rawText: String) -> FormattedScript {
        let blocks = parseBlocks(from: rawText)
        let plainText = blocks.map(\.plainText).joined(separator: "\n\n")
        let wordCount = plainText.split(separator: " ").count
        let estimatedDuration = Double(wordCount) / 2.5

        return FormattedScript(
            blocks: blocks,
            plainText: plainText,
            wordCount: wordCount,
            estimatedDuration: estimatedDuration
        )
    }

    // MARK: - Block Parsing

    private func parseBlocks(from text: String) -> [ScriptBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [ScriptBlock] = []
        var currentParagraph: [String] = []
        var globalIndex = 0

        func flushParagraph() {
            guard !currentParagraph.isEmpty else { return }
            let joined = currentParagraph.joined(separator: " ")
            let rewrapped = rewrapText(joined)
            blocks.append(.paragraph(
                meta: ScriptBlock.BlockMeta(sourceRange: nil),
                text: rewrapped
            ))
            currentParagraph.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                globalIndex += 1
                continue
            }

            if isHeading(trimmed) {
                flushParagraph()
                let cleaned = cleanHeadingPrefix(trimmed)
                blocks.append(.heading(
                    meta: ScriptBlock.BlockMeta(sourceRange: nil),
                    text: cleaned
                ))
                globalIndex += 1
                continue
            }

            if let (number, content) = parseNumberedItem(trimmed) {
                flushParagraph()
                blocks.append(.numberedItem(
                    meta: ScriptBlock.BlockMeta(sourceRange: nil),
                    number: number,
                    text: content
                ))
                globalIndex += 1
                continue
            }

            if isBullet(trimmed) {
                flushParagraph()
                let content = cleanBulletPrefix(trimmed)
                blocks.append(.bullet(
                    meta: ScriptBlock.BlockMeta(sourceRange: nil),
                    text: content
                ))
                globalIndex += 1
                continue
            }

            currentParagraph.append(trimmed)
            globalIndex += 1
        }

        flushParagraph()
        return blocks
    }

    // MARK: - Text Classification

    private func isHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(":") && trimmed.count < 80 {
            let wordCount = trimmed.split(separator: " ").count
            if wordCount <= 8 { return true }
        }
        if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") {
            return true
        }
        return false
    }

    private func cleanHeadingPrefix(_ line: String) -> String {
        var result = line
        if result.hasPrefix("# ") {
            result = String(result.dropFirst(2))
        } else if result.hasPrefix("## ") {
            result = String(result.dropFirst(3))
        }
        if result.hasSuffix(":") {
            result = String(result.dropLast())
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func isBullet(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
    }

    private func cleanBulletPrefix(_ line: String) -> String {
        var result = line.trimmingCharacters(in: .whitespaces)
        if result.hasPrefix("- ") || result.hasPrefix("* ") {
            result = String(result.dropFirst(2))
        } else if result.hasPrefix("• ") {
            result = String(result.dropFirst(2))
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func parseNumberedItem(_ line: String) -> (Int, String)? {
        let pattern = #"^(\d+)[\.\)]\s+(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        guard let numRange = Range(match.range(at: 1), in: line),
              let contentRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        guard let number = Int(line[numRange]) else { return nil }
        return (number, String(line[contentRange]))
    }

    // MARK: - Rewrapping

    private func rewrapText(_ text: String) -> String {
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return text }

        var lines: [String] = []
        var currentLine: [String] = []

        for word in words {
            currentLine.append(String(word))
            let joined = currentLine.joined(separator: " ")

            if joined.count >= options.maxLineLength || currentLine.count >= options.targetWordsPerLine {
                lines.append(joined)
                currentLine.removeAll()
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine.joined(separator: " "))
        }

        return lines.joined(separator: "\n")
    }
}
