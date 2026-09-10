import Foundation

/// Time envelopes that drive the tracking → uncertain → degraded ladder.
public struct TrackingEnvelopeConfig: Sendable, Equatable {
    /// How long an unmatched stretch is tolerated before `.uncertain` is shown.
    public var uncertainGrace: TimeInterval
    /// How long before the engine freezes into `.degraded` without a confirmed match.
    public var degradedAfter: TimeInterval

    public init(uncertainGrace: TimeInterval = 0.3, degradedAfter: TimeInterval = 3.0) {
        self.uncertainGrace = uncertainGrace
        self.degradedAfter = degradedAfter
    }

    public static let `default` = TrackingEnvelopeConfig()
}

public actor TrackingEngine {
    private var status: TrackingStatus = .paused
    private var position: TrackingPosition = TrackingPosition()
    private var mode: TrackingMode = .voice
    private var history: [TrackingEvent] = []
    private var lastUpdateTime: Date = .now
    private var lastConfirmedAt: Date?
    private var scriptTokens: ScriptTokens?

    public let latencyRecorder: LatencyRecorder
    private let positionEngine: PositionEngine
    private let recoveryManager: RecoveryManager
    private let clock: @Sendable () -> Date
    private let envelope: TrackingEnvelopeConfig

    public var onStatusChange: (@Sendable (TrackingStatus) -> Void)?
    public var onPositionUpdate: (@Sendable (TrackingPosition) -> Void)?
    /// Fires for every telemetry-worthy event: manual corrections, pause/
    /// resume, degrade/recover transitions, and skip/backtrack re-anchors.
    /// This is the only way for a caller (e.g. `RecordingTelemetry`) to see
    /// individual events — `history` below is a private, capped ring buffer
    /// for the engine's own bookkeeping only.
    public var onEvent: (@Sendable (TrackingEvent) -> Void)?

    public init(
        positionEngine: PositionEngine = PositionEngine(),
        recoveryManager: RecoveryManager = RecoveryManager(),
        latencyRecorder: LatencyRecorder = LatencyRecorder(),
        clock: @escaping @Sendable () -> Date = { .now },
        envelope: TrackingEnvelopeConfig = .default
    ) {
        self.positionEngine = positionEngine
        self.recoveryManager = recoveryManager
        self.latencyRecorder = latencyRecorder
        self.clock = clock
        self.envelope = envelope
    }

    // MARK: - Public API

    public func configure(mode: TrackingMode) {
        self.mode = mode
    }

    /// Installs the script's token index so the position matcher can run.
    public func configure(script tokens: ScriptTokens?) async {
        scriptTokens = tokens
        await positionEngine.configure(script: tokens)
    }

    public func start(from position: TrackingPosition = TrackingPosition()) async {
        self.position = position
        await resetMatcher(to: position)
        await recoveryManager.reset()
        lastConfirmedAt = clock()
        self.status = .tracking
        await notifyStatusChange(.tracking)
    }

    public func pause() async {
        guard status == .tracking else { return }
        status = .paused
        let event = TrackingEvent(type: .pause, position: position)
        recordEvent(event)
        await notifyEvent(event)
        await notifyStatusChange(.paused)
    }

    public func resume() async {
        guard status == .paused else { return }
        status = .tracking
        let event = TrackingEvent(type: .resume, position: position)
        recordEvent(event)
        await notifyEvent(event)
        await notifyStatusChange(.tracking)
    }

    public func processASRResult(_ result: ASRResult, latencyCycle: UInt64? = nil) async {
        guard mode != .manual else { return }
        guard !result.transcript.isEmpty else { return }
        // Sticky: automatic recovery has given up. Freeze until the user taps
        // a position — no auto re-anchor, no position movement, no status flip.
        guard status != .manualFallback else { return }

        if let latencyCycle {
            await latencyRecorder.mark(.matcherStarted, forCycle: latencyCycle)
        }
        let outcome = await positionEngine.feed(transcript: result.transcript)
        if let latencyCycle {
            await latencyRecorder.mark(.matcherFinished, forCycle: latencyCycle)
        }

        switch outcome.quality {
        case .high:
            // Captured before `.recovering` (below) overwrites `status`, so
            // `handleHighConfidenceMatch` can still tell whether this match
            // is recovering from a genuinely degraded state versus a routine
            // uncertain blip.
            let wasDegradedFamily = status.isDegraded || status.isManualFallback
            if outcome.reanchored {
                status = .recovering
                await notifyStatusChange(.recovering)
            }
            if let target = outcome.position {
                if let latencyCycle {
                    await latencyRecorder.mark(.positionEmitted, forCycle: latencyCycle)
                }
                await handleHighConfidenceMatch(
                    target,
                    reanchored: outcome.reanchored,
                    recoveringFromDegraded: wasDegradedFamily
                )
            } else if outcome.missStreak > 0 {
                await handleNoMatch()
            }
        case .medium, .low:
            await handleNoMatch()
        case .none:
            if outcome.missStreak > 0 {
                await handleNoMatch()
            }
        }
    }

    public func jumpTo(position: TrackingPosition) async {
        let event = TrackingEvent(
            type: .correction,
            position: position,
            detail: "Manual jump"
        )
        recordEvent(event)
        await notifyEvent(event)
        self.position = position
        await resetMatcher(to: position)
        await recoveryManager.reset()
        lastConfirmedAt = clock()
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
        onPositionUpdate: (@Sendable (TrackingPosition) -> Void)?,
        onEvent: (@Sendable (TrackingEvent) -> Void)? = nil
    ) {
        self.onStatusChange = onStatusChange
        self.onPositionUpdate = onPositionUpdate
        self.onEvent = onEvent
    }

    // MARK: - Internal state handling

    /// - Parameters:
    ///   - reanchored: True when the matcher had to globally re-anchor
    ///     (rather than advance near/far within the lookahead window) to
    ///     reach `newPosition` — i.e. the reader skipped ahead or backtracked
    ///     far enough that ordinary forward matching lost them.
    ///   - recoveringFromDegraded: True when `status` was `.degraded` or
    ///     `.manualFallback` at the moment this ASR result arrived, captured
    ///     by the caller before the `.recovering` intermediate status
    ///     overwrites it.
    private func handleHighConfidenceMatch(
        _ newPosition: TrackingPosition,
        reanchored: Bool,
        recoveringFromDegraded: Bool
    ) async {
        lastConfirmedAt = clock()
        await recoveryManager.reset()

        // A reanchor is only a "skip" or "backtrack" in the telemetry sense
        // when it actually moved off the ordinary forward-reading path;
        // routine near/far advances (even large `.far` catch-ups within the
        // lookahead window) are just normal reading and stay `.positionUpdate`.
        let eventType: TrackingEvent.EventType
        if reanchored {
            eventType = newPosition.normalizedOffset < position.normalizedOffset ? .backtrack : .skip
        } else {
            eventType = .positionUpdate
        }
        let event = TrackingEvent(type: eventType, position: newPosition)
        recordEvent(event)
        await notifyEvent(event)

        position = newPosition
        lastUpdateTime = .now

        if status != .tracking {
            status = .tracking
            await notifyStatusChange(.tracking)
        }
        if recoveringFromDegraded {
            let recoverEvent = TrackingEvent(type: .recover, position: newPosition)
            recordEvent(recoverEvent)
            await notifyEvent(recoverEvent)
        }
        await notifyPositionUpdate(newPosition)
    }

    /// Drives the tracking → uncertain → degraded → manualFallback ladder
    /// based on how long it has been since the last confirmed match. In
    /// degraded the position is frozen but automatic recovery keeps trying;
    /// once `RecoveryManager` reports repeated failed attempts the engine
    /// escalates to the sticky `manualFallback` state (only a manual jump
    /// exits it — see the guard at the top of `processASRResult`).
    private func handleNoMatch() async {
        guard let lastConfirmedAt else { return }
        let elapsed = clock().timeIntervalSince(lastConfirmedAt)

        var candidate = status
        if elapsed >= envelope.degradedAfter {
            candidate = .degraded(reason: .asrUnreliable)
        } else if elapsed >= envelope.uncertainGrace {
            candidate = .uncertain
        }

        if candidate.isDegraded {
            let action = await recoveryManager.recordFailure()
            if action == .enterDegradedMode {
                candidate = .manualFallback
            }
        }

        if candidate != status {
            let isDegradedTransition = candidate.isDegraded || candidate.isManualFallback
            status = candidate
            await notifyStatusChange(candidate)
            if isDegradedTransition {
                let event = TrackingEvent(type: .degrade, position: position, detail: "\(candidate)")
                recordEvent(event)
                await notifyEvent(event)
            }
        }
    }

    // MARK: - Helpers

    /// Points the matcher cursor at `position`'s flat token and discards the
    /// spoken backlog, used by manual jumps and session starts.
    private func resetMatcher(to position: TrackingPosition) async {
        guard let scriptTokens else { return }
        guard scriptTokens.count > 0 else { return }
        let token = scriptTokens.tokenIndex(block: position.blockIndex, word: position.wordIndex)
        await positionEngine.reset(toToken: token ?? 0)
    }

    private func recordEvent(_ event: TrackingEvent) {
        history.append(event)
        if history.count > 200 {
            history.removeFirst(50)
        }
    }

    private func notifyStatusChange(_ newStatus: TrackingStatus) async {
        onStatusChange?(newStatus)
    }

    private func notifyPositionUpdate(_ newPosition: TrackingPosition) async {
        onPositionUpdate?(newPosition)
    }

    private func notifyEvent(_ event: TrackingEvent) async {
        onEvent?(event)
    }
}