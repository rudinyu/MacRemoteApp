import Foundation
import RemoteProtocol

/// A single-consumer bounded stream used by the transport implementations.
///
/// Control messages are never evicted. Media follows the keyframe-aware
/// policy in `KeyframeAwareMediaAdmission`, so a discarded delta frame never
/// leaves later delta frames referencing a missing picture. The queue is deliberately
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

    struct ReceiptAwareAsyncIterator: AsyncIteratorProtocol {
        fileprivate let storage: EnvelopeStreamStorage

        mutating func next() async throws -> EnvelopeStreamElement? {
            try await storage.nextStamped()
        }
    }

    fileprivate let storage: EnvelopeStreamStorage

    fileprivate init(storage: EnvelopeStreamStorage) {
        self.storage = storage
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage)
    }

    func makeReceiptAwareAsyncIterator() -> ReceiptAwareAsyncIterator {
        ReceiptAwareAsyncIterator(storage: storage)
    }

    func installReceiptStampProvider(_ provider: @escaping @Sendable () -> EnvelopeReceiptStamp) {
        storage.installReceiptStampProvider(provider)
    }

    func removeProtectedMessages() {
        storage.removeProtectedMessages()
    }
}

struct EnvelopeReceiptStamp: Sendable {
    let epoch: UInt64
    let transitionInFlight: Bool
}

struct EnvelopeStreamElement: Sendable {
    let envelope: Envelope
    let receiptStamp: EnvelopeReceiptStamp?
}

internal enum EnvelopeStreamYieldResult: Equatable, Sendable {
    case queued
    case replacedMedia
}

internal final class EnvelopeStreamStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let maxControlFrames: Int
    private let maxMediaFrames: Int
    private var queue: [EnvelopeStreamElement] = []
    private var mediaAdmission = KeyframeAwareMediaAdmission()
    private var waiter: CheckedContinuation<EnvelopeStreamElement?, Error>?
    private var receiptStampProvider: (@Sendable () -> EnvelopeReceiptStamp)?
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
        try await nextStamped()?.envelope
    }

    func nextStamped() async throws -> EnvelopeStreamElement? {
        try await withCheckedThrowingContinuation { continuation in
            var result: Result<EnvelopeStreamElement?, Error>?

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
        var directWaiter: CheckedContinuation<EnvelopeStreamElement?, Error>?
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
            let decision: KeyframeAwareMediaAdmission.Decision
            do {
                decision = try mediaAdmission.admit(
                    envelope.mediaAdmissionKind,
                    into: &queue,
                    maxMediaCount: maxMediaFrames,
                    isMedia: { $0.envelope.channel == .media },
                    kindOf: { $0.envelope.mediaAdmissionKind }
                )
            } catch {
                lock.unlock()
                throw error
            }
            result = decision.awaitingKeyframe ? .replacedMedia : .queued
            guard decision.admitIncoming else {
                lock.unlock()
                return result
            }
        }

        let item = EnvelopeStreamElement(
            envelope: envelope,
            receiptStamp: receiptStampProvider?()
        )

        if let waiter {
            self.waiter = nil
            directWaiter = waiter
        } else {
            queue.append(item)
        }
        lock.unlock()

        directWaiter?.resume(returning: item)
        return result
    }

    func installReceiptStampProvider(_ provider: @escaping @Sendable () -> EnvelopeReceiptStamp) {
        lock.withLock {
            receiptStampProvider = provider
        }
    }

    func finish(throwing error: Error? = nil) {
        var waiterToResume: CheckedContinuation<EnvelopeStreamElement?, Error>?

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
            let mediaCount = mediaCountLocked
            queue = queue.map { item in
                EnvelopeStreamElement(
                    envelope: item.envelope.authorizationInvalidationTombstone ?? item.envelope,
                    receiptStamp: item.receiptStamp
                )
            }.filter {
                !$0.envelope.isProtectedSessionMessage || $0.envelope.channel == .control
            }
            if mediaCountLocked != mediaCount {
                mediaAdmission.noteMediaRemoved()
            }
        }
    }

    private var controlCountLocked: Int {
        queue.reduce(into: 0) { count, item in
            if item.envelope.channel == .control {
                count += 1
            }
        }
    }

    private var mediaCountLocked: Int {
        queue.reduce(into: 0) { count, item in
            if item.envelope.channel == .media {
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
