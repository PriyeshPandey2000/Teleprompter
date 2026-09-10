import Foundation
import Speech
import AVFoundation

public enum ASRError: LocalizedError, Sendable {
    case unsupportedLocale
    case permissionDenied
    case recognizerUnavailable
    case assetNotReady
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale:
            return "Speech recognition is not available for the selected language."
        case .permissionDenied:
            return "Microphone or speech recognition permission was denied."
        case .recognizerUnavailable:
            return "Speech recognition is temporarily unavailable."
        case .assetNotReady:
            return "The on-device speech model hasn't finished downloading yet."
        case .recognitionFailed(let message):
            return message
        }
    }
}

public enum ASRState: Sendable, Equatable {
    case idle
    case listening
    case processing
    case unavailable(String)
}

/// Sendable translation of a `recognitionTask` callback, built synchronously
/// off the main actor before crossing into a `Task`. Keeps the non-Sendable
/// `SFSpeechRecognitionResult`/`Error` from ever leaving the callback's own
/// thread.
private enum RecognitionOutcome: Sendable {
    case transcript(ASRResult, isFinal: Bool)
    case cancelled
    case noSpeechDetected
    case assetNotReady
    case failed(String)
    case empty
}

public struct SpeechRecognitionOptions: Sendable {
    public var locale: Locale
    public var requiresOnDeviceRecognition: Bool
    public var shouldReportPartialResults: Bool

    public init(
        locale: Locale = Locale(identifier: "en_US"),
        requiresOnDeviceRecognition: Bool = true,
        shouldReportPartialResults: Bool = true
    ) {
        self.locale = locale
        self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        self.shouldReportPartialResults = shouldReportPartialResults
    }
}

@MainActor
public protocol SpeechRecognizerProtocol: AnyObject {
    var state: ASRState { get }
    var onResult: ((ASRResult) -> Void)? { get set }
    /// Fires whenever `state` changes, in particular `.unavailable` — the
    /// only signal that ASR is silently failing (no-speech runs, on-device
    /// model not downloaded, recognizer errors). Without this, a caller has
    /// no way to know results have stopped arriving versus the user just
    /// being quiet.
    var onStateChange: ((ASRState) -> Void)? { get set }

    func requestPermission() async -> Bool
    func start() async throws
    func stop() async
}

@MainActor
public final class SFSpeechRecognizerService: SpeechRecognizerProtocol {
    private let options: SpeechRecognitionOptions
    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false

    private var _state: ASRState = .idle {
        didSet {
            guard _state != oldValue else { return }
            onStateChange?(_state)
        }
    }
    public var state: ASRState { _state }

    public var onResult: ((ASRResult) -> Void)?
    public var onStateChange: ((ASRState) -> Void)?

    public init(options: SpeechRecognitionOptions = SpeechRecognitionOptions()) {
        self.options = options
        self.recognizer = Self.buildRecognizer(preferredLocale: options.locale)
    }

    public func requestPermission() async -> Bool {
        guard await Self.requestSpeechAuthorization() else { return false }

        // Speech-recognition authorization is separate from microphone TCC
        // access. AVAudioEngine's `inputNode` triggers its own implicit mic
        // permission negotiation on first touch; if that hasn't settled
        // before `prepare()`/`start()` run, CoreAudio's internal queue
        // assertion fires. Request and await mic access explicitly first so
        // the engine is only ever touched after TCC has fully resolved.
        return await Self.requestMicrophoneAuthorization()
    }

    // `nonisolated` is load-bearing: these completion handlers are invoked by
    // TCC/CoreAudio on their own internal queues, never on the main actor. A
    // closure written directly inside a `@MainActor` method inherits that
    // isolation, so Swift inserts a runtime check that the callback is
    // running on the main actor's executor — which it never is here — and
    // crashes with `_dispatch_assert_queue_fail`. Keeping these `static
    // nonisolated` means the closures carry no actor affinity at all.
    nonisolated private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated private static func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Same `nonisolated` reasoning as the permission helpers above: the tap
    /// block is invoked by AVAudioEngine on its own real-time audio thread
    /// (`RealtimeMessenger`), never the main actor. `append(_:)` is designed
    /// to be called from that thread — the crash was Swift's isolation check
    /// on the closure itself, not the audio API.
    nonisolated private static func makeTapBlock(
        appendingTo request: SFSpeechAudioBufferRecognitionRequest
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            request.append(buffer)
        }
    }

    /// Same reasoning again: `recognitionTask`'s result handler fires on a
    /// Speech-framework-owned queue. The closure itself must stay isolation-
    /// free; hopping to the main actor happens *inside* it via `Task`, which
    /// is safe to schedule from any thread. `SFSpeechRecognitionResult`/
    /// `Error` aren't `Sendable`, so they're translated to a `Sendable`
    /// payload synchronously, here, before crossing into the `Task`.
    nonisolated private static func makeResultHandler(
        for service: SFSpeechRecognizerService
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak service] result, error in
            let outcome = translate(result: result, error: error)
            Task { @MainActor [weak service] in
                service?.handleRecognition(outcome)
            }
        }
    }

    nonisolated private static func translate(result: SFSpeechRecognitionResult?, error: Error?) -> RecognitionOutcome {
        if let error {
            let nsError = error as NSError
            switch nsError.code {
            case 301: // cancelled (expected on stop)
                return .cancelled
            case 209: // no speech detected — keep listening
                return .noSpeechDetected
            case 1110: // on-device assets not downloaded yet
                return .assetNotReady
            default:
                return .failed(nsError.localizedDescription)
            }
        }

        guard let result else { return .empty }

        let segments = result.bestTranscription.segments.map {
            ASRSegment(
                text: $0.substring,
                startTime: $0.timestamp,
                endTime: $0.timestamp + $0.duration,
                confidence: Double($0.confidence)
            )
        }

        let asr = ASRResult(
            transcript: result.bestTranscription.formattedString,
            segments: segments,
            isFinal: result.isFinal,
            confidence: Double(result.bestTranscription.segments.last?.confidence ?? 0)
        )
        return .transcript(asr, isFinal: result.isFinal)
    }

    public func start() async throws {
        // Permission is gated by the caller via `requestPermission()` before
        // `start()` is invoked — requesting it again here races the first
        // authorization dialog and crashes the Speech framework's internal
        // dispatch-queue assertion.
        guard let recognizer, recognizer.isAvailable else {
            throw ASRError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = options.shouldReportPartialResults
        request.requiresOnDeviceRecognition = options.requiresOnDeviceRecognition
        self.recognitionRequest = request

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(appendingTo: request))
        tapInstalled = true

        engine.prepare()
        try engine.start()
        self.audioEngine = engine

        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler(for: self))

        _state = .listening
    }

    public func stop() async {
        recognitionTask?.cancel()
        recognitionTask = nil

        if tapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine?.stop()
        audioEngine = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        _state = .idle
    }

    // MARK: - Callback handling

    private func handleRecognition(_ outcome: RecognitionOutcome) {
        switch outcome {
        case .cancelled:
            _state = .idle
        case .noSpeechDetected:
            _state = .listening
        case .assetNotReady:
            _state = .unavailable("On-device speech model not downloaded yet.")
        case .failed(let message):
            _state = .unavailable(message)
        case .empty:
            break
        case .transcript(let asr, let isFinal):
            onResult?(asr)
            _state = isFinal ? .listening : .processing
        }
    }

    // MARK: - Locale selection

    private static func buildRecognizer(preferredLocale: Locale) -> SFSpeechRecognizer? {
        let supported = SFSpeechRecognizer.supportedLocales()

        if !supported.isEmpty {
            if supported.contains(preferredLocale),
               let recognizer = SFSpeechRecognizer(locale: preferredLocale) {
                return recognizer
            }
            for identifier in ["en_US", "en_IN", "en_GB"] {
                let locale = Locale(identifier: identifier)
                if supported.contains(locale),
                   let recognizer = SFSpeechRecognizer(locale: locale) {
                    return recognizer
                }
            }
        }

        return SFSpeechRecognizer()
    }
}