import Foundation
import InputCore

struct ViewerInputSendScope: Equatable, Sendable {
    let sessionID: UUID
    let authorizationGeneration: UInt64
    let windowGeneration: UInt64
}

/// Snapshot replies may arrive out of order even though their session actor
/// advanced authorization monotonically. Only the current session may call this.
struct ViewerAuthorizationSnapshotGate {
    private var sessionID: UUID?
    private var generation: UInt64 = 0

    mutating func admit(sessionID: UUID, authorizationGeneration: UInt64) -> Bool {
        if self.sessionID == sessionID, authorizationGeneration < generation {
            return false
        }
        self.sessionID = sessionID
        generation = authorizationGeneration
        return true
    }
}

/// Retry cleanup can retain its disabled/reconnecting UI only while all three
/// owners are still current. It must decide before asynchronous teardown starts.
struct ViewerRetryCleanupOwnership {
    let sessionID: UUID
    let attemptID: UUID
    let reconnectID: UUID

    func matches(
        sessionID: UUID?,
        attemptID: UUID?,
        reconnectID: UUID?
    ) -> Bool {
        self.sessionID == sessionID &&
            self.attemptID == attemptID &&
            self.reconnectID == reconnectID
    }
}

enum ViewerSessionCleanupPresentation: Equatable {
    case disconnected
    case reconnecting

    var hostSelectionEnabled: Bool { self == .disconnected }

    static func resolve(
        retryOwnership: ViewerRetryCleanupOwnership?,
        sessionID: UUID?,
        attemptID: UUID?,
        reconnectID: UUID?
    ) -> Self? {
        guard let retryOwnership else { return .disconnected }
        guard retryOwnership.matches(
            sessionID: sessionID,
            attemptID: attemptID,
            reconnectID: reconnectID
        ) else { return nil }
        return .reconnecting
    }
}

/// A bounded FIFO with one consumer. Scope changes discard queued work, while
/// an already-running send is allowed to finish before the next scope drains.
@MainActor
final class ViewerInputSendQueue {
    enum EnqueueResult: Equatable {
        case enqueued
        case staleScope
        case overflow
    }

    typealias Sender = (InputEventRecord, UInt64) async throws -> Void

    private struct Entry {
        let record: InputEventRecord
        let scope: ViewerInputSendScope
        let sender: Sender
    }

    private let capacity: Int
    private let onFailure: (ViewerInputSendScope) -> Void
    private var activeScope: ViewerInputSendScope?
    private var entries: [Entry] = []
    private var isSending = false
    private var worker: Task<Void, Never>?
    private var workerID: UUID?

    init(
        capacity: Int = 128,
        onFailure: @escaping (ViewerInputSendScope) -> Void = { _ in }
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.onFailure = onFailure
    }

    func updateScope(_ scope: ViewerInputSendScope?) {
        guard scope != activeScope else { return }
        activeScope = scope
        entries.removeAll(keepingCapacity: true)
        worker?.cancel()
        startWorkerIfNeeded()
    }

    @discardableResult
    func enqueue(
        _ record: InputEventRecord,
        in scope: ViewerInputSendScope,
        send: @escaping Sender
    ) -> EnqueueResult {
        guard activeScope == scope,
              record.windowGeneration == scope.windowGeneration else {
            return .staleScope
        }
        guard entries.count + (isSending ? 1 : 0) < capacity else {
            invalidate(scope, notifyFailure: true)
            return .overflow
        }
        entries.append(Entry(record: record, scope: scope, sender: send))
        startWorkerIfNeeded()
        return .enqueued
    }

    func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !entries.isEmpty else { return }
        let id = UUID()
        workerID = id
        worker = Task { @MainActor [weak self] in
            await self?.consume(workerID: id)
        }
    }

    private func consume(workerID id: UUID) async {
        while !Task.isCancelled,
              workerID == id,
              !entries.isEmpty {
            let entry = entries.removeFirst()
            guard activeScope == entry.scope else { continue }
            isSending = true
            do {
                try await entry.sender(
                    entry.record,
                    entry.scope.authorizationGeneration
                )
            } catch {
                isSending = false
                if activeScope == entry.scope {
                    invalidate(entry.scope, notifyFailure: true)
                }
            }
            isSending = false
        }

        guard workerID == id else { return }
        worker = nil
        workerID = nil
        startWorkerIfNeeded()
    }

    private func invalidate(
        _ scope: ViewerInputSendScope,
        notifyFailure: Bool
    ) {
        guard activeScope == scope else { return }
        activeScope = nil
        entries.removeAll(keepingCapacity: true)
        worker?.cancel()
        if notifyFailure {
            onFailure(scope)
        }
    }
}

/// Opaque app-local fence for asynchronous decode and drawable callbacks.
@MainActor
final class ViewerPresentationLifetime {
    private(set) var token = UUID()

    @discardableResult
    func advance() -> UUID {
        token = UUID()
        return token
    }

    func accepts(_ candidate: UUID) -> Bool {
        token == candidate
    }
}
