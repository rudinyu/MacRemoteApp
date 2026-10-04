import CodecCore
import Foundation

/// Hands encoder output to one sender task in encode order.
///
/// VideoToolbox completion callbacks arrive in encode order, but spawning a
/// separate `Task` per callback does not guarantee the actor runs them in that
/// order. A reordered H.264 frame would receive a valid, increasing wire
/// sequence and still decode against the wrong reference. The relay keeps a
/// single FIFO consumer instead.
///
/// The buffer is bounded. If it overflows, the dropped frame breaks the
/// reference chain, so the consumer is told to skip delta frames until the
/// next keyframe and to request one, matching the transport queue policy.
final class HostEncodedFrameRelay: @unchecked Sendable {
    typealias ResultElement = Result<EncodedH264Frame, CodecError>

    struct Frame: Sendable {
        let result: ResultElement
        /// True only on the first accepted frame submitted after one or more
        /// frames were dropped from the bounded stream.
        let followsDroppedFrame: Bool
    }

    static let capacity = 8

    let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private let lock = NSLock()
    private var droppedFrame = false
    private var discontinuityPending = false

    init() {
        (frames, continuation) = AsyncStream.makeStream(
            of: Frame.self,
            bufferingPolicy: .bufferingOldest(Self.capacity)
        )
    }

    /// Called from the encoder completion callback.
    func submit(_ result: ResultElement) {
        lock.withLock {
            let frame = Frame(
                result: result,
                followsDroppedFrame: discontinuityPending
            )
            switch continuation.yield(frame) {
            case .enqueued:
                discontinuityPending = false
            case .dropped:
                // Regardless of whether the rejected result is a keyframe or
                // a codec error, it represents a gap in the encoded sequence.
                droppedFrame = true
                discontinuityPending = true
            case .terminated:
                break
            @unknown default:
                droppedFrame = true
                discontinuityPending = true
            }
        }
    }

    /// Returns whether a frame was dropped since the last call.
    func takeDroppedFrame() -> Bool {
        lock.withLock {
            defer { droppedFrame = false }
            return droppedFrame
        }
    }

    func finish() {
        continuation.finish()
    }
}

/// Applies the sender-side H.264 recovery rule to relay entries in FIFO order.
struct HostEncodedFrameContinuity {
    struct Decision {
        let requestKeyframe: Bool
        let shouldSend: Bool
    }

    private(set) var awaitingKeyframe = false

    /// A drop notification requests recovery immediately. The per-entry marker
    /// controls when the consumer begins skipping, because earlier buffered
    /// entries still precede the dropped frame in FIFO order.
    mutating func consume(
        _ relayFrame: HostEncodedFrameRelay.Frame,
        droppedFrameObserved: Bool
    ) -> Decision {
        if relayFrame.followsDroppedFrame {
            awaitingKeyframe = true
        }

        guard awaitingKeyframe else {
            return Decision(
                requestKeyframe: droppedFrameObserved,
                shouldSend: true
            )
        }
        guard case let .success(frame) = relayFrame.result, frame.keyframe else {
            return Decision(
                requestKeyframe: droppedFrameObserved,
                shouldSend: false
            )
        }

        awaitingKeyframe = false
        return Decision(
            requestKeyframe: droppedFrameObserved,
            shouldSend: true
        )
    }
}
