import RemoteProtocol

/// Viewer-side congestion measurement for `ReceiverReport`.
///
/// Each video envelope carries the Host's monotonic send-admission time. The
/// difference to the Viewer's receive time mixes a fixed clock offset with the
/// time the frame spent in queues (Host send queue, TCP buffers, network).
/// The fixed part is removed by subtracting the minimum difference seen over
/// the last one to two `baselineWindowNanoseconds`; what remains is queuing
/// delay, which rises before any frame is dropped. The windowed minimum also
/// absorbs slow clock drift.
///
/// Pure value type: the caller supplies all timestamps.
struct ReceiverCongestionMonitor: Sendable {
    static let reportIntervalNanoseconds: UInt64 = 500_000_000
    static let baselineWindowNanoseconds: UInt64 = 5_000_000_000

    private var baselineWindowStart: UInt64?
    private var currentWindowMinimum: Int64?
    private var previousWindowMinimum: Int64?
    private var intervalStart: UInt64?
    private var queuingDelaySum: UInt64 = 0
    private var receivedFrames: UInt64 = 0
    private var discardedFrames: UInt64 = 0

    mutating func recordFrame(senderTimestamp: UInt64, receivedAt now: UInt64) {
        // The two clocks differ, so the difference may be negative; a wrapping
        // subtraction reinterpreted as signed keeps it exact within ±2^63 ns.
        let sample = Int64(bitPattern: now &- senderTimestamp)
        if let start = baselineWindowStart,
           now &- start < Self.baselineWindowNanoseconds {
            currentWindowMinimum = min(currentWindowMinimum ?? sample, sample)
        } else {
            previousWindowMinimum = currentWindowMinimum
            currentWindowMinimum = sample
            baselineWindowStart = now
        }
        let current = currentWindowMinimum ?? sample
        let baseline = min(current, previousWindowMinimum ?? current)
        let (delay, overflow) = sample.subtractingReportingOverflow(baseline)
        if !overflow, delay > 0 {
            queuingDelaySum &+= UInt64(delay)
        }
        receivedFrames &+= 1
        if intervalStart == nil {
            intervalStart = now
        }
    }

    mutating func recordDiscarded(_ count: UInt64, at now: UInt64) {
        discardedFrames &+= count
        if intervalStart == nil {
            intervalStart = now
        }
    }

    /// Returns a report once per interval when there was activity, and starts
    /// a new interval. The baseline is kept across intervals.
    mutating func takeReport(generation: UInt64, at now: UInt64) -> ReceiverReportMessage? {
        guard let intervalStart,
              now &- intervalStart >= Self.reportIntervalNanoseconds,
              receivedFrames > 0 || discardedFrames > 0 else {
            return nil
        }
        let meanDelayNanoseconds = receivedFrames > 0 ? queuingDelaySum / receivedFrames : 0
        let report = ReceiverReportMessage(
            generation: generation,
            queuingDelayMicroseconds: Self.clamped(meanDelayNanoseconds / 1_000),
            receivedFrames: Self.clamped(receivedFrames),
            discardedFrames: Self.clamped(discardedFrames)
        )
        self.intervalStart = now
        queuingDelaySum = 0
        receivedFrames = 0
        discardedFrames = 0
        return report
    }

    private static func clamped(_ value: UInt64) -> UInt32 {
        UInt32(min(value, UInt64(UInt32.max)))
    }
}
