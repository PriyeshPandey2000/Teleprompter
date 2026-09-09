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

    private var _state: ASRState = .idle
    public var state: ASRState { _state }

    public var onResult: ((ASRResult) -> Void)?

    public init(options: SpeechRecognitionOptions = SpeechRecognitionOptions()) {
        self.options = options
        self.recognizer = Self.buildRecognizer(preferredLocale: options.locale)
    }

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public func start() async throws {
        guard await requestPermission() else {
            throw ASRError.permissionDenied
        }
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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        self.audioEngine = engine

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognition(result: result, error: error)
            }
        }

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

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            let nsError = error as NSError
            switch nsError.code {
            case 301: // cancelled (expected on stop)
                _state = .idle
            case 209: // no speech detected — keep listening
                _state = .listening
            case 1110: // on-device assets not downloaded yet
                _state = .unavailable("On-device speech model not downloaded yet.")
            default:
                _state = .unavailable(nsError.localizedDescription)
            }
            return
        }

        guard let result else { return }

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

        onResult?(asr)
        _state = result.isFinal ? .listening : .processing
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