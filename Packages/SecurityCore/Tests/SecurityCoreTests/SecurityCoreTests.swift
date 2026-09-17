import Foundation
import SecurityCore
import XCTest

final class SecurityCoreTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(SecurityCoreModule.name, "SecurityCore")
    }

    func testTrustStoreRoundTripAndRevocation() async throws {
        let identity = try PeerIdentity(publicKeyRepresentation: Data("peer-key".utf8))
        let store = InMemoryTrustStore()
        let peer = TrustedPeer(identity: identity, displayName: "Test Peer")

        try await store.save(peer)
        let storedPeer = try await store.trustedPeer(for: identity.identifier)
        let allStoredPeers = try await store.allTrustedPeers()
        XCTAssertEqual(storedPeer, peer)
        XCTAssertEqual(allStoredPeers, [peer])

        try await store.revoke(peerIdentifier: identity.identifier)
        let revokedPeer = try await store.trustedPeer(for: identity.identifier)
        XCTAssertNil(revokedPeer)
    }

    func testPairingRequiresBothLocalAndRemoteConsentBeforeTrustAndRevocationFailsClosed() async throws {
        let local = try PeerIdentity(publicKeyRepresentation: Data("local-key".utf8))
        let remote = try PeerIdentity(publicKeyRepresentation: Data("remote-key".utf8))
        let store = InMemoryTrustStore()
        let coordinator = PairingCoordinator(localIdentity: local, trustStore: store)
        let now = Date(timeIntervalSince1970: 1_000)

        let challenge = try await coordinator.beginPairing(
            with: remote,
            challengeID: 42,
            nonce: Data(repeating: 0xA5, count: 32),
            now: now,
            timeout: 60
        )
        let awaitingState = await coordinator.state()
        XCTAssertEqual(awaitingState, .awaitingConfirmation)

        let awaitingRemoteConsent = try await coordinator.confirmLocalConsent(
            challengeID: challenge.challengeID,
            remoteIdentity: remote,
            confirmationCode: challenge.confirmationCode,
            accepted: true,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(awaitingRemoteConsent, .awaitingRemoteConsent)
        let pendingDecision = try await coordinator.trustDecision(for: remote)
        XCTAssertEqual(pendingDecision, .pairingRequired)

        let trustedResult = try await coordinator.recordRemoteConsent(
            challengeID: challenge.challengeID,
            remoteIdentity: remote,
            confirmationCode: challenge.confirmationCode,
            accepted: true,
            now: now.addingTimeInterval(2)
        )
        guard case let .paired(trusted) = trustedResult else {
            return XCTFail("both consents should commit trust")
        }
        XCTAssertEqual(trusted.identity, remote)
        let trustedDecision = try await coordinator.trustDecision(for: remote)
        XCTAssertEqual(trustedDecision, .trusted)

        try await coordinator.revoke(remoteIdentity: remote)
        let revokedState = await coordinator.state()
        let revokedDecision = try await coordinator.trustDecision(for: remote)
        XCTAssertEqual(revokedState, .revoked)
        XCTAssertEqual(revokedDecision, .pairingRequired)
    }

    func testPairingRejectsWrongCodeAndExpiredChallenge() async throws {
        let local = try PeerIdentity(publicKeyRepresentation: Data("local-key".utf8))
        let remote = try PeerIdentity(publicKeyRepresentation: Data("remote-key".utf8))
        let store = InMemoryTrustStore()
        let coordinator = PairingCoordinator(localIdentity: local, trustStore: store)
        let now = Date(timeIntervalSince1970: 2_000)

        let challenge = try await coordinator.beginPairing(
            with: remote,
            challengeID: 7,
            nonce: Data(repeating: 0x5A, count: 16),
            now: now,
            timeout: 1
        )
        do {
            _ = try await coordinator.confirm(
                challengeID: challenge.challengeID,
                remoteIdentity: remote,
                confirmationCode: "0000-0000-0000",
                accepted: true,
                now: now
            )
            XCTFail("wrong pairing code should fail")
        } catch SecurityCoreError.pairingCodeMismatch {
            // Expected.
        }

        do {
            _ = try await coordinator.confirm(
                challengeID: challenge.challengeID,
                remoteIdentity: remote,
                confirmationCode: challenge.confirmationCode,
                accepted: true,
                now: now.addingTimeInterval(2)
            )
            XCTFail("expired pairing challenge should fail")
        } catch SecurityCoreError.pairingExpired {
            // Expected.
        }
    }

    func testRemoteChallengeCanBeAdoptedBeforeUserConfirmation() async throws {
        let local = try PeerIdentity(publicKeyRepresentation: Data("local-adopter".utf8))
        let remote = try PeerIdentity(publicKeyRepresentation: Data("remote-adopter".utf8))
        let source = PairingCoordinator(localIdentity: remote, trustStore: InMemoryTrustStore())
        let coordinator = PairingCoordinator(localIdentity: local, trustStore: InMemoryTrustStore())

        let sourceChallenge = try await source.beginSessionPairing(
            with: local,
            challengeID: 99,
            now: Date(timeIntervalSince1970: 3_000),
            timeout: 60
        )
        let challenge = try await coordinator.adoptRemoteSessionChallenge(
            challengeID: 99,
            from: remote,
            confirmationCode: sourceChallenge.confirmationCode,
            now: Date(timeIntervalSince1970: 3_000),
            timeout: 60
        )
        XCTAssertEqual(challenge.challengeID, 99)
        XCTAssertEqual(challenge.remoteIdentity, remote)
        XCTAssertEqual(challenge.confirmationCode, sourceChallenge.confirmationCode)

        let awaitingRemoteConsent = try await coordinator.confirmLocalConsent(
            challengeID: challenge.challengeID,
            remoteIdentity: remote,
            confirmationCode: challenge.confirmationCode,
            accepted: true,
            now: Date(timeIntervalSince1970: 3_001)
        )
        XCTAssertEqual(awaitingRemoteConsent, .awaitingRemoteConsent)
        let pendingDecision = try await coordinator.trustDecision(for: remote)
        XCTAssertEqual(pendingDecision, .pairingRequired)
    }

    func testRemoteConsentAloneRejectsTrustAndAbortClearsPendingState() async throws {
        let local = try PeerIdentity(publicKeyRepresentation: Data("local-consent".utf8))
        let remote = try PeerIdentity(publicKeyRepresentation: Data("remote-consent".utf8))
        let coordinator = PairingCoordinator(localIdentity: local, trustStore: InMemoryTrustStore())
        let now = Date(timeIntervalSince1970: 4_000)
        let challenge = try await coordinator.beginPairing(
            with: remote,
            challengeID: 101,
            nonce: Data(repeating: 0x11, count: 16),
            now: now,
            timeout: 10
        )

        let remoteOnlyResult = try await coordinator.recordRemoteConsent(
            challengeID: challenge.challengeID,
            remoteIdentity: remote,
            confirmationCode: challenge.confirmationCode,
            accepted: true,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(remoteOnlyResult, .awaitingRemoteConsent)
        let consentState = await coordinator.consentState()
        XCTAssertEqual(
            consentState,
            PairingConsentState(
                challengeID: challenge.challengeID,
                localConsent: false,
                remoteConsent: true,
                expiresAt: challenge.expiresAt
            )
        )
        let remoteOnlyDecision = try await coordinator.trustDecision(for: remote)
        XCTAssertEqual(remoteOnlyDecision, .pairingRequired)

        await coordinator.abortPendingPairing()
        let abortedState = await coordinator.state()
        let abortedConsent = await coordinator.consentState()
        let abortedDecision = try await coordinator.trustDecision(for: remote)
        XCTAssertEqual(abortedState, .idle)
        XCTAssertNil(abortedConsent)
        XCTAssertEqual(abortedDecision, .pairingRequired)
    }

    func testPairingRejectAndExpiryNeverPersistTrust() async throws {
        let local = try PeerIdentity(publicKeyRepresentation: Data("local-reject".utf8))
        let remote = try PeerIdentity(publicKeyRepresentation: Data("remote-reject".utf8))
        let coordinator = PairingCoordinator(localIdentity: local, trustStore: InMemoryTrustStore())
        let now = Date(timeIntervalSince1970: 5_000)

        let rejectedChallenge = try await coordinator.beginPairing(
            with: remote,
            challengeID: 102,
            nonce: Data(repeating: 0x22, count: 16),
            now: now,
            timeout: 10
        )
        do {
            _ = try await coordinator.confirmLocalConsent(
                challengeID: rejectedChallenge.challengeID,
                remoteIdentity: remote,
                confirmationCode: rejectedChallenge.confirmationCode,
                accepted: false,
                now: now
            )
            XCTFail("local rejection should fail closed")
        } catch SecurityCoreError.pairingRejected {
            // Expected.
        }
        let rejectedPendingChallenge = await coordinator.pendingChallenge()
        let rejectedDecision = try await coordinator.trustDecision(for: remote)
        XCTAssertNil(rejectedPendingChallenge)
        XCTAssertEqual(rejectedDecision, .pairingRequired)

        let expiredChallenge = try await coordinator.beginPairing(
            with: remote,
            challengeID: 103,
            nonce: Data(repeating: 0x33, count: 16),
            now: now,
            timeout: 1
        )
        let didExpire = await coordinator.expirePendingPairing(now: now.addingTimeInterval(2))
        let expiredPendingChallenge = await coordinator.pendingChallenge()
        let expiredDecision = try await coordinator.trustDecision(for: remote)
        XCTAssertTrue(didExpire)
        XCTAssertNil(expiredPendingChallenge)
        XCTAssertEqual(expiredChallenge.challengeID, 103)
        XCTAssertEqual(expiredDecision, .pairingRequired)
    }

    func testPeerTrustEvaluatorDistinguishesUnknownAndChangedIdentity() throws {
        let presented = try PeerIdentity(publicKeyRepresentation: Data("presented".utf8))
        let changed = try PeerIdentity(publicKeyRepresentation: Data("changed".utf8))
        let evaluator = PeerTrustEvaluator()

        XCTAssertEqual(evaluator.decision(for: presented, trustedPeer: nil), .pairingRequired)
        XCTAssertEqual(
            evaluator.decision(
                for: changed,
                trustedPeer: TrustedPeer(identity: presented)
            ),
            .identityMismatch
        )
        XCTAssertEqual(
            evaluator.decision(
                for: presented,
                trustedPeer: TrustedPeer(identity: presented)
            ),
            .trusted
        )
    }
}
