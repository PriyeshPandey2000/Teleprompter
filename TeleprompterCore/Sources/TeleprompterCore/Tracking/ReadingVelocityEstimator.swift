import Foundation

/// Smoothed estimate of how many script tokens the reader is consuming per
/// second, built from (token delta, elapsed time) samples.
///
/// The PRD frames this as a *state*, not a per-result decision: "Given the
/// last 10 seconds of movement, line 472 is probably the current position."
/// Samples decay exponentially (`exp(-elapsed / timeConstant)`), so a burst
/// of movement shapes the estimate while a pause lets it fall back toward
/// zero instead of latching onto an outdated pace. Instantaneous rates are
/// clamped so a hail of zero-length ASR deltas can never produce a runaway
/// velocity.
public struct ReadingVelocityEstimator: Sendable, Equatable {
    /// Upper bound on a single sample's instantaneous words/sec.
    public var clampMax: Double
    /// EWMA time constant in seconds — how much history shapes the estimate.
    public var timeConstant: Double
    /// Beloved estimate, words/sec.
    public private(set) var velocity: Double

    public init(clampMax: Double = 10, timeConstant: Double = 5) {
        self.clampMax = max(1, clampMax)
        self.timeConstant = max(0.1, timeConstant)
        self.velocity = 0
    }

    /// Advances the estimate with one sample.
    ///
    /// - Parameters:
    ///   - deltaTokens: How many net tokens the matcher consumed since the
    ///     previous sample. Zero/negative inputs only decay the estimate.
    ///   - elapsed: Wall-clock seconds since the previous sample. Samples
    ///     that arrive in the same instant (or out of order) are a no-op.
    public mutating func update(deltaTokens: Int, elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        let decay = exp(-elapsed / timeConstant)
        if deltaTokens > 0 {
            let instantaneous = min(Double(deltaTokens) / elapsed, clampMax)
            velocity = velocity * decay + instantaneous * (1 - decay)
        } else {
            velocity *= decay
        }
        if velocity < 0.05 {
            velocity = 0
        }
    }

    /// Drops the estimate to zero (manual jumps, re-syncs, session starts).
    public mutating func reset() {
        velocity = 0
    }
}