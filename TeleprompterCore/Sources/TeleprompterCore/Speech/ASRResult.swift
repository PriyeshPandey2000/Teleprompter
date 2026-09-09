import Foundation

public struct ASRResult: Sendable {
    public let transcript: String
    public let segments: [ASRSegment]
    public let isFinal: Bool
    public let confidence: Double
    public let timestamp: Date

    public init(transcript: String, segments: [ASRSegment] = [], isFinal: Bool = false, confidence: Double = 0, timestamp: Date = .now) {
        self.transcript = transcript
        self.segments = segments
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

public struct ASRSegment: Sendable, Identifiable {
    public let id = UUID()
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Double

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Double = 0) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}
