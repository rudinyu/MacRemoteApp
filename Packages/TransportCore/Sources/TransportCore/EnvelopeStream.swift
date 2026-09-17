import Foundation
import RemoteProtocol

/// A single-consumer bounded stream used by the transport implementations.
///
/// Control messages are never evicted. When the media limit is reached, only
/// an older discardable video frame may be replaced. The queue is deliberately
/// implemented outside AsyncThrowingStream so the per-channel limits remain
/// enforceable even when the consumer is slow.
public struct EnvelopeStream: AsyncSequence, Sendable {
    public typealias Element = Envelope
    public typealias Failure = Error

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let storage: EnvelopeStreamStorage

        public mutating func next() async throws -> Envelope? {
            try await storage.next()
        }
    }

    fileprivate let storage: EnvelopeStreamStorage

    fileprivate init(storage: EnvelopeStreamStorage) {
        self.storage = storage
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage)
    }
}

internal enum EnvelopeStreamYieldResult: Equatable, Sendable {
    case queued
    case replacedMedia
}

internal final class EnvelopeStreamStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let maxControlFrames: Int
    private let maxMediaFrames: Int
    private var queue: [Envelope] = []
    private var waiter: CheckedContinuation<Envelope?, Error>?
    private var isFinished = false
    private var terminalError: Error?

    init(maxControlFrames: Int, maxMediaFrames: Int) throws {
        guard maxControlFrames > 0, maxMediaFrames > 0 else {
            throw TransportError.protocolViolation("stream limits must be positive")
        }
        self.maxControlFrames = maxControlFrames
        self.maxMediaFrames = maxMediaFrames
    }

    func next() async throws -> Envelope? {
        try await withCheckedThrowingContinuation { continuation in
            var result: Result<Envelope?, Error>?

            lock.lock()
            if !queue.isEmpty {
                result = .success(queue.removeFirst())
            } else if isFinished {
                if let terminalError {
                    result = .failure(terminalError)
                } else {
                    result = .success(nil)
                }
            } else if waiter == nil {
                waiter = continuation
            } else {
                result = .failure(
                    TransportError.protocolViolation("incoming stream supports one consumer")
                )
            }
            lock.unlock()

            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func yield(_ envelope: Envelope) throws -> EnvelopeStreamYieldResult {
        var directWaiter: CheckedContinuation<Envelope?, Error>?
        let result: EnvelopeStreamYieldResult

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            throw TransportError.alreadyClosed
        }

        switch envelope.channel {
        case .control:
            guard controlCountLocked < maxControlFrames else {
                lock.unlock()
                throw TransportError.controlBackpressure
            }
            result = .queued
        case .media:
            if mediaCountLocked >= maxMediaFrames {
                guard envelope.isDiscardableMedia,
                      let discardableIndex = queue.firstIndex(where: { $0.isDiscardableMedia }) else {
                    lock.unlock()
                    throw TransportError.mediaBackpressure
                }
                queue.remove(at: discardableIndex)
                result = .replacedMedia
            } else {
                result = .queued
            }
        }

        if let waiter {
            self.waiter = nil
            directWaiter = waiter
        } else {
            queue.append(envelope)
        }
        lock.unlock()

        directWaiter?.resume(returning: envelope)
        return result
    }

    func finish(throwing error: Error? = nil) {
        var waiterToResume: CheckedContinuation<Envelope?, Error>?

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        terminalError = error
        waiterToResume = waiter
        waiter = nil
        lock.unlock()

        if let error {
            waiterToResume?.resume(throwing: error)
        } else {
            waiterToResume?.resume(returning: nil)
        }
    }

    func counts() -> (control: Int, media: Int) {
        lock.withLock {
            (controlCountLocked, mediaCountLocked)
        }
    }

    func removeProtectedMessages() {
        lock.withLock {
            // Control sequence numbers are strict. Replace an invalidated
            // protected control envelope with an optional tombstone so local
            // sequence validation can continue without exposing its payload.
            // Protected media is best-effort and can be purged outright.
            queue = queue.map {
                $0.authorizationInvalidationTombstone ?? $0
            }.filter {
                !$0.isProtectedSessionMessage || $0.channel == .control
            }
        }
    }

    private var controlCountLocked: Int {
        queue.reduce(into: 0) { count, envelope in
            if envelope.channel == .control {
                count += 1
            }
        }
    }

    private var mediaCountLocked: Int {
        queue.reduce(into: 0) { count, envelope in
            if envelope.channel == .media {
                count += 1
            }
        }
    }
}

extension EnvelopeStream {
    static func makeBounded(
        maxControlFrames: Int,
        maxMediaFrames: Int
    ) throws -> (stream: EnvelopeStream, storage: EnvelopeStreamStorage) {
        let storage = try EnvelopeStreamStorage(
            maxControlFrames: maxControlFrames,
            maxMediaFrames: maxMediaFrames
        )
        return (EnvelopeStream(storage: storage), storage)
    }
}
