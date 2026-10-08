import Foundation
import InputCore
import XCTest
@testable import Viewer

@MainActor
final class ViewerRuntimeLifecycleTests: XCTestCase {
    func testQueueOverflowInvalidatesScopeAndDiscardsPendingEvents() async {
        let scope = makeScope()
        let started = AsyncSignal()
        let release = AsyncSignal()
        let recorder = SendRecorder()
        var failedScopes: [ViewerInputSendScope] = []
        let queue = ViewerInputSendQueue(capacity: 2) { failedScopes.append($0) }
        queue.updateScope(scope)

        XCTAssertEqual(
            queue.enqueue(record(1, window: scope.windowGeneration), in: scope) { event, epoch in
                await recorder.send(event, epoch, route: "current", started: started, release: release)
            },
            .enqueued
        )
        await started.wait()
        XCTAssertEqual(
            queue.enqueue(record(2, window: scope.windowGeneration), in: scope) { event, epoch in
                await recorder.send(event, epoch, route: "current")
            },
            .enqueued
        )
        XCTAssertEqual(
            queue.enqueue(record(3, window: scope.windowGeneration), in: scope) { event, epoch in
                await recorder.send(event, epoch, route: "current")
            },
            .overflow
        )
        XCTAssertEqual(failedScopes, [scope])

        await release.signal()
        await queue.waitUntilIdle()
        let sent = await recorder.snapshot()
        XCTAssertEqual(sent.map(\.sequence), [1])
    }

    func testSessionReplacementDuringBlockedSendCannotRouteQueuedInputAcrossRepeatedWireGeneration() async {
        let oldScope = makeScope(windowGeneration: 7)
        let replacementScope = makeScope(windowGeneration: 7)
        let started = AsyncSignal()
        let release = AsyncSignal()
        let recorder = SendRecorder()
        let queue = ViewerInputSendQueue(capacity: 4)
        queue.updateScope(oldScope)

        XCTAssertEqual(
            queue.enqueue(record(1, window: 7), in: oldScope) { event, epoch in
                await recorder.send(event, epoch, route: "old", started: started, release: release)
            },
            .enqueued
        )
        await started.wait()
        XCTAssertEqual(
            queue.enqueue(record(2, window: 7), in: oldScope) { event, epoch in
                await recorder.send(event, epoch, route: "old")
            },
            .enqueued
        )

        queue.updateScope(replacementScope)
        XCTAssertEqual(
            queue.enqueue(record(3, window: 7), in: replacementScope) { event, epoch in
                await recorder.send(event, epoch, route: "replacement")
            },
            .enqueued
        )
        await release.signal()
        await queue.waitUntilIdle()

        let sent = await recorder.snapshot()
        XCTAssertEqual(sent.map(\.sequence), [1, 3])
        XCTAssertEqual(sent.map(\.route), ["old", "replacement"])
        XCTAssertEqual(sent.map(\.authorizationGeneration), [4, 4])
    }

    func testAuthorizationEpochChangeDropsQueuedInputButKeepsSameStreamGenerationUsable() async {
        let oldScope = makeScope(windowGeneration: 11, authorizationGeneration: 4)
        let renewedScope = ViewerInputSendScope(
            sessionID: oldScope.sessionID,
            authorizationGeneration: 5,
            windowGeneration: oldScope.windowGeneration
        )
        let started = AsyncSignal()
        let release = AsyncSignal()
        let recorder = SendRecorder()
        let queue = ViewerInputSendQueue(capacity: 4)
        queue.updateScope(oldScope)

        XCTAssertEqual(
            queue.enqueue(record(1, window: 11), in: oldScope) { event, epoch in
                await recorder.send(event, epoch, route: "same-session", started: started, release: release)
            },
            .enqueued
        )
        await started.wait()
        XCTAssertEqual(
            queue.enqueue(record(2, window: 11), in: oldScope) { event, epoch in
                await recorder.send(event, epoch, route: "stale-epoch")
            },
            .enqueued
        )

        queue.updateScope(renewedScope)
        XCTAssertEqual(
            queue.enqueue(record(3, window: 11), in: renewedScope) { event, epoch in
                await recorder.send(event, epoch, route: "renewed-epoch")
            },
            .enqueued
        )
        await release.signal()
        await queue.waitUntilIdle()

        let sent = await recorder.snapshot()
        XCTAssertEqual(sent.map(\.sequence), [1, 3])
        XCTAssertEqual(sent.map(\.authorizationGeneration), [4, 5])
        XCTAssertEqual(sent.last?.route, "renewed-epoch")
        XCTAssertEqual(renewedScope.windowGeneration, 11)
    }

    func testControlGenerationChangeDropsQueuedInputWithoutChangingWindowEpoch() async {
        let pausedScope = makeScope(windowGeneration: 11, authorizationGeneration: 4, controlGeneration: 8)
        let resumedScope = makeScope(
            sessionID: pausedScope.sessionID,
            windowGeneration: 11,
            authorizationGeneration: 4,
            controlGeneration: 10
        )
        let started = AsyncSignal()
        let release = AsyncSignal()
        let recorder = SendRecorder()
        let queue = ViewerInputSendQueue(capacity: 4)
        queue.updateScope(pausedScope)

        XCTAssertEqual(
            queue.enqueue(record(1, window: 11), in: pausedScope) { event, epoch in
                await recorder.send(event, epoch, route: "old-control", started: started, release: release)
            },
            .enqueued
        )
        await started.wait()
        XCTAssertEqual(
            queue.enqueue(record(2, window: 11), in: pausedScope) { event, epoch in
                await recorder.send(event, epoch, route: "stale-queued")
            },
            .enqueued
        )

        queue.updateScope(resumedScope)
        XCTAssertEqual(
            queue.enqueue(record(3, window: 11), in: resumedScope) { event, epoch in
                await recorder.send(event, epoch, route: "resumed-control")
            },
            .enqueued
        )
        await release.signal()
        await queue.waitUntilIdle()

        let sent = await recorder.snapshot()
        XCTAssertEqual(sent.map(\.sequence), [1, 3])
        XCTAssertEqual(sent.map(\.route), ["old-control", "resumed-control"])
        XCTAssertEqual(sent.map(\.authorizationGeneration), [4, 4])
        XCTAssertEqual(resumedScope.windowGeneration, pausedScope.windowGeneration)
        XCTAssertEqual(resumedScope.controlGeneration, 10)
    }

    func testSameScopePreservesOrderedKeyReleaseAcrossSettingsNavigation() async {
        let scope = makeScope()
        let recorder = SendRecorder()
        let queue = ViewerInputSendQueue(capacity: 4)
        queue.updateScope(scope)

        XCTAssertEqual(
            queue.enqueue(record(1, window: scope.windowGeneration, kind: .keyDown), in: scope) { event, epoch in
                await recorder.send(event, epoch, route: "session")
            },
            .enqueued
        )
        queue.updateScope(scope)
        XCTAssertEqual(
            queue.enqueue(record(2, window: scope.windowGeneration, kind: .keyUp), in: scope) { event, epoch in
                await recorder.send(event, epoch, route: "session")
            },
            .enqueued
        )

        await queue.waitUntilIdle()
        let sent = await recorder.snapshot()
        XCTAssertEqual(sent.map(\.kind), [.keyDown, .keyUp])
    }

    func testP6HostPermissionLossPrecedesProcessTargetSafety() {
        XCTAssertEqual(
            ViewerProcessControlReadiness.blocker(
                hostPermissionGranted: false,
                processTargetEligible: false
            ),
            .hostPermissionUnavailable
        )
        XCTAssertEqual(
            ViewerProcessControlReadiness.blocker(
                hostPermissionGranted: true,
                processTargetEligible: false
            ),
            .hostProcessTargetUnavailable
        )
        XCTAssertNil(
            ViewerProcessControlReadiness.blocker(
                hostPermissionGranted: true,
                processTargetEligible: true
            )
        )
        XCTAssertEqual(
            ViewerProcessControlReadiness.blocker(
                hostPermissionGranted: true,
                processTargetEligible: true,
                controlGeneration: nil
            ),
            .hostStateUnavailable
        )
    }

    func testDrawableCallbackFromPreviousPresentationLifetimeIsRejected() {
        let lifetime = ViewerPresentationLifetime()
        let oldDrawableToken = lifetime.token
        XCTAssertTrue(lifetime.accepts(oldDrawableToken))

        _ = lifetime.advance()

        XCTAssertFalse(lifetime.accepts(oldDrawableToken))
        XCTAssertTrue(lifetime.accepts(lifetime.token))
    }

    func testRetryCleanupOwnsReconnectingPresentationBeforeBlockedTeardown() async {
        let ownership = ViewerRetryCleanupOwnership(
            sessionID: UUID(),
            attemptID: UUID(),
            reconnectID: UUID()
        )
        let started = AsyncSignal()
        let release = AsyncSignal()
        var currentSessionID: UUID? = ownership.sessionID
        var currentAttemptID: UUID? = ownership.attemptID
        var currentReconnectID: UUID? = ownership.reconnectID
        var cleanupPresentation: ViewerSessionCleanupPresentation?
        var replacementOwnsPresentation = false
        var hostSelectionEnabled = true
        let cleanup = Task { @MainActor in
            guard let presentation = ViewerSessionCleanupPresentation.resolve(
                retryOwnership: ownership,
                sessionID: currentSessionID,
                attemptID: currentAttemptID,
                reconnectID: currentReconnectID
            ) else { return }
            cleanupPresentation = presentation
            hostSelectionEnabled = presentation.hostSelectionEnabled
            await started.signal()
            await release.wait()
        }

        await started.wait()
        XCTAssertEqual(cleanupPresentation, .reconnecting)
        XCTAssertFalse(hostSelectionEnabled)

        // A manual replacement owns its presentation while old teardown waits.
        currentSessionID = UUID()
        currentAttemptID = UUID()
        currentReconnectID = nil
        replacementOwnsPresentation = true
        cleanupPresentation = nil
        XCTAssertNil(ViewerSessionCleanupPresentation.resolve(
            retryOwnership: ownership,
            sessionID: currentSessionID,
            attemptID: currentAttemptID,
            reconnectID: currentReconnectID
        ))
        await release.signal()
        await cleanup.value
        XCTAssertTrue(replacementOwnsPresentation)
        XCTAssertNil(cleanupPresentation)
        XCTAssertFalse(hostSelectionEnabled)
    }

    func testRetryCleanupRejectsSupersededSessionAttemptOrReconnectOwner() {
        let ownership = ViewerRetryCleanupOwnership(
            sessionID: UUID(),
            attemptID: UUID(),
            reconnectID: UUID()
        )
        XCTAssertTrue(ownership.matches(
            sessionID: ownership.sessionID,
            attemptID: ownership.attemptID,
            reconnectID: ownership.reconnectID
        ))
        XCTAssertFalse(ownership.matches(
            sessionID: UUID(),
            attemptID: ownership.attemptID,
            reconnectID: ownership.reconnectID
        ))
        XCTAssertFalse(ownership.matches(
            sessionID: ownership.sessionID,
            attemptID: UUID(),
            reconnectID: ownership.reconnectID
        ))
        XCTAssertFalse(ownership.matches(
            sessionID: ownership.sessionID,
            attemptID: ownership.attemptID,
            reconnectID: nil
        ))
        XCTAssertEqual(ViewerSessionCleanupPresentation.resolve(
            retryOwnership: nil,
            sessionID: ownership.sessionID,
            attemptID: ownership.attemptID,
            reconnectID: ownership.reconnectID
        ), .disconnected)
        XCTAssertTrue(ViewerSessionCleanupPresentation.disconnected.hostSelectionEnabled)
    }

    func testLateLowerAuthorizationSnapshotCannotResetConfiguredPresentationOrContinueProcessing() async {
        let sessionID = UUID()
        var gate = ViewerAuthorizationSnapshotGate()
        let lifetime = ViewerPresentationLifetime()
        let started = AsyncSignal()
        let release = AsyncSignal()
        var decoderConfigured = false
        var staleProcessingCount = 0
        XCTAssertTrue(gate.admit(sessionID: sessionID, authorizationGeneration: 4))

        let lateSnapshot = Task { @MainActor in
            await started.signal()
            await release.wait()
            guard gate.admit(sessionID: sessionID, authorizationGeneration: 4) else { return }
            lifetime.advance()
            decoderConfigured = false
            staleProcessingCount += 1
        }
        await started.wait()
        XCTAssertTrue(gate.admit(sessionID: sessionID, authorizationGeneration: 5))
        lifetime.advance()
        decoderConfigured = true
        let configuredToken = lifetime.token

        await release.signal()
        await lateSnapshot.value
        XCTAssertTrue(decoderConfigured)
        XCTAssertTrue(lifetime.accepts(configuredToken))
        XCTAssertEqual(staleProcessingCount, 0)
        XCTAssertFalse(gate.admit(sessionID: sessionID, authorizationGeneration: 4))
        XCTAssertTrue(gate.admit(sessionID: sessionID, authorizationGeneration: 5))
    }

    func testReplacementSessionMayRestartAuthorizationAtLowerEpoch() {
        var gate = ViewerAuthorizationSnapshotGate()
        let oldSessionID = UUID()
        let replacementSessionID = UUID()
        XCTAssertTrue(gate.admit(sessionID: oldSessionID, authorizationGeneration: 12))
        XCTAssertFalse(gate.admit(sessionID: oldSessionID, authorizationGeneration: 11))
        XCTAssertTrue(gate.admit(sessionID: replacementSessionID, authorizationGeneration: 1))
        XCTAssertFalse(gate.admit(sessionID: replacementSessionID, authorizationGeneration: 0))
        XCTAssertTrue(gate.admit(sessionID: replacementSessionID, authorizationGeneration: 2))
    }

    func testInputSourceAcknowledgementReleasesFirstTypedKeyInOrder() {
        let scope = makeScope()
        var gate = ViewerInputSourceSyncGate(maximumBufferedEvents: 4)
        let request = gate.beginSynchronization(
            in: scope,
            source: InputSourceDescriptor(identifier: "test.chinese", kind: .chinese)
        )
        let down = keyRecord(1, window: scope.windowGeneration, keyCode: 42, pressed: true)
        let up = keyRecord(2, window: scope.windowGeneration, keyCode: 42, pressed: false)

        XCTAssertNotNil(request)
        XCTAssertEqual(gate.state, .pending)
        XCTAssertEqual(gate.routeKeyboard(down, in: scope), .buffered)
        XCTAssertEqual(gate.routeKeyboard(up, in: scope), .buffered)
        XCTAssertEqual(
            gate.acknowledge(scope: scope, requestID: request!.requestID, applied: true),
            .applied([down, up])
        )
        XCTAssertEqual(gate.state, .synchronized)
    }

    func testInitialAndSameWindowReauthorizedScopeBothRequireSynchronization() {
        let firstScope = makeScope(windowGeneration: 11, authorizationGeneration: 4)
        let source = InputSourceDescriptor(identifier: "test.chinese", kind: .chinese)
        var gate = ViewerInputSourceSyncGate(maximumBufferedEvents: 4)

        XCTAssertTrue(gate.needsSynchronization(to: source, in: firstScope))
        let first = gate.beginSynchronization(in: firstScope, source: source)!
        XCTAssertEqual(
            gate.acknowledge(scope: firstScope, requestID: first.requestID, applied: true),
            .applied([])
        )

        gate.invalidateScope()
        let reauthorizedScope = makeScope(
            sessionID: firstScope.sessionID,
            windowGeneration: firstScope.windowGeneration,
            authorizationGeneration: firstScope.authorizationGeneration + 1
        )
        XCTAssertTrue(gate.needsSynchronization(to: source, in: reauthorizedScope))
        let reauthorized = gate.beginSynchronization(in: reauthorizedScope, source: source)!
        XCTAssertEqual(reauthorized.scope, reauthorizedScope)
    }

    func testFailedSourceRemainsStickyUntilRetryOrSourceChange() {
        let scope = makeScope()
        let source = InputSourceDescriptor(identifier: "test.chinese", kind: .chinese)
        let changedSource = InputSourceDescriptor(identifier: "test.english", kind: .english)
        var gate = ViewerInputSourceSyncGate(maximumBufferedEvents: 4)
        let request = gate.beginSynchronization(in: scope, source: source)!

        XCTAssertEqual(
            gate.acknowledge(scope: scope, requestID: request.requestID, applied: false),
            .failed
        )
        XCTAssertFalse(gate.needsSynchronization(to: source, in: scope))
        XCTAssertTrue(gate.needsSynchronization(to: changedSource, in: scope))

        let explicitRetry = gate.beginSynchronization(in: scope, source: source)!
        XCTAssertGreaterThan(explicitRetry.requestID, request.requestID)
    }

    func testUnsentQueuedKeyboardPressIsInvalidatedBySourceSupersession() {
        let scope = makeScope()
        var gate = ViewerInputSourceSyncGate(maximumBufferedEvents: 4)
        gate.useManualSelection(in: scope)
        let down = keyRecord(1, window: scope.windowGeneration, keyCode: 0, pressed: true)
        XCTAssertEqual(gate.routeKeyboard(down, in: scope), .send)
        let oldDeliveryToken = gate.keyboardDeliveryToken

        _ = gate.beginSynchronization(
            in: scope,
            source: InputSourceDescriptor(identifier: "test.chinese", kind: .chinese)
        )
        XCTAssertFalse(gate.allowsQueuedKeyboardSend(
            down,
            in: scope,
            deliveryToken: oldDeliveryToken
        ))
        XCTAssertEqual(gate.takeRemoteKeysForOrderedRelease(in: scope), [])
    }

    func testOrderedKeyReleaseSurvivesFocusLossAfterInFlightPressCompletes() async {
        let scope = makeScope()
        let started = AsyncSignal()
        let release = AsyncSignal()
        let recorder = SendRecorder()
        var gate = ViewerInputSourceSyncGate(maximumBufferedEvents: 4)
        gate.useManualSelection(in: scope)
        let down = keyRecord(1, window: scope.windowGeneration, keyCode: 56, pressed: true)
        let up = keyRecord(2, window: scope.windowGeneration, keyCode: 56, pressed: false)
        let deliveryToken = gate.keyboardDeliveryToken
        XCTAssertEqual(gate.routeKeyboard(down, in: scope), .send)

        let queue = ViewerInputSendQueue(capacity: 4)
        queue.updateScope(scope)
        XCTAssertEqual(queue.enqueue(down, in: scope) { event, epoch in
            guard gate.allowsQueuedKeyboardSend(event, in: scope, deliveryToken: deliveryToken) else { return }
            await recorder.send(event, epoch, route: "remote", started: started, release: release)
            gate.noteDelivered(event, in: scope)
        }, .enqueued)
        await started.wait()

        XCTAssertEqual(gate.routeKeyboard(up, in: scope), .send)
        XCTAssertEqual(queue.enqueue(up, in: scope) { event, epoch in
            guard gate.allowsQueuedKeyboardSend(event, in: scope, deliveryToken: deliveryToken) else { return }
            await recorder.send(event, epoch, route: "remote")
            gate.noteDelivered(event, in: scope)
        }, .enqueued)

        gate.setInactive()
        XCTAssertFalse(gate.allowsQueuedKeyboardSend(up, in: scope, deliveryToken: deliveryToken))
        await release.signal()
        await queue.waitUntilIdle()

        XCTAssertFalse(gate.allowsQueuedKeyboardSend(up, in: scope, deliveryToken: deliveryToken))
        let sent = await recorder.snapshot()
        XCTAssertEqual(sent.map(\.kind), [.keyDown, .keyUp])
    }

    func testSyntheticModifierReleaseKeepsPhysicalReleaseFenceUntilKeyUp() {
        let scope = makeScope()
        let source = InputSourceDescriptor(identifier: "test.chinese", kind: .chinese)
        var gate = ViewerInputSourceSyncGate(maximumBufferedEvents: 4)
        gate.useManualSelection(in: scope)

        let modifierDown = keyRecord(1, window: scope.windowGeneration, keyCode: 56, pressed: true)
        XCTAssertEqual(gate.routeKeyboard(modifierDown, in: scope), .send)
        gate.noteDelivered(modifierDown, in: scope)

        let request = gate.beginSynchronization(in: scope, source: source)!
        XCTAssertEqual(gate.takeRemoteKeysForOrderedRelease(in: scope), [56])
        // Synthetic release confirms only remote bookkeeping; physical release
        // is still required to clear the gate's discard-until-up fence.
        gate.noteDelivered(
            keyRecord(2, window: scope.windowGeneration, keyCode: 56, pressed: false),
            in: scope
        )
        XCTAssertEqual(
            gate.acknowledge(scope: scope, requestID: request.requestID, applied: true),
            .applied([])
        )

        XCTAssertEqual(
            gate.routeKeyboard(
                keyRecord(3, window: scope.windowGeneration, keyCode: 56, pressed: false),
                in: scope
            ),
            .discarded
        )
        XCTAssertEqual(
            gate.routeKeyboard(
                keyRecord(4, window: scope.windowGeneration, keyCode: 56, pressed: true),
                in: scope
            ),
            .send
        )
    }

    func testRetryRequestedFromSettingsWaitsForRemoteSurfaceFocus() {
        var retryGate = ViewerInputSourceRetryGate()
        XCTAssertFalse(retryGate.request(remoteSurfaceFocused: false))
        XCTAssertTrue(retryGate.isWaitingForRemoteFocus)
        XCTAssertTrue(retryGate.consumeOnRemoteFocus())
        XCTAssertFalse(retryGate.isWaitingForRemoteFocus)
        XCTAssertFalse(retryGate.consumeOnRemoteFocus())
        XCTAssertTrue(retryGate.request(remoteSurfaceFocused: true))
    }

    func testSupersedingSourceDropsOldQueuedKeysAndIgnoresLateAcknowledgement() {
        let scope = makeScope()
        var gate = ViewerInputSourceSyncGate(maximumBufferedEvents: 8)
        let first = gate.beginSynchronization(
            in: scope,
            source: InputSourceDescriptor(identifier: "test.zhuyin", kind: .chinese)
        )!
        let staleDown = keyRecord(1, window: scope.windowGeneration, keyCode: 12, pressed: true)
        XCTAssertEqual(gate.routeKeyboard(staleDown, in: scope), .buffered)

        let second = gate.beginSynchronization(
            in: scope,
            source: InputSourceDescriptor(identifier: "test.english", kind: .english)
        )!
        XCTAssertGreaterThan(second.requestID, first.requestID)
        XCTAssertEqual(
            gate.acknowledge(scope: scope, requestID: first.requestID, applied: true),
            .stale
        )
        XCTAssertEqual(
            gate.routeKeyboard(
                keyRecord(2, window: scope.windowGeneration, keyCode: 12, pressed: false),
                in: scope
            ),
            .discarded
        )

        let freshDown = keyRecord(3, window: scope.windowGeneration, keyCode: 0, pressed: true)
        XCTAssertEqual(gate.routeKeyboard(freshDown, in: scope), .buffered)
        XCTAssertEqual(
            gate.acknowledge(scope: scope, requestID: second.requestID, applied: true),
            .applied([freshDown])
        )
    }

    func testSameWindowReauthorizationInvalidatesBufferedAndLateAcknowledgedKeys() {
        let oldScope = makeScope(windowGeneration: 11, authorizationGeneration: 4)
        let newScope = makeScope(
            sessionID: oldScope.sessionID,
            windowGeneration: 11,
            authorizationGeneration: 5
        )
        var gate = ViewerInputSourceSyncGate(maximumBufferedEvents: 8)
        let oldRequest = gate.beginSynchronization(
            in: oldScope,
            source: InputSourceDescriptor(identifier: "test.chinese", kind: .chinese)
        )!
        let oldDown = keyRecord(1, window: 11, keyCode: 56, pressed: true)
        XCTAssertEqual(gate.routeKeyboard(oldDown, in: oldScope), .buffered)

        let newRequest = gate.beginSynchronization(
            in: newScope,
            source: InputSourceDescriptor(identifier: "test.chinese", kind: .chinese)
        )!
        XCTAssertEqual(
            gate.acknowledge(scope: oldScope, requestID: oldRequest.requestID, applied: true),
            .stale
        )
        XCTAssertEqual(
            gate.routeKeyboard(
                keyRecord(2, window: 11, keyCode: 56, pressed: false),
                in: newScope
            ),
            .discarded
        )
        let currentDown = keyRecord(3, window: 11, keyCode: 56, pressed: true)
        XCTAssertEqual(gate.routeKeyboard(currentDown, in: newScope), .buffered)
        XCTAssertEqual(
            gate.acknowledge(scope: newScope, requestID: newRequest.requestID, applied: true),
            .applied([currentDown])
        )
    }

    func testTimeoutDropsUnsentsButAllowsOrderedReleaseOfRemoteHeldKey() {
        let scope = makeScope()
        var gate = ViewerInputSourceSyncGate(maximumBufferedEvents: 4)
        gate.useManualSelection(in: scope)
        let heldDown = keyRecord(1, window: scope.windowGeneration, keyCode: 59, pressed: true)
        XCTAssertEqual(gate.routeKeyboard(heldDown, in: scope), .send)
        gate.noteDelivered(heldDown, in: scope)

        let request = gate.beginSynchronization(
            in: scope,
            source: InputSourceDescriptor(identifier: "test.chinese", kind: .chinese)
        )!
        let pendingDown = keyRecord(2, window: scope.windowGeneration, keyCode: 0, pressed: true)
        XCTAssertEqual(gate.routeKeyboard(pendingDown, in: scope), .buffered)
        XCTAssertEqual(gate.takeRemoteKeysForOrderedRelease(in: scope), [59])
        XCTAssertTrue(gate.timeout(scope: scope, requestID: request.requestID))
        XCTAssertEqual(gate.state, .failed)
        XCTAssertEqual(
            gate.acknowledge(scope: scope, requestID: request.requestID, applied: true),
            .stale
        )

        let heldUp = keyRecord(3, window: scope.windowGeneration, keyCode: 59, pressed: false)
        gate.noteDelivered(heldUp, in: scope)
        XCTAssertEqual(gate.takeRemoteKeysForOrderedRelease(in: scope), [])
        XCTAssertEqual(
            gate.routeKeyboard(
                keyRecord(4, window: scope.windowGeneration, keyCode: 0, pressed: false),
                in: scope
            ),
            .discarded
        )
    }

    func testKeyboardGateOverflowFailsClosedWithoutReplayingPendingPresses() {
        let scope = makeScope()
        var gate = ViewerInputSourceSyncGate(maximumBufferedEvents: 1)
        let request = gate.beginSynchronization(
            in: scope,
            source: InputSourceDescriptor(identifier: "test.chinese", kind: .chinese)
        )!
        XCTAssertEqual(
            gate.routeKeyboard(
                keyRecord(1, window: scope.windowGeneration, keyCode: 0, pressed: true),
                in: scope
            ),
            .buffered
        )
        XCTAssertEqual(
            gate.routeKeyboard(
                keyRecord(2, window: scope.windowGeneration, keyCode: 1, pressed: true),
                in: scope
            ),
            .overflow
        )
        XCTAssertEqual(gate.state, .failed)
        XCTAssertEqual(
            gate.acknowledge(scope: scope, requestID: request.requestID, applied: true),
            .stale
        )
    }

    private func makeScope(
        sessionID: UUID = UUID(),
        windowGeneration: UInt64 = 7,
        authorizationGeneration: UInt64 = 4,
        controlGeneration: UInt64? = nil
    ) -> ViewerInputSendScope {
        ViewerInputSendScope(
            sessionID: sessionID,
            authorizationGeneration: authorizationGeneration,
            windowGeneration: windowGeneration,
            controlGeneration: controlGeneration
        )
    }

    private func record(
        _ sequence: UInt64,
        window: UInt64,
        kind: InputEventKind = .focusIntent
    ) -> InputEventRecord {
        InputEventRecord(
            sequence: sequence,
            timestampNanoseconds: sequence,
            windowGeneration: window,
            kind: kind,
            keyCode: kind == .keyDown || kind == .keyUp ? 0 : nil,
            modifiers: kind == .keyDown || kind == .keyUp ? 0 : nil
        )
    }

    private func keyRecord(
        _ sequence: UInt64,
        window: UInt64,
        keyCode: UInt16,
        pressed: Bool
    ) -> InputEventRecord {
        InputEventRecord(
            sequence: sequence,
            timestampNanoseconds: sequence,
            windowGeneration: window,
            kind: pressed ? .keyDown : .keyUp,
            keyCode: keyCode,
            modifiers: 0
        )
    }
}

private actor AsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        signaled = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor SendRecorder {
    struct Sent: Equatable, Sendable {
        let sequence: UInt64
        let authorizationGeneration: UInt64
        let route: String
        let kind: InputEventKind
    }

    private var values: [Sent] = []

    func send(
        _ event: InputEventRecord,
        _ authorizationGeneration: UInt64,
        route: String,
        started: AsyncSignal? = nil,
        release: AsyncSignal? = nil
    ) async {
        values.append(
            Sent(
                sequence: event.sequence,
                authorizationGeneration: authorizationGeneration,
                route: route,
                kind: event.kind
            )
        )
        if let started, let release {
            await started.signal()
            await release.wait()
        }
    }

    func snapshot() -> [Sent] {
        values
    }
}
