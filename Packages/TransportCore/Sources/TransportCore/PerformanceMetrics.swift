import Foundation

public enum ClockSyncProbeDirection: String, Codable, Equatable, Sendable {
    case hostInitiated
    case viewerInitiated
}

/// One authenticated four-timestamp clock probe.
///
/// The Host and Viewer timestamp the same four events.  The direction records
/// which peer initiated the exchange because the two valid event orders have
/// different round-trip formulas. The estimator uses the minimum-RTT probe as
/// the least-contended offset sample and reports a conservative residual
/// uncertainty instead of pretending that the hosts share a clock.
public struct ClockSyncProbe: Codable, Equatable, Sendable {
    public let direction: ClockSyncProbeDirection
    public let hostSentNanoseconds: UInt64
    public let viewerReceivedNanoseconds: UInt64
    public let viewerSentNanoseconds: UInt64
    public let hostReceivedNanoseconds: UInt64

    public init(
        hostSentNanoseconds: UInt64,
        viewerReceivedNanoseconds: UInt64,
        viewerSentNanoseconds: UInt64,
        hostReceivedNanoseconds: UInt64,
        direction: ClockSyncProbeDirection = .hostInitiated
    ) {
        self.direction = direction
        self.hostSentNanoseconds = hostSentNanoseconds
        self.viewerReceivedNanoseconds = viewerReceivedNanoseconds
        self.viewerSentNanoseconds = viewerSentNanoseconds
        self.hostReceivedNanoseconds = hostReceivedNanoseconds
    }

    /// Estimated Viewer-minus-Host clock offset for this probe.
    public var offsetNanoseconds: Int64? {
        let validOrdering: Bool
        switch direction {
        case .hostInitiated:
            validOrdering = viewerSentNanoseconds >= viewerReceivedNanoseconds &&
                hostReceivedNanoseconds >= hostSentNanoseconds
        case .viewerInitiated:
            validOrdering = viewerReceivedNanoseconds >= viewerSentNanoseconds &&
                hostSentNanoseconds >= hostReceivedNanoseconds
        }
        guard validOrdering,
              let forward = Self.signedDifference(viewerReceivedNanoseconds, hostSentNanoseconds),
              let reverse = Self.signedDifference(viewerSentNanoseconds, hostReceivedNanoseconds) else {
            return nil
        }
        return Self.average(forward, reverse)
    }

    /// Round-trip transport time after subtracting the responder's work.
    public var roundTripNanoseconds: UInt64? {
        switch direction {
        case .hostInitiated:
            guard hostReceivedNanoseconds >= hostSentNanoseconds,
                  viewerSentNanoseconds >= viewerReceivedNanoseconds else {
                return nil
            }
            let total = hostReceivedNanoseconds - hostSentNanoseconds
            let viewerWork = viewerSentNanoseconds - viewerReceivedNanoseconds
            guard total >= viewerWork else { return nil }
            return total - viewerWork
        case .viewerInitiated:
            guard viewerReceivedNanoseconds >= viewerSentNanoseconds,
                  hostSentNanoseconds >= hostReceivedNanoseconds else {
                return nil
            }
            let total = viewerReceivedNanoseconds - viewerSentNanoseconds
            let hostWork = hostSentNanoseconds - hostReceivedNanoseconds
            guard total >= hostWork else { return nil }
            return total - hostWork
        }
    }

    private static func signedDifference(_ lhs: UInt64, _ rhs: UInt64) -> Int64? {
        if lhs >= rhs {
            guard lhs - rhs <= UInt64(Int64.max) else { return nil }
            return Int64(lhs - rhs)
        }
        guard rhs - lhs <= UInt64(Int64.max) else { return nil }
        return -Int64(rhs - lhs)
    }

    /// Averages two Int64 values without forming an overflowing sum. The
    /// quotient/remainder form preserves Swift's truncation-toward-zero
    /// semantics even for the asymmetric Int64.min/Int64.max boundary.
    private static func average(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let base = lhs / 2 + rhs / 2
        let remainder = lhs % 2 + rhs % 2
        let correction: Int64
        if base > 0, remainder < 0 {
            correction = (remainder - 1) / 2
        } else if base >= 0 {
            correction = remainder / 2
        } else if remainder >= 0 {
            correction = (remainder + 1) / 2
        } else {
            correction = remainder / 2
        }
        return base + correction
    }
}

public struct ClockSyncEstimate: Codable, Equatable, Sendable {
    public let probeCount: Int
    public let offsetNanoseconds: Int64
    public let minimumRoundTripNanoseconds: UInt64
    public let residualOffsetUncertaintyNanoseconds: UInt64
    public let driftNanosecondsPerSecond: Double

    public init(
        probeCount: Int,
        offsetNanoseconds: Int64,
        minimumRoundTripNanoseconds: UInt64,
        residualOffsetUncertaintyNanoseconds: UInt64,
        driftNanosecondsPerSecond: Double
    ) {
        self.probeCount = probeCount
        self.offsetNanoseconds = offsetNanoseconds
        self.minimumRoundTripNanoseconds = minimumRoundTripNanoseconds
        self.residualOffsetUncertaintyNanoseconds = residualOffsetUncertaintyNanoseconds
        self.driftNanosecondsPerSecond = driftNanosecondsPerSecond
    }

    public var hasRequiredProbeCount: Bool {
        probeCount >= 20
    }

    public var oneWayMeasurementEligible: Bool {
        hasRequiredProbeCount && residualOffsetUncertaintyNanoseconds <= 5_000_000
    }
}

public struct ClockSyncEstimator: Sendable {
    public static let minimumProbeCount = 20

    private var validProbes: [ClockSyncProbe] = []

    public init() {}

    @discardableResult
    public mutating func append(_ probe: ClockSyncProbe) -> Bool {
        guard probe.offsetNanoseconds != nil,
              probe.roundTripNanoseconds != nil else {
            return false
        }
        validProbes.append(probe)
        return true
    }

    public var probeCount: Int { validProbes.count }

    public func estimate() -> ClockSyncEstimate? {
        guard let first = validProbes.first,
              let firstOffset = first.offsetNanoseconds,
              let minimumProbe = validProbes.min(by: { lhs, rhs in
                  lhs.roundTripNanoseconds! < rhs.roundTripNanoseconds!
              }),
              let minimumRTT = minimumProbe.roundTripNanoseconds,
              let minimumOffset = minimumProbe.offsetNanoseconds else {
            return nil
        }

        let offsets = validProbes.compactMap(\.offsetNanoseconds)
        let spread = offsets
            .map { Self.absoluteDifference($0, minimumOffset) }
            .max() ?? 0
        let pathUncertainty = minimumRTT / 2
        let residualUncertainty = max(pathUncertainty, spread)

        let last = validProbes.last!
        let elapsed = last.hostSentNanoseconds >= first.hostSentNanoseconds
            ? last.hostSentNanoseconds - first.hostSentNanoseconds
            : 0
        let drift: Double
        if elapsed == 0, let lastOffset = last.offsetNanoseconds {
            drift = Self.signedDifferenceAsDouble(lastOffset, firstOffset)
        } else if elapsed == 0 {
            drift = 0
        } else if let lastOffset = last.offsetNanoseconds {
            drift = Self.signedDifferenceAsDouble(lastOffset, firstOffset) /
                (Double(elapsed) / 1_000_000_000)
        } else {
            drift = 0
        }

        return ClockSyncEstimate(
            probeCount: validProbes.count,
            offsetNanoseconds: minimumOffset,
            minimumRoundTripNanoseconds: minimumRTT,
            residualOffsetUncertaintyNanoseconds: residualUncertainty,
            driftNanosecondsPerSecond: drift
        )
    }

    /// Returns the mathematical absolute difference without first subtracting
    /// two Int64 values. Opposite signed boundaries can differ by almost 2^64,
    /// which is representable by the UInt64 uncertainty field but traps in a
    /// normal signed subtraction or `abs` call.
    private static func absoluteDifference(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        if lhs < rhs {
            return absoluteDifference(rhs, lhs)
        }
        if lhs >= 0, rhs < 0 {
            let (value, overflow) = UInt64(lhs).addingReportingOverflow(magnitude(of: rhs))
            return overflow ? UInt64.max : value
        }
        return magnitude(of: lhs - rhs)
    }

    private static func magnitude(of value: Int64) -> UInt64 {
        guard value < 0 else { return UInt64(value) }
        return UInt64(-(value + 1)) + 1
    }

    private static func signedDifferenceAsDouble(_ lhs: Int64, _ rhs: Int64) -> Double {
        let magnitude = Double(absoluteDifference(lhs, rhs))
        return lhs >= rhs ? magnitude : -magnitude
    }
}

/// A presentation timestamp pair retained only inside a bounded production
/// collector. The pair is never part of the sanitized report; it is kept long
/// enough to apply the final authenticated clock estimate at snapshot time.
public struct PresentationTimingSample: Equatable, Sendable {
    public let captureTimestampNanoseconds: UInt64
    public let presentedTimestampNanoseconds: UInt64

    public init(
        captureTimestampNanoseconds: UInt64,
        presentedTimestampNanoseconds: UInt64
    ) {
        self.captureTimestampNanoseconds = captureTimestampNanoseconds
        self.presentedTimestampNanoseconds = presentedTimestampNanoseconds
    }
}

/// Sanitized, bounded production measurement output. It contains timing
/// aggregates and counts only; raw capture/presentation timestamps are not
/// exposed so a release run cannot accidentally persist a frame trace.
public struct PresentationSampleSnapshot: Codable, Equatable, Sendable {
    public let presentedFrameCount: Int
    public let warmupFrames: Int
    public let retainedSampleCount: Int
    public let droppedSampleCount: Int
    public let validFrameSamples: Int
    public let captureToDisplay: PercentileSummary?
    public let clockSync: ClockSyncEstimate?

    public init(
        presentedFrameCount: Int,
        warmupFrames: Int,
        retainedSampleCount: Int,
        droppedSampleCount: Int,
        validFrameSamples: Int,
        captureToDisplay: PercentileSummary?,
        clockSync: ClockSyncEstimate?
    ) {
        self.presentedFrameCount = presentedFrameCount
        self.warmupFrames = warmupFrames
        self.retainedSampleCount = retainedSampleCount
        self.droppedSampleCount = droppedSampleCount
        self.validFrameSamples = validFrameSamples
        self.captureToDisplay = captureToDisplay
        self.clockSync = clockSync
    }

    public var oneWayMeasurementEligible: Bool {
        guard let clockSync else { return false }
        return clockSync.oneWayMeasurementEligible
    }
}

/// Collects actual Viewer drawable-presentation timestamps for the M8/M10
/// latency boundary. It deliberately keeps a small, fixed number of raw
/// timing pairs and converts them only with an authenticated clock estimate.
/// If the estimate never meets the uncertainty bound, the snapshot reports no
/// one-way samples instead of manufacturing a latency result.
public struct BoundedPresentationSampleCollector: Sendable {
    public static let defaultWarmupFrameCount = 60
    public static let defaultMaximumSamples = 10_000

    private let warmupFrameCount: Int
    private let maximumSamples: Int
    private var presentedFrameCountValue = 0
    private var droppedSampleCountValue = 0
    private var samples: [PresentationTimingSample] = []

    public init(
        warmupFrameCount: Int = Self.defaultWarmupFrameCount,
        maximumSamples: Int = Self.defaultMaximumSamples
    ) {
        self.warmupFrameCount = max(0, warmupFrameCount)
        self.maximumSamples = max(1, maximumSamples)
        self.samples.reserveCapacity(min(self.maximumSamples, 256))
    }

    public var presentedFrameCount: Int { presentedFrameCountValue }
    public var retainedSampleCount: Int { samples.count }
    public var droppedSampleCount: Int { droppedSampleCountValue }

    public mutating func append(
        captureTimestampNanoseconds: UInt64,
        presentedTimestampNanoseconds: UInt64
    ) {
        let ordinal = presentedFrameCountValue
        if presentedFrameCountValue < Int.max {
            presentedFrameCountValue += 1
        }
        guard ordinal >= warmupFrameCount else { return }
        guard samples.count < maximumSamples else {
            if droppedSampleCountValue < Int.max {
                droppedSampleCountValue += 1
            }
            return
        }
        samples.append(
            PresentationTimingSample(
                captureTimestampNanoseconds: captureTimestampNanoseconds,
                presentedTimestampNanoseconds: presentedTimestampNanoseconds
            )
        )
    }

    public mutating func reset() {
        presentedFrameCountValue = 0
        droppedSampleCountValue = 0
        samples.removeAll(keepingCapacity: true)
    }

    public func snapshot(clockSync: ClockSyncEstimate?) -> PresentationSampleSnapshot {
        var latencies: [UInt64] = []
        if let clockSync, clockSync.oneWayMeasurementEligible {
            latencies.reserveCapacity(samples.count)
            for sample in samples {
                guard let latency = Self.latency(
                    for: sample,
                    offsetNanoseconds: clockSync.offsetNanoseconds
                ) else { continue }
                latencies.append(latency)
            }
        }
        return PresentationSampleSnapshot(
            presentedFrameCount: presentedFrameCountValue,
            warmupFrames: warmupFrameCount,
            retainedSampleCount: samples.count,
            droppedSampleCount: droppedSampleCountValue,
            validFrameSamples: latencies.count,
            captureToDisplay: PercentileSummary(samples: latencies),
            clockSync: clockSync
        )
    }

    private static func latency(
        for sample: PresentationTimingSample,
        offsetNanoseconds: Int64
    ) -> UInt64? {
        guard sample.presentedTimestampNanoseconds <= UInt64(Int64.max),
              sample.captureTimestampNanoseconds <= UInt64(Int64.max) else {
            return nil
        }
        let presented = Int64(sample.presentedTimestampNanoseconds)
        let capture = Int64(sample.captureTimestampNanoseconds)
        let (hostAligned, alignmentOverflow) = presented
            .subtractingReportingOverflow(offsetNanoseconds)
        let (latency, subtractionOverflow) = hostAligned
            .subtractingReportingOverflow(capture)
        guard !alignmentOverflow, !subtractionOverflow, latency >= 0 else {
            return nil
        }
        return UInt64(latency)
    }
}

public struct PercentileSummary: Codable, Equatable, Sendable {
    public let count: Int
    public let minimumNanoseconds: UInt64
    public let p50Nanoseconds: UInt64
    public let p95Nanoseconds: UInt64
    public let maximumNanoseconds: UInt64

    public init?(samples: [UInt64]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        self.count = sorted.count
        self.minimumNanoseconds = sorted[0]
        self.p50Nanoseconds = Self.value(at: 0.50, in: sorted)
        self.p95Nanoseconds = Self.value(at: 0.95, in: sorted)
        self.maximumNanoseconds = sorted[sorted.count - 1]
    }

    private static func value(at percentile: Double, in sorted: [UInt64]) -> UInt64 {
        let index = min(
            sorted.count - 1,
            max(0, Int(ceil(percentile * Double(sorted.count))) - 1)
        )
        return sorted[index]
    }
}

public struct ResourceSnapshot: Codable, Equatable, Sendable {
    public let userCPUSeconds: Double
    public let systemCPUSeconds: Double
    public let maximumResidentBytes: UInt64
    public let gpuMeasurementAvailable: Bool

    public init(
        userCPUSeconds: Double,
        systemCPUSeconds: Double,
        maximumResidentBytes: UInt64,
        gpuMeasurementAvailable: Bool
    ) {
        self.userCPUSeconds = userCPUSeconds
        self.systemCPUSeconds = systemCPUSeconds
        self.maximumResidentBytes = maximumResidentBytes
        self.gpuMeasurementAvailable = gpuMeasurementAvailable
    }
}

public struct PerformanceRunReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let measurementKind: String
    public let hostArchitecture: String
    public let viewerArchitecture: String
    public let macOSVersion: String
    public let resolution: String
    public let targetFrameRate: UInt16
    public let durationSeconds: Double
    public let warmupFrames: Int
    public let validFrameSamples: Int
    public let deliveredFrames: Int
    public let droppedFrames: Int
    public let supersededFrames: Int
    public let achievedFrameRate: Double
    public let captureToDisplay: PercentileSummary?
    public let interaction: PercentileSummary?
    public let clockSync: ClockSyncEstimate?
    public let reconnectCount: Int
    public let keyframeRecoveryCount: Int
    public let slowPeerEvents: Int
    public let maximumControlQueueDepth: Int
    public let maximumMediaQueueDepth: Int
    public let resources: ResourceSnapshot?
    public let verdict: String

    public init(
        schemaVersion: Int = 1,
        measurementKind: String,
        hostArchitecture: String,
        viewerArchitecture: String,
        macOSVersion: String,
        resolution: String,
        targetFrameRate: UInt16,
        durationSeconds: Double,
        warmupFrames: Int,
        validFrameSamples: Int,
        deliveredFrames: Int,
        droppedFrames: Int,
        supersededFrames: Int,
        achievedFrameRate: Double,
        captureToDisplay: PercentileSummary?,
        interaction: PercentileSummary?,
        clockSync: ClockSyncEstimate?,
        reconnectCount: Int,
        keyframeRecoveryCount: Int,
        slowPeerEvents: Int,
        maximumControlQueueDepth: Int,
        maximumMediaQueueDepth: Int,
        resources: ResourceSnapshot?,
        verdict: String
    ) {
        self.schemaVersion = schemaVersion
        self.measurementKind = measurementKind
        self.hostArchitecture = hostArchitecture
        self.viewerArchitecture = viewerArchitecture
        self.macOSVersion = macOSVersion
        self.resolution = resolution
        self.targetFrameRate = targetFrameRate
        self.durationSeconds = durationSeconds
        self.warmupFrames = warmupFrames
        self.validFrameSamples = validFrameSamples
        self.deliveredFrames = deliveredFrames
        self.droppedFrames = droppedFrames
        self.supersededFrames = supersededFrames
        self.achievedFrameRate = achievedFrameRate
        self.captureToDisplay = captureToDisplay
        self.interaction = interaction
        self.clockSync = clockSync
        self.reconnectCount = reconnectCount
        self.keyframeRecoveryCount = keyframeRecoveryCount
        self.slowPeerEvents = slowPeerEvents
        self.maximumControlQueueDepth = maximumControlQueueDepth
        self.maximumMediaQueueDepth = maximumMediaQueueDepth
        self.resources = resources
        self.verdict = verdict
    }
}

/// Bounded interval collector for one pipeline stage whose start and end are
/// taken on the same monotonic clock, so no clock synchronization is needed.
/// Only interval lengths are retained, never raw timestamps.
public struct BoundedStageLatencyCollector: Sendable {
    public static let defaultWarmupSampleCount = 60
    public static let defaultMaximumSamples = 10_000

    private let warmupSampleCount: Int
    private let maximumSamples: Int
    private var observedCount = 0
    private var intervals: [UInt64] = []

    public init(
        warmupSampleCount: Int = Self.defaultWarmupSampleCount,
        maximumSamples: Int = Self.defaultMaximumSamples
    ) {
        self.warmupSampleCount = max(0, warmupSampleCount)
        self.maximumSamples = max(1, maximumSamples)
    }

    public var retainedSampleCount: Int { intervals.count }

    /// Ignores an interval whose end precedes its start.
    public mutating func append(startNanoseconds: UInt64, endNanoseconds: UInt64) {
        guard endNanoseconds >= startNanoseconds else { return }
        let ordinal = observedCount
        if observedCount < Int.max {
            observedCount += 1
        }
        guard ordinal >= warmupSampleCount, intervals.count < maximumSamples else { return }
        intervals.append(endNanoseconds - startNanoseconds)
    }

    public mutating func reset() {
        observedCount = 0
        intervals.removeAll(keepingCapacity: true)
    }

    public func summary() -> PercentileSummary? {
        PercentileSummary(samples: intervals)
    }
}

/// The p95 latency budget for each pipeline stage. The stages sum to the
/// V1 end-to-end target, so a miss can be attributed to one stage.
///
/// - `hostCaptureToSend`: capture arrival to wire-queue admission on the
///   Host clock (encode plus Host scheduling).
/// - `networkTransit`: wire admission to Viewer receipt. It spans two clocks
///   and is not measured directly; it is the remainder of the end-to-end
///   figure.
/// - `viewerReceiveToPresent`: Viewer receipt to drawable presentation on
///   the Viewer clock (decode plus waiting for the display refresh).
public struct LatencyBudget: Codable, Equatable, Sendable {
    public let hostCaptureToSendNanoseconds: UInt64
    public let networkTransitNanoseconds: UInt64
    public let viewerReceiveToPresentNanoseconds: UInt64

    public static let v1 = LatencyBudget(
        hostCaptureToSendNanoseconds: 12_000_000,
        networkTransitNanoseconds: 18_000_000,
        viewerReceiveToPresentNanoseconds: 20_000_000
    )

    public init(
        hostCaptureToSendNanoseconds: UInt64,
        networkTransitNanoseconds: UInt64,
        viewerReceiveToPresentNanoseconds: UInt64
    ) {
        self.hostCaptureToSendNanoseconds = hostCaptureToSendNanoseconds
        self.networkTransitNanoseconds = networkTransitNanoseconds
        self.viewerReceiveToPresentNanoseconds = viewerReceiveToPresentNanoseconds
    }

    public var endToEndNanoseconds: UInt64 {
        hostCaptureToSendNanoseconds + networkTransitNanoseconds + viewerReceiveToPresentNanoseconds
    }

    /// Returns `nil` when the stage has no samples, otherwise whether its p95
    /// is within the budget.
    public static func isWithinBudget(_ summary: PercentileSummary?, budget: UInt64) -> Bool? {
        summary.map { $0.p95Nanoseconds <= budget }
    }
}
