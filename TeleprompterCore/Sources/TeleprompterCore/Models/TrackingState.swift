import Foundation

public enum TrackingMode: Sendable, CaseIterable {
    case voice
    case manual
    case hybrid
}

public enum TrackingStatus: Sendable, Equatable {
    case tracking
    case paused
    case uncertain
    case recovering
    case manual
    case degraded(reason: DegradedReason)

    public var isHealthy: Bool {
        switch self {
        case .tracking, .paused, .manual:
            return true
        case .uncertain, .recovering, .degraded:
            return false
        }
    }

    public var indicatorColor: String {
        switch self {
        case .tracking: return "green"
        case .paused: return "gray"
        case .manual: return "blue"
        case .uncertain, .recovering: return "yellow"
        case .degraded: return "red"
        }
    }
}

public enum DegradedReason: Sendable, Equatable {
    case asrUnavailable
    case asrUnreliable
    case microphoneLost
}

public struct TrackingPosition: Sendable, Equatable {
    public var blockIndex: Int
    public var wordIndex: Int
    public var confidence: Double
    public var velocity: Double

    public init(blockIndex: Int = 0, wordIndex: Int = 0, confidence: Double = 1.0, velocity: Double = 0) {
        self.blockIndex = blockIndex
        self.wordIndex = wordIndex
        self.confidence = confidence
        self.velocity = velocity
    }

    public var normalizedOffset: Double {
        Double(blockIndex) + Double(wordIndex) * 0.01
    }
}

public struct TrackingEvent: Sendable, Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let type: EventType
    public let position: TrackingPosition
    public let detail: String?

    public enum EventType: Sendable {
        case positionUpdate
        case correction
        case pause
        case resume
        case degrade
        case recover
        case skip
        case backtrack
    }

    public init(timestamp: Date = .now, type: EventType, position: TrackingPosition, detail: String? = nil) {
        self.timestamp = timestamp
        self.type = type
        self.position = position
        self.detail = detail
    }
}
