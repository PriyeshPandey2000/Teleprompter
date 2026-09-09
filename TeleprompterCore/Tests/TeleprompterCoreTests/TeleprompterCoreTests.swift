import Testing
@testable import TeleprompterCore

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
    @Test("Smooths position with small delta")
    func smoothSmallDelta() async {
        let engine = PositionEngine()
        let current = TrackingPosition(blockIndex: 10, wordIndex: 0)
        let candidate = TrackingPosition(blockIndex: 11, wordIndex: 0, confidence: 0.8)
        let smoothed = await engine.smoothPosition(current: current, candidate: candidate, velocity: 0)
        #expect(smoothed.blockIndex >= 10 && smoothed.blockIndex <= 11)
    }

    @Test("Passes through large delta")
    func smoothLargeDelta() async {
        let engine = PositionEngine()
        let current = TrackingPosition(blockIndex: 10, wordIndex: 0)
        let candidate = TrackingPosition(blockIndex: 20, wordIndex: 0, confidence: 0.8)
        let smoothed = await engine.smoothPosition(current: current, candidate: candidate, velocity: 0)
        #expect(smoothed.blockIndex == 20)
    }
}
