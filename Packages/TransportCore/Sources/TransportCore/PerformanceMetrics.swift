import Foundation

/// One authenticated four-timestamp clock probe.
///
/// The Host timestamps `hostSent` and `hostReceived`; the Viewer timestamps
/// `viewerReceived` and `viewerSent`.  The estimator uses the minimum-RTT
/// probe as the least-contended offset sample and reports a conservative
/// residual uncertainty instead of pretending that the hosts share a clock.
public struct ClockSyncProbe: Codable, Equatable, Sendable {
    public let hostSentNanoseconds: UInt64
    public let viewerReceivedNanoseconds: UInt64
    public let viewerSentNanoseconds: UInt64
    public let hostReceivedNanoseconds: UInt64

    public init(
        hostSentNanoseconds: UInt64,
        viewerReceivedNanoseconds: UInt64,
        viewerSentNanoseconds: UInt64,
        hostReceivedNanoseconds: UInt64
    ) {
        self.hostSentNanoseconds = hostSentNanoseconds
        self.viewerReceivedNanoseconds = viewerReceivedNanoseconds
        self.viewerSentNanoseconds = viewerSentNanoseconds
        self.hostReceivedNanoseconds = hostReceivedNanoseconds
    }

    /// Estimated Viewer-minus-Host clock offset for this probe.
    public var offsetNanoseconds: Int64? {
        guard viewerSentNanoseconds >= viewerReceivedNanoseconds,
              hostReceivedNanoseconds >= hostSentNanoseconds,
              let forward = Self.signedDifference(
                  viewerReceivedNanoseconds,
                  hostSentNanoseconds
              ),
              let reverse = Self.signedDifference(
                  viewerSentNanoseconds,
                  hostReceivedNanoseconds
              ) else {
            return nil
        }
        return Self.average(forward, reverse)
    }

    /// Round-trip transport time after subtracting time spent on the Viewer.
    public var roundTripNanoseconds: UInt64? {
        guard hostReceivedNanoseconds >= hostSentNanoseconds,
              viewerSentNanoseconds >= viewerReceivedNanoseconds else {
            return nil
        }
        let total = hostReceivedNanoseconds - hostSentNanoseconds
        let viewerWork = viewerSentNanoseconds - viewerReceivedNanoseconds
        guard total >= viewerWork else { return nil }
        return total - viewerWork
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
