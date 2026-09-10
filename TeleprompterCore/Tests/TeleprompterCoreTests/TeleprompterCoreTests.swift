import Foundation
import Testing
@testable import TeleprompterCore

/// Thread-safe mutable clock for envelope tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _date: Date
    init(date: Date = Date(timeIntervalSince1970: 0)) {
        _date = date
    }
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return _date
    }
    func set(_ timeInterval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        _date = Date(timeIntervalSince1970: timeInterval)
    }
    func advance(_ delta: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        _date = _date.addingTimeInterval(delta)
    }
}

/// Thread-safe side-channel collector for engine callbacks fired off-actor.
private final class CallbackCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [TrackingStatus] = []
    private var _blocks: [Int] = []
    private var _events: [TrackingEvent] = []
    var statuses: [TrackingStatus] {
        lock.lock()
        defer { lock.unlock() }
        return _statuses
    }
    var blocks: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return _blocks
    }
    var events: [TrackingEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }
    func record(status: TrackingStatus) {
        lock.lock()
        defer { lock.unlock() }
        _statuses.append(status)
    }
    func record(position: TrackingPosition) {
        lock.lock()
        defer { lock.unlock() }
        _blocks.append(position.blockIndex)
    }
    func record(event: TrackingEvent) {
        lock.lock()
        defer { lock.unlock() }
        _events.append(event)
    }
}

@Suite("Script Formatting")
struct ScriptFormatterTests {
    @Test("Formats plain text into blocks")
    func formatPlainText() async {
        let formatter = ScriptFormatter()
        let result = await formatter.format("Hello world. This is a test paragraph.")

        #expect(result.blocks.count >= 1)
        #expect(result.wordCount > 0)
        #expect(result.estimatedDuration > 0)
    }

    @Test("Detects headings")
    func detectHeadings() async {
        let formatter = ScriptFormatter()
        let result = await formatter.format("Introduction:\nThis is the body text.")

        #expect(result.blocks.count == 2)
        if case .heading(_, let text) = result.blocks[0] {
            #expect(text == "Introduction")
        } else {
            Issue.record("First block should be a heading")
        }
    }

    @Test("Detects bullet points")
    func detectBullets() async {
        let formatter = ScriptFormatter()
        let result = await formatter.format("- First item\n- Second item\n- Third item")

        #expect(result.blocks.count == 3)
        for block in result.blocks {
            if case .bullet(_, _) = block {
                // ok
            } else {
                Issue.record("All blocks should be bullets")
            }
        }
    }

    @Test("Detects numbered items")
    func detectNumbered() async {
        let formatter = ScriptFormatter()
        let result = await formatter.format("1. First step\n2. Second step\n3. Third step")

        #expect(result.blocks.count == 3)
        if case .numberedItem(_, let number, _) = result.blocks[0] {
            #expect(number == 1)
        } else {
            Issue.record("First block should be numbered item")
        }
    }
}

@Suite("Tracking State Machine")
struct TrackingEngineTests {
    @Test("Starts in paused state")
    func initialState() async {
        let engine = TrackingEngine()
        let state = await engine.getCurrentState()
        #expect(state.status == .paused)
    }

    @Test("Transitions to tracking on start")
    func startTracking() async {
        let engine = TrackingEngine()
        await engine.start()
        let state = await engine.getCurrentState()
        #expect(state.status == .tracking)
    }

    @Test("Jumps to position")
    func jumpToPosition() async {
        let engine = TrackingEngine()
        let position = TrackingPosition(blockIndex: 5, wordIndex: 0, confidence: 1.0)
        await engine.jumpTo(position: position)
        let state = await engine.getCurrentState()
        #expect(state.position.blockIndex == 5)
        #expect(state.status == .tracking)
    }

    @Test("Adjusts position")
    func adjustPosition() async {
        let engine = TrackingEngine()
        await engine.start()
        await engine.adjustPosition(delta: 3)
        let state = await engine.getCurrentState()
        #expect(state.position.blockIndex == 3)
    }

    @Test("Processed ASR advances position")
    func processASRMovesPosition() async {
        let engine = TrackingEngine()
        let formatter = ScriptFormatter()
        let tokens = await formatter.format(ScriptMatcherTests.sampleScript).tokens
        await engine.configure(script: tokens)
        await engine.start()

        await engine.processASRResult(ASRResult(transcript: "We need to make sales now and grow the business."))

        let state = await engine.getCurrentState()
        #expect(state.status == .tracking)
        #expect(state.position.blockIndex == 0)
        #expect(state.position.wordIndex == 9)
    }

    @Test("Immediate unmatched speech stays tracking; stops match turns uncertain")
    func processASRUnmatchedIsUncertain() async {
        let clock = TestClock()
        let engine = TrackingEngine(clock: { clock.now })
        let formatter = ScriptFormatter()
        let tokens = await formatter.format(ScriptMatcherTests.sampleScript).tokens
        await engine.configure(script: tokens)
        await engine.start()

        await engine.processASRResult(ASRResult(transcript: "um hmm okay whatever"))

        // Elapsed << uncertainGrace, so the engine stays put for now.
        var state = await engine.getCurrentState()
        #expect(state.status == .tracking)

        clock.advance(0.4)
        await engine.processASRResult(ASRResult(transcript: "um hmm okay whatever still talking"))
        state = await engine.getCurrentState()
        #expect(state.status == .uncertain)
    }

    @Test("Manual jump survives subsequent ASR flow")
    func manualJumpThenASR() async {
        let engine = TrackingEngine()
        let formatter = ScriptFormatter()
        let tokens = await formatter.format(ScriptMatcherTests.sampleScript).tokens
        await engine.configure(script: tokens)
        await engine.start()
        await engine.processASRResult(ASRResult(transcript: "We need to make sales."))

        await engine.jumpTo(position: TrackingPosition(blockIndex: 2, wordIndex: 0))
        await engine.processASRResult(ASRResult(transcript: "Next we will hire more people"))

        let state = await engine.getCurrentState()
        #expect(state.position.blockIndex == 2)
    }
}

@Suite("Recovery Manager")
struct RecoveryManagerTests {
    @Test("Records failure and suggests correction after threshold")
    func failureRecovery() async {
        let manager = RecoveryManager()
        let action1 = await manager.recordFailure()
        #expect(action1 == .holdPosition)

        let _ = await manager.recordFailure()
        let action3 = await manager.recordFailure()
        #expect(action3 == .suggestManualCorrection)

        let action4 = await manager.recordFailure()
        #expect(action4 == .enterDegradedMode)
    }

    @Test("Reset clears failures")
    func resetClearsFailures() async {
        let manager = RecoveryManager()
        let _ = await manager.recordFailure()
        let _ = await manager.recordFailure()
        await manager.reset()
        let action = await manager.recordFailure()
        #expect(action == .holdPosition)
    }
}

@Suite("Position Engine")
struct PositionEngineTests {
    private func sampleTokens() async -> ScriptTokens {
        let formatter = ScriptFormatter()
        let result = await formatter.format(ScriptMatcherTests.sampleScript)
        return result.tokens
    }

    @Test("Feeds matched transcript into a new position")
    func feedMatchedTranscript() async {
        let engine = PositionEngine()
        await engine.configure(script: await sampleTokens())
        let outcome = await engine.feed(transcript: "We need to make sales now and grow the business.")
        #expect(outcome.quality == .high)
        #expect(outcome.position != nil)
        #expect(outcome.position?.blockIndex == 0)
        #expect(outcome.position?.wordIndex == 9)
    }

    @Test("Holds still on unmatched improvisation")
    func feedUnmatchedSpeech() async {
        let engine = PositionEngine()
        await engine.configure(script: await sampleTokens())
        let outcome = await engine.feed(transcript: "um hmm okay so anyway let me just talk freely")
        #expect(outcome.quality == .none)
        #expect(outcome.position == nil)
        #expect(outcome.missStreak >= 4)
    }

    @Test("Manual jump sticks and does not replay old backlog")
    func resetThenFeedForwardKeepsJump() async {
        let engine = PositionEngine()
        await engine.configure(script: await sampleTokens())
        _ = await engine.feed(transcript: "We need to make")
        await engine.reset(toToken: 30)
        let outcome = await engine.feed(transcript: "We need to make sales now and grow the business. Next we will hire more people")
        // Must not fall back toward line one; the jump survives.
        #expect((outcome.position?.blockIndex ?? -1) >= 2)
    }

    @Test("Works with no script configured")
    func noScriptConfigured() async {
        let engine = PositionEngine()
        let outcome = await engine.feed(transcript: "anything at all")
        #expect(outcome.quality == .none)
        #expect(outcome.position == nil)
    }
}

@Suite("Script Matcher")
struct ScriptMatcherTests {
    /// Four blocks (blank-line separated): tokens 0-9, 10-19, 20-30, 31-39.
    static let sampleScript = """
    We need to make sales now and grow the business.

    Sales are up this quarter, so the plan is working.

    Next we will hire more people and expand into new cities.

    Finally we will launch the product across every channel.
    """

    private func sampleTokens() async -> ScriptTokens {
        let formatter = ScriptFormatter()
        let result = await formatter.format(Self.sampleScript)
        return result.tokens
    }

    private struct Drive {
        var snapshot = MatcherSnapshot()
        let script: ScriptTokens
        let config: MatcherConfiguration
        @discardableResult
        mutating func advance(_ transcript: String) -> MatcherAdvancement {
            let words = ScriptMatcher.tokenizeSpoken(transcript, config: config)
            let out = ScriptMatcher.advance(snapshot: snapshot, script: script, spoken: words, config: config)
            snapshot = out.snapshot
            return out.result
        }
    }

    // MARK: Normal reading

    @Test("Big batch reading reaches the right token")
    func bigBatchReading() async {
        var drive = Drive(script: await sampleTokens(), config: .default)
        let result = drive.advance("We need to make sales now and grow the business.")
        #expect(drive.snapshot.cursor == 10)
        #expect(result.missStreak == 0)
    }

    @Test("Word-by-word reading reaches the same place")
    func wordByWordReading() async {
        var drive = Drive(script: await sampleTokens(), config: .default)
        var partial = ""
        for word in ["We", "need", "to", "make", "sales", "now", "and", "grow", "the", "business"] {
            partial.append(" \(word)")
            drive.advance(partial)
        }
        #expect(drive.snapshot.cursor == 10)
        #expect(drive.snapshot.missStreak == 0)
    }

    @Test("Long pause with no new words holds position")
    func longPauseHolds() async {
        var drive = Drive(script: await sampleTokens(), config: .default)
        drive.advance("We need to make sales now and grow the business.")
        let result = drive.advance("We need to make sales now and grow the business.")
        #expect(result.kind == .hold)
        #expect(drive.snapshot.cursor == 10)
    }

    // MARK: Hysteresis / improvisation

    @Test("Improvisation freezes position instead of jumping")
    func improvisationFreezes() async {
        var drive = Drive(script: await sampleTokens(), config: .default)
        let result = drive.advance("um hmm okay so anyway let me just talk freely")
        #expect(result.kind == .hold)
        #expect(drive.snapshot.cursor == 0)
        #expect(drive.snapshot.missStreak >= 4)
    }

    @Test("Repeated single word does not yank the cursor backward")
    func repeatedSingleWordDoesNotJump() async {
        var drive = Drive(script: await sampleTokens(), config: .default)
        drive.advance("We need to make sales now and grow the business.")
        let result = drive.advance("We need to make sales now and grow the business. business business")
        #expect(result.kind == .hold)
        #expect(drive.snapshot.cursor == 10)
        #expect(drive.snapshot.missStreak == 2)
    }

    // MARK: Skip, backtrack, re-anchor

    @Test("Skip ahead re-anchors forward after a miss streak")
    func skipAheadReanchors() async {
        var drive = Drive(script: await sampleTokens(), config: .default)
        let result = drive.advance("Next we will hire more people and expand into new cities")
        #expect(result.kind == .reanchor)
        #expect(drive.snapshot.cursor == 31)
    }

    @Test("Reading backward re-anchors to the repeated section")
    func backtrackReanchors() async {
        var drive = Drive(script: await sampleTokens(), config: .default)
        let full = Self.sampleScript.replacingOccurrences(of: "\n", with: " ")
        drive.advance(full)
        #expect(drive.snapshot.cursor == 40)
        let result = drive.advance("\(full) Sales are up this quarter so the plan is working.")
        #expect(result.kind == .reanchor)
        #expect(drive.snapshot.cursor == 20)
    }

    // MARK: Bigram gating

    @Test("A lone far word does not jump without confirmation")
    func loneFarWordDoesNotJump() async {
        var drive = Drive(script: await sampleTokens(), config: .default)
        drive.advance("plan")
        #expect(drive.snapshot.cursor == 0)
        #expect(drive.snapshot.missStreak == 1)
    }

    @Test("Bigram confirmation allows a far jump")
    func bigramConfirmedFarJump() async {
        var drive = Drive(script: await sampleTokens(), config: .default)
        let result = drive.advance("so plan")
        #expect(result.kind == .far)
        #expect(drive.snapshot.cursor == 18)
    }

    // MARK: Normalization and fuzzy match

    @Test("Homophones normalize on both sides")
    func homophonesNormalize() async {
        #expect(TextNormalizer.normalize("Their") == "there")
        #expect(TextNormalizer.normalize("two") == "to")
        #expect(TextNormalizer.normalize("too") == "to")
        #expect(TextNormalizer.normalize("you're") == "youre")

        let formatter = ScriptFormatter()
        let tokens = await formatter.format("Their plan will work too.").tokens
        #expect(tokens.count == 5)
        #expect(tokens.items[0].norm == "there")
        #expect(tokens.items[4].norm == "to")

        var drive = Drive(script: tokens, config: .default)
        drive.advance("There plan will work to.")
        #expect(drive.snapshot.cursor == tokens.count)
    }

    @Test("Fuzzy matching tolerates one edit in longer words")
    func fuzzyLongWords() async {
        #expect(ScriptMatcher.wordsMatch("quickly", "quicky"))
        #expect(ScriptMatcher.wordsMatch("quickly", "slowly") == false)
        #expect(ScriptMatcher.wordsMatch("to", "to"))
        #expect(ScriptMatcher.wordsMatch("is", "us") == false)

        let formatter = ScriptFormatter()
        let tokens = await formatter.format("expand into new cities quickly").tokens
        var drive = Drive(script: tokens, config: .default)
        drive.advance("expand into new cities quicky")
        #expect(drive.snapshot.cursor == tokens.count)
    }

    @Test("Partial interim words do not break matching")
    func partialInterimWords() async {
        var drive = Drive(script: await sampleTokens(), config: .default)
        let partial = drive.advance("Nex")
        #expect(partial.kind == .hold)
        #expect(drive.snapshot.cursor == 0)
        drive.advance("we need to make sales")
        #expect(drive.snapshot.cursor == 5)
    }

    // MARK: ASR revisions

    @Test("Shrinking transcript rebases without reprocessing")
    func shrinkingTranscriptRebases() async {
        var drive = Drive(script: await sampleTokens(), config: .default)
        drive.advance("We need to make sales now and grow the business.")
        let result = drive.advance("we need")
        #expect(result.kind == .rebased)
        #expect(drive.snapshot.cursor == 10)
        #expect(drive.snapshot.consumedSpokenCount == 2)
    }

    // MARK: Primitives

    @Test("ScriptTokens maps flat tokens to blocks")
    func scriptTokensBlockMapping() async {
        let tokens = await sampleTokens()
        #expect(tokens.count == 40)
        #expect(tokens.blockIndex(forToken: 0) == 0)
        #expect(tokens.blockIndex(forToken: 9) == 0)
        #expect(tokens.blockIndex(forToken: 10) == 1)
        #expect(tokens.blockIndex(forToken: 30) == 2)
        #expect(tokens.blockIndex(forToken: 39) == 3)
        #expect(tokens.wordIndex(forToken: 15, inBlock: 1) == 5)
        #expect(tokens.tokenIndex(block: 2, word: 0) == 20)
    }

    @Test("Edit distance admits single substitutions")
    func editDistance() {
        #expect(ScriptMatcher.editDistanceAtMost("cat", "cat", limit: 1))
        #expect(ScriptMatcher.editDistanceAtMost("cat", "bat", limit: 1))
        #expect(ScriptMatcher.editDistanceAtMost("cat", "dog", limit: 1) == false)
        #expect(ScriptMatcher.editDistanceAtMost("hello", "hello world", limit: 1) == false)
    }
}

@Suite("Latency Recorder")
struct LatencyRecorderTests {
    @Test("Computes per-segment mean and percentiles for one cycle")
    func completeCycle() async {
        let recorder = LatencyRecorder()
        let cycle = await recorder.beginCycle()
        await recorder.mark(.asrReceived, forCycle: cycle, at: 100)
        await recorder.mark(.matcherStarted, forCycle: cycle, at: 120)
        await recorder.mark(.matcherFinished, forCycle: cycle, at: 140)
        await recorder.mark(.positionEmitted, forCycle: cycle, at: 150)
        _ = await recorder.completePendingCycle(uiReceivedAt: 190)

        let summary = await recorder.summary()
        #expect(summary.completedCycles == 1)
        #expect(summary.asrToMatcher?.p50 == 20)
        #expect(summary.matcherDuration?.p50 == 20)
        #expect(summary.matcherToEmit?.p50 == 10)
        #expect(summary.emitToUI?.p50 == 40)
        #expect(summary.total?.p50 == 90)
    }

    @Test("A new cycle supersedes an incomplete previous one")
    func supersedeIncompleteCycle() async {
        let recorder = LatencyRecorder()
        let stale = await recorder.beginCycle()
        await recorder.mark(.asrReceived, forCycle: stale)
        _ = await recorder.beginCycle()
        let summary = await recorder.summary()
        #expect(summary.completedCycles == 0)
    }

    @Test("Marks for unknown cycles are ignored")
    func staleCycleIgnored() async {
        let recorder = LatencyRecorder()
        await recorder.mark(.asrReceived, forCycle: 999)
        let sample = await recorder.completePendingCycle(uiReceivedAt: 60)
        #expect(sample == nil)
    }

    @Test("Rolls samples beyond the cap")
    func rollsSamples() async {
        let recorder = LatencyRecorder(maxSamples: 3)
        for i in 1...5 {
            let cycle = await recorder.beginCycle()
            await recorder.mark(.asrReceived, forCycle: cycle, at: Double(i))
            _ = await recorder.completePendingCycle(uiReceivedAt: Double(i) + 10)
        }
        let summary = await recorder.summary()
        #expect(summary.completedCycles == 3)
    }
}

@Suite("Tracking Envelope")
struct TrackingEnvelopeTests {
    private func tokens() async -> ScriptTokens {
        let formatter = ScriptFormatter()
        return await formatter.format(ScriptMatcherTests.sampleScript).tokens
    }

    @Test("Climbs tracking → uncertain → degraded as silence grows, recovers on speech")
    func degradedLadderAndRecovery() async {
        let clock = TestClock()
        let engine = TrackingEngine(clock: { clock.now })
        await engine.configure(script: await tokens())
        await engine.start()

        await engine.processASRResult(ASRResult(transcript: "We need to make sales"))
        var state = await engine.getCurrentState()
        #expect(state.status == .tracking)

        clock.set(0.4)
        await engine.processASRResult(ASRResult(transcript: "We need to make sales um hmm"))
        state = await engine.getCurrentState()
        #expect(state.status == .uncertain)

        clock.set(3.5)
        await engine.processASRResult(ASRResult(transcript: "We need to make sales um hmm blip"))
        state = await engine.getCurrentState()
        #expect(state.status == .degraded(reason: .asrUnreliable))

        // A confirmed match pulls the engine straight back to tracking. The
        // tail-heavy re-anchor may land past the re-read section, so only the
        // forward-monotonic recovery matters here.
        clock.set(4.0)
        await engine.processASRResult(ASRResult(
            transcript: "We need to make sales um hmm blip Next we will hire more people and expand into new cities"
        ))
        state = await engine.getCurrentState()
        #expect(state.status == .tracking)
        #expect(state.position.blockIndex >= 2)
    }

    @Test("Degraded freezes position; manual jump recovers to tracking")
    func degradedFreezeAndManualRecovery() async {
        let clock = TestClock()
        let engine = TrackingEngine(clock: { clock.now })
        await engine.configure(script: await tokens())
        await engine.start()
        await engine.processASRResult(ASRResult(transcript: "We need to make sales"))
        clock.set(3.5)
        await engine.processASRResult(ASRResult(transcript: "We need to make sales nonsense nonsense"))
        var state = await engine.getCurrentState()
        #expect(state.status == .degraded(reason: .asrUnreliable))
        #expect(state.position.blockIndex == 0)

        await engine.jumpTo(position: TrackingPosition(blockIndex: 2, wordIndex: 0))
        state = await engine.getCurrentState()
        #expect(state.status == .tracking)
        #expect(state.position.blockIndex == 2)
    }

    @Test("Custom envelope can degrade faster")
    func customEnvelope() async {
        let clock = TestClock()
        let engine = TrackingEngine(
            clock: { clock.now },
            envelope: TrackingEnvelopeConfig(uncertainGrace: 0.1, degradedAfter: 1.0)
        )
        await engine.configure(script: await tokens())
        await engine.start()
        await engine.processASRResult(ASRResult(transcript: "We need to make sales"))
        clock.set(0.2)
        await engine.processASRResult(ASRResult(transcript: "We need to make sales blip"))
        var state = await engine.getCurrentState()
        #expect(state.status == .uncertain)
        clock.set(1.2)
        await engine.processASRResult(ASRResult(transcript: "We need to make sales blip bloop"))
        state = await engine.getCurrentState()
        #expect(state.status == .degraded(reason: .asrUnreliable))
    }
}

@Suite("Recovery Escalation")
struct RecoveryEscalationTests {
    private func tokens() async -> ScriptTokens {
        let formatter = ScriptFormatter()
        return await formatter.format(ScriptMatcherTests.sampleScript).tokens
    }

    @Test("Repeated failed recovery escalates to sticky manualFallback; manual jump re-arms tracking")
    func escalatesToManualFallbackThenRecovers() async {
        let clock = TestClock()
        let collector = CallbackCollector()
        let engine = TrackingEngine(clock: { clock.now })
        await engine.configure(script: await tokens())
        await engine.setCallbacks(
            onStatusChange: { collector.record(status: $0) },
            onPositionUpdate: { collector.record(position: $0) }
        )
        await engine.start()

        await engine.processASRResult(ASRResult(transcript: "We need to make sales"))
        var state = await engine.getCurrentState()
        #expect(state.status == .tracking)
        let frozenPosition = state.position

        // ASR goes unreliable: unmatched gibberish, well past degradedAfter.
        clock.set(4.0)
        var accumulated = "We need to make sales xylophone glorp fizzbin"
        await engine.processASRResult(ASRResult(transcript: accumulated))
        state = await engine.getCurrentState()
        #expect(state.status == .degraded(reason: .asrUnreliable))
        #expect(state.position == frozenPosition)

        // Three more failed automatic-recovery attempts while still degraded
        // (RecoveryManager's failure/attempt threshold is 3).
        for suffix in [" quonk", " zavtu", " mendrasco"] {
            accumulated += suffix
            await engine.processASRResult(ASRResult(transcript: accumulated))
        }

        state = await engine.getCurrentState()
        #expect(state.status == .manualFallback)
        #expect(state.position == frozenPosition, "position must not move during degraded/escalation")

        // No automatic jumps after escalation: even a clean confirmed match
        // is ignored while manualFallback is sticky.
        await engine.processASRResult(ASRResult(transcript: "Next we will hire more people"))
        state = await engine.getCurrentState()
        #expect(state.status == .manualFallback, "no automatic recovery once escalated")
        #expect(state.position == frozenPosition)

        // User taps the "Next we will hire..." block to manually re-sync.
        let manualPosition = TrackingPosition(blockIndex: 2, wordIndex: 0)
        await engine.jumpTo(position: manualPosition)
        state = await engine.getCurrentState()
        #expect(state.status == .tracking, "matcher re-arms and tracking resumes")
        #expect(state.position == manualPosition)

        // Speech continues from the manually selected token: the matcher
        // backlog accumulated during the degraded stretch is discarded, not
        // replayed, so this new batch is matched fresh from the jump point.
        accumulated += " Next we will hire more people and expand into new cities."
        await engine.processASRResult(ASRResult(transcript: accumulated))
        state = await engine.getCurrentState()
        #expect(state.status == .tracking)
        #expect(state.position.blockIndex == 2)

        // Recovery counters reset after the manual jump: a single fresh
        // failure afterwards must land back on plain `.degraded`, not jump
        // straight to `.manualFallback` from stale attempt counts.
        clock.set(20.0)
        accumulated += " plonk"
        await engine.processASRResult(ASRResult(transcript: accumulated))
        state = await engine.getCurrentState()
        #expect(state.status == .degraded(reason: .asrUnreliable))

        let statuses = collector.statuses
        #expect(statuses.contains { $0 == .manualFallback })
    }

    @Test("Recovery success before escalation resets counters; RecoveryManager isn't overly aggressive")
    func recoverySuccessBeforeEscalationResets() async {
        let clock = TestClock()
        let engine = TrackingEngine(clock: { clock.now })
        await engine.configure(script: await tokens())
        await engine.start()

        await engine.processASRResult(ASRResult(transcript: "We need to make sales"))
        var state = await engine.getCurrentState()
        #expect(state.status == .tracking)

        // One brief degraded episode, well short of the escalation threshold.
        clock.set(4.0)
        await engine.processASRResult(ASRResult(transcript: "We need to make sales xylophone glorp"))
        state = await engine.getCurrentState()
        #expect(state.status == .degraded(reason: .asrUnreliable))

        // ASR recovers on its own — automatic recovery, no manual jump needed.
        await engine.processASRResult(ASRResult(
            transcript: "We need to make sales xylophone glorp Sales are up this quarter"
        ))
        state = await engine.getCurrentState()
        #expect(state.status == .tracking)
        #expect(state.position.blockIndex == 1)

        // A fresh degraded episode afterwards must go through the full ladder
        // again: RecoveryManager must not have carried failures across the
        // earlier successful automatic recovery.
        clock.set(8.0)
        await engine.processASRResult(ASRResult(
            transcript: "We need to make sales xylophone glorp Sales are up this quarter plonk"
        ))
        state = await engine.getCurrentState()
        #expect(state.status == .degraded(reason: .asrUnreliable), "a single fresh failure should not jump straight to manualFallback")
    }
}

@Suite("Telemetry Events")
struct TelemetryEventTests {
    private func tokens() async -> ScriptTokens {
        let formatter = ScriptFormatter()
        return await formatter.format(ScriptMatcherTests.sampleScript).tokens
    }

    private func makeEngine(clock: @escaping @Sendable () -> Date) async -> (TrackingEngine, CallbackCollector) {
        let collector = CallbackCollector()
        let engine = TrackingEngine(clock: clock)
        await engine.configure(script: await tokens())
        await engine.setCallbacks(
            onStatusChange: { collector.record(status: $0) },
            onPositionUpdate: { collector.record(position: $0) },
            onEvent: { collector.record(event: $0) }
        )
        return (engine, collector)
    }

    @Test("Pause and resume emit their own events")
    func pauseResumeEvents() async {
        let (engine, collector) = await makeEngine(clock: { .now })
        await engine.start()
        await engine.pause()
        await engine.resume()

        let types = collector.events.map(\.type)
        #expect(types.contains(.pause))
        #expect(types.contains(.resume))
    }

    @Test("Manual jump emits a correction event")
    func manualJumpEvent() async {
        let (engine, collector) = await makeEngine(clock: { .now })
        await engine.start()
        await engine.jumpTo(position: TrackingPosition(blockIndex: 2, wordIndex: 0))

        #expect(collector.events.contains { $0.type == .correction })
    }

    @Test("A forward global re-anchor emits a skip event, not a plain position update")
    func forwardReanchorEmitsSkip() async {
        let (engine, collector) = await makeEngine(clock: { .now })
        await engine.start()

        // Fresh cursor at block 0; jumping straight into block 2's text forces
        // enough misses to trigger a global forward re-anchor (mirrors
        // `ScriptMatcherTests.skipAheadReanchors`).
        await engine.processASRResult(ASRResult(
            transcript: "Next we will hire more people and expand into new cities"
        ))

        let state = await engine.getCurrentState()
        #expect(state.position.blockIndex == 2)
        #expect(collector.events.contains { $0.type == .skip })
        #expect(!collector.events.contains { $0.type == .backtrack })
    }

    @Test("A backward global re-anchor emits a backtrack event")
    func backwardReanchorEmitsBacktrack() async {
        let (engine, collector) = await makeEngine(clock: { .now })
        await engine.start()

        let full = ScriptMatcherTests.sampleScript.replacingOccurrences(of: "\n", with: " ")
        await engine.processASRResult(ASRResult(transcript: full))
        var state = await engine.getCurrentState()
        #expect(state.position.blockIndex == 3)

        // Repeating block 1's sentence forces enough misses (nothing forward
        // matches) to trigger a global backward re-anchor (mirrors
        // `ScriptMatcherTests.backtrackReanchors`).
        await engine.processASRResult(ASRResult(
            transcript: "\(full) Sales are up this quarter so the plan is working."
        ))
        state = await engine.getCurrentState()
        #expect(state.position.blockIndex == 1)
        #expect(collector.events.contains { $0.type == .backtrack })
    }

    @Test("Entering degraded emits degrade; recovering afterward emits recover")
    func degradeAndRecoverEvents() async {
        let clock = TestClock()
        let (engine, collector) = await makeEngine(clock: { clock.now })
        await engine.start()

        await engine.processASRResult(ASRResult(transcript: "We need to make sales"))
        clock.set(4.0)
        await engine.processASRResult(ASRResult(transcript: "We need to make sales xylophone glorp"))
        var state = await engine.getCurrentState()
        #expect(state.status == .degraded(reason: .asrUnreliable))
        #expect(collector.events.contains { $0.type == .degrade })
        #expect(!collector.events.contains { $0.type == .recover })

        await engine.processASRResult(ASRResult(
            transcript: "We need to make sales xylophone glorp Sales are up this quarter"
        ))
        state = await engine.getCurrentState()
        #expect(state.status == .tracking)
        #expect(collector.events.contains { $0.type == .recover })
    }

    @Test("Recovering from a routine uncertain blip does not emit recover")
    func routineUncertainRecoveryDoesNotEmitRecover() async {
        let clock = TestClock()
        let (engine, collector) = await makeEngine(clock: { clock.now })
        await engine.start()

        await engine.processASRResult(ASRResult(transcript: "We need to make sales"))
        clock.set(0.4)
        await engine.processASRResult(ASRResult(transcript: "We need to make sales um hmm"))
        var state = await engine.getCurrentState()
        #expect(state.status == .uncertain)

        await engine.processASRResult(ASRResult(
            transcript: "We need to make sales um hmm now and grow the business"
        ))
        state = await engine.getCurrentState()
        #expect(state.status == .tracking)
        #expect(!collector.events.contains { $0.type == .recover })
    }
}

@Suite("Messy Take Behavior")
struct MessyTakeBehaviorTests {
    static let script = ScriptMatcherTests.sampleScript

    @Test("Human-like messy take never loses the position and recovers from a stall")
    func messyTake() async {
        let formatter = ScriptFormatter()
        let tokens = await formatter.format(Self.script).tokens
        let clock = TestClock()
        let collector = CallbackCollector()
        let engine = TrackingEngine(clock: { clock.now })
        await engine.configure(script: tokens)
        await engine.setCallbacks(
            onStatusChange: { collector.record(status: $0) },
            onPositionUpdate: { collector.record(position: $0) }
        )
        await engine.start()

        var acc = "We need to make sales"
        let steps: [(TimeInterval, String)] = [
            (0.0, " now and grow the business."),
            (0.6, " Sales are up this quarter"),
            (1.2, " so the plan is working."),
            (2.0, " Next we will hire more people"),
            (2.6, " and expand into new cities."),
            (6.0, " um hmm nonsense blabber filler words"),
            (9.0, " Sales are up this quarter so the plan is working."),
            (10.4, " and grow the business. Finally we will launch the product across every channel."),
        ]
        for (time, suffix) in steps {
            clock.set(time)
            acc += suffix
            await engine.processASRResult(ASRResult(transcript: acc))
        }

        let final = await engine.getCurrentState()
        #expect(final.status == .tracking)
        #expect(final.position.blockIndex == 3)
        #expect(collector.blocks.allSatisfy { $0 >= 0 && $0 <= 3 })
        let statuses = collector.statuses
        #expect(statuses.contains { if case .degraded = $0 { return true } else { return false } })
        #expect(statuses.contains { if case .recovering = $0 { return true } else { return false } })
    }
}

@Suite("Repeated Context Stress")
struct RepeatedContextStressTests {
    /// Five identical blocks; boundary mid-words every 4 tokens.
    static let script = """
    We need momentum now.

    We need momentum now.

    We need momentum now.

    We need momentum now.

    We need momentum now.
    """

    private func tokens() async -> ScriptTokens {
        let formatter = ScriptFormatter()
        return await formatter.format(Self.script).tokens
    }

    private struct Drive {
        var snapshot = MatcherSnapshot()
        let script: ScriptTokens
        let config: MatcherConfiguration
        @discardableResult
        mutating func advance(_ transcript: String) -> MatcherAdvancement {
            let words = ScriptMatcher.tokenizeSpoken(transcript, config: config)
            let out = ScriptMatcher.advance(snapshot: snapshot, script: script, spoken: words, config: config)
            snapshot = out.snapshot
            return out.result
        }
    }

    @Test("A single stray word of a repeated phrase does not leap into the next occurrence")
    func singleStrayWordDoesNotLeap() async {
        var drive = Drive(script: await tokens(), config: .default)
        drive.advance("We need momentum now.")
        #expect(drive.snapshot.cursor == 4)

        let result = drive.advance("We need momentum now. momentum")
        #expect(result.kind == .hold)
        #expect(drive.snapshot.cursor == 4)
        #expect(drive.snapshot.missStreak == 1)
    }

    @Test("A two-word repeat can leap but lands on a valid occurrence and stays monotonic")
    func twoWordRepeatLeapsOnceThenFlows() async {
        var drive = Drive(script: await tokens(), config: .default)
        drive.advance("We need momentum now.")
        #expect(drive.snapshot.cursor == 4)

        let leap = drive.advance("We need momentum now. momentum now")
        #expect(leap.kind == .far)
        #expect(drive.snapshot.cursor == 8)

        // Cumulative transcript: a full replay of the phrase advances exactly
        // one occurrence (8 → 12), staying monotonic.
        let onward = drive.advance("We need momentum now. momentum now We need momentum now")
        #expect(drive.snapshot.cursor == 12)
        #expect(onward.kind != .hold)
    }

    @Test("After a leap, a single stray word does not cause oscillation")
    func noOscillationAfterLeap() async {
        var drive = Drive(script: await tokens(), config: .default)
        drive.advance("We need momentum now.")
        drive.advance("We need momentum now. momentum now")
        #expect(drive.snapshot.cursor == 8)

        let result = drive.advance("We need momentum now. momentum now We need momentum now. momentum")
        #expect(drive.snapshot.cursor == 12)
        #expect(drive.snapshot.missStreak == 1)
    }
}
