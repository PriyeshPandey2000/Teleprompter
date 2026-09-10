import Foundation

/// Named instants within one ASR → UI update cycle.
public struct LatencyMarkName: Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let asrReceived = LatencyMarkName(rawValue: "asrReceived")
    public static let matcherStarted = LatencyMarkName(rawValue: "matcherStarted")
    public static let matcherFinished = LatencyMarkName(rawValue: "matcherFinished")
    public static let positionEmitted = LatencyMarkName(rawValue: "positionEmitted")
    public static let uiReceived = LatencyMarkName(rawValue: "uiReceived")
}

/// Per-segment timing deltas for a single update cycle.
public struct LatencySample: Sendable, Equatable {
    public let cycleID: UInt64
    public let asrReceivedAt: TimeInterval?
    public let asrToMatcher: TimeInterval?
    public let matcherDuration: TimeInterval?
    public let matcherToEmit: TimeInterval?
    public let emitToUI: TimeInterval?
    public let total: TimeInterval?

    public init(
        cycleID: UInt64,
        asrReceivedAt: TimeInterval? = nil,
        asrToMatcher: TimeInterval? = nil,
        matcherDuration: TimeInterval? = nil,
        matcherToEmit: TimeInterval? = nil,
        emitToUI: TimeInterval? = nil,
        total: TimeInterval? = nil
    ) {
        self.cycleID = cycleID
        self.asrReceivedAt = asrReceivedAt
        self.asrToMatcher = asrToMatcher
        self.matcherDuration = matcherDuration
        self.matcherToEmit = matcherToEmit
        self.emitToUI = emitToUI
        self.total = total
    }
}

/// Percentile summary of one latency segment.
public struct DistributionStats: Sendable, Equatable {
    public let count: Int
    public let mean: TimeInterval
    public let p50: TimeInterval
    public let p95: TimeInterval
    public let p99: TimeInterval
    public let max: TimeInterval

    public init(count: Int, mean: TimeInterval, p50: TimeInterval, p95: TimeInterval, p99: TimeInterval, max: TimeInterval) {
        self.count = count
        self.mean = mean
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.max = max
    }

    static func make(_ values: [TimeInterval]) -> DistributionStats? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func percentile(_ q: Double) -> TimeInterval {
            let index = Swift.max(0, Swift.min(Int(ceil(Double(sorted.count) * q)) - 1, sorted.count - 1))
            return sorted[index]
        }
        let sum = sorted.reduce(0, +)
        return DistributionStats(
            count: sorted.count,
            mean: sum / Double(sorted.count),
            p50: percentile(0.50),
            p95: percentile(0.95),
            p99: percentile(0.99),
            max: sorted.last!
        )
    }
}

/// Rolling latency summary across update cycles.
public struct LatencySummary: Sendable, Equatable {
    public let completedCycles: Int
    public let asrCadence: DistributionStats?
    public let asrToMatcher: DistributionStats?
    public let matcherDuration: DistributionStats?
    public let matcherToEmit: DistributionStats?
    public let emitToUI: DistributionStats?
    public let total: DistributionStats?

    public init(
        completedCycles: Int,
        asrCadence: DistributionStats? = nil,
        asrToMatcher: DistributionStats? = nil,
        matcherDuration: DistributionStats? = nil,
        matcherToEmit: DistributionStats? = nil,
        emitToUI: DistributionStats? = nil,
        total: DistributionStats? = nil
    ) {
        self.completedCycles = completedCycles
        self.asrCadence = asrCadence
        self.asrToMatcher = asrToMatcher
        self.matcherDuration = matcherDuration
        self.matcherToEmit = matcherToEmit
        self.emitToUI = emitToUI
        self.total = total
    }
}

/// Records named timestamps per update cycle and computes latency percentiles.
///
/// One update cycle is the path ASR result → matcher → position emission →
/// UI receipt. Cycles are sequential; a cycle left incomplete is superseded by
/// the next one (its partial marks are discarded), which is fine because UI
/// work rarely overlaps with the next ASR callback.
public actor LatencyRecorder {
    private let maxSamples: Int
    private let now: @Sendable () -> TimeInterval

    private var counter: UInt64 = 0
    private var pendingCycleID: UInt64?
    private var pending: [LatencyMarkName: TimeInterval] = [:]
    private var samples: [LatencySample] = []

    public init(
        maxSamples: Int = 200,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.maxSamples = maxSamples
        self.now = now
    }

    /// Opens a new cycle and returns its id. The previous incomplete cycle is
    /// discarded.
    @discardableResult
    public func beginCycle() -> UInt64 {
        counter &+= 1
        pendingCycleID = counter
        pending = [:]
        return counter
    }

    /// Records a mark for the open cycle; marks for any other cycle are ignored.
    public func mark(_ name: LatencyMarkName, forCycle id: UInt64, at time: TimeInterval? = nil) {
        guard id == pendingCycleID ?? 0 else { return }
        pending[name] = time ?? now()
    }

    /// Finalizes the open cycle with the UI-receipt time and appends a sample.
    public func completePendingCycle(uiReceivedAt time: TimeInterval? = nil) -> LatencySample? {
        guard let id = pendingCycleID, !pending.isEmpty else {
            pendingCycleID = nil
            pending = [:]
            return nil
        }

        let asr = pending[.asrReceived]
        let matcherStart = pending[.matcherStarted]
        let matcherFinish = pending[.matcherFinished]
        let emit = pending[.positionEmitted]
        let ui = pending[.uiReceived] ?? time

        let sample = LatencySample(
            cycleID: id,
            asrReceivedAt: asr,
            asrToMatcher: asr != nil && matcherStart != nil ? matcherStart! - asr! : nil,
            matcherDuration: matcherStart != nil && matcherFinish != nil ? matcherFinish! - matcherStart! : nil,
            matcherToEmit: matcherFinish != nil && emit != nil ? emit! - matcherFinish! : nil,
            emitToUI: emit != nil && ui != nil ? ui! - emit! : nil,
            total: asr != nil && ui != nil ? ui! - asr! : nil
        )

        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }

        pendingCycleID = nil
        pending = [:]
        return sample
    }

    public func summary() -> LatencySummary {
        let arrivals = samples.compactMap(\.asrReceivedAt)
        return LatencySummary(
            completedCycles: samples.count,
            // Gap between consecutive ASR partial arrivals — this is how often
            // new transcript text (and therefore a new highlight step) can
            // possibly happen. The dominant part of *perceived* response for
            // a live reader, entirely owned by the Speech framework, not us.
            asrCadence: DistributionStats.make(zip(arrivals.dropFirst(), arrivals).map { $0 - $1 }),
            asrToMatcher: DistributionStats.make(samples.compactMap(\.asrToMatcher)),
            matcherDuration: DistributionStats.make(samples.compactMap(\.matcherDuration)),
            matcherToEmit: DistributionStats.make(samples.compactMap(\.matcherToEmit)),
            emitToUI: DistributionStats.make(samples.compactMap(\.emitToUI)),
            total: DistributionStats.make(samples.compactMap(\.total))
        )
    }

    public func reset() {
        samples = []
        pending = [:]
        pendingCycleID = nil
    }
}