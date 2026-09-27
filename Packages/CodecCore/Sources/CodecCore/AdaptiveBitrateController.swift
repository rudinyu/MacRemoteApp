import Foundation

/// Decides the Host encoder bitrate from congestion signals.
///
/// Additive-increase / multiplicative-decrease: a congestion signal cuts the
/// bitrate to `decreaseFactor` of its current value, at most once per
/// `decreaseHoldoffNanoseconds` so one burst of signals counts once. After
/// `increaseQuietNanoseconds` without congestion, a low-delay report raises
/// the bitrate by `increaseStepBitrate`, at most once per
/// `increaseIntervalNanoseconds`, back up to `maximumBitrate`.
///
/// The controller is pure: callers pass a monotonic time and apply the
/// returned bitrate to the encoder. It has no clock, codec, or network state.
public struct AdaptiveBitrateController: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var minimumBitrate: UInt32
        public var maximumBitrate: UInt32
        public var decreaseFactor: Double
        public var increaseStepBitrate: UInt32
        /// Mean queuing delay at or above this is congestion.
        public var congestionQueuingDelayMicroseconds: UInt32
        /// Mean queuing delay at or below this allows an increase.
        public var clearQueuingDelayMicroseconds: UInt32
        public var decreaseHoldoffNanoseconds: UInt64
        public var increaseQuietNanoseconds: UInt64
        public var increaseIntervalNanoseconds: UInt64

        public static func standard(maximumBitrate: UInt32) -> Configuration {
            Configuration(
                minimumBitrate: min(2_000_000, maximumBitrate),
                maximumBitrate: maximumBitrate,
                decreaseFactor: 0.7,
                increaseStepBitrate: max(1, maximumBitrate / 10),
                congestionQueuingDelayMicroseconds: 40_000,
                clearQueuingDelayMicroseconds: 15_000,
                decreaseHoldoffNanoseconds: 500_000_000,
                increaseQuietNanoseconds: 3_000_000_000,
                increaseIntervalNanoseconds: 1_000_000_000
            )
        }
    }

    public let configuration: Configuration
    public private(set) var bitrate: UInt32
    private var lastCongestionNanoseconds: UInt64?
    private var lastDecreaseNanoseconds: UInt64?
    private var lastIncreaseNanoseconds: UInt64?

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.bitrate = configuration.maximumBitrate
    }

    /// A local or remote loss signal: a Host queue discard, or a Viewer
    /// keyframe request caused by a media gap. Returns the new bitrate when
    /// it changed.
    public mutating func recordCongestion(atNanoseconds now: UInt64) -> UInt32? {
        lastCongestionNanoseconds = now
        if let lastDecreaseNanoseconds,
           now &- lastDecreaseNanoseconds < configuration.decreaseHoldoffNanoseconds {
            return nil
        }
        let reduced = UInt32(
            max(Double(configuration.minimumBitrate), Double(bitrate) * configuration.decreaseFactor)
                .rounded()
        )
        guard reduced < bitrate else { return nil }
        bitrate = reduced
        lastDecreaseNanoseconds = now
        return bitrate
    }

    /// A Viewer receiver report. Discards or high queuing delay count as
    /// congestion; a quiet, low-delay report may raise the bitrate. Returns
    /// the new bitrate when it changed.
    public mutating func recordReport(
        queuingDelayMicroseconds: UInt32,
        discardedFrames: UInt32,
        atNanoseconds now: UInt64
    ) -> UInt32? {
        if discardedFrames > 0 ||
            queuingDelayMicroseconds >= configuration.congestionQueuingDelayMicroseconds {
            return recordCongestion(atNanoseconds: now)
        }
        guard queuingDelayMicroseconds <= configuration.clearQueuingDelayMicroseconds,
              bitrate < configuration.maximumBitrate else {
            return nil
        }
        if let lastCongestionNanoseconds,
           now &- lastCongestionNanoseconds < configuration.increaseQuietNanoseconds {
            return nil
        }
        if let lastIncreaseNanoseconds,
           now &- lastIncreaseNanoseconds < configuration.increaseIntervalNanoseconds {
            return nil
        }
        bitrate = min(configuration.maximumBitrate, bitrate &+ configuration.increaseStepBitrate)
        lastIncreaseNanoseconds = now
        return bitrate
    }
}
