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
    typealias Element = Result<EncodedH264Frame, CodecError>

    static let capacity = 8

    let frames: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let lock = NSLock()
    private var droppedFrame = false

    init() {
        (frames, continuation) = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: .bufferingOldest(Self.capacity)
        )
    }

    /// Called from the encoder completion callback.
    func submit(_ result: Element) {
        if case .dropped = continuation.yield(result) {
            lock.withLock { droppedFrame = true }
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
