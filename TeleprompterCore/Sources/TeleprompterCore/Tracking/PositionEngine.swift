import Foundation

public actor PositionEngine {
    private let maxCandidateHistory = 20

    public struct MatchResult: Sendable {
        public let position: TrackingPosition
        public let quality: MatchQuality

        public init(position: TrackingPosition, quality: MatchQuality) {
            self.position = position
            self.quality = quality
        }
    }

    public enum MatchQuality: Sendable {
        case high
        case medium
        case low
        case none
    }

    public init() {}

    public func findBestMatch(
        for transcript: String,
        currentPosition: TrackingPosition,
        history: [TrackingEvent]
    ) async -> MatchResult {
        let normalizedInput = normalizeText(transcript)
        guard !normalizedInput.isEmpty else {
            return MatchResult(position: currentPosition, quality: .none)
        }

        let nearbyBlocks = findNearbyBlocks(
            matching: normalizedInput,
            near: currentPosition,
            searchRadius: 5
        )

        guard let bestCandidate = nearbyBlocks.first else {
            return MatchResult(position: currentPosition, quality: .none)
        }

        let quality = assessQuality(
            candidate: bestCandidate.position,
            current: currentPosition,
            similarity: bestCandidate.similarity,
            history: history
        )

        return MatchResult(position: bestCandidate.position, quality: quality)
    }

    public func smoothPosition(
        current: TrackingPosition,
        candidate: TrackingPosition,
        velocity: Double
    ) -> TrackingPosition {
        let smoothingFactor = 0.6
        let blockDiff = candidate.blockIndex - current.blockIndex

        guard abs(blockDiff) <= 2 else {
            return candidate
        }

        let smoothedBlock = Double(current.blockIndex) * (1 - smoothingFactor) + Double(candidate.blockIndex) * smoothingFactor
        let smoothedWord = Double(current.wordIndex) * (1 - smoothingFactor) + Double(candidate.wordIndex) * smoothingFactor
        let newVelocity = Double(blockDiff) * smoothingFactor + velocity * (1 - smoothingFactor)

        return TrackingPosition(
            blockIndex: Int(smoothedBlock.rounded()),
            wordIndex: Int(smoothedWord.rounded()),
            confidence: candidate.confidence,
            velocity: newVelocity
        )
    }

    // MARK: - Private

    private func findNearbyBlocks(
        matching query: String,
        near position: TrackingPosition,
        searchRadius: Int
    ) -> [(position: TrackingPosition, similarity: Double)] {
        var results: [(position: TrackingPosition, similarity: Double)] = []

        let startBlock = max(0, position.blockIndex - searchRadius)
        let endBlock = position.blockIndex + searchRadius

        for blockIndex in startBlock...endBlock {
            let similarity = calculateSimilarity(query, blockIndex: blockIndex)
            if similarity > 0.3 {
                let pos = TrackingPosition(
                    blockIndex: blockIndex,
                    wordIndex: 0,
                    confidence: similarity
                )
                results.append((position: pos, similarity: similarity))
            }
        }

        return results.sorted { $0.similarity > $1.similarity }
    }

    private func calculateSimilarity(_ query: String, blockIndex: Int) -> Double {
        let words = query.split(separator: " ")
        guard !words.isEmpty else { return 0 }

        let matchCount = words.prefix(5).enumerated().filter { index, word in
            index < 5
        }.count

        return Double(matchCount) / Double(min(words.count, 5))
    }

    private func assessQuality(
        candidate: TrackingPosition,
        current: TrackingPosition,
        similarity: Double,
        history: [TrackingEvent]
    ) -> MatchQuality {
        let blockDelta = abs(candidate.blockIndex - current.blockIndex)

        if similarity > 0.8 && blockDelta <= 1 {
            return .high
        }
        if similarity > 0.5 && blockDelta <= 3 {
            return .medium
        }
        if similarity > 0.3 && blockDelta <= 5 {
            return .low
        }
        return .none
    }

    private func normalizeText(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
