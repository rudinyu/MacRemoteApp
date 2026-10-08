import Foundation
import SecurityCore
import XCTest
@testable import Host

final class HostControlAuthorizationTests: XCTestCase {
    func testDurableGrantIsReusedWithoutPrompt() async {
        let peer = "peer-durable"
        let store = FakeControlGrantStore(grants: [peer])
        let prompt = ControlledConsentPrompt()
        let coordinator = makeCoordinator(store: store, prompt: prompt)
        let sessionID = UUID()

        let initial = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer,
            peerName: "Viewer",
            supportsControl: true
        )
        let resolved = await coordinator.resolveInitialConsent(for: sessionID)
        let storeEvents = await store.events()
        let promptCount = await prompt.requestCount()

        XCTAssertEqual(initial.status, .negotiating)
        XCTAssertEqual(resolved.status, .active)
        XCTAssertTrue(resolved.granted)
        XCTAssertFalse(resolved.paused)
        XCTAssertEqual(storeEvents, [.contains(peer)])
        XCTAssertEqual(promptCount, 0)
    }

    func testDeniedConsentLeavesAuthenticatedSessionViewOnly() async {
        let peer = "peer-denied"
        let store = FakeControlGrantStore()
        let prompt = ControlledConsentPrompt()
        let coordinator = makeCoordinator(store: store, prompt: prompt)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer,
            peerName: "Viewer",
            supportsControl: true
        )
        let resolveTask = Task { await coordinator.resolveInitialConsent(for: sessionID) }
        await prompt.waitForRequestCount(1)
        await prompt.answerNext(false)
        let denied = await resolveTask.value
        let savedPeers = await store.savedPeers()

        XCTAssertEqual(denied.status, .requiresConsent)
        XCTAssertFalse(denied.granted)
        XCTAssertFalse(denied.paused)
        XCTAssertTrue(savedPeers.isEmpty)
    }

    func testLookupFailureRemainsFailClosedWhenReconnectLookupAlsoFails() async {
        let peer = "peer-lookup-failure"
        let store = FakeControlGrantStore(failingOperations: [.contains])
        let prompt = ControlledConsentPrompt()
        let coordinator = makeCoordinator(store: store, prompt: prompt)

        let firstSession = UUID()
        _ = await coordinator.beginSession(
            sessionID: firstSession,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let first = await coordinator.resolveInitialConsent(for: firstSession)

        let reconnectedSession = UUID()
        _ = await coordinator.beginSession(
            sessionID: reconnectedSession,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let reconnected = await coordinator.resolveInitialConsent(for: reconnectedSession)
        let storeEvents = await store.events()
        let promptCount = await prompt.requestCount()

        XCTAssertEqual(first.status, .persistenceFailure)
        XCTAssertFalse(first.granted)
        XCTAssertEqual(reconnected.status, .persistenceFailure)
        XCTAssertFalse(reconnected.granted)
        XCTAssertEqual(storeEvents, [.contains(peer), .contains(peer)])
        XCTAssertEqual(promptCount, 0)
    }

    func testGrantWriteFailureBlocksSamePeerAfterReconnect() async {
        let peer = "peer-grant-failure"
        let store = FakeControlGrantStore(failingOperations: [.grant])
        let prompt = ControlledConsentPrompt()
        let coordinator = makeCoordinator(store: store, prompt: prompt)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let resolveTask = Task { await coordinator.resolveInitialConsent(for: sessionID) }
        await prompt.waitForRequestCount(1)
        await prompt.answerNext(true)
        let failedGrant = await resolveTask.value

        let reconnectedSession = UUID()
        let reconnected = await coordinator.beginSession(
            sessionID: reconnectedSession,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let checkedAgain = await coordinator.resolveInitialConsent(for: reconnectedSession)
        let storeEvents = await store.events()

        XCTAssertEqual(failedGrant.status, .persistenceFailure)
        XCTAssertFalse(failedGrant.granted)
        XCTAssertEqual(reconnected.status, .persistenceFailure)
        XCTAssertEqual(checkedAgain.status, .persistenceFailure)
        XCTAssertFalse(checkedAgain.granted)
        XCTAssertEqual(storeEvents, [.contains(peer), .grantStarted(peer)])
    }

    func testRevokeFailureBlocksSamePeerAfterReconnect() async throws {
        let peer = "peer-revoke-failure"
        let store = FakeControlGrantStore(grants: [peer], failingOperations: [.revoke])
        let prompt = ControlledConsentPrompt()
        let coordinator = makeCoordinator(store: store, prompt: prompt)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let active = await coordinator.resolveInitialConsent(for: sessionID)
        let ticket = await coordinator.beginRevocation(for: sessionID)
        let revoked = await coordinator.completeRevocation(try XCTUnwrap(ticket))

        let reconnectedSession = UUID()
        let reconnected = await coordinator.beginSession(
            sessionID: reconnectedSession,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let checkedAgain = await coordinator.resolveInitialConsent(for: reconnectedSession)
        let storeEvents = await store.events()
        let promptCount = await prompt.requestCount()

        XCTAssertEqual(active.status, .active)
        XCTAssertEqual(revoked.status, .persistenceFailure)
        XCTAssertFalse(revoked.granted)
        XCTAssertEqual(reconnected.status, .persistenceFailure)
        XCTAssertEqual(checkedAgain.status, .persistenceFailure)
        XCTAssertEqual(storeEvents, [.contains(peer), .revokeStarted(peer)])
        XCTAssertEqual(promptCount, 0)
    }

    func testPendingRevocationAcrossSessionReplacementCannotReloadOldGrant() async throws {
        let peer = "peer-revoke-replaced-session"
        let store = FakeControlGrantStore(grants: [peer])
        let prompt = ControlledConsentPrompt()
        let coordinator = makeCoordinator(store: store, prompt: prompt)
        let originalSession = UUID()

        _ = await coordinator.beginSession(
            sessionID: originalSession,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let active = await coordinator.resolveInitialConsent(for: originalSession)
        let maybeTicket = await coordinator.beginRevocation(for: originalSession)
        let ticket = try XCTUnwrap(maybeTicket)

        // Replace the session after the in-memory revoke intent is recorded,
        // but before its Keychain write starts. The replacement must not read
        // and reuse the still-present durable grant.
        let replacementSession = UUID()
        let replacement = await coordinator.beginSession(
            sessionID: replacementSession,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let resolvedReplacement = await coordinator.resolveInitialConsent(for: replacementSession)
        let beforePersistence = await store.events()

        let completedRevoke = await coordinator.completeRevocation(ticket)
        let savedPeers = await store.savedPeers()
        let promptCount = await prompt.requestCount()

        XCTAssertEqual(active.status, .active)
        XCTAssertEqual(replacement.status, .revoked)
        XCTAssertEqual(resolvedReplacement.status, .revoked)
        XCTAssertFalse(resolvedReplacement.granted)
        XCTAssertEqual(beforePersistence, [.contains(peer)])
        XCTAssertEqual(completedRevoke.status, .revoked)
        XCTAssertFalse(completedRevoke.granted)
        XCTAssertTrue(savedPeers.isEmpty)
        XCTAssertEqual(promptCount, 0)
    }

    func testLateConsentCannotGrantAfterRevokeEndOrSessionReplacement() async throws {
        for invalidation in [ConsentInvalidation.revoke, .end, .replaceSession] {
            let peer = "peer-late-\(invalidation.rawValue)"
            let store = FakeControlGrantStore()
            let prompt = ControlledConsentPrompt()
            let coordinator = makeCoordinator(store: store, prompt: prompt)
            let sessionID = UUID()

            _ = await coordinator.beginSession(
                sessionID: sessionID,
                peerIdentifier: peer,
                peerName: nil,
                supportsControl: true
            )
            let resolveTask = Task { await coordinator.resolveInitialConsent(for: sessionID) }
            await prompt.waitForRequestCount(1)

            switch invalidation {
            case .revoke:
                let maybeTicket = await coordinator.beginRevocation(for: sessionID)
                let ticket = try XCTUnwrap(maybeTicket)
                _ = await coordinator.completeRevocation(ticket)
            case .end:
                await coordinator.endSession(sessionID)
            case .replaceSession:
                _ = await coordinator.beginSession(
                    sessionID: UUID(),
                    peerIdentifier: peer,
                    peerName: nil,
                    supportsControl: true
                )
            }

            await prompt.answerNext(true)
            _ = await resolveTask.value
            let current = await coordinator.snapshot()
            let savedPeers = await store.savedPeers()

            XCTAssertFalse(current.granted, "late consent revived control after \(invalidation.rawValue)")
            XCTAssertFalse(savedPeers.contains(peer), "late consent persisted a grant after \(invalidation.rawValue)")
            switch invalidation {
            case .revoke:
                XCTAssertEqual(current.status, .revoked)
            case .end:
                XCTAssertEqual(current.status, .unavailable)
            case .replaceSession:
                XCTAssertEqual(current.status, .negotiating)
            }
        }
    }

    func testPauseAndResumeAdvanceRevisionWithoutRemovingDurableGrant() async {
        let peer = "peer-pause"
        let store = FakeControlGrantStore(grants: [peer])
        let prompt = ControlledConsentPrompt()
        let coordinator = makeCoordinator(store: store, prompt: prompt)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let active = await coordinator.resolveInitialConsent(for: sessionID)
        let paused = await coordinator.togglePause(for: sessionID)
        let resumed = await coordinator.togglePause(for: sessionID)
        let savedPeers = await store.savedPeers()

        XCTAssertEqual(active.status, .active)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertTrue(paused.granted)
        XCTAssertTrue(paused.paused)
        XCTAssertEqual(paused.revision, active.revision + 1)
        XCTAssertEqual(resumed.status, .active)
        XCTAssertTrue(resumed.granted)
        XCTAssertFalse(resumed.paused)
        XCTAssertEqual(resumed.revision, paused.revision + 1)
        XCTAssertEqual(savedPeers, Set([peer]))
    }

    func testRevocationWaitsForInFlightGrantAndRemainsLastStoreMutation() async throws {
        let peer = "peer-grant-then-revoke"
        let store = FakeControlGrantStore()
        let grantBarrier = AsyncBarrier()
        await store.suspendNext(.grant, on: grantBarrier)
        let prompt = ControlledConsentPrompt()
        let coordinator = makeCoordinator(store: store, prompt: prompt)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let grantTask = Task { await coordinator.resolveInitialConsent(for: sessionID) }
        await prompt.waitForRequestCount(1)
        await prompt.answerNext(true)
        await grantBarrier.waitUntilSuspended()

        let maybeTicket = await coordinator.beginRevocation(for: sessionID)
        let ticket = try XCTUnwrap(maybeTicket)
        let revokeTask = Task { await coordinator.completeRevocation(ticket) }
        await grantBarrier.release()
        _ = await grantTask.value
        let final = await revokeTask.value
        let finalPeers = await store.savedPeers()
        let events = await store.events()

        XCTAssertEqual(final.status, .revoked)
        XCTAssertFalse(final.granted)
        XCTAssertTrue(finalPeers.isEmpty)
        XCTAssertEqual(events, [
            .contains(peer),
            .grantStarted(peer),
            .grantSucceeded(peer),
            .revokeStarted(peer),
            .revokeSucceeded(peer)
        ])
    }

    func testConsentSupersededWhileWaitingBehindRevokeNeverWritesGrant() async throws {
        let peer = "peer-stale-grant-at-gate"
        let store = FakeControlGrantStore(grants: [peer])
        let revokeBarrier = AsyncBarrier()
        await store.suspendNext(.revoke, on: revokeBarrier)
        let prompt = ControlledConsentPrompt()
        let coordinator = makeCoordinator(store: store, prompt: prompt)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        _ = await coordinator.resolveInitialConsent(for: sessionID)

        let firstTicketValue = await coordinator.beginRevocation(for: sessionID)
        let firstTicket = try XCTUnwrap(firstTicketValue)
        let firstRevokeTask = Task { await coordinator.completeRevocation(firstTicket) }
        await revokeBarrier.waitUntilSuspended()

        let consentTask = Task { await coordinator.requestConsent(for: sessionID) }
        let consentResult = await consentTask.value
        let promptCount = await prompt.requestCount()

        // A pending revoke closes the consent path immediately. A newer local
        // revoke supersedes the first one while it is still at the store gate.
        let secondTicketValue = await coordinator.beginRevocation(for: sessionID)
        let secondTicket = try XCTUnwrap(secondTicketValue)
        let secondRevokeTask = Task { await coordinator.completeRevocation(secondTicket) }
        await revokeBarrier.release()

        _ = await firstRevokeTask.value
        let final = await secondRevokeTask.value
        let finalPeers = await store.savedPeers()
        let events = await store.events()

        XCTAssertEqual(consentResult.status, .revoked)
        XCTAssertFalse(consentResult.granted)
        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(final.status, .revoked)
        XCTAssertFalse(final.granted)
        XCTAssertTrue(finalPeers.isEmpty)
        XCTAssertEqual(events, [
            .contains(peer),
            .revokeStarted(peer),
            .revokeSucceeded(peer),
            .revokeStarted(peer),
            .revokeSucceeded(peer)
        ])
    }

    func testRemoveAllWaitsForInFlightGrantAndDeletesItsResult() async throws {
        let peer = "peer-grant-then-reset"
        let store = FakeControlGrantStore()
        let grantBarrier = AsyncBarrier()
        await store.suspendNext(.grant, on: grantBarrier)
        let prompt = ControlledConsentPrompt()
        let coordinator = makeCoordinator(store: store, prompt: prompt)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let grantTask = Task { await coordinator.resolveInitialConsent(for: sessionID) }
        await prompt.waitForRequestCount(1)
        await prompt.answerNext(true)
        await grantBarrier.waitUntilSuspended()

        let resetTask = Task { try await coordinator.removeAllGrants() }
        await grantBarrier.release()
        _ = await grantTask.value
        let removedCount = try await resetTask.value
        let finalPeers = await store.savedPeers()
        let events = await store.events()

        XCTAssertEqual(removedCount, 1)
        XCTAssertTrue(finalPeers.isEmpty)
        XCTAssertEqual(events, [
            .contains(peer),
            .grantStarted(peer),
            .grantSucceeded(peer),
            .removeAllStarted,
            .removeAllSucceeded
        ])
    }

    func testFailedRemoveAllPreventsReusingAnyOldGrantAfterReconnect() async throws {
        let peer = "peer-reset-failure"
        let store = FakeControlGrantStore(grants: [peer], failingOperations: [.removeAll])
        let prompt = ControlledConsentPrompt()
        let coordinator = makeCoordinator(store: store, prompt: prompt)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let active = await coordinator.resolveInitialConsent(for: sessionID)
        do {
            _ = try await coordinator.removeAllGrants()
            XCTFail("removeAll should propagate a storage failure")
        } catch {
            // The coordinator must keep the global fail-closed latch set.
        }

        let reconnectedSession = UUID()
        let reconnected = await coordinator.beginSession(
            sessionID: reconnectedSession,
            peerIdentifier: peer,
            peerName: nil,
            supportsControl: true
        )
        let checkedAgain = await coordinator.resolveInitialConsent(for: reconnectedSession)
        let storeEvents = await store.events()
        let savedPeers = await store.savedPeers()

        XCTAssertEqual(active.status, .active)
        XCTAssertEqual(reconnected.status, .persistenceFailure)
        XCTAssertEqual(checkedAgain.status, .persistenceFailure)
        XCTAssertFalse(checkedAgain.granted)
        XCTAssertEqual(storeEvents, [.contains(peer), .removeAllStarted])
        XCTAssertEqual(savedPeers, Set([peer]), "the test fixture should retain the grant after failed removal")
    }

    private func makeCoordinator(
        store: FakeControlGrantStore,
        prompt: ControlledConsentPrompt
    ) -> HostControlAuthorizationCoordinator {
        HostControlAuthorizationCoordinator(store: store) { peerName, peerIdentifier in
            await prompt.ask(peerName: peerName, peerIdentifier: peerIdentifier)
        }
    }
}

private enum ConsentInvalidation: String {
    case revoke
    case end
    case replaceSession
}

private enum StoreOperation: Hashable, Sendable {
    case contains
    case grant
    case revoke
    case removeAll
}

private enum StoreEvent: Equatable, Sendable {
    case contains(String)
    case grantStarted(String)
    case grantSucceeded(String)
    case revokeStarted(String)
    case revokeSucceeded(String)
    case removeAllStarted
    case removeAllSucceeded
}

private struct FakeStoreError: Error, Sendable {}

private actor FakeControlGrantStore: ControlGrantStore {
    private var grants: Set<String>
    private let failingOperations: Set<StoreOperation>
    private var barriers: [StoreOperation: AsyncBarrier] = [:]
    private var recordedEvents: [StoreEvent] = []

    init(
        grants: Set<String> = [],
        failingOperations: Set<StoreOperation> = []
    ) {
        self.grants = grants
        self.failingOperations = failingOperations
    }

    func suspendNext(_ operation: StoreOperation, on barrier: AsyncBarrier) {
        barriers[operation] = barrier
    }

    func contains(peerIdentifier: String) async throws -> Bool {
        recordedEvents.append(.contains(peerIdentifier))
        await suspendIfNeeded(.contains)
        guard !failingOperations.contains(.contains) else { throw FakeStoreError() }
        return grants.contains(peerIdentifier)
    }

    func grant(peerIdentifier: String) async throws {
        recordedEvents.append(.grantStarted(peerIdentifier))
        await suspendIfNeeded(.grant)
        guard !failingOperations.contains(.grant) else { throw FakeStoreError() }
        grants.insert(peerIdentifier)
        recordedEvents.append(.grantSucceeded(peerIdentifier))
    }

    func revoke(peerIdentifier: String) async throws {
        recordedEvents.append(.revokeStarted(peerIdentifier))
        await suspendIfNeeded(.revoke)
        guard !failingOperations.contains(.revoke) else { throw FakeStoreError() }
        grants.remove(peerIdentifier)
        recordedEvents.append(.revokeSucceeded(peerIdentifier))
    }

    func removeAll() async throws -> Int {
        recordedEvents.append(.removeAllStarted)
        await suspendIfNeeded(.removeAll)
        guard !failingOperations.contains(.removeAll) else { throw FakeStoreError() }
        let count = grants.count
        grants.removeAll()
        recordedEvents.append(.removeAllSucceeded)
        return count
    }

    func events() -> [StoreEvent] { recordedEvents }

    func savedPeers() -> Set<String> { grants }

    private func suspendIfNeeded(_ operation: StoreOperation) async {
        guard let barrier = barriers.removeValue(forKey: operation) else { return }
        await barrier.suspend()
    }
}

private actor AsyncBarrier {
    private var released = false
    private var hasSuspended = false
    private var suspension: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            suspension = continuation
            hasSuspended = true
            let waitingObservers = observers
            observers.removeAll()
            waitingObservers.forEach { $0.resume() }
        }
    }

    func waitUntilSuspended() async {
        guard !hasSuspended && !released else { return }
        await withCheckedContinuation { continuation in
            observers.append(continuation)
        }
    }

    func release() {
        released = true
        suspension?.resume()
        suspension = nil
        let waitingObservers = observers
        observers.removeAll()
        waitingObservers.forEach { $0.resume() }
    }
}

private actor ControlledConsentPrompt {
    private var requests = 0
    private var pending: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var requestObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    func ask(peerName: String?, peerIdentifier: String) async -> Bool {
        _ = peerName
        _ = peerIdentifier
        let requestID = requests + 1
        return await withCheckedContinuation { continuation in
            requests = requestID
            pending[requestID] = continuation
            let readyObservers = requestObservers.filter { requests >= $0.0 }
            requestObservers.removeAll { requests >= $0.0 }
            readyObservers.forEach { $0.1.resume() }
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests < count else { return }
        await withCheckedContinuation { continuation in
            requestObservers.append((count, continuation))
        }
    }

    func answerNext(_ accepted: Bool) {
        guard let requestID = pending.keys.min(),
              let continuation = pending.removeValue(forKey: requestID) else {
            preconditionFailure("No consent prompt is waiting for an answer")
        }
        continuation.resume(returning: accepted)
    }

    func requestCount() -> Int { requests }
}
