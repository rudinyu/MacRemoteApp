import Foundation
import SecurityCore
import XCTest
@testable import Host

final class HostControlAuthorizationTests: XCTestCase {
    func testNewlyAcceptedTrustedPeerActivatesControlWithoutConsentPrompt() async throws {
        let peer = try makePeer("newly-accepted-viewer")
        let store = RecordingTrustStore(peers: [peer.identity.identifier: peer])
        let coordinator = HostControlAuthorizationCoordinator(trustStore: store)
        let sessionID = UUID()

        let initial = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer.identity.identifier,
            peerName: "Viewer",
            supportsControl: true
        )
        let resolved = await coordinator.resolvePairingTrust(for: sessionID)
        let events = await store.events()

        XCTAssertEqual(initial.status, .negotiating)
        XCTAssertEqual(resolved.status, .active)
        XCTAssertTrue(resolved.trusted)
        XCTAssertTrue(resolved.granted)
        XCTAssertFalse(resolved.paused)
        XCTAssertTrue(HostRuntimeClipboardAuthorizationPolicy.permits(
            pairedPeerTrusted: resolved.trusted,
            capabilityNegotiated: true
        ), "trusted pairing plus negotiated text clipboard must not need a Host prompt")
        // The coordinator performs only a trust lookup; no per-session control
        // or clipboard consent prompt is part of this authorization path.
        XCTAssertEqual(events, [.lookup(peer.identity.identifier)])
    }

    func testReconnectReusesPairingTrustAndActivatesControlWithoutPrompt() async throws {
        let peer = try makePeer("reconnect-viewer")
        let store = RecordingTrustStore(peers: [peer.identity.identifier: peer])
        let coordinator = HostControlAuthorizationCoordinator(trustStore: store)
        let firstSession = UUID()
        let reconnectSession = UUID()

        _ = await coordinator.beginSession(
            sessionID: firstSession,
            peerIdentifier: peer.identity.identifier,
            peerName: "Viewer",
            supportsControl: true
        )
        let first = await coordinator.resolvePairingTrust(for: firstSession)
        await coordinator.endSession(firstSession)

        let reconnect = await coordinator.beginSession(
            sessionID: reconnectSession,
            peerIdentifier: peer.identity.identifier,
            peerName: "Viewer",
            supportsControl: true
        )
        let resolvedReconnect = await coordinator.resolvePairingTrust(for: reconnectSession)
        let events = await store.events()

        XCTAssertEqual(first.status, .active)
        XCTAssertEqual(reconnect.status, .negotiating)
        XCTAssertEqual(resolvedReconnect.status, .active)
        XCTAssertTrue(resolvedReconnect.trusted)
        XCTAssertTrue(resolvedReconnect.granted)
        XCTAssertEqual(events, [
            .lookup(peer.identity.identifier),
            .lookup(peer.identity.identifier)
        ])
    }

    func testUnpairedIdentityDoesNotReceiveControlAndKeychainLookupFailureBlocks() async throws {
        let peer = try makePeer("unpaired-viewer")
        let missingStore = RecordingTrustStore()
        let missingCoordinator = HostControlAuthorizationCoordinator(trustStore: missingStore)
        let missingSession = UUID()
        _ = await missingCoordinator.beginSession(
            sessionID: missingSession,
            peerIdentifier: peer.identity.identifier,
            peerName: nil,
            supportsControl: true
        )
        let missing = await missingCoordinator.resolvePairingTrust(for: missingSession)

        let failingStore = RecordingTrustStore(
            peers: [peer.identity.identifier: peer],
            failingOperations: [.lookup]
        )
        let failingCoordinator = HostControlAuthorizationCoordinator(trustStore: failingStore)
        let failedSession = UUID()
        _ = await failingCoordinator.beginSession(
            sessionID: failedSession,
            peerIdentifier: peer.identity.identifier,
            peerName: nil,
            supportsControl: true
        )
        let failed = await failingCoordinator.resolvePairingTrust(for: failedSession)

        XCTAssertEqual(missing.status, .requiresConsent)
        XCTAssertFalse(missing.granted)
        XCTAssertEqual(failed.status, .persistenceFailure)
        XCTAssertFalse(failed.trusted)
        XCTAssertFalse(failed.granted)
    }

    func testPauseAndResumeAreSessionScopedAndKeepPairingTrust() async throws {
        let peer = try makePeer("pause-viewer")
        let store = RecordingTrustStore(peers: [peer.identity.identifier: peer])
        let coordinator = HostControlAuthorizationCoordinator(trustStore: store)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer.identity.identifier,
            peerName: nil,
            supportsControl: true
        )
        let active = await coordinator.resolvePairingTrust(for: sessionID)
        let paused = await coordinator.togglePause(for: sessionID)
        let resumed = await coordinator.togglePause(for: sessionID)
        let savedPeer = try await store.trustedPeer(for: peer.identity.identifier)

        XCTAssertEqual(active.status, .active)
        XCTAssertTrue(active.trusted)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertTrue(paused.trusted)
        XCTAssertTrue(paused.granted)
        XCTAssertTrue(paused.paused)
        XCTAssertEqual(paused.revision, active.revision + 1)
        XCTAssertEqual(resumed.status, .active)
        XCTAssertTrue(resumed.trusted)
        XCTAssertTrue(resumed.granted)
        XCTAssertFalse(resumed.paused)
        XCTAssertEqual(resumed.revision, paused.revision + 1)
        XCTAssertEqual(savedPeer, peer)
    }

    func testRevokeRemovesPairingAndReconnectCannotRestoreControl() async throws {
        let peer = try makePeer("revoked-viewer")
        let store = RecordingTrustStore(peers: [peer.identity.identifier: peer])
        let coordinator = HostControlAuthorizationCoordinator(trustStore: store)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer.identity.identifier,
            peerName: nil,
            supportsControl: true
        )
        let active = await coordinator.resolvePairingTrust(for: sessionID)
        let ticketValue = await coordinator.beginRevocation(for: sessionID)
        let ticket = try XCTUnwrap(ticketValue)
        let revoked = await coordinator.completeRevocation(ticket)
        let savedPeer = try await store.trustedPeer(for: peer.identity.identifier)

        let reconnectSession = UUID()
        _ = await coordinator.beginSession(
            sessionID: reconnectSession,
            peerIdentifier: peer.identity.identifier,
            peerName: nil,
            supportsControl: true
        )
        let reconnect = await coordinator.resolvePairingTrust(for: reconnectSession)

        XCTAssertEqual(active.status, .active)
        XCTAssertEqual(revoked.status, .revoked)
        XCTAssertFalse(revoked.trusted)
        XCTAssertNil(savedPeer)
        XCTAssertEqual(reconnect.status, .requiresConsent)
        XCTAssertFalse(reconnect.granted)
    }

    func testFailedRevokeFencesReconnectUntilPairingReset() async throws {
        let peer = try makePeer("failed-revoke-viewer")
        let store = RecordingTrustStore(
            peers: [peer.identity.identifier: peer],
            failingOperations: [.revoke]
        )
        let coordinator = HostControlAuthorizationCoordinator(trustStore: store)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer.identity.identifier,
            peerName: nil,
            supportsControl: true
        )
        _ = await coordinator.resolvePairingTrust(for: sessionID)
        let ticketValue = await coordinator.beginRevocation(for: sessionID)
        let ticket = try XCTUnwrap(ticketValue)
        let failed = await coordinator.completeRevocation(ticket)

        let reconnectSession = UUID()
        let reconnect = await coordinator.beginSession(
            sessionID: reconnectSession,
            peerIdentifier: peer.identity.identifier,
            peerName: nil,
            supportsControl: true
        )
        let stillFenced = await coordinator.resolvePairingTrust(for: reconnectSession)

        XCTAssertEqual(failed.status, .persistenceFailure)
        XCTAssertFalse(failed.granted)
        XCTAssertEqual(reconnect.status, .persistenceFailure)
        XCTAssertEqual(stillFenced.status, .persistenceFailure)
        XCTAssertFalse(stillFenced.granted)
    }

    func testNonP6TrustedPairingStillEnablesClipboardAuthorityOnlyWhenNegotiated() async throws {
        let peer = try makePeer("clipboard-viewer")
        let store = RecordingTrustStore(peers: [peer.identity.identifier: peer])
        let coordinator = HostControlAuthorizationCoordinator(trustStore: store)
        let sessionID = UUID()

        _ = await coordinator.beginSession(
            sessionID: sessionID,
            peerIdentifier: peer.identity.identifier,
            peerName: nil,
            supportsControl: false
        )
        let pairing = await coordinator.resolvePairingTrust(for: sessionID)

        XCTAssertEqual(pairing.status, .unsupported)
        XCTAssertTrue(pairing.trusted)
        XCTAssertFalse(pairing.granted)
        XCTAssertTrue(HostRuntimeClipboardAuthorizationPolicy.permits(
            pairedPeerTrusted: pairing.trusted,
            capabilityNegotiated: true
        ))
        XCTAssertFalse(HostRuntimeClipboardAuthorizationPolicy.permits(
            pairedPeerTrusted: pairing.trusted,
            capabilityNegotiated: false
        ))
        XCTAssertFalse(HostRuntimeClipboardAuthorizationPolicy.permits(
            pairedPeerTrusted: pairing.trusted,
            capabilityNegotiated: true,
            pairingRevoked: true
        ))
    }

    private func makePeer(_ key: String) throws -> TrustedPeer {
        let identity = try PeerIdentity(publicKeyRepresentation: Data(key.utf8))
        return TrustedPeer(identity: identity, displayName: "Viewer")
    }
}

private actor RecordingTrustStore: TrustStore {
    enum Operation: Hashable {
        case lookup
        case revoke
    }

    enum Event: Equatable {
        case lookup(String)
        case revoke(String)
    }

    private var peers: [String: TrustedPeer]
    private let failingOperations: Set<Operation>
    private var recordedEvents: [Event] = []

    init(
        peers: [String: TrustedPeer] = [:],
        failingOperations: Set<Operation> = []
    ) {
        self.peers = peers
        self.failingOperations = failingOperations
    }

    func trustedPeer(for identifier: String) async throws -> TrustedPeer? {
        recordedEvents.append(.lookup(identifier))
        guard !failingOperations.contains(.lookup) else { throw FakeTrustStoreError() }
        return peers[identifier]
    }

    func allTrustedPeers() async throws -> [TrustedPeer] {
        Array(peers.values)
    }

    func save(_ peer: TrustedPeer) async throws {
        peers[peer.identity.identifier] = peer
    }

    func revoke(peerIdentifier: String) async throws {
        recordedEvents.append(.revoke(peerIdentifier))
        guard !failingOperations.contains(.revoke) else { throw FakeTrustStoreError() }
        peers.removeValue(forKey: peerIdentifier)
    }

    func events() -> [Event] { recordedEvents }
}

private struct FakeTrustStoreError: Error {}
