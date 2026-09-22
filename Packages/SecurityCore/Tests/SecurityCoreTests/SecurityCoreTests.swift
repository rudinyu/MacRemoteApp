import Foundation
@testable import SecurityCore
import Security
import XCTest

final class SecurityCoreTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(SecurityCoreModule.name, "SecurityCore")
    }

    func testLocalIdentityEnrollmentCreatesAndReusesAKeychainIdentity() async throws {
        let temporaryKeychain = try TemporaryKeychain()
        let tag = "com.rudinyu.MacRemoteApp.test.\(UUID().uuidString)"
        let provider = KeychainIdentityProvider(
            label: "Existing TLS Identity",
            applicationTag: tag,
            keychain: KeychainReference(temporaryKeychain.reference)
        )
        do {
            let first = try await provider.loadOrCreate()
            let second = try await provider.loadOrCreate()

            XCTAssertEqual(first.peerIdentity, second.peerIdentity)
            XCTAssertFalse(first.peerIdentity.identifier.isEmpty)
            try await provider.removeGeneratedIdentity()
        } catch {
            try? await provider.removeGeneratedIdentity()
            throw error
        }
    }

    func testLocalIdentityEnrollmentAdoptsConcurrentKeychainClaim() async throws {
        let temporaryKeychain = try TemporaryKeychain()
        let tag = "com.rudinyu.MacRemoteApp.test.concurrent.\(UUID().uuidString)"
        let providerA = KeychainIdentityProvider(
            label: "Concurrent TLS Identity",
            applicationTag: tag,
            keychain: KeychainReference(temporaryKeychain.reference)
        )
        let providerB = KeychainIdentityProvider(
            label: "Concurrent TLS Identity",
            applicationTag: tag,
            keychain: KeychainReference(temporaryKeychain.reference)
        )

        do {
            async let first = providerA.loadOrCreate()
            async let second = providerB.loadOrCreate()
            let (firstIdentity, secondIdentity) = try await (first, second)

            XCTAssertEqual(firstIdentity.peerIdentity, secondIdentity.peerIdentity)
            try await providerA.removeGeneratedIdentity()
        } catch {
            try? await providerA.removeGeneratedIdentity()
            throw error
        }
    }

    func testLocalIdentityEnrollmentRepairsMissingAndStalePersistentReference() async throws {
        let temporaryKeychain = try TemporaryKeychain()
        let tag = "com.rudinyu.MacRemoteApp.test.recovery.\(UUID().uuidString)"
        let provider = KeychainIdentityProvider(
            label: "Recoverable TLS Identity",
            applicationTag: tag,
            keychain: KeychainReference(temporaryKeychain.reference)
        )
        do {
            let first = try await provider.loadOrCreate()
            let referenceQuery = scoped([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: KeychainIdentityProvider.defaultKeyReferenceService,
                kSecAttrAccount: tag
            ], keychain: temporaryKeychain.reference)

            let removeStatus = SecItemDelete(referenceQuery as CFDictionary)
            XCTAssertEqual(removeStatus, errSecSuccess)
            let recoveredWithoutReference = try await provider.loadOrCreate()
            XCTAssertEqual(recoveredWithoutReference.peerIdentity, first.peerIdentity)

            var referenceResult: CFTypeRef?
            let referenceStatus = SecItemCopyMatching(
                referenceQuery.merging([kSecReturnData: true]) { _, new in new } as CFDictionary,
                &referenceResult
            )
            XCTAssertEqual(referenceStatus, errSecSuccess)
            let reference = try XCTUnwrap(referenceResult as? Data)
            let staleReference = Data(repeating: 0xA5, count: max(reference.count, 32))
            let staleStatus = SecItemUpdate(
                referenceQuery as CFDictionary,
                [kSecValueData: staleReference] as CFDictionary
            )
            XCTAssertEqual(staleStatus, errSecSuccess)

            let recoveredFromStaleReference = try await provider.loadOrCreate()
            XCTAssertEqual(recoveredFromStaleReference.peerIdentity, first.peerIdentity)
            try await provider.removeGeneratedIdentity()
        } catch {
            try? await provider.removeGeneratedIdentity()
            throw error
        }
    }

    func testLocalIdentityEnrollmentRecoversKeyWhenMetadataWasNotSaved() async throws {
        let temporaryKeychain = try TemporaryKeychain()
        let tag = "com.rudinyu.MacRemoteApp.test.partial.\(UUID().uuidString)"
        let provider = KeychainIdentityProvider(
            label: "Partial TLS Identity",
            applicationTag: tag,
            keychain: KeychainReference(temporaryKeychain.reference)
        )
        do {
            let first = try await provider.loadOrCreate()
            let certificateQuery = scoped([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: KeychainIdentityProvider.defaultCertificateService,
                kSecAttrAccount: tag
            ], keychain: temporaryKeychain.reference)
            let referenceQuery = scoped([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: KeychainIdentityProvider.defaultKeyReferenceService,
                kSecAttrAccount: tag
            ], keychain: temporaryKeychain.reference)
            XCTAssertEqual(SecItemDelete(certificateQuery as CFDictionary), errSecSuccess)

            // Certificate metadata may be lost after the key-reference record
            // was persisted. The provider must reuse the same private key and
            // recreate only the public certificate metadata.
            let recoveredWithReference = try await provider.loadOrCreate()
            XCTAssertEqual(recoveredWithReference.peerIdentity, first.peerIdentity)

            XCTAssertEqual(SecItemDelete(referenceQuery as CFDictionary), errSecSuccess)

            let recovered = try await provider.loadOrCreate()
            XCTAssertEqual(recovered.peerIdentity, first.peerIdentity)
            try await provider.removeGeneratedIdentity()
        } catch {
            try? await provider.removeGeneratedIdentity()
            throw error
        }
    }

    func testKeychainIdentitySelectionUsesExactLabelAndRejectsAmbiguity() async throws {
        let label = "MacRemoteApp Legacy Label \(UUID().uuidString)"
        let unrelated = try makeStoredTestIdentity(
            label: "Unrelated Identity \(UUID().uuidString)",
            commonName: "Unrelated operator-selected CN"
        )
        let selected = try makeStoredTestIdentity(
            label: label,
            commonName: "Selected operator CN"
        )
        let selectedIdentity = try KeychainIdentityProvider.selectIdentity(
            from: [
                (label: unrelated.label, identity: unrelated.identity),
                (label: selected.label, identity: selected.identity)
            ],
            label: label
        )
        let provisioned = try ProvisionedIdentity(secIdentity: selectedIdentity)
        XCTAssertEqual(provisioned.peerIdentity, try identity(for: selected.privateKey))

        let duplicate = try makeStoredTestIdentity(
            label: label,
            commonName: "A second operator-selected CN"
        )

        do {
            _ = try KeychainIdentityProvider.selectIdentity(
                from: [
                    (label: unrelated.label, identity: unrelated.identity),
                    (label: selected.label, identity: selected.identity),
                    (label: duplicate.label, identity: duplicate.identity)
                ],
                label: label
            )
            XCTFail("duplicate exact labels must fail closed")
        } catch SecurityCoreError.identityAmbiguous {
            // Expected.
        }
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

    private struct StoredTestIdentity {
        let privateKey: SecKey
        let identity: SecIdentity
        let label: String
    }

    private func makeStoredTestIdentity(
        label: String,
        commonName: String
    ) throws -> StoredTestIdentity {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: false,
                kSecAttrLabel: label,
                kSecAttrIsSensitive: true,
                kSecAttrIsExtractable: false
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SecurityCoreError.identityEnrollmentFailed
        }
        let certificateData = try LocalIdentityCertificate.make(
            privateKey: privateKey,
            commonName: commonName
        )
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            SecItemDelete([kSecValueRef: privateKey] as CFDictionary)
            throw SecurityCoreError.certificateUnavailable
        }
        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw SecurityCoreError.identityEnrollmentFailed
        }
        return StoredTestIdentity(
            privateKey: privateKey,
            identity: identity,
            label: label
        )
    }

    private func identity(for privateKey: SecKey) throws -> DeviceIdentity {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecurityCoreError.invalidPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw SecurityCoreError.invalidPublicKey
        }
        return try DeviceIdentity(publicKeyRepresentation: representation)
    }

    private func scoped(
        _ query: [CFString: Any],
        keychain: SecKeychain
    ) -> [CFString: Any] {
        var scopedQuery = query
        scopedQuery[kSecUseKeychain] = keychain
        return scopedQuery
    }
}

private final class TemporaryKeychain {
    let reference: SecKeychain
    private let previousSearchList: [SecKeychain]
    private let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteApp-Test-\(UUID().uuidString).keychain")
        let password = Data(UUID().uuidString.utf8)
        var created: SecKeychain?
        let status = url.path.withCString { path in
            password.withUnsafeBytes { bytes in
                SecKeychainCreate(
                    path,
                    UInt32(password.count),
                    bytes.baseAddress,
                    false,
                    nil,
                    &created
                )
            }
        }
        guard status == errSecSuccess, let created else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        reference = created

        var existingSearchList: CFArray?
        let copyStatus = SecKeychainCopySearchList(&existingSearchList)
        guard copyStatus == errSecSuccess else {
            _ = SecKeychainDelete(created)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(copyStatus))
        }
        previousSearchList = existingSearchList as? [SecKeychain] ?? []
        let newSearchList = ([created] + previousSearchList) as CFArray
        let setStatus = SecKeychainSetSearchList(newSearchList)
        guard setStatus == errSecSuccess else {
            _ = SecKeychainDelete(created)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(setStatus))
        }
    }

    deinit {
        _ = SecKeychainSetSearchList(previousSearchList as CFArray)
        _ = SecKeychainDelete(reference)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
