import Foundation
import InputCore

struct ViewerInputSendScope: Equatable, Sendable {
    let sessionID: UUID
    let authorizationGeneration: UInt64
    let windowGeneration: UInt64
}

enum ViewerInputSourceSyncState: Equatable, Sendable {
    case inactive
    case manualSelection
    case pending
    case synchronized
    case failed
}

struct ViewerInputSourceSyncRequest: Equatable, Sendable {
    let scope: ViewerInputSendScope
    let requestID: UInt64
    let source: InputSourceDescriptor
}

enum ViewerInputSourceSyncAcknowledgement: Equatable {
    case stale
    case applied([InputEventRecord])
    case failed
}

enum ViewerKeyboardInputDecision: Equatable {
    case send
    case buffered
    case discarded
    case overflow
}

/// Fences keyboard delivery until the exact input-source request for the
/// current session/epoch/window is acknowledged. Pending presses are bounded
/// and are discarded on supersession; keys that were actually sent are tracked
/// separately so the app can release them in-order before the next source
/// request reaches the Host.
struct ViewerInputSourceSyncGate {
    private let maximumBufferedEvents: Int
    private(set) var state: ViewerInputSourceSyncState = .inactive
    private(set) var scope: ViewerInputSendScope?
    private(set) var pendingRequest: ViewerInputSourceSyncRequest?
    private(set) var synchronizedSource: InputSourceDescriptor?
    private(set) var failedSource: InputSourceDescriptor?
    private(set) var manualSelectionSource: InputSourceDescriptor?
    private(set) var keyboardDeliveryToken = UUID()

    private var nextRequestID: UInt64 = 1
    private var requestIDsExhausted = false
    private var bufferedEvents: [InputEventRecord] = []
    private var bufferedPressedKeys: Set<UInt16> = []
    private var physicallyPressedKeys: Set<UInt16> = []
    private var discardUntilPhysicalRelease: Set<UInt16> = []
    private var queuedPressedKeys: Set<UInt16> = []
    private var remotelyPressedKeys: Set<UInt16> = []
    private var scheduledReleaseKeys: Set<UInt16> = []

    init(maximumBufferedEvents: Int = 64) {
        precondition(maximumBufferedEvents > 0)
        self.maximumBufferedEvents = maximumBufferedEvents
    }

    mutating func beginSynchronization(
        in newScope: ViewerInputSendScope,
        source: InputSourceDescriptor
    ) -> ViewerInputSourceSyncRequest? {
        guard newScope.windowGeneration > 0, source.isValid,
              !requestIDsExhausted else {
            failPendingSynchronization()
            return nil
        }

        discardBufferedKeyboard()
        discardUntilPhysicalRelease.formUnion(physicallyPressedKeys)
        queuedPressedKeys.removeAll(keepingCapacity: false)
        rotateKeyboardDeliveryToken()
        scope = newScope
        synchronizedSource = nil
        failedSource = nil
        manualSelectionSource = nil
        let request = ViewerInputSourceSyncRequest(
            scope: newScope,
            requestID: nextRequestID,
            source: source
        )
        if nextRequestID == UInt64.max {
            requestIDsExhausted = true
        } else {
            nextRequestID += 1
        }
        pendingRequest = request
        state = .pending
        return request
    }

    mutating func useManualSelection(
        in newScope: ViewerInputSendScope,
        source: InputSourceDescriptor? = nil
    ) {
        guard state != .manualSelection || scope != newScope || manualSelectionSource != source else { return }
        discardBufferedKeyboard()
        discardUntilPhysicalRelease.formUnion(physicallyPressedKeys.subtracting(remotelyPressedKeys))
        queuedPressedKeys.removeAll(keepingCapacity: false)
        rotateKeyboardDeliveryToken()
        scope = newScope
        pendingRequest = nil
        synchronizedSource = nil
        failedSource = nil
        manualSelectionSource = source
        state = .manualSelection
    }

    mutating func setInactive() {
        discardBufferedKeyboard()
        discardUntilPhysicalRelease.formUnion(physicallyPressedKeys.subtracting(remotelyPressedKeys))
        queuedPressedKeys.removeAll(keepingCapacity: false)
        rotateKeyboardDeliveryToken()
        pendingRequest = nil
        synchronizedSource = nil
        failedSource = nil
        manualSelectionSource = nil
        state = .inactive
    }

    mutating func invalidateScope() {
        setInactive()
        scope = nil
        physicallyPressedKeys.removeAll(keepingCapacity: false)
        discardUntilPhysicalRelease.removeAll(keepingCapacity: false)
        queuedPressedKeys.removeAll(keepingCapacity: false)
        remotelyPressedKeys.removeAll(keepingCapacity: false)
        scheduledReleaseKeys.removeAll(keepingCapacity: false)
        rotateKeyboardDeliveryToken()
    }

    func isCurrent(_ request: ViewerInputSourceSyncRequest) -> Bool {
        state == .pending && pendingRequest == request && scope == request.scope
    }

    func needsSynchronization(
        to source: InputSourceDescriptor,
        in requestedScope: ViewerInputSendScope
    ) -> Bool {
        guard scope == requestedScope else { return true }
        if state == .pending, pendingRequest?.source == source { return false }
        switch state {
        case .inactive:
            return true
        case .manualSelection:
            return manualSelectionSource != source
        case .pending:
            return true
        case .synchronized:
            return synchronizedSource != source
        case .failed:
            return failedSource != source
        }
    }

    func allowsQueuedKeyboardSend(
        _ record: InputEventRecord,
        in eventScope: ViewerInputSendScope,
        deliveryToken: UUID
    ) -> Bool {
        guard scope == eventScope else { return false }
        if keyboardDeliveryToken != deliveryToken {
            // State changes invalidate queued presses, but an already-remote
            // key must still receive its ordered release in the same scope.
            return record.kind == .keyUp &&
                record.keyCode.map(remotelyPressedKeys.contains) == true
        }
        switch record.kind {
        case .keyDown:
            return state == .manualSelection || state == .synchronized
        case .keyUp:
            return state == .manualSelection || state == .synchronized ||
                record.keyCode.map(remotelyPressedKeys.contains) == true
        default:
            return false
        }
    }

    mutating func routeKeyboard(
        _ record: InputEventRecord,
        in eventScope: ViewerInputSendScope
    ) -> ViewerKeyboardInputDecision {
        guard scope == eventScope,
              record.windowGeneration == eventScope.windowGeneration,
              let keyCode = record.keyCode else {
            return .discarded
        }

        switch record.kind {
        case .keyDown:
            physicallyPressedKeys.insert(keyCode)
            guard !discardUntilPhysicalRelease.contains(keyCode) else { return .discarded }
            switch state {
            case .manualSelection, .synchronized:
                queuedPressedKeys.insert(keyCode)
                return .send
            case .pending:
                return buffer(record, pressedKey: keyCode)
            case .inactive, .failed:
                return .discarded
            }

        case .keyUp:
            physicallyPressedKeys.remove(keyCode)
            if discardUntilPhysicalRelease.remove(keyCode) != nil {
                bufferedPressedKeys.remove(keyCode)
                return .discarded
            }
            switch state {
            case .manualSelection, .synchronized:
                guard queuedPressedKeys.remove(keyCode) != nil ||
                        remotelyPressedKeys.contains(keyCode) else { return .discarded }
                return .send
            case .pending:
                guard bufferedPressedKeys.remove(keyCode) != nil else { return .discarded }
                return buffer(record, pressedKey: nil)
            case .inactive, .failed:
                // A state-ending event for a key already delivered to the
                // Host is always allowed through, even after a failed ACK.
                return remotelyPressedKeys.contains(keyCode) ? .send : .discarded
            }

        default:
            return .discarded
        }
    }

    mutating func acknowledge(
        scope acknowledgedScope: ViewerInputSendScope,
        requestID: UInt64,
        applied: Bool
    ) -> ViewerInputSourceSyncAcknowledgement {
        guard let pendingRequest,
              self.scope == acknowledgedScope,
              pendingRequest.scope == acknowledgedScope,
              pendingRequest.requestID == requestID else {
            return .stale
        }

        self.pendingRequest = nil
        guard applied else {
            failPendingSynchronization(source: pendingRequest.source)
            return .failed
        }

        state = .synchronized
        synchronizedSource = pendingRequest.source
        failedSource = nil
        manualSelectionSource = nil
        let events = bufferedEvents
        bufferedEvents.removeAll(keepingCapacity: true)
        bufferedPressedKeys.removeAll(keepingCapacity: false)
        return .applied(events)
    }

    mutating func timeout(
        scope timedOutScope: ViewerInputSendScope,
        requestID: UInt64
    ) -> Bool {
        guard let pendingRequest,
              pendingRequest.scope == timedOutScope,
              pendingRequest.requestID == requestID,
              scope == timedOutScope else {
            return false
        }
        failPendingSynchronization()
        return true
    }

    /// Called only after the transport send succeeds, so this set represents
    /// Host-admitted held keys rather than locally buffered key presses.
    mutating func noteDelivered(
        _ record: InputEventRecord,
        in deliveredScope: ViewerInputSendScope
    ) {
        guard scope == deliveredScope,
              record.windowGeneration == deliveredScope.windowGeneration,
              let keyCode = record.keyCode else { return }
        switch record.kind {
        case .keyDown:
            remotelyPressedKeys.insert(keyCode)
        case .keyUp:
            remotelyPressedKeys.remove(keyCode)
            queuedPressedKeys.remove(keyCode)
            scheduledReleaseKeys.remove(keyCode)
        default:
            break
        }
    }

    /// Evaluated from the ordered send-queue barrier, after all earlier key
    /// sends have completed. The returned keys are remotely held and can be
    /// released before the matching source-selection request is sent.
    mutating func takeRemoteKeysForOrderedRelease(
        in requestedScope: ViewerInputSendScope
    ) -> [UInt16] {
        guard scope == requestedScope else { return [] }
        let keys = remotelyPressedKeys.subtracting(scheduledReleaseKeys).sorted()
        scheduledReleaseKeys.formUnion(keys)
        return keys
    }

    private mutating func buffer(
        _ record: InputEventRecord,
        pressedKey: UInt16?
    ) -> ViewerKeyboardInputDecision {
        guard bufferedEvents.count < maximumBufferedEvents else {
            failPendingSynchronization()
            return .overflow
        }
        bufferedEvents.append(record)
        if let pressedKey {
            bufferedPressedKeys.insert(pressedKey)
        }
        return .buffered
    }

    private mutating func discardBufferedKeyboard() {
        bufferedEvents.removeAll(keepingCapacity: true)
        bufferedPressedKeys.removeAll(keepingCapacity: false)
    }

    private mutating func failPendingSynchronization(source: InputSourceDescriptor? = nil) {
        discardBufferedKeyboard()
        discardUntilPhysicalRelease.formUnion(physicallyPressedKeys.subtracting(remotelyPressedKeys))
        failedSource = source ?? pendingRequest?.source
        pendingRequest = nil
        synchronizedSource = nil
        manualSelectionSource = nil
        queuedPressedKeys.removeAll(keepingCapacity: false)
        rotateKeyboardDeliveryToken()
        state = .failed
    }

    private mutating func rotateKeyboardDeliveryToken() {
        keyboardDeliveryToken = UUID()
    }
}

/// Snapshot replies may arrive out of order even though their session actor
/// advanced authorization monotonically. Only the current session may call this.
struct ViewerInputSourceRetryGate {
    private(set) var isWaitingForRemoteFocus = false

    mutating func request(remoteSurfaceFocused: Bool) -> Bool {
        guard remoteSurfaceFocused else {
            isWaitingForRemoteFocus = true
            return false
        }
        isWaitingForRemoteFocus = false
        return true
    }

    mutating func consumeOnRemoteFocus() -> Bool {
        guard isWaitingForRemoteFocus else { return false }
        isWaitingForRemoteFocus = false
        return true
    }

    mutating func cancel() {
        isWaitingForRemoteFocus = false
    }
}

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
    typealias Operation = (ViewerInputSendScope) async throws -> Void

    private struct Entry {
        let scope: ViewerInputSendScope
        let operation: Operation
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
        entries.append(Entry(scope: scope) { currentScope in
            try await send(record, currentScope.authorizationGeneration)
        })
        startWorkerIfNeeded()
        return .enqueued
    }

    @discardableResult
    func enqueueOperation(
        in scope: ViewerInputSendScope,
        operation: @escaping Operation
    ) -> EnqueueResult {
        guard activeScope == scope else { return .staleScope }
        guard entries.count + (isSending ? 1 : 0) < capacity else {
            invalidate(scope, notifyFailure: true)
            return .overflow
        }
        entries.append(Entry(scope: scope, operation: operation))
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
                try await entry.operation(entry.scope)
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
