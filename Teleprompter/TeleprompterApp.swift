import SwiftUI
import TeleprompterCore

@main
struct TeleprompterApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        .defaultSize(width: 1200, height: 800)

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(appState)
        }
        #endif
    }
}

@Observable
@MainActor
final class AppState: @unchecked Sendable {
    var currentScript: Script?
    var formattedScript: FormattedScript?
    var isRecording = false
    var countdownRemaining: Int?
    var trackingStatus: TrackingStatus = .paused
    var trackingPosition: TrackingPosition = TrackingPosition()

    let trackingEngine = TrackingEngine()
    let formatter = ScriptFormatter()
    let telemetry = RecordingTelemetry()
    let recognizer: SpeechRecognizerProtocol

    init(recognizer: SpeechRecognizerProtocol? = nil) {
        self.recognizer = recognizer ?? SFSpeechRecognizerService()
    }

    func loadScript(rawText: String) async {
        let script = Script(rawContent: rawText)
        currentScript = script
        formattedScript = await formatter.format(rawText)
    }

    // MARK: - Recording

    func beginRecording(withCountdown duration: Int, at position: TrackingPosition = TrackingPosition()) async {
        guard !isRecording && countdownRemaining == nil else { return }

        if duration > 0 {
            await runCountdown(duration)
        }
        await startRecording(at: position)
    }

    private func runCountdown(_ duration: Int) async {
        countdownRemaining = duration
        while let remaining = countdownRemaining, remaining > 0 {
            try? await Task.sleep(for: .seconds(1))
            countdownRemaining = remaining - 1
        }
        countdownRemaining = nil
    }

    func startRecording(at position: TrackingPosition = TrackingPosition()) async {
        await registerTrackingCallbacks()

        let granted = await recognizer.requestPermission()
        guard granted else {
            trackingStatus = .degraded(reason: .asrUnavailable)
            return
        }

        recognizer.onResult = { [weak self] result in
            guard let self else { return }
            Task { await self.trackingEngine.processASRResult(result) }
        }

        do {
            try await recognizer.start()
            await trackingEngine.start(from: position)
            isRecording = true
        } catch {
            trackingStatus = .degraded(reason: .asrUnavailable)
        }
    }

    func stopRecording() async {
        await recognizer.stop()
        await trackingEngine.pause()
        isRecording = false
        countdownRemaining = nil
    }

    // MARK: - Position

    func jumpTo(position: TrackingPosition) async {
        await trackingEngine.jumpTo(position: position)
    }

    func adjustPosition(delta: Int) async {
        await trackingEngine.adjustPosition(delta: delta)
    }

    func recenter() async {
        await trackingEngine.recenter()
    }

    // MARK: - Callbacks

    private func registerTrackingCallbacks() async {
        await trackingEngine.setCallbacks(
            onStatusChange: { [weak self] status in
                Task { @MainActor in
                    self?.trackingStatus = status
                }
            },
            onPositionUpdate: { [weak self] position in
                Task { @MainActor in
                    self?.trackingPosition = position
                }
            }
        )
    }
}
