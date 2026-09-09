import Foundation

public struct RecordingSession: Sendable, Identifiable {
    public let id: UUID
    public let scriptID: UUID
    public var startTime: Date
    public var endTime: Date?
    public var events: [TrackingEvent]
    public var takeNumber: Int

    public init(scriptID: UUID, takeNumber: Int = 1) {
        self.id = UUID()
        self.scriptID = scriptID
        self.startTime = .now
        self.endTime = nil
        self.events = []
        self.takeNumber = takeNumber
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
