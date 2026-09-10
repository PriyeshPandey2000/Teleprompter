import SwiftUI
import AppKit
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
        ensureSmartDefaults()
    }

    /// PRD §8: on first launch, size the typography to the display instead of a
    /// hardcoded default. Runs only when the user hasn't already set a size
    /// (i.e. the `fontSize` key has never been written), so their override —
    /// via the slider or Cmd shortcuts — is always respected.
    static let fontSizeKey = "fontSize"

    private func ensureSmartDefaults() {
        guard UserDefaults.standard.object(forKey: Self.fontSizeKey) == nil else { return }
        UserDefaults.standard.set(Self.autoFontSize(), forKey: Self.fontSizeKey)
    }

    /// Font size heuristic: a comfortable word height for the primary display.
    static func autoFontSize() -> Double {
        guard let screen = NSScreen.main?.visibleFrame else { return 36 }
        let base = min(screen.width, screen.height)
        let stepped = ((base * 0.045) / 2).rounded() * 2
        return min(72, max(20, stepped))
    }

    func loadScript(rawText: String) async {
        let script = Script(rawContent: rawText)
        currentScript = script
        formattedScript = await formatter.format(rawText)
        // A new script invalidates any position/status left over from a
        // previous one. Without this, a stale `trackingPosition` (e.g. block
        // 5 from a longer script that was just replaced) would carry into
        // the next `startRecording` via its `position ?? trackingPosition`
        // fallback — and might not even be a valid position in the new script.
        trackingPosition = TrackingPosition()
        trackingStatus = .paused
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

        startASRConsumer()

        // `onResult` only synchronously enqueues — the actual processing
        // happens one at a time in the consumer task started above. ASR
        // partial results can arrive faster than one full asr -> matcher ->
        // position -> UI round trip completes; spawning an independent Task
        // per callback (the old approach) let those races reorder
        // `processASRResult` calls relative to when the results actually
        // arrived, which could rewind the matcher's `consumedSpokenCount` as
        // if a *newer* transcript were a stale ASR revision of an *older*
        // one. `AsyncStream.Continuation.yield` is synchronous and
        // FIFO-ordered, so this can't happen anymore.
        recognizer.onResult = { [weak self] result in
            self?.asrQueue?.yield((result, Date().timeIntervalSinceReferenceDate))
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
        // Stop new work first, then wait for whatever was already queued or
        // mid-flight to actually finish (or notice the cancellation and bail
        // — see the `Task.isCancelled` check in `startASRConsumer`) before
        // pausing the engine. Otherwise a result that snuck in right as the
        // user hit stop could still land after `pause()` and — since
        // `processASRResult` had no way to know recording had ended — flip
        // status back to `.tracking` or emit telemetry into a session that's
        // about to be closed.
        asrQueue?.finish()
        asrConsumerTask?.cancel()
        await asrConsumerTask?.value
        asrQueue = nil
        asrConsumerTask = nil

        await trackingEngine.pause()
        _ = await telemetry.endSession()
        isRecording = false
        countdownRemaining = nil
    }

    // MARK: - ASR result queue

    private var asrQueue: AsyncStream<(ASRResult, TimeInterval)>.Continuation?
    private var asrConsumerTask: Task<Void, Never>?

    private func startASRConsumer() {
        asrConsumerTask?.cancel()
        let (stream, continuation) = AsyncStream<(ASRResult, TimeInterval)>.makeStream()
        asrQueue = continuation
        asrConsumerTask = Task { [weak self] in
            for await (result, receivedAt) in stream {
                guard !Task.isCancelled, let self else { break }
                let recorder = await self.trackingEngine.latencyRecorder
                let cycle = await recorder.beginCycle()
                await recorder.mark(.asrReceived, forCycle: cycle, at: receivedAt)
                await self.trackingEngine.processASRResult(result, latencyCycle: cycle)
                _ = await recorder.completePendingCycle(uiReceivedAt: Date().timeIntervalSinceReferenceDate)
            }
        }
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
        // These callbacks are `async` on `TrackingEngine`'s side, and
        // `notifyStatusChange`/`notifyPositionUpdate`/`notifyEvent` there
        // `await` them — so awaiting the MainActor hop directly here (rather
        // than spawning a detached `Task` and returning immediately) means
        // `jumpTo`/`start`/etc. don't return until `trackingPosition` and
        // `trackingStatus` have actually been assigned. That's what makes a
        // test like "tap before recording, then immediately assert the
        // position" deterministic instead of a timing race.
        await trackingEngine.setCallbacks(
            onStatusChange: { [weak self] status in
                await self?.applyStatus(status)
            },
            onPositionUpdate: { [weak self] position in
                await self?.applyPosition(position)
            },
            onEvent: { [weak self] event in
                await self?.telemetry.recordEvent(event)
            }
        )
    }

    /// A pre-recording start-point tap re-arms the engine's internal state to
    /// `.tracking` so it's ready the instant recording starts, but the user
    /// isn't speaking yet — the visible indicator should read "paused" until
    /// recording actually begins.
    private func applyStatus(_ status: TrackingStatus) {
        trackingStatus = isRecording ? status : .paused
    }

    private func applyPosition(_ position: TrackingPosition) {
        trackingPosition = position
    }
}
