import Foundation

public struct RecordingSession: Sendable, Identifiable {
    public let id: UUID
    public let scriptID: UUID
    public var startTime: Date
    public var endTime: Date?
    public var events: [TrackingEvent]
    public var takeNumber: Int
    /// Gate-1 latency (asr → UI round trip) stamped at `finish` when the
    /// take actually tracked the reader. `nil` for takes with no matched
    /// results (e.g. ASR never engaged).
    public var trackingLatencyMean: TimeInterval?
    public var trackingLatencyP95: TimeInterval?
    public var trackingLatencyP99: TimeInterval?

    public init(scriptID: UUID, takeNumber: Int = 1) {
        self.id = UUID()
        self.scriptID = scriptID
        self.startTime = .now
        self.endTime = nil
        self.events = []
        self.takeNumber = takeNumber
        self.trackingLatencyMean = nil
        self.trackingLatencyP95 = nil
        self.trackingLatencyP99 = nil
    }

    public var duration: TimeInterval {
        (endTime ?? .now).timeIntervalSince(startTime)
    }

    public var correctionCount: Int {
        events.filter { $0.type == .correction }.count
    }

    public var pauseCount: Int {
        events.filter { $0.type == .pause }.count
    }

    public var degradeCount: Int {
        events.filter { $0.type == .degrade }.count
    }

    public mutating func record(_ event: TrackingEvent) {
        events.append(event)
    }

    public mutating func finish() {
        endTime = .now
    }

    /// Finishes the session and stamps the Gate-1 latency distribution from
    /// the take's ASR → UI pipeline.
    public mutating func finish(latency: LatencySummary) {
        finish()
        guard let total = latency.total else { return }
        trackingLatencyMean = total.mean
        trackingLatencyP95 = total.p95
        trackingLatencyP99 = total.p99
    }
}

public struct TakeSummary: Sendable, Identifiable {
    public let id: UUID
    public let session: RecordingSession
    public let scriptCoverage: Double
    public let wordsPerMinute: Double
    public let fillerWordCount: Int
    public let longPauseCount: Int

    public init(session: RecordingSession, scriptCoverage: Double, wordsPerMinute: Double, fillerWordCount: Int, longPauseCount: Int) {
        self.id = session.id
        self.session = session
        self.scriptCoverage = scriptCoverage
        self.wordsPerMinute = wordsPerMinute
        self.fillerWordCount = fillerWordCount
        self.longPauseCount = longPauseCount
    }
}
