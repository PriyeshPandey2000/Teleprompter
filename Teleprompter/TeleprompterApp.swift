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
        if let formattedScript {
            await trackingEngine.configure(script: formattedScript.tokens)
        }
    }

    // MARK: - Recording

    /// `position` defaults to `nil`, meaning "wherever `trackingPosition`
    /// currently sits" — which is exactly where a pre-recording tap (see
    /// `jumpTo`) left it. This is what makes start-point selection stick: a
    /// tap before pressing Start updates `trackingPosition`, and recording
    /// then just starts from the same anchor rather than always block 0.
    func beginRecording(withCountdown duration: Int, at position: TrackingPosition? = nil) async {
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

    func startRecording(at position: TrackingPosition? = nil) async {
        await registerTrackingCallbacksIfNeeded()
        let startPosition = position ?? trackingPosition

        let granted = await recognizer.requestPermission()
        guard granted else {
            trackingStatus = .degraded(reason: .asrUnavailable)
            return
        }

        recognizer.onResult = { [weak self] result in
            guard let self else { return }
            Task {
                let recorder = await self.trackingEngine.latencyRecorder
                let cycle = await recorder.beginCycle()
                await recorder.mark(.asrReceived, forCycle: cycle)
                await self.trackingEngine.processASRResult(result, latencyCycle: cycle)
                await recorder.completePendingCycle(uiReceivedAt: Date().timeIntervalSinceReferenceDate)
            }
        }

        // TrackingEngine only re-evaluates tracking → uncertain → degraded
        // from within `processASRResult` — if ASR silently keeps failing
        // (on-device model not downloaded, no speech detected, recognizer
        // errors), `onResult` never fires and nothing ever tells the engine.
        // Surface ASR-level failure here so it's visible instead of the
        // status just sitting frozen on whatever it last was.
        recognizer.onStateChange = { [weak self] state in
            guard let self else { return }
            if case .unavailable = state {
                trackingStatus = .degraded(reason: .asrUnreliable)
            }
        }

        do {
            try await recognizer.start()
            // Flip `isRecording` before starting the engine: `trackingEngine
            // .start(from:)` fires `onStatusChange` synchronously-ish, and
            // that callback (below) only forwards real status to the UI
            // while `isRecording` is true — flipping it after would make the
            // very first `.tracking` status get swallowed as "not recording
            // yet".
            isRecording = true
            if let scriptID = currentScript?.id {
                let takeNumber = await telemetry.getSessions(for: scriptID).count + 1
                _ = await telemetry.startSession(scriptID: scriptID, takeNumber: takeNumber)
            }
            await trackingEngine.start(from: startPosition)
        } catch {
            trackingStatus = .degraded(reason: .asrUnavailable)
        }
    }

    func stopRecording() async {
        await recognizer.stop()
        await trackingEngine.pause()
        _ = await telemetry.endSession()
        isRecording = false
        countdownRemaining = nil
    }

    // MARK: - Position

    /// Also doubles as start-point selection: tapping the script before
    /// recording begins calls this (see `TeleprompterView`'s tap gesture),
    /// which is what lets `beginRecording`/`startRecording` pick it up as
    /// the anchor. See the `onStatusChange` callback below for how the
    /// status indicator avoids showing "tracking" for this pre-recording case.
    func jumpTo(position: TrackingPosition) async {
        await registerTrackingCallbacksIfNeeded()
        await trackingEngine.jumpTo(position: position)
    }

    func adjustPosition(delta: Int) async {
        await registerTrackingCallbacksIfNeeded()
        await trackingEngine.adjustPosition(delta: delta)
    }

    func recenter() async {
        await registerTrackingCallbacksIfNeeded()
        await trackingEngine.recenter()
    }

    func latencySummary() async -> LatencySummary {
        await trackingEngine.latencyRecorder.summary()
    }

    // MARK: - Callbacks

    private var callbacksRegistered = false

    /// Idempotent by design (a `Bool` guard, not just accidentally-harmless
    /// repeat assignment) so every entry point that can produce an engine
    /// callback — `jumpTo`, `adjustPosition`, `recenter`, `startRecording` —
    /// can call this unconditionally without worrying about registration
    /// order or timing races.
    private func registerTrackingCallbacksIfNeeded() async {
        guard !callbacksRegistered else { return }
        callbacksRegistered = true
        await trackingEngine.setCallbacks(
            onStatusChange: { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    // A pre-recording start-point tap re-arms the engine's
                    // internal state to `.tracking` so it's ready the instant
                    // recording starts, but the user isn't speaking yet — the
                    // visible indicator should read "paused" until recording
                    // actually begins.
                    self.trackingStatus = self.isRecording ? status : .paused
                }
            },
            onPositionUpdate: { [weak self] position in
                Task { @MainActor in
                    self?.trackingPosition = position
                }
            },
            onEvent: { [weak self] event in
                Task { @MainActor in
                    await self?.telemetry.recordEvent(event)
                }
            }
        )
    }
}
