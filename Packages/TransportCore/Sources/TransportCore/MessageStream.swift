import Foundation
import RemoteProtocol

/// A single-consumer bounded stream for decoded session messages.
///
/// Control messages are reliable: they are never evicted. Media messages
/// follow the keyframe-aware policy in `KeyframeAwareMediaAdmission`: delta
/// frames are discarded only in a way that skips to the next keyframe, and
/// required media such as `VideoConfig` and keyframes may purge queued delta
/// frames. If no safe room exists, delivery fails explicitly instead of
/// silently losing a required message.
public struct MessageStream: AsyncSequence, Sendable {
    public typealias Element = MessagePayload
    public typealias Failure = Error

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let storage: MessageStreamStorage

        fileprivate init(storage: MessageStreamStorage) {
            self.storage = storage
        }

        public mutating func next() async throws -> MessagePayload? {
            try await storage.next()
        }
    }

    internal let storage: MessageStreamStorage

    fileprivate init(storage: MessageStreamStorage) {
        self.storage = storage
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage)
    }
}

internal enum MessageStreamYieldResult: Equatable, Sendable {
    case queued
    case replacedMedia
}

private final class PendingMessageWaiter: @unchecked Sendable {
    var continuation: CheckedContinuation<MessagePayload?, Error>?
    var isCancelled = false
}

internal final class MessageStreamStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let maxControlMessages: Int
    private let maxMediaMessages: Int
    private let beforeWaiterRegistrationHook: (@Sendable () -> Void)?
    private var queue: [MessagePayload] = []
    private var mediaAdmission = KeyframeAwareMediaAdmission()
    private var waiter: PendingMessageWaiter?
    private var isFinished = false
    private var terminalError: Error?

    init(
        maxControlMessages: Int,
        maxMediaMessages: Int,
        beforeWaiterRegistrationHook: (@Sendable () -> Void)? = nil
    ) throws {
        guard maxControlMessages > 0, maxMediaMessages > 0 else {
            throw TransportError.protocolViolation("message stream limits must be positive")
        }
        self.maxControlMessages = maxControlMessages
        self.maxMediaMessages = maxMediaMessages
        self.beforeWaiterRegistrationHook = beforeWaiterRegistrationHook
    }

    func next() async throws -> MessagePayload? {
        let pending = PendingMessageWaiter()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                var result: Result<MessagePayload?, Error>?

                beforeWaiterRegistrationHook?()

                lock.lock()
                if pending.isCancelled || Task.isCancelled {
                    pending.isCancelled = true
                    result = .failure(CancellationError())
                } else if !queue.isEmpty {
                    result = .success(queue.removeFirst())
                } else if isFinished {
                    if let terminalError {
                        result = .failure(terminalError)
                    } else {
                        result = .success(nil)
                    }
                } else if waiter == nil {
                    pending.continuation = continuation
                    waiter = pending
                } else {
                    result = .failure(
                        TransportError.protocolViolation("incoming message stream supports one consumer")
                    )
                }
                lock.unlock()

                if let result {
                    continuation.resume(with: result)
                }
            }
        }, onCancel: {
            cancel(pending)
        })
    }

    func yield(_ message: MessagePayload) throws -> MessageStreamYieldResult {
        var directWaiter: CheckedContinuation<MessagePayload?, Error>?
        let result: MessageStreamYieldResult

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            throw TransportError.alreadyClosed
        }

        switch message.messageType.defaultChannel {
        case .control:
            guard controlCountLocked < maxControlMessages else {
                lock.unlock()
                throw TransportError.controlBackpressure
            }
            result = .queued
        case .media:
            let decision: KeyframeAwareMediaAdmission.Decision
            do {
                decision = try mediaAdmission.admit(
                    message.mediaAdmissionKind,
                    into: &queue,
                    maxMediaCount: maxMediaMessages,
                    isMedia: { $0.messageType.defaultChannel == .media },
                    kindOf: \.mediaAdmissionKind
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

        if let waiter {
            self.waiter = nil
            directWaiter = waiter.continuation
            waiter.continuation = nil
        } else {
            queue.append(message)
        }
        lock.unlock()

        directWaiter?.resume(returning: message)
        return result
    }

    func finish(throwing error: Error? = nil) {
        var waiterToResume: CheckedContinuation<MessagePayload?, Error>?

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        terminalError = error
        waiterToResume = waiter?.continuation
        waiter?.continuation = nil
        waiter = nil
        lock.unlock()

        if let error {
            waiterToResume?.resume(throwing: error)
        } else {
            waiterToResume?.resume(returning: nil)
        }
    }

    func removeProtectedMessages() {
        lock.withLock {
            let mediaCount = mediaCountLocked
            queue.removeAll { $0.isProtectedSessionMessage }
            if mediaCountLocked != mediaCount {
                mediaAdmission.noteMediaRemoved()
            }
        }
    }

    /// Removes queued input records after a local Host safety transition.
    ///
    /// Other control messages remain available to the app dispatcher. An
    /// input record already handed to the sole consumer cannot be recalled;
    /// the Host input loop therefore pairs this operation with its controller
    /// reset before it admits another record.
    func removePendingInputMessages() {
        lock.withLock {
            queue.removeAll { message in
                if case .inputEvent = message {
                    return true
                }
                return false
            }
        }
    }

    func reset() {
        lock.withLock {
            queue.removeAll(keepingCapacity: false)
            mediaAdmission.reset()
            isFinished = false
            terminalError = nil
        }
    }

    func hasWaitingConsumer() -> Bool {
        lock.withLock { waiter != nil }
    }

    private func cancel(_ pending: PendingMessageWaiter) {
        var continuationToResume: CheckedContinuation<MessagePayload?, Error>?

        lock.lock()
        pending.isCancelled = true
        if let waiter, waiter === pending {
            self.waiter = nil
            continuationToResume = waiter.continuation
            waiter.continuation = nil
        }
        lock.unlock()

        continuationToResume?.resume(throwing: CancellationError())
    }

    func counts() -> (control: Int, media: Int) {
        lock.withLock {
            (controlCountLocked, mediaCountLocked)
        }
    }

    private var controlCountLocked: Int {
        queue.reduce(into: 0) { count, message in
            if message.messageType.defaultChannel == .control {
                count += 1
            }
        }
    }

    private var mediaCountLocked: Int {
        queue.reduce(into: 0) { count, message in
            if message.messageType.defaultChannel == .media {
                count += 1
            }
        }
    }
}

private extension MessagePayload {
    var mediaAdmissionKind: KeyframeAwareMediaAdmission.Kind {
        guard messageType.defaultChannel == .media else { return .control }
        guard case let .videoFrame(frame) = self else { return .requiredMedia }
        return frame.keyframe ? .keyframe : .deltaFrame
    }

    var isProtectedSessionMessage: Bool {
        switch self {
        case .windowList, .windowSelection, .streamConfig, .videoConfig,
             .videoFrame, .inputEvent, .clipboardOffer, .clipboardText,
             .clipboardAcknowledgement, .keyframeRequest, .receiverReport:
            return true
        default:
            return false
        }
    }
}

extension MessageStream {
    internal static func makeBounded(
        maxControlMessages: Int,
        maxMediaMessages: Int,
        beforeWaiterRegistrationHook: (@Sendable () -> Void)? = nil
    ) throws -> (stream: MessageStream, storage: MessageStreamStorage) {
        let storage = try MessageStreamStorage(
            maxControlMessages: maxControlMessages,
            maxMediaMessages: maxMediaMessages,
            beforeWaiterRegistrationHook: beforeWaiterRegistrationHook
        )
        return (MessageStream(storage: storage), storage)
    }
}
