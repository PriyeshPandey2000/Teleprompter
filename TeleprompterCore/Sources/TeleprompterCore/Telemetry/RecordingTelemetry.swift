import Foundation

public actor RecordingTelemetry {
    private var sessions: [RecordingSession] = []
    private var currentSession: RecordingSession?

    public init() {}

    public func startSession(scriptID: UUID, takeNumber: Int) -> RecordingSession {
        let session = RecordingSession(scriptID: scriptID, takeNumber: takeNumber)
        currentSession = session
        return session
    }

    public func recordEvent(_ event: TrackingEvent) {
        currentSession?.record(event)
    }

    public func endSession(latency: LatencySummary? = nil) -> RecordingSession? {
        guard var session = currentSession else { return nil }
        if let latency {
            session.finish(latency: latency)
        } else {
            session.finish()
        }
        sessions.append(session)
        currentSession = nil
        return session
    }

    public func getSessions(for scriptID: UUID) -> [RecordingSession] {
        sessions.filter { $0.scriptID == scriptID }
    }

    public func getSummary(for session: RecordingSession, scriptWordCount: Int) -> TakeSummary {
        let coveredWords = calculateCoveredWords(session: session)
        let coverage = scriptWordCount > 0 ? Double(coveredWords) / Double(scriptWordCount) : 0
        let wpm = session.duration > 0 ? Double(coveredWords) / (session.duration / 60.0) : 0

        return TakeSummary(
            session: session,
            scriptCoverage: min(coverage, 1.0),
            wordsPerMinute: wpm,
            fillerWordCount: 0,
            longPauseCount: session.pauseCount
        )
    }

    private func calculateCoveredWords(session: RecordingSession) -> Int {
        let updates = session.events.filter { $0.type == .positionUpdate }
        guard let lastUpdate = updates.last else { return 0 }
        return lastUpdate.position.blockIndex * 15 + lastUpdate.position.wordIndex
    }
}
