import Foundation
import InputCore
import TransportCore

enum ViewerInputFailureDisposition: Equatable, Sendable {
    case recheckInput
    case endSession

    var requiresSessionReset: Bool {
        self == .endSession
    }
}

enum ViewerInputFailureCategory: String, CaseIterable, Equatable, Hashable, Sendable {
    case localPreflight = "local_preflight"
    case capabilityUnavailable = "capability_unavailable"
    case authorizationNotReady = "authorization_not_ready"
    case deliveryUncertain = "delivery_uncertain"
    case queueOverflow = "queue_overflow"
    case heldStateReleaseFailure = "held_state_release_failure"
    case unexpected

    var disposition: ViewerInputFailureDisposition {
        switch self {
        case .localPreflight, .capabilityUnavailable, .authorizationNotReady:
            return .recheckInput
        case .deliveryUncertain, .queueOverflow, .heldStateReleaseFailure, .unexpected:
            return .endSession
        }
    }
}

enum ViewerInputSendBoundary: String, CaseIterable, Equatable, Hashable, Sendable {
    case beforeTransportInvocation = "before_transport_invocation"
    case transportSendStarted = "transport_send_started"
    case unknown
}

struct ViewerInputSendFailureDiagnostic: Equatable, Sendable {
    let underlyingCategory: ViewerInputFailureCategory
    let boundary: ViewerInputSendBoundary
    let hasConfirmedAuthorizationEpochTransition: Bool
}

enum ViewerInputSendFailureClassifier {
    static func category(for error: Error) -> ViewerInputFailureCategory {
        diagnostic(for: error).underlyingCategory
    }

    static func diagnostic(for error: Error) -> ViewerInputSendFailureDiagnostic {
        if let error = error as? ViewerInputTransportError {
            return ViewerInputSendFailureDiagnostic(
                underlyingCategory: error.failureCategory,
                boundary: error.failureBoundary,
                hasConfirmedAuthorizationEpochTransition:
                    error == .authorizationEpochChangedAfterAdmissionBeforeTransport &&
                    error.failureBoundary == .beforeTransportInvocation
            )
        }
        if error is InputCoreError {
            return ViewerInputSendFailureDiagnostic(
                underlyingCategory: .localPreflight,
                boundary: .beforeTransportInvocation,
                hasConfirmedAuthorizationEpochTransition: false
            )
        }
        if let error = error as? SessionError {
            let category: ViewerInputFailureCategory
            switch error {
            case .unauthorizedMessage:
                category = .capabilityUnavailable
            case .authorizationChanged, .reconnectRequired:
                category = .authorizationNotReady
            case .transportEOF, .transportFailure:
                category = .deliveryUncertain
            default:
                category = .unexpected
            }
            return ViewerInputSendFailureDiagnostic(
                underlyingCategory: category,
                boundary: .unknown,
                hasConfirmedAuthorizationEpochTransition: false
            )
        }
        // Unknown operation errors may have crossed the transport boundary.
        return ViewerInputSendFailureDiagnostic(
            underlyingCategory: .unexpected,
            boundary: .unknown,
            hasConfirmedAuthorizationEpochTransition: false
        )
    }

    static func effectiveCategory(
        for diagnostic: ViewerInputSendFailureDiagnostic,
        mayLeaveHeldInputState: Bool
    ) -> ViewerInputFailureCategory {
        if diagnostic.underlyingCategory.disposition == .recheckInput && mayLeaveHeldInputState {
            // ViewerInputTransport emits this exact error only when
            // SessionCoordinator positively reports
            // authorizationEpochChangedAfterAdmission before transport.
            // HostInputSessionLoop fences that authorization transition and
            // resets its controller before the receipt; retained cleanup can
            // retry when the target becomes eligible. Keep every other
            // held-state failure terminal because Host cleanup is not proven.
            if diagnostic.hasConfirmedAuthorizationEpochTransition,
               diagnostic.underlyingCategory == .authorizationNotReady,
               diagnostic.boundary == .beforeTransportInvocation {
                return .authorizationNotReady
            }
            return .heldStateReleaseFailure
        }
        return diagnostic.underlyingCategory
    }
}

struct ViewerInputSendScope: Equatable, Sendable {
    let sessionID: UUID
    let authorizationGeneration: UInt64
    let windowGeneration: UInt64
    let controlGeneration: UInt64?

    init(
        sessionID: UUID,
        authorizationGeneration: UInt64,
        windowGeneration: UInt64,
        controlGeneration: UInt64? = nil
    ) {
        self.sessionID = sessionID
        self.authorizationGeneration = authorizationGeneration
        self.windowGeneration = windowGeneration
        self.controlGeneration = controlGeneration
    }
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

enum ViewerInputSendOutcome: Equatable, Sendable {
    case sent
    case discarded
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

    typealias Sender = (InputEventRecord, UInt64) async throws -> ViewerInputSendOutcome
    typealias Operation = (ViewerInputSendScope) async throws -> Void
    typealias StatefulOperation = (ViewerInputSendScope) async throws -> [InputStateTransition]

    private struct Entry {
        let scope: ViewerInputSendScope
        let operation: StatefulOperation
        let mayEndHeldInputState: Bool
    }

    private let capacity: Int
    private let onFailure: (ViewerInputSendScope, ViewerInputFailureCategory) -> Void
    private var activeScope: ViewerInputSendScope?
    private var entries: [Entry] = []
    private var isSending = false
    private var sentInputState = InputStateTracker()
    private var worker: Task<Void, Never>?
    private var workerID: UUID?

    init(
        capacity: Int = 128,
        onFailure: @escaping (ViewerInputSendScope, ViewerInputFailureCategory) -> Void = { _, _ in }
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.onFailure = onFailure
    }

    func updateScope(_ scope: ViewerInputSendScope?) {
        guard scope != activeScope else { return }
        activeScope = scope
        sentInputState.reset()
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
#if DEBUG
            M10ViewerDiagnosticRecorder.shared.recordViewerInputFailureContext(
                underlyingCategory: .queueOverflow,
                boundary: .beforeTransportInvocation
            )
#endif
            invalidate(scope, failureCategory: .queueOverflow)
            return .overflow
        }
        entries.append(Entry(
            scope: scope,
            operation: { currentScope in
                let outcome = try await send(record, currentScope.authorizationGeneration)
                guard outcome == .sent else { return [] }
                return Self.stateTransition(for: record).map { [$0] } ?? []
            },
            mayEndHeldInputState: Self.isStateEnding(record)
        ))
        startWorkerIfNeeded()
        return .enqueued
    }

    @discardableResult
    func enqueueOperation(
        in scope: ViewerInputSendScope,
        mayEndHeldInputState: Bool = false,
        operation: @escaping Operation
    ) -> EnqueueResult {
        guard activeScope == scope else { return .staleScope }
        guard entries.count + (isSending ? 1 : 0) < capacity else {
#if DEBUG
            M10ViewerDiagnosticRecorder.shared.recordViewerInputFailureContext(
                underlyingCategory: .queueOverflow,
                boundary: .beforeTransportInvocation
            )
#endif
            invalidate(scope, failureCategory: .queueOverflow)
            return .overflow
        }
        entries.append(Entry(
            scope: scope,
            operation: { currentScope in
                try await operation(currentScope)
                return []
            },
            mayEndHeldInputState: mayEndHeldInputState
        ))
        startWorkerIfNeeded()
        return .enqueued
    }

    @discardableResult
    func enqueueStatefulOperation(
        in scope: ViewerInputSendScope,
        mayEndHeldInputState: Bool = false,
        operation: @escaping StatefulOperation
    ) -> EnqueueResult {
        guard activeScope == scope else { return .staleScope }
        guard entries.count + (isSending ? 1 : 0) < capacity else {
#if DEBUG
            M10ViewerDiagnosticRecorder.shared.recordViewerInputFailureContext(
                underlyingCategory: .queueOverflow,
                boundary: .beforeTransportInvocation
            )
#endif
            invalidate(scope, failureCategory: .queueOverflow)
            return .overflow
        }
        entries.append(Entry(
            scope: scope,
            operation: operation,
            mayEndHeldInputState: mayEndHeldInputState
        ))
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
                let transitions = try await entry.operation(entry.scope)
                if activeScope == entry.scope {
                    for transition in transitions {
                        sentInputState.apply(transition)
                    }
                }
            } catch {
                isSending = false
                if activeScope == entry.scope {
                    let diagnostic = ViewerInputSendFailureClassifier.diagnostic(for: error)
                    let mayLeaveHeldInputState = !sentInputState.isEmpty ||
                        entry.mayEndHeldInputState ||
                        entries.contains(where: \.mayEndHeldInputState)
                    let category = ViewerInputSendFailureClassifier.effectiveCategory(
                        for: diagnostic,
                        mayLeaveHeldInputState: mayLeaveHeldInputState
                    )
#if DEBUG
                    M10ViewerDiagnosticRecorder.shared.recordViewerInputFailureContext(
                        underlyingCategory: diagnostic.underlyingCategory,
                        boundary: diagnostic.boundary
                    )
#endif
                    invalidate(entry.scope, failureCategory: category)
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
        failureCategory: ViewerInputFailureCategory? = nil
    ) {
        guard activeScope == scope else { return }
        activeScope = nil
        entries.removeAll(keepingCapacity: true)
        worker?.cancel()
        if let failureCategory {
            onFailure(scope, failureCategory)
        }
    }

    private static func isStateEnding(_ record: InputEventRecord) -> Bool {
        switch record.kind {
        case .keyUp:
            return true
        case .pointerButton:
            return record.pressed == false
        default:
            return false
        }
    }

    private static func stateTransition(for record: InputEventRecord) -> InputStateTransition? {
        switch record.kind {
        case .keyDown:
            guard let keyCode = record.keyCode else { return nil }
            return .began(.key(keyCode))
        case .keyUp:
            guard let keyCode = record.keyCode else { return nil }
            return .ended(.key(keyCode))
        case .pointerButton:
            guard let button = record.button, let pressed = record.pressed else { return nil }
            return pressed ? .began(.pointerButton(button)) : .ended(.pointerButton(button))
        case .pointerMove, .scroll, .focusIntent, .text:
            return nil
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

/// ADR-0008 bridge between local composition and ADR-0007 source following.
/// While the session negotiates `textInput` and the Viewer's own source is a
/// Chinese input method, the Viewer composes locally and sends committed text,
/// so the Host must stay on an English source: a Host input method would
/// otherwise re-compose forwarded keys. Source following reads the Viewer
/// source through this provider, which then reports an enabled English source.
final class ViewerHostInputSourceTargetProvider: InputSourceProvider, @unchecked Sendable {
    private let base: any InputSourceProvider
    private let lock = NSLock()
    private var localTextCompositionAvailable = false

    init(base: any InputSourceProvider) {
        self.base = base
    }

    func setLocalTextCompositionAvailable(_ available: Bool) {
        lock.lock()
        localTextCompositionAvailable = available
        lock.unlock()
    }

    private var compositionAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return localTextCompositionAvailable
    }

    /// True when keystrokes should compose with the Viewer's input method.
    @MainActor
    var isLocalTextCompositionActive: Bool {
        compositionAvailable && base.currentInputSource()?.kind == .chinese
    }

    @MainActor
    func currentInputSource() -> InputSourceDescriptor? {
        guard let current = base.currentInputSource() else { return nil }
        guard compositionAvailable, current.kind == .chinese else { return current }
        return Self.hostEnglishTarget(from: base.enabledInputSources())
    }

    /// The Viewer's enabled English source, used as the Host target. The Host
    /// applies ADR-0007's bounded English fallback if it lacks that exact one.
    static func hostEnglishTarget(from enabled: [InputSourceDescriptor]) -> InputSourceDescriptor? {
        enabled
            .filter { $0.kind == .english }
            .sorted { $0.identifier < $1.identifier }
            .first
    }

    @MainActor
    func enabledInputSources() -> [InputSourceDescriptor] {
        base.enabledInputSources()
    }

    @MainActor
    func selectInputSource(_ descriptor: InputSourceDescriptor) -> InputSourceSelectionOutcome {
        base.selectInputSource(descriptor)
    }

    @MainActor
    func selectInputSource(
        _ descriptor: InputSourceDescriptor,
        validatingImmediatelyBeforeSelection isStillEligible: @MainActor () -> Bool
    ) -> InputSourceSelectionOutcome {
        base.selectInputSource(descriptor, validatingImmediatelyBeforeSelection: isStillEligible)
    }
}

/// The Viewer's requested stream quality. It is advertised as the session's
/// video bound; the Host streams at min(Host, Viewer). 4K is experimental on
/// older Intel Hosts. A change applies to the next connection.
enum ViewerStreamQuality: String, CaseIterable, Equatable, Sendable {
    case hd1080p30
    case hd1080p60
    case qhd1440p30
    case qhd1440p60
    case uhd4k30
    case uhd4k60

    static let storageKey = "ViewerStreamQuality"
    static let defaultQuality: ViewerStreamQuality = .hd1080p60

    var maximumWidth: UInt32 {
        switch self {
        case .hd1080p30, .hd1080p60: 1920
        case .qhd1440p30, .qhd1440p60: 2560
        case .uhd4k30, .uhd4k60: 3840
        }
    }

    var maximumHeight: UInt32 {
        switch self {
        case .hd1080p30, .hd1080p60: 1080
        case .qhd1440p30, .qhd1440p60: 1440
        case .uhd4k30, .uhd4k60: 2160
        }
    }

    var maximumFrameRate: UInt16 {
        switch self {
        case .hd1080p30, .qhd1440p30, .uhd4k30: 30
        case .hd1080p60, .qhd1440p60, .uhd4k60: 60
        }
    }

    var label: String {
        switch self {
        case .hd1080p30: "1080p · 30 fps"
        case .hd1080p60: "1080p · 60 fps"
        case .qhd1440p30: "1440p · 30 fps"
        case .qhd1440p60: "1440p · 60 fps"
        case .uhd4k30: "4K · 30 fps (experimental)"
        case .uhd4k60: "4K · 60 fps (experimental)"
        }
    }

    /// The next option, wrapping around, for the Settings cycle button.
    var next: ViewerStreamQuality {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    static func load(from defaults: UserDefaults = .standard) -> ViewerStreamQuality {
        defaults.string(forKey: storageKey).flatMap(ViewerStreamQuality.init(rawValue:)) ?? defaultQuality
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
