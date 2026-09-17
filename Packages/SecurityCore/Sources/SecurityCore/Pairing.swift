import CryptoKit
import Foundation

public enum PairingState: Equatable, Sendable {
    case idle
    case awaitingConfirmation
    case paired
    case revoked
}

public enum PairingConsentResult: Equatable, Sendable {
    case awaitingRemoteConsent
    case paired(TrustedPeer)
}

public struct PairingConsentState: Equatable, Sendable {
    public let challengeID: UInt64
    public let localConsent: Bool
    public let remoteConsent: Bool
    public let expiresAt: Date

    public init(
        challengeID: UInt64,
        localConsent: Bool,
        remoteConsent: Bool,
        expiresAt: Date
    ) {
        self.challengeID = challengeID
        self.localConsent = localConsent
        self.remoteConsent = remoteConsent
        self.expiresAt = expiresAt
    }
}

public struct PairingChallenge: Equatable, Sendable {
    public let challengeID: UInt64
    public let remoteIdentity: PeerIdentity
    public let confirmationCode: String
    public let expiresAt: Date

    public init(
        challengeID: UInt64,
        remoteIdentity: PeerIdentity,
        confirmationCode: String,
        expiresAt: Date
    ) {
        self.challengeID = challengeID
        self.remoteIdentity = remoteIdentity
        self.confirmationCode = confirmationCode
        self.expiresAt = expiresAt
    }
}

public actor PairingCoordinator {
    private struct PendingPairing: Sendable {
        let challenge: PairingChallenge
        let nonce: Data
        var localConsent = false
        var remoteConsent = false
        var displayName: String?
    }

    private let localIdentity: DeviceIdentity
    private let trustStore: any TrustStore
    private var pending: PendingPairing?
    private var currentState: PairingState = .idle

    public init(localIdentity: DeviceIdentity, trustStore: any TrustStore) {
        self.localIdentity = localIdentity
        self.trustStore = trustStore
    }

    public func state() -> PairingState {
        currentState
    }

    public func pendingChallenge() -> PairingChallenge? {
        pending?.challenge
    }

    public func consentState() -> PairingConsentState? {
        guard let pending else { return nil }
        return PairingConsentState(
            challengeID: pending.challenge.challengeID,
            localConsent: pending.localConsent,
            remoteConsent: pending.remoteConsent,
            expiresAt: pending.challenge.expiresAt
        )
    }

    public func beginPairing(
        with remoteIdentity: PeerIdentity,
        challengeID: UInt64,
        nonce: Data,
        now: Date = Date(),
        timeout: TimeInterval = 300
    ) throws -> PairingChallenge {
        guard nonce.count >= 16, nonce.count <= 64 else {
            throw SecurityCoreError.invalidNonce
        }
        guard pending == nil else {
            throw SecurityCoreError.pairingAlreadyPending
        }
        let code = Self.confirmationCode(
            localIdentity: localIdentity,
            remoteIdentity: remoteIdentity,
            nonce: nonce
        )
        let challenge = PairingChallenge(
            challengeID: challengeID,
            remoteIdentity: remoteIdentity,
            confirmationCode: code,
            expiresAt: now.addingTimeInterval(timeout)
        )
        pending = PendingPairing(challenge: challenge, nonce: nonce)
        currentState = .awaitingConfirmation
        return challenge
    }

    public func beginSessionPairing(
        with remoteIdentity: PeerIdentity,
        challengeID: UInt64,
        now: Date = Date(),
        timeout: TimeInterval = 300
    ) throws -> PairingChallenge {
        try beginPairing(
            with: remoteIdentity,
            challengeID: challengeID,
            nonce: Self.sessionNonce(for: challengeID),
            now: now,
            timeout: timeout
        )
    }

    public func adoptRemoteChallenge(
        challengeID: UInt64,
        from remoteIdentity: PeerIdentity,
        confirmationCode: String,
        now: Date = Date(),
        timeout: TimeInterval = 300
    ) throws -> PairingChallenge {
        guard !confirmationCode.isEmpty, confirmationCode.utf8.count <= 256 else {
            throw SecurityCoreError.pairingCodeMismatch
        }
        guard pending == nil else {
            throw SecurityCoreError.pairingAlreadyPending
        }
        let challenge = PairingChallenge(
            challengeID: challengeID,
            remoteIdentity: remoteIdentity,
            confirmationCode: confirmationCode,
            expiresAt: now.addingTimeInterval(timeout)
        )
        // The adopted challenge has no locally generated nonce, but its
        // confirmation code is still an exact part of the challenge
        // transcript. Keep it as the revalidation token so an old async trust
        // commit cannot accidentally match a newly adopted challenge that
        // reuses the same ID and peer identity.
        pending = PendingPairing(
            challenge: challenge,
            nonce: Data(confirmationCode.utf8)
        )
        currentState = .awaitingConfirmation
        return challenge
    }

    public func adoptRemoteSessionChallenge(
        challengeID: UInt64,
        from remoteIdentity: PeerIdentity,
        confirmationCode: String,
        now: Date = Date(),
        timeout: TimeInterval = 300
    ) throws -> PairingChallenge {
        let expectedCode = Self.confirmationCode(
            localIdentity: localIdentity,
            remoteIdentity: remoteIdentity,
            nonce: Self.sessionNonce(for: challengeID)
        )
        guard confirmationCode == expectedCode else {
            throw SecurityCoreError.pairingCodeMismatch
        }
        return try adoptRemoteChallenge(
            challengeID: challengeID,
            from: remoteIdentity,
            confirmationCode: confirmationCode,
            now: now,
            timeout: timeout
        )
    }

    public func confirmLocalConsent(
        challengeID: UInt64,
        remoteIdentity: PeerIdentity,
        confirmationCode: String,
        accepted: Bool,
        displayName: String? = nil,
        now: Date = Date()
    ) async throws -> PairingConsentResult {
        guard let pending else {
            throw SecurityCoreError.noPendingPairing
        }
        guard pending.challenge.challengeID == challengeID,
              pending.challenge.remoteIdentity == remoteIdentity else {
            throw SecurityCoreError.peerIdentityMismatch
        }
        guard now <= pending.challenge.expiresAt else {
            self.pending = nil
            currentState = .idle
            throw SecurityCoreError.pairingExpired
        }
        guard accepted else {
            self.pending = nil
            currentState = .idle
            throw SecurityCoreError.pairingRejected
        }
        guard confirmationCode == pending.challenge.confirmationCode else {
            throw SecurityCoreError.pairingCodeMismatch
        }

        self.pending?.localConsent = true
        if let displayName {
            self.pending?.displayName = displayName
        }
        return try await commitIfReady(now: now)
    }

    public func confirm(
        challengeID: UInt64,
        remoteIdentity: PeerIdentity,
        confirmationCode: String,
        accepted: Bool,
        displayName: String? = nil,
        now: Date = Date()
    ) async throws -> PairingConsentResult {
        try await confirmLocalConsent(
            challengeID: challengeID,
            remoteIdentity: remoteIdentity,
            confirmationCode: confirmationCode,
            accepted: accepted,
            displayName: displayName,
            now: now
        )
    }

    public func recordRemoteConsent(
        challengeID: UInt64,
        remoteIdentity: PeerIdentity,
        confirmationCode: String,
        accepted: Bool,
        now: Date = Date()
    ) async throws -> PairingConsentResult {
        guard let pending else {
            throw SecurityCoreError.noPendingPairing
        }
        guard pending.challenge.challengeID == challengeID,
              pending.challenge.remoteIdentity == remoteIdentity else {
            throw SecurityCoreError.peerIdentityMismatch
        }
        guard now <= pending.challenge.expiresAt else {
            self.pending = nil
            currentState = .idle
            throw SecurityCoreError.pairingExpired
        }
        guard accepted else {
            self.pending = nil
            currentState = .idle
            throw SecurityCoreError.pairingRejected
        }
        guard confirmationCode == pending.challenge.confirmationCode else {
            throw SecurityCoreError.pairingCodeMismatch
        }

        self.pending?.remoteConsent = true
        return try await commitIfReady(now: now)
    }

    public func abortPendingPairing() {
        pending = nil
        if currentState == .awaitingConfirmation {
            currentState = .idle
        }
    }

    @discardableResult
    public func expirePendingPairing(now: Date = Date()) -> Bool {
        guard let pending, now > pending.challenge.expiresAt else { return false }
        self.pending = nil
        currentState = .idle
        return true
    }

    public func trustDecision(for remoteIdentity: PeerIdentity) async throws -> PeerTrustDecision {
        let trustedPeer = try await trustStore.trustedPeer(for: remoteIdentity.identifier)
        return PeerTrustEvaluator().decision(for: remoteIdentity, trustedPeer: trustedPeer)
    }

    public func revoke(remoteIdentity: PeerIdentity) async throws {
        try await trustStore.revoke(peerIdentifier: remoteIdentity.identifier)
        pending = nil
        currentState = .revoked
    }

    private func commitIfReady(now: Date) async throws -> PairingConsentResult {
        guard let pending else {
            throw SecurityCoreError.noPendingPairing
        }
        guard pending.localConsent, pending.remoteConsent else {
            return .awaitingRemoteConsent
        }

        let trustedPeer = TrustedPeer(
            identity: pending.challenge.remoteIdentity,
            displayName: pending.displayName,
            createdAt: now
        )
        let challengeNonce = pending.nonce
        try await trustStore.save(trustedPeer)

        // TrustStore is asynchronous, so abort/revoke can run while the
        // record is being written. Re-check the exact challenge after the
        // await and roll back the write if the pending consent was cancelled.
        guard let current = self.pending,
              current.challenge.challengeID == pending.challenge.challengeID,
              current.challenge.remoteIdentity == pending.challenge.remoteIdentity,
              current.nonce == challengeNonce,
              current.localConsent,
              current.remoteConsent else {
            try? await trustStore.revoke(peerIdentifier: trustedPeer.identity.identifier)
            throw SecurityCoreError.noPendingPairing
        }
        self.pending = nil
        currentState = .paired
        return .paired(trustedPeer)
    }

    private static func confirmationCode(
        localIdentity: DeviceIdentity,
        remoteIdentity: PeerIdentity,
        nonce: Data
    ) -> String {
        var transcript = Data()
        for identifier in [localIdentity.identifier, remoteIdentity.identifier].sorted() {
            transcript.append(contentsOf: identifier.utf8)
            transcript.append(0)
        }
        transcript.append(nonce)
        let digest = Array(SHA256.hash(data: transcript))
        let code = digest.prefix(6).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: code.count, by: 4).map { start in
            let begin = code.index(code.startIndex, offsetBy: start)
            let end = code.index(begin, offsetBy: min(4, code.distance(from: begin, to: code.endIndex)))
            return String(code[begin ..< end])
        }.joined(separator: "-")
    }

    private static func sessionNonce(for challengeID: UInt64) -> Data {
        var transcript = Data("MacRemoteApp.M2.Pairing".utf8)
        transcript.append(UInt8((challengeID >> 56) & 0xFF))
        transcript.append(UInt8((challengeID >> 48) & 0xFF))
        transcript.append(UInt8((challengeID >> 40) & 0xFF))
        transcript.append(UInt8((challengeID >> 32) & 0xFF))
        transcript.append(UInt8((challengeID >> 24) & 0xFF))
        transcript.append(UInt8((challengeID >> 16) & 0xFF))
        transcript.append(UInt8((challengeID >> 8) & 0xFF))
        transcript.append(UInt8(challengeID & 0xFF))
        return Data(SHA256.hash(data: transcript))
    }
}
