import Foundation

public actor RecoveryManager {
    private var consecutiveFailures: Int = 0
    private var lastSuccessfulMatch: Date?
    private var recoveryAttempts: Int = 0
    private let maxRecoveryAttempts = 3
    private let failureThreshold = 3

    public enum RecoveryAction: Sendable, Equatable {
        case none
        case holdPosition
        case suggestManualCorrection
        case enterDegradedMode
        case fallbackToManualScroll
    }

    public init() {}

    public func reset() {
        consecutiveFailures = 0
        recoveryAttempts = 0
        lastSuccessfulMatch = .now
    }

    public func recordFailure() -> RecoveryAction {
        consecutiveFailures += 1
        recoveryAttempts += 1

        if consecutiveFailures < failureThreshold {
            return .holdPosition
        }

        if recoveryAttempts <= maxRecoveryAttempts {
            return .suggestManualCorrection
        }

        return .enterDegradedMode
    }

    public func recordSuccess() {
        consecutiveFailures = 0
        recoveryAttempts = 0
        lastSuccessfulMatch = .now
    }

    public func shouldFallbackToManualScroll() -> Bool {
        guard let lastSuccess = lastSuccessfulMatch else { return true }
        return Date().timeIntervalSince(lastSuccess) > 10.0
    }

    public func getDiagnostics() -> RecoveryDiagnostics {
        RecoveryDiagnostics(
            consecutiveFailures: consecutiveFailures,
            totalRecoveryAttempts: recoveryAttempts,
            lastSuccessfulMatch: lastSuccessfulMatch,
            shouldFallback: shouldFallbackToManualScroll()
        )
    }
}

public struct RecoveryDiagnostics: Sendable {
    public let consecutiveFailures: Int
    public let totalRecoveryAttempts: Int
    public let lastSuccessfulMatch: Date?
    public let shouldFallback: Bool
}
