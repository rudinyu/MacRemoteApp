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

    private func makeScope(
        sessionID: UUID = UUID(),
        windowGeneration: UInt64 = 7,
        authorizationGeneration: UInt64 = 4
    ) -> ViewerInputSendScope {
        ViewerInputSendScope(
            sessionID: sessionID,
            authorizationGeneration: authorizationGeneration,
            windowGeneration: windowGeneration
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
