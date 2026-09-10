import Testing
import TeleprompterCore
@testable import Teleprompter

// MARK: - Mock

@MainActor
final class MockSpeechRecognizer: SpeechRecognizerProtocol {
    var state: ASRState = .idle
    var onResult: ((ASRResult) -> Void)?
    var onStateChange: ((ASRState) -> Void)?
    var permissionGranted = true
    var startShouldFail = false
    var resultToEmit: ASRResult?

    func requestPermission() async -> Bool { permissionGranted }

    func start() async throws {
        if startShouldFail { throw ASRError.recognizerUnavailable }
        state = .listening
    }

    func stop() async {
        state = .idle
    }
}

// MARK: - AppState Recording Flow

@MainActor
@Suite("AppState Recording Flow")
struct AppStateTests {
    @Test("startRecording activates tracking and recording state")
    func startRecordingActivatesTracking() async throws {
        let mock = MockSpeechRecognizer()
        let appState = AppState(recognizer: mock)

        #expect(mock.state == .idle)
        await appState.startRecording()

        #expect(appState.isRecording == true)
        #expect(appState.trackingStatus == .tracking)
        try await Task.sleep(for: .milliseconds(50))
        #expect(appState.isRecording == true)
    }

    @Test("permission denial degrades gracefully")
    func permissionDenialDegrades() async {
        let mock = MockSpeechRecognizer()
        mock.permissionGranted = false
        let appState = AppState(recognizer: mock)

        await appState.startRecording()

        #expect(appState.isRecording == false)
        if case .degraded = appState.trackingStatus {
            // expected
        } else {
            Issue.record("Expected degraded state on permission denial")
        }
    }

    @Test("recognizer failure degrades gracefully")
    func recognizerFailureDegrades() async {
        let mock = MockSpeechRecognizer()
        mock.startShouldFail = true
        let appState = AppState(recognizer: mock)

        await appState.startRecording()

        #expect(appState.isRecording == false)
        if case .degraded = appState.trackingStatus {
            // expected
        } else {
            Issue.record("Expected degraded state on recognizer failure")
        }
    }

    @Test("stopRecording resets state")
    func stopRecordingResets() async {
        let mock = MockSpeechRecognizer()
        let appState = AppState(recognizer: mock)

        await appState.startRecording()
        await appState.stopRecording()

        #expect(appState.isRecording == false)
        #expect(appState.trackingStatus == .paused)
        #expect(mock.state == .idle)
    }

    @Test("ASR results flow into the tracking engine")
    func asrResultsFlowIntoEngine() async throws {
        let mock = MockSpeechRecognizer()
        let appState = AppState(recognizer: mock)
        await appState.startRecording()

        #expect(mock.onResult != nil)
        mock.onResult?(ASRResult(transcript: "Hello world this is a test script", isFinal: false, confidence: 0.9))
        try await Task.sleep(for: .milliseconds(100))

        // Engine consumed the result without leaving the tracking state
        #expect(appState.trackingStatus == .tracking)
    }

    @Test("countdown completes before recording starts")
    func countdownCompletesBeforeStart() async {
        let mock = MockSpeechRecognizer()
        let appState = AppState(recognizer: mock)

        await appState.beginRecording(withCountdown: 1)
        #expect(appState.isRecording == true)
    }

    @Test("A start-point tap before recording sticks, and doesn't show as tracking yet")
    func startPointSelectionSticks() async {
        let mock = MockSpeechRecognizer()
        let appState = AppState(recognizer: mock)
        await appState.loadScript(rawText: "First paragraph here.\n\nSecond paragraph here.\n\nThird paragraph here.")

        let anchor = TrackingPosition(blockIndex: 2, wordIndex: 0)
        await appState.jumpTo(position: anchor)

        #expect(appState.trackingPosition.blockIndex == 2)
        #expect(appState.trackingStatus == .paused, "a pre-recording tap shouldn't show as actively tracking")

        await appState.startRecording()

        #expect(appState.isRecording == true)
        #expect(appState.trackingStatus == .tracking)
        #expect(appState.trackingPosition.blockIndex == 2, "recording should start from the tapped anchor, not block 0")
    }

    @Test("Recording sessions are captured in telemetry")
    func telemetryCapturesSession() async throws {
        let mock = MockSpeechRecognizer()
        let appState = AppState(recognizer: mock)
        await appState.loadScript(rawText: "First paragraph here.\n\nSecond paragraph here.")

        await appState.startRecording()
        mock.onResult?(ASRResult(transcript: "First paragraph here", isFinal: false, confidence: 0.9))
        try await Task.sleep(for: .milliseconds(100))
        await appState.stopRecording()

        let scriptID = try #require(appState.currentScript?.id)
        let sessions = await appState.telemetry.getSessions(for: scriptID)
        let session = try #require(sessions.first)

        #expect(sessions.count == 1)
        #expect(session.takeNumber == 1)
        #expect(session.endTime != nil)
        #expect(!session.events.isEmpty, "position/status events from the take should be recorded")
    }
}

// MARK: - Script Loading

@MainActor
@Suite("Script Loading")
struct ScriptLoadingTests {
    @Test("loadScript formats raw text")
    func loadScriptFormats() async {
        let appState = AppState(recognizer: MockSpeechRecognizer())
        await appState.loadScript(rawText: "Title:\nThis is a paragraph with enough words.")

        #expect(appState.currentScript != nil)
        #expect(appState.formattedScript != nil)
        #expect(appState.formattedScript?.blocks.count == 2)
    }
}