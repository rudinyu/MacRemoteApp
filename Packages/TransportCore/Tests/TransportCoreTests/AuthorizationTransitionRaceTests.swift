import Foundation
import RemoteProtocol
import SecurityCore
@testable import TransportCore
import XCTest

final class AuthorizationTransitionRaceTests: XCTestCase {
    func testHostKeepsReceiptFenceUntilViewerProcessesReplacementAuthorization() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("authorization-barrier-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("authorization-barrier-viewer".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        let delayedHostTransport = DelayedAuthorizationReceiptTransport(base: pair.first)
        let viewerTransport = LocalOnlyInvalidationTransport(base: pair.second)
        // Custom sessions need not negotiate periodic heartbeats. The
        // one-shot receipt Ping still has to receive its exact Pong.
        let capabilities: Set<Capability> = [.mouseInput]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "authorization-barrier-host",
                capabilities: capabilities,
                heartbeatIntervalNanoseconds: 60_000_000_000,
                heartbeatTimeoutNanoseconds: 2_000_000_000
            ),
            transport: delayedHostTransport
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "authorization-barrier-viewer",
                capabilities: capabilities,
                heartbeatIntervalNanoseconds: 60_000_000_000,
                heartbeatTimeoutNanoseconds: 2_000_000_000
            ),
            transport: viewerTransport
        )
        var transitionTask: Task<String?, Never>?
        var phase = "session start"

        do {
            async let hostStart: Void = host.start()
            async let viewerStart: Void = viewer.start()
            try await hostStart
            try await viewerStart
            _ = try await waitForSnapshot(of: host) { $0.state == .capabilitiesNegotiated }
            _ = try await waitForSnapshot(of: viewer) { $0.state == .capabilitiesNegotiated }

            phase = "initial authorization"
            try await host.authorize(windowGeneration: 47, capabilities: [.mouseInput])
            _ = try await waitForSnapshot(of: viewer) {
                $0.authorized && $0.authorizedWindowGeneration == 47
            }

            delayedHostTransport.armNextAuthorizationDelivery()
            phase = "replacement authorization send and receipt barrier"
            transitionTask = Task { () -> String? in
                do {
                    try await host.authorize(windowGeneration: 48, capabilities: [.mouseInput])
                    return nil
                } catch {
                    return String(describing: error)
                }
            }
            guard delayedHostTransport.waitForReceiptBarrier(timeout: 2) == .success else {
                try? await delayedHostTransport.releaseReceiptBarrier()
                let error = await transitionTask?.value
                XCTFail("Host did not reach the receipt barrier after the authorization send returned: \(error ?? "no error")")
                await host.stop()
                await viewer.stop()
                return
            }

            // The transport adapter has returned from send(SessionAuthorize)
            // but withholds that frame from the Viewer until the later Ping is
            // released. The Viewer therefore still has its old authorization.
            let viewerBeforeReceipt = await viewer.snapshot()
            XCTAssertTrue(viewerBeforeReceipt.authorized)
            XCTAssertEqual(viewerBeforeReceipt.authorizedWindowGeneration, 47)

            phase = "old-epoch protected traffic while replacement is unreceived"
            let staleInput = InputEventMessage(
                kind: .pointerMove,
                windowGeneration: 47,
                x: 12,
                y: 34
            )
            _ = try await viewer.send(.inputEvent(staleInput))
            let orderedMarker = SessionStateMessage(
                state: .streaming,
                permission: .granted,
                focusEligible: true,
                windowGeneration: 48
            )
            _ = try await viewer.send(.sessionState(orderedMarker))
            let staleTrafficObservation = try await waitForTransitionBarrier(
                from: host.incomingMessages,
                windowGeneration: 48,
                timeout: .seconds(3)
            )
            XCTAssertFalse(staleTrafficObservation.sawInputEvent)
            let hostWhileViewerIsOld = await host.snapshot()
            let hostFailureWhileViewerIsOld = await host.failureReason()
            XCTAssertEqual(hostWhileViewerIsOld.state, .capabilitiesNegotiated)
            XCTAssertFalse(hostWhileViewerIsOld.authorized)
            XCTAssertNil(hostFailureWhileViewerIsOld)

            phase = "release ordered authorization and Ping"
            try await delayedHostTransport.releaseReceiptBarrier()
            let transitionError = await transitionTask?.value
            XCTAssertNil(transitionError)
            _ = try await waitForSnapshot(of: host) {
                $0.authorized && $0.authorizedWindowGeneration == 48
            }
            _ = try await waitForSnapshot(of: viewer) {
                $0.authorized && $0.authorizedWindowGeneration == 48
            }

            phase = "fresh input under replacement authorization"
            let freshInput = InputEventMessage(
                kind: .pointerMove,
                windowGeneration: 48,
                x: 56,
                y: 78
            )
            _ = try await viewer.send(.inputEvent(freshInput))
            let deliveredInput = try await nextInputEvent(
                from: host.incomingMessages,
                timeout: .seconds(3)
            )
            XCTAssertEqual(deliveredInput, freshInput)
        } catch {
            XCTFail("Failed during \(phase): \(error)")
            try? await delayedHostTransport.releaseReceiptBarrier()
            _ = await transitionTask?.value
            await host.stop()
            await viewer.stop()
            return
        }

        await host.stop()
        await viewer.stop()
    }

    func testHostReauthorizationDropsStaleProtectedTrafficAndKeepsSessionLive() async throws {
        try await exerciseAuthorizationTransition(.reauthorization)
    }

    func testAuthorizationReceiptBarrierTimesOutClosedWithoutPeerReceipt() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("authorization-timeout-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("authorization-timeout-viewer".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        let delayedHostTransport = DelayedAuthorizationReceiptTransport(base: pair.first)
        let viewerTransport = LocalOnlyInvalidationTransport(base: pair.second)
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "authorization-timeout-host",
                capabilities: [.mouseInput],
                heartbeatIntervalNanoseconds: 60_000_000_000,
                heartbeatTimeoutNanoseconds: 500_000_000
            ),
            transport: delayedHostTransport
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "authorization-timeout-viewer",
                capabilities: [.mouseInput],
                heartbeatIntervalNanoseconds: 60_000_000_000,
                heartbeatTimeoutNanoseconds: 500_000_000
            ),
            transport: viewerTransport
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        _ = try await waitForSnapshot(of: host) { $0.state == .capabilitiesNegotiated }
        _ = try await waitForSnapshot(of: viewer) { $0.state == .capabilitiesNegotiated }

        try await host.authorize(windowGeneration: 47, capabilities: [.mouseInput])
        _ = try await waitForSnapshot(of: viewer) {
            $0.authorized && $0.authorizedWindowGeneration == 47
        }

        delayedHostTransport.armNextAuthorizationDelivery()
        let transitionTask = Task<SessionError?, Never> {
            do {
                try await host.authorize(windowGeneration: 48, capabilities: [.mouseInput])
                return nil
            } catch let error as SessionError {
                return error
            } catch {
                return .transportFailure(String(describing: error))
            }
        }
        guard delayedHostTransport.waitForReceiptBarrier(timeout: 2) == .success else {
            _ = await transitionTask.value
            XCTFail("Host did not enqueue the receipt Ping")
            await host.stop()
            await viewer.stop()
            return
        }

        let transitionError = await transitionTask.value
        XCTAssertEqual(transitionError, .authorizationReceiptTimeout)
        let hostSnapshot = await host.snapshot()
        let hostFailure = await host.failureReason()
        XCTAssertEqual(hostSnapshot.state, .failed)
        XCTAssertFalse(hostSnapshot.authorized)
        XCTAssertEqual(hostFailure, .authorizationReceiptTimeout)

        await host.stop()
        await viewer.stop()
    }

    func testQueuedAuthorizationRequestsCannotRebindAcrossReconnect() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("authorization-reconnect-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("authorization-reconnect-viewer".utf8))
        let firstPair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        let delayedHostTransport = DelayedAuthorizationReceiptTransport(base: firstPair.first)
        let viewerTransport = LocalOnlyInvalidationTransport(base: firstPair.second)
        let capabilities: Set<Capability> = [.mouseInput]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "authorization-reconnect-host",
                capabilities: capabilities,
                heartbeatTimeoutNanoseconds: 5_000_000_000
            ),
            transport: delayedHostTransport
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "authorization-reconnect-viewer",
                capabilities: capabilities,
                heartbeatTimeoutNanoseconds: 5_000_000_000
            ),
            transport: viewerTransport
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        _ = try await waitForSnapshot(of: host) { $0.state == .capabilitiesNegotiated }
        _ = try await waitForSnapshot(of: viewer) { $0.state == .capabilitiesNegotiated }
        try await host.authorize(windowGeneration: 47, capabilities: [.mouseInput])
        _ = try await waitForSnapshot(of: viewer) {
            $0.authorized && $0.authorizedWindowGeneration == 47
        }

        delayedHostTransport.armNextAuthorizationDelivery()
        let firstTransition = Task<SessionError?, Never> {
            do {
                try await host.authorize(windowGeneration: 48, capabilities: [.mouseInput])
                return nil
            } catch let error as SessionError {
                return error
            } catch {
                return .transportFailure(String(describing: error))
            }
        }
        guard delayedHostTransport.waitForReceiptBarrier(timeout: 2) == .success else {
            _ = await firstTransition.value
            XCTFail("First authorization did not reach its receipt barrier")
            await host.stop()
            await viewer.stop()
            return
        }

        let secondTransition = Task<SessionError?, Never> {
            do {
                try await host.authorize(windowGeneration: 49, capabilities: [.mouseInput])
                return nil
            } catch let error as SessionError {
                return error
            } catch {
                return .transportFailure(String(describing: error))
            }
        }
        do {
            // This DEBUG-only count becomes observable after authorize() has
            // suspended on the held mutex, with its original transport epoch
            // already captured.
            try await waitForAuthorizationTransitionMutexWaiter(of: host, timeout: .seconds(1))
        } catch {
            XCTFail("Second authorization did not queue behind the held transition mutex: \(error)")
            try? await delayedHostTransport.releaseReceiptBarrier()
            _ = await firstTransition.value
            _ = await secondTransition.value
            await host.stop()
            await viewer.stop()
            return
        }

        let replacementPair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await replacementPair.first.start()
        try await replacementPair.second.start()
        async let hostReconnect: Void = host.reconnect(using: replacementPair.first)
        async let viewerReconnect: Void = viewer.reconnect(using: replacementPair.second)
        try await hostReconnect
        try await viewerReconnect

        let firstTransitionError = await firstTransition.value
        let secondTransitionError = await secondTransition.value
        XCTAssertEqual(firstTransitionError, .reconnectRequired)
        XCTAssertEqual(secondTransitionError, .reconnectRequired)
        _ = try await waitForSnapshot(of: host) { $0.state == .capabilitiesNegotiated }
        let replacementViewer = try await waitForSnapshot(of: viewer) {
            $0.state == .capabilitiesNegotiated
        }
        XCTAssertFalse(replacementViewer.authorized)
        XCTAssertNil(replacementViewer.authorizedWindowGeneration)

        await host.stop()
        await viewer.stop()
    }

    func testHostRevocationDropsStaleProtectedTrafficAndKeepsSessionLive() async throws {
        try await exerciseAuthorizationTransition(.revocation)
    }

    private func exerciseAuthorizationTransition(
        _ scenario: AuthorizationTransitionScenario
    ) async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("authorization-transition-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("authorization-transition-viewer".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        let gatedHostTransport = GatedAuthorizationTransitionTransport(base: pair.first)
        let viewerTransport = LocalOnlyInvalidationTransport(base: pair.second)
        let capabilities: Set<Capability> = [.pingPong, .h264Video, .receiverReport, .mouseInput]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "authorization-transition-host",
                capabilities: capabilities
            ),
            transport: gatedHostTransport
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "authorization-transition-viewer",
                capabilities: capabilities
            ),
            transport: viewerTransport
        )
        var transitionTask: Task<String?, Never>?
        var phase = "start"

        do {
            phase = "session start"
            async let hostStart: Void = host.start()
            async let viewerStart: Void = viewer.start()
            try await hostStart
            try await viewerStart

            _ = try await waitForSnapshot(of: host) { $0.state == .capabilitiesNegotiated }
            _ = try await waitForSnapshot(of: viewer) { $0.state == .capabilitiesNegotiated }

            let windowGeneration: UInt64 = 47
            let firstCapabilities: Set<Capability> = [.h264Video, .receiverReport, .mouseInput]
            phase = "initial authorization"
            try await host.authorize(
                windowGeneration: windowGeneration,
                capabilities: firstCapabilities
            )
            _ = try await waitForSnapshot(of: viewer) {
                $0.authorized && $0.authorizedWindowGeneration == windowGeneration
            }
            let previousHostAuthorizationGeneration = await host.snapshot().authorizationGeneration
            let previousViewerAuthorizationGeneration = await viewer.snapshot().authorizationGeneration

            let staleInput = InputEventMessage(
                kind: .pointerMove,
                windowGeneration: windowGeneration,
                x: 12,
                y: 34
            )
            let staleReport = ReceiverReportMessage(
                generation: windowGeneration,
                queuingDelayMicroseconds: 1_200,
                receivedFrames: 30,
                discardedFrames: 1
            )
            let transitionBarrier = SessionStateMessage(
                state: .streaming,
                permission: .granted,
                focusEligible: true,
                windowGeneration: windowGeneration
            )

            // The Viewer keeps its previous authorization until it receives
            // the replacement SessionAuthorize, so these protected messages
            // model input and periodic congestion feedback already in flight
            // on the authenticated control stream.
            gatedHostTransport.armNextAuthorizationTransition()
            phase = "authorization transition gate"
            transitionTask = Task { () -> String? in
                do {
                    switch scenario {
                    case .reauthorization:
                        try await host.authorize(
                            windowGeneration: windowGeneration,
                            capabilities: firstCapabilities
                        )
                    case .revocation:
                        try await host.revokeAuthorization()
                    }
                    return nil
                } catch {
                    return String(describing: error)
                }
            }

            guard gatedHostTransport.waitForTransitionStart(timeout: 2) == .success else {
                await gatedHostTransport.releaseTransition()
                let error = await transitionTask?.value
                XCTFail("Host authorization did not reach the gated invalidation: \(error ?? "no error")")
                await host.stop()
                await viewer.stop()
                return
            }

            phase = "send stale input"
            _ = try await viewer.send(.inputEvent(staleInput))
            phase = "send stale receiver report"
            _ = try await viewer.send(.receiverReport(staleReport))
            phase = "send transition barrier"
            _ = try await viewer.send(.sessionState(transitionBarrier))

            let duringTransition = await host.snapshot()
            XCTAssertEqual(duringTransition.state, .capabilitiesNegotiated)
            XCTAssertFalse(duringTransition.authorized)
            let transportDuringTransition = await gatedHostTransport.snapshot()
            XCTAssertEqual(transportDuringTransition.state, .ready)

            await gatedHostTransport.releaseTransition()
            phase = "await authorization transition"
            let transitionError = await transitionTask?.value
            XCTAssertNil(transitionError)

            phase = "wait for transition barrier"
            let observation = try await waitForTransitionBarrier(
                from: host.incomingMessages,
                windowGeneration: windowGeneration,
                timeout: .seconds(3)
            )
            XCTAssertFalse(observation.sawInputEvent, "stale input must not reach Host input admission")
            XCTAssertFalse(observation.sawReceiverReport, "stale feedback must not be applied in the new epoch")
            let hostAfterTransition = await host.snapshot()
            let transportAfterTransition = await gatedHostTransport.snapshot()
            let hostFailure = await host.failureReason()
            XCTAssertEqual(
                hostAfterTransition.state,
                scenario.finalSessionState,
                "Host failure after queued transition traffic: \(String(describing: hostFailure))"
            )
            XCTAssertEqual(hostAfterTransition.authorized, scenario.authorizedAfterTransition)
            XCTAssertEqual(
                hostAfterTransition.authorizedWindowGeneration,
                scenario.authorizedAfterTransition ? windowGeneration : nil
            )
            XCTAssertEqual(transportAfterTransition.state, .ready)
            let viewerFailure = await viewer.failureReason()
            XCTAssertNil(
                viewerFailure,
                "Viewer must remain live after authorization transition: \(String(describing: viewerFailure))"
            )

            phase = "wait for host authorization"
            _ = try await waitForSnapshot(of: host) {
                $0.state == scenario.finalSessionState &&
                    $0.authorized == scenario.authorizedAfterTransition &&
                    (!scenario.authorizedAfterTransition || $0.authorizedWindowGeneration == windowGeneration) &&
                    $0.authorizationGeneration > previousHostAuthorizationGeneration
            }
            phase = "wait for viewer authorization"
            _ = try await waitForSnapshot(of: viewer) {
                $0.state == scenario.finalSessionState &&
                    $0.authorized == scenario.authorizedAfterTransition &&
                    (!scenario.authorizedAfterTransition || $0.authorizedWindowGeneration == windowGeneration) &&
                    $0.authorizationGeneration > previousViewerAuthorizationGeneration
            }

            if scenario.authorizedAfterTransition {
                let freshInput = InputEventMessage(
                    kind: .pointerMove,
                    windowGeneration: windowGeneration,
                    x: 56,
                    y: 78
                )
                phase = "send fresh input"
                _ = try await viewer.send(.inputEvent(freshInput))
                phase = "wait for fresh input"
                let deliveredInput = try await nextInputEvent(
                    from: host.incomingMessages,
                    timeout: .seconds(3)
                )
                XCTAssertEqual(deliveredInput, freshInput, "fresh authorized input must be delivered after the transition")
            }
        } catch {
            XCTFail("Failed during \(phase): \(error)")
            await gatedHostTransport.releaseTransition()
            _ = await transitionTask?.value
            await host.stop()
            await viewer.stop()
            return
        }

        await host.stop()
        await viewer.stop()
    }

    private func waitForSnapshot(
        of session: SessionCoordinator,
        timeout: Duration = .seconds(5),
        satisfying predicate: (SessionSnapshot) -> Bool
    ) async throws -> SessionSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let snapshot = await session.snapshot()
            if predicate(snapshot) { return snapshot }
            guard clock.now < deadline else { throw AuthorizationTransitionTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForAuthorizationTransitionMutexWaiter(
        of session: SessionCoordinator,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await session.authorizationTransitionMutexWaiterCountForTesting == 0 {
            guard clock.now < deadline else { throw AuthorizationTransitionTestError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitForTransitionBarrier(
        from stream: MessageStream,
        windowGeneration: UInt64,
        timeout: Duration
    ) async throws -> TransitionObservation {
        try await withThrowingTaskGroup(of: TransitionObservation.self) { group in
            group.addTask {
                var observation = TransitionObservation()
                var iterator = stream.makeAsyncIterator()
                while let message = try await iterator.next() {
                    switch message {
                    case .inputEvent:
                        observation.sawInputEvent = true
                    case .receiverReport:
                        observation.sawReceiverReport = true
                    case let .sessionState(state)
                        where state.state == .streaming && state.windowGeneration == windowGeneration:
                        return observation
                    default:
                        break
                    }
                }
                throw AuthorizationTransitionTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AuthorizationTransitionTestError.timedOut
            }
            defer { group.cancelAll() }
            guard let observation = try await group.next() else {
                throw AuthorizationTransitionTestError.streamEnded
            }
            return observation
        }
    }

    private func nextInputEvent(
        from stream: MessageStream,
        timeout: Duration
    ) async throws -> InputEventMessage {
        try await withThrowingTaskGroup(of: InputEventMessage.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                while let message = try await iterator.next() {
                    if case let .inputEvent(input) = message { return input }
                }
                throw AuthorizationTransitionTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AuthorizationTransitionTestError.timedOut
            }
            defer { group.cancelAll() }
            guard let input = try await group.next() else {
                throw AuthorizationTransitionTestError.streamEnded
            }
            return input
        }
    }

}

final class AuthorizationReceiptFenceTests: XCTestCase {
    func testReceiptCapturedDuringTransitionIsDroppedAfterTransitionEnds() {
        let fence = AuthorizationReceiptFence()
        let epoch = fence.beginLocalTransition()
        let queuedReceipt = fence.capture()

        fence.endLocalTransition(epoch: epoch)

        XCTAssertTrue(fence.shouldDiscardProtectedMessage(receivedAt: queuedReceipt))
        XCTAssertFalse(fence.shouldDiscardProtectedMessage(receivedAt: fence.capture()))
    }
}

private struct TransitionObservation: Sendable {
    var sawInputEvent = false
    var sawReceiverReport = false
}

private enum AuthorizationTransitionScenario {
    case reauthorization
    case revocation

    var authorizedAfterTransition: Bool {
        switch self {
        case .reauthorization: true
        case .revocation: false
        }
    }

    var finalSessionState: SessionState {
        switch self {
        case .reauthorization: .windowSelectionAuthorized
        case .revocation: .capabilitiesNegotiated
        }
    }
}

private enum AuthorizationTransitionTestError: Error {
    case streamEnded
    case timedOut
}

private final class GatedAuthorizationTransitionTransport: SessionTransport, @unchecked Sendable {
    let incoming: EnvelopeStream

    private let base: InMemoryTransport
    private let transitionStarted = DispatchSemaphore(value: 0)
    private let releaseSignal = AuthorizationTransitionSignal()
    private let lock = NSLock()
    private var shouldGateNextTransition = false

    init(base: InMemoryTransport) {
        self.base = base
        self.incoming = base.incoming
    }

    func armNextAuthorizationTransition() {
        lock.withLock {
            shouldGateNextTransition = true
        }
    }

    func start() async throws {
        try await base.start()
    }

    func send(_ envelope: Envelope) async throws -> TransportSendResult {
        return try await base.send(envelope)
    }

    func invalidateProtectedMessages() async {
        // Purge preexisting queued traffic first. The test then injects its
        // ordered protected messages while the coordinator is still inside
        // the local transition, so invalidation cannot make the test pass by
        // silently removing those messages from the queue.
        await base.invalidateProtectedMessages()

        let shouldGate = lock.withLock {
            let shouldGate = shouldGateNextTransition
            shouldGateNextTransition = false
            return shouldGate
        }
        guard shouldGate else { return }

        transitionStarted.signal()
        await releaseSignal.wait()
    }

    func close() async {
        await base.close()
    }

    func authentication() async -> PeerAuthenticationState {
        await base.authentication()
    }

    func snapshot() async -> TransportSnapshot {
        await base.snapshot()
    }

    func waitForTransitionStart(timeout: TimeInterval) -> DispatchTimeoutResult {
        transitionStarted.wait(timeout: .now() + timeout)
    }

    func releaseTransition() async {
        await releaseSignal.release()
    }
}

private final class DelayedAuthorizationReceiptTransport: SessionTransport, @unchecked Sendable {
    let incoming: EnvelopeStream

    private let base: InMemoryTransport
    private let receiptBarrierStarted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldDelayNextAuthorization = false
    private var delayedAuthorization: Envelope?
    private var delayedReceiptPing: Envelope?

    init(base: InMemoryTransport) {
        self.base = base
        self.incoming = base.incoming
    }

    func armNextAuthorizationDelivery() {
        lock.withLock {
            shouldDelayNextAuthorization = true
        }
    }

    func start() async throws {
        try await base.start()
    }

    func send(_ envelope: Envelope) async throws -> TransportSendResult {
        if envelope.messageType == .sessionAuthorize {
            let shouldDelay = lock.withLock { () -> Bool in
                guard shouldDelayNextAuthorization else { return false }
                shouldDelayNextAuthorization = false
                delayedAuthorization = envelope
                return true
            }
            if shouldDelay { return .queued }
        }

        if envelope.messageType == .ping,
           lock.withLock({ delayedAuthorization != nil }) {
            let didHoldPing = lock.withLock { () -> Bool in
                guard delayedAuthorization != nil else { return false }
                delayedReceiptPing = envelope
                return true
            }
            if didHoldPing {
                // Both local send calls now return successfully while the
                // Viewer has received neither frame. The test releases the
                // held frames in control-stream order after injecting stale
                // traffic into the active receipt fence.
                receiptBarrierStarted.signal()
                return .queued
            }
        }

        return try await base.send(envelope)
    }

    func invalidateProtectedMessages() async {
        await base.invalidateProtectedMessages()
    }

    func close() async {
        await base.close()
    }

    func authentication() async -> PeerAuthenticationState {
        await base.authentication()
    }

    func snapshot() async -> TransportSnapshot {
        await base.snapshot()
    }

    func waitForReceiptBarrier(timeout: TimeInterval) -> DispatchTimeoutResult {
        receiptBarrierStarted.wait(timeout: .now() + timeout)
    }

    func releaseReceiptBarrier() async throws {
        let heldFrames = lock.withLock { () -> (Envelope, Envelope)? in
            guard let authorization = delayedAuthorization,
                  let ping = delayedReceiptPing else { return nil }
            delayedAuthorization = nil
            delayedReceiptPing = nil
            return (authorization, ping)
        }
        guard let (authorization, ping) = heldFrames else { return }
        _ = try await base.send(authorization)
        _ = try await base.send(ping)
    }
}

private final class LocalOnlyInvalidationTransport: SessionTransport, @unchecked Sendable {
    let incoming: EnvelopeStream

    private let base: InMemoryTransport

    init(base: InMemoryTransport) {
        self.base = base
        self.incoming = base.incoming
    }

    func start() async throws {
        try await base.start()
    }

    func send(_ envelope: Envelope) async throws -> TransportSendResult {
        try await base.send(envelope)
    }

    func invalidateProtectedMessages() async {
        // Network transports can recall only their local outbound queue. This
        // test adapter mirrors that boundary: Viewer reauthorization must not
        // retroactively purge envelopes already accepted by the Host stream.
        incoming.removeProtectedMessages()
    }

    func close() async {
        await base.close()
    }

    func authentication() async -> PeerAuthenticationState {
        await base.authentication()
    }

    func snapshot() async -> TransportSnapshot {
        await base.snapshot()
    }
}

private actor AuthorizationTransitionSignal {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}
