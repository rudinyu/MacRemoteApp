import Foundation
import InputCore
import RemoteProtocol
import TransportCore

/// Keeps a deferred release tied to the Host session that admitted it. A new
/// Host session invalidates the old lease before it can use the same selected
/// window, while a released runtime may still keep its own lease alive long
/// enough to finish cleanup.
final class HostInputSessionCleanupLease: @unchecked Sendable {
    private let lock = NSLock()
    private var isValid = true

    func invalidate() {
        lock.lock()
        isValid = false
        lock.unlock()
    }

    func withValidAccess<T>(_ operation: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard isValid else { return nil }
        return operation()
    }
}

/// Serializes input admissions with a local CaptureCore selection replacement.
/// The replacement barrier remains held until the lifecycle owner explicitly
/// completes the provider update, so a stream waiter cannot admit an event in
/// the gap between the old-target reset and the new-target publication.
private actor HostInputAdmissionGate {
    private var selectionChangeDepth = 0
    private var inFlightInputs = 0
    private var selectionWaiters: [CheckedContinuation<Void, Never>] = []

    func beginInput() -> Bool {
        guard selectionChangeDepth == 0 else { return false }
        inFlightInputs += 1
        return true
    }

    func endInput() {
        guard inFlightInputs > 0 else { return }
        inFlightInputs -= 1
        guard inFlightInputs == 0 else { return }
        let waiters = selectionWaiters
        selectionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func beginSelectionChange() async {
        selectionChangeDepth += 1
        guard inFlightInputs > 0 else { return }
        await withCheckedContinuation { continuation in
            selectionWaiters.append(continuation)
        }
    }

    func endSelectionChange() {
        guard selectionChangeDepth > 0 else { return }
        selectionChangeDepth -= 1
    }
}

/// Dispatches the single-consumer, already-authenticated Host message stream.
/// Input messages go to the M6 handler; every other message is handed to the
/// app's central dispatcher instead of being silently discarded. Session
/// lifecycle code must call `reset()` when it observes authorization,
/// selection, or reconnect changes; stream termination also resets the handler.
final class HostInputSessionLoop: @unchecked Sendable {
    private let session: SessionCoordinator
    private let handler: HostInputMessageHandler
    private let onNonInputMessage: @Sendable (MessagePayload) async -> Void
    private let now: @Sendable () -> UInt64
    private let admissionGate = HostInputAdmissionGate()
    private let cleanupLeaseLock = NSLock()
    private var cleanupLease: HostInputSessionCleanupLease

    init(
        session: SessionCoordinator,
        handler: HostInputMessageHandler,
        cleanupLease: HostInputSessionCleanupLease,
        onNonInputMessage: @escaping @Sendable (MessagePayload) async -> Void,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.session = session
        self.handler = handler
        self.cleanupLease = cleanupLease
        self.onNonInputMessage = onNonInputMessage
        self.now = now
    }

    func run() async {
        var iterator = session.incomingMessages.makeAsyncIterator()
        let lifecycleTask = Task { [session, handler, admissionGate] in
            var previous = await session.snapshot()
            var previousInputStatus = handler.status()
            var previousSelection = handler.selectionSnapshot()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                let current = await session.snapshot()
                if current.authorizationGeneration != previous.authorizationGeneration ||
                    current.reconnectGeneration != previous.reconnectGeneration ||
                    current.authorized != previous.authorized ||
                    current.authorizedWindowGeneration != previous.authorizedWindowGeneration {
                    await session.discardPendingInputMessages()
                    handler.reset()
                }
                let selection = handler.selectionSnapshot()
                if !selection.hasSameSelectedTarget(as: previousSelection) {
                    await admissionGate.beginSelectionChange()
                    await session.discardPendingInputMessages()
                    handler.reset()
                    if handler.status() == .inputStateCleanupPending {
                        // Selection changed without the lifecycle owner first
                        // calling selectionWillChange(). The old target could
                        // not be released safely, so close this session rather
                        // than carrying pressed state into the new target.
                        await session.stop(reason: .replaced)
                        await admissionGate.endSelectionChange()
                        return
                    }
                    await admissionGate.endSelectionChange()
                }
                let inputStatus = handler.status()
                if inputStatus != previousInputStatus {
                    await session.discardPendingInputMessages()
                    handler.reset()
                }
                if inputStatus == .inputStateCleanupPending {
                    handler.reconcileInputState()
                }
                previousInputStatus = inputStatus
                previousSelection = selection
                previous = current
            }
        }
        do {
            while let message = try await iterator.next() {
                if case let .sessionAuthorize(authorization) = message,
                   !authorization.authorized {
                    await session.discardPendingInputMessages()
                    handler.reset()
                } else if case .close = message {
                    await session.discardPendingInputMessages()
                    handler.reset()
                }
                guard case let .inputEvent(input) = message else {
                    await onNonInputMessage(message)
                    continue
                }
                guard await admissionGate.beginInput() else {
                    // A selection replacement owns the admission barrier. The
                    // current event is consumed and rejected rather than
                    // allowing it to target either side of the transition.
                    continue
                }
                do {
                    let timestampNanoseconds = now()
                    _ = try await session.withIncomingInputAdmission(for: input) {
                        try handler.handle(
                            input,
                            timestampNanoseconds: timestampNanoseconds
                        )
                    }
                } catch {
                    if Self.requiresInputReset(after: error) {
                        await session.discardPendingInputMessages()
                        handler.reset()
                    }
                    // The event is rejected and the loop remains alive for a
                    // later authorized event. The UI can read controller
                    // status; no raw event or platform error is logged.
                }
                await admissionGate.endInput()
            }
        } catch {
            // Disconnect, cancellation, and stream failure all stop input.
        }
        lifecycleTask.cancel()
        await lifecycleTask.value
        handler.reset()
    }

    func reset() {
        handler.reset()
    }

    /// Must be called immediately before the Host changes CaptureCore's
    /// selected-window provider. The lifecycle poll remains a backstop for
    /// callers that miss this ordering requirement.
    func selectionWillChange() async {
        await admissionGate.beginSelectionChange()
        await session.discardPendingInputMessages()
        handler.reset()
    }

    /// Completes the barrier opened by `selectionWillChange()` after the
    /// CaptureCore provider has published the replacement selection.
    func selectionDidChange() async {
        await admissionGate.endSelectionChange()
    }

    func replaceCleanupLease(_ lease: HostInputSessionCleanupLease) {
        cleanupLeaseLock.lock()
        cleanupLease = lease
        cleanupLeaseLock.unlock()
    }

    /// Preferred lifecycle API: hold the admission barrier while the caller
    /// replaces the CaptureCore selection provider.
    func withSelectionReplacement(
        _ operation: @escaping @Sendable () async -> Void
    ) async {
        await selectionWillChange()
        await operation()
        await selectionDidChange()
    }

    func reconcileInputState() {
        handler.reconcileInputState()
    }

    func pendingInputTarget() -> HostInputTarget? {
        handler.pendingInputTarget()
    }

    func selectionSnapshot() -> HostInputSelectionSnapshot {
        handler.selectionSnapshot()
    }

    /// Starts a target-bound background retry for state that could not be
    /// released before the session stream ended. The controller can obtain a
    /// live release context for the admitted target even after CaptureCore has
    /// published a replacement selection; it still refuses cleanup when that
    /// old target is no longer safely identifiable.
    func startCleanupReconciliation() -> Task<Void, Never> {
        let loop = self
        cleanupLeaseLock.lock()
        let cleanupLease = cleanupLease
        cleanupLeaseLock.unlock()
        return Task {
            while !Task.isCancelled {
                guard loop.pendingInputTarget() != nil else {
                    return
                }
                let shouldContinue = cleanupLease.withValidAccess {
                    loop.reconcileInputState()
                    return loop.status() == .inputStateCleanupPending
                } ?? false
                guard shouldContinue else {
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func status() -> HostInputStatus {
        handler.status()
    }

    private static func requiresInputReset(after error: Error) -> Bool {
        if let error = error as? HostInputError {
            switch error {
            case .sessionUnauthorized,
                 .windowGenerationMismatch,
                 .windowUnavailable,
                 .permissionUnavailable,
                 .focusUnavailable,
                 .capabilityUnavailable,
                 .invalidWindowGeometry,
                 .inputStateCleanupPending:
                return true
            case .invalidEvent,
                 .replayedEvent,
                 .rateLimited,
                 .invalidModifierMask,
                 .unsupportedButton,
                 .unmatchedStateRelease:
                return false
            }
        }
        if let error = error as? HostInputAdapterError {
            switch error {
            case .permissionUnavailable, .targetUnavailable:
                return true
            case .eventCreationFailed, .unsupportedButton:
                return true
            }
        }
        if let error = error as? SessionError {
            switch error {
            case .unauthorizedMessage(.inputEvent),
                 .authorizationChanged,
                 .reconnectRequired:
                return true
            default:
                return false
            }
        }
        return false
    }
}
