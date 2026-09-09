import Foundation

public actor TrackingEngine {
    private var status: TrackingStatus = .paused
    private var position: TrackingPosition = TrackingPosition()
    private var mode: TrackingMode = .voice
    private var history: [TrackingEvent] = []
    private var candidatePositions: [TrackingPosition] = []
    private var lastUpdateTime: Date = .now
    private var uncertainSince: Date?

    private let positionEngine: PositionEngine
    private let recoveryManager: RecoveryManager

    public var onStatusChange: (@Sendable (TrackingStatus) -> Void)?
    public var onPositionUpdate: (@Sendable (TrackingPosition) -> Void)?

    public init(positionEngine: PositionEngine = PositionEngine(), recoveryManager: RecoveryManager = RecoveryManager()) {
        self.positionEngine = positionEngine
        self.recoveryManager = recoveryManager
    }

    // MARK: - Public API

    public func configure(mode: TrackingMode) {
        self.mode = mode
    }

    public func start(from position: TrackingPosition = TrackingPosition()) async {
        self.position = position
        self.status = .tracking
        await notifyStatusChange(.tracking)
    }

    public func pause() async {
        guard status == .tracking else { return }
        status = .paused
        recordEvent(type: .pause)
        await notifyStatusChange(.paused)
    }

    public func resume() async {
        guard status == .paused else { return }
        status = .tracking
        recordEvent(type: .resume)
        await notifyStatusChange(.tracking)
    }

    public func processASRResult(_ result: ASRResult) async {
        guard mode != .manual else { return }

        let match = await positionEngine.findBestMatch(
            for: result.transcript,
            currentPosition: position,
            history: history.suffix(20)
        )

        switch match.quality {
        case .high:
            await handleHighConfidenceMatch(match.position)
        case .medium:
            await handleMediumConfidenceMatch(match.position)
        case .low:
            await handleLowConfidenceMatch(match.position)
        case .none:
            await handleNoMatch()
        }
    }

    public func jumpTo(position: TrackingPosition) async {
        let event = TrackingEvent(
            type: .correction,
            position: position,
            detail: "Manual jump"
        )
        recordEvent(event)
        self.position = position
        status = .tracking
        await notifyPositionUpdate(position)
        await notifyStatusChange(.tracking)
    }

    public func adjustPosition(delta: Int) async {
        var newPos = position
        newPos.blockIndex = max(0, newPos.blockIndex + delta)
        newPos.confidence = 1.0
        await jumpTo(position: newPos)
    }

    public func recenter() async {
        await notifyPositionUpdate(position)
    }

    public func getCurrentState() -> (status: TrackingStatus, position: TrackingPosition) {
        (status, position)
    }

    public func setCallbacks(
        onStatusChange: (@Sendable (TrackingStatus) -> Void)?,
        onPositionUpdate: (@Sendable (TrackingPosition) -> Void)?
    ) {
        self.onStatusChange = onStatusChange
        self.onPositionUpdate = onPositionUpdate
    }

    // MARK: - Internal state handling

    private func handleHighConfidenceMatch(_ newPosition: TrackingPosition) async {
        uncertainSince = nil
        await recoveryManager.reset()

        let event = TrackingEvent(type: .positionUpdate, position: newPosition)
        recordEvent(event)
        position = newPosition
        lastUpdateTime = .now

        if status != .tracking {
            status = .tracking
            await notifyStatusChange(.tracking)
        }
        await notifyPositionUpdate(newPosition)
    }

    private func handleMediumConfidenceMatch(_ newPosition: TrackingPosition) async {
        uncertainSince = nil

        let smoothed = await positionEngine.smoothPosition(
            current: position,
            candidate: newPosition,
            velocity: position.velocity
        )

        let event = TrackingEvent(type: .positionUpdate, position: smoothed, detail: "Smoothed")
        recordEvent(event)
        position = smoothed
        lastUpdateTime = .now

        await notifyPositionUpdate(smoothed)
    }

    private func handleLowConfidenceMatch(_ newPosition: TrackingPosition) async {
        if uncertainSince == nil {
            uncertainSince = .now
            status = .uncertain
            await notifyStatusChange(.uncertain)
        }

        candidatePositions.append(newPosition)
        if candidatePositions.count > 5 {
            candidatePositions.removeFirst()
        }

        if let uncertainSince, Date().timeIntervalSince(uncertainSince) > 3.0 {
            status = .degraded(reason: .asrUnreliable)
            await notifyStatusChange(.degraded(reason: .asrUnreliable))
        }
    }

    private func handleNoMatch() async {
        if uncertainSince == nil {
            uncertainSince = .now
            status = .uncertain
            await notifyStatusChange(.uncertain)
        }

        if let uncertainSince, Date().timeIntervalSince(uncertainSince) > 3.0 {
            status = .degraded(reason: .asrUnreliable)
            await notifyStatusChange(.degraded(reason: .asrUnreliable))
        }
    }

    // MARK: - Helpers

    private func recordEvent(_ event: TrackingEvent) {
        history.append(event)
        if history.count > 200 {
            history.removeFirst(50)
        }
    }

    private func recordEvent(type: TrackingEvent.EventType, detail: String? = nil) {
        let event = TrackingEvent(type: type, position: position, detail: detail)
        recordEvent(event)
    }

    private func notifyStatusChange(_ newStatus: TrackingStatus) async {
        onStatusChange?(newStatus)
    }

    private func notifyPositionUpdate(_ newPosition: TrackingPosition) async {
        onPositionUpdate?(newPosition)
    }
}
