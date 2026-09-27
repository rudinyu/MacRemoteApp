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
    /// The initiator's commitment for the M10 commit/reveal exchange.
    /// Legacy/unit-test challenges may leave this nil.
    public let commitment: Data?

    public var isVerificationReady: Bool {
        !confirmationCode.isEmpty
    }

    public init(
        challengeID: UInt64,
        remoteIdentity: PeerIdentity,
        confirmationCode: String,
        expiresAt: Date,
        commitment: Data? = nil
    ) {
        self.challengeID = challengeID
        self.remoteIdentity = remoteIdentity
        self.confirmationCode = confirmationCode
        self.expiresAt = expiresAt
        self.commitment = commitment
    }
}

/// The Viewer commitment sent after receiving the Host commitment.
public struct PairingSessionResponse: Equatable, Sendable {
    public let challengeID: UInt64
    public let commitment: Data

    public init(challengeID: UInt64, commitment: Data) {
        self.challengeID = challengeID
        self.commitment = commitment
    }
}

/// The Host reveal sent after both endpoints have committed to their values.
public struct PairingSessionVerification: Equatable, Sendable {
    public let challengeID: UInt64
    public let contribution: Data

    public init(challengeID: UInt64, contribution: Data) {
        self.challengeID = challengeID
        self.contribution = contribution
    }
}

/// The Viewer reveal sent after verifying the Host contribution.
public struct PairingSessionReveal: Equatable, Sendable {
    public let challengeID: UInt64
    public let contribution: Data

    public init(challengeID: UInt64, contribution: Data) {
        self.challengeID = challengeID
        self.contribution = contribution
    }
}

/// MacKVM-style commit/reveal code derivation for the first-pairing flow.
/// Both endpoints derive the same short display value from the challenge,
/// both public identities, and both random contributions.
public enum PairingVerificationCode {
    public static let contributionByteCount = 32
    public static let commitmentByteCount = 32

    public static func randomContribution() -> Data {
        Data((0 ..< contributionByteCount).map { _ in
            UInt8.random(in: UInt8.min ... UInt8.max)
        })
    }

    public static func commitment(for contribution: Data) -> Data {
        var transcript = Data("MacRemoteApp pairing commitment v1".utf8)
        transcript.append(contribution)
        return Data(SHA256.hash(data: transcript))
    }

    public static func deriveCode(
        challengeID: UInt64,
        localIdentity: PeerIdentity,
        remoteIdentity: PeerIdentity,
        localContribution: Data,
        remoteContribution: Data
    ) -> String {
        let identityContributions = [
            (localIdentity, localContribution),
            (remoteIdentity, remoteContribution)
        ].sorted { $0.0.identifier < $1.0.identifier }

        var transcript = Data("MacRemoteApp pairing verification v1".utf8)
        appendUInt64(challengeID, to: &transcript)
        for (identity, contribution) in identityContributions {
            appendUInt32(UInt32(identity.publicKeyRepresentation.count), to: &transcript)
            transcript.append(identity.publicKeyRepresentation)
            appendUInt32(UInt32(contribution.count), to: &transcript)
            transcript.append(contribution)
        }
        let digest = Array(SHA256.hash(data: transcript))
        let number = (UInt32(digest[0]) << 24 |
            UInt32(digest[1]) << 16 |
            UInt32(digest[2]) << 8 |
            UInt32(digest[3])) % 1_000_000
        return String(format: "%06u", number)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        data.append(UInt8((value >> 56) & 0xFF))
        data.append(UInt8((value >> 48) & 0xFF))
        data.append(UInt8((value >> 40) & 0xFF))
        data.append(UInt8((value >> 32) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

public actor PairingCoordinator {
    private struct PendingPairing: Sendable {
        var challenge: PairingChallenge
        let nonce: Data
        let localContribution: Data?
        var remoteCommitment: Data?
        var remoteContribution: Data?
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
        pending = PendingPairing(
            challenge: challenge,
            nonce: nonce,
            localContribution: nil,
            remoteCommitment: nil,
            remoteContribution: nil
        )
        currentState = .awaitingConfirmation
        return challenge
    }

    public func beginSessionPairing(
        with remoteIdentity: PeerIdentity,
        challengeID: UInt64,
        now: Date = Date(),
        timeout: TimeInterval = 300
    ) throws -> PairingChallenge {
        guard pending == nil else {
            throw SecurityCoreError.pairingAlreadyPending
        }
        let localContribution = PairingVerificationCode.randomContribution()
        let challenge = PairingChallenge(
            challengeID: challengeID,
            remoteIdentity: remoteIdentity,
            confirmationCode: "",
            expiresAt: now.addingTimeInterval(timeout),
            commitment: PairingVerificationCode.commitment(for: localContribution)
        )
        pending = PendingPairing(
            challenge: challenge,
            nonce: localContribution,
            localContribution: localContribution,
            remoteCommitment: nil,
            remoteContribution: nil
        )
        currentState = .awaitingConfirmation
        return challenge
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
            nonce: Data(confirmationCode.utf8),
            localContribution: nil,
            remoteCommitment: nil,
            remoteContribution: nil
        )
        currentState = .awaitingConfirmation
        return challenge
    }

    /// Adopts the Host commitment and creates the Viewer contribution.
    public func adoptRemoteSessionChallenge(
        challengeID: UInt64,
        from remoteIdentity: PeerIdentity,
        commitment: Data,
        now: Date = Date(),
        timeout: TimeInterval = 300
    ) throws -> PairingChallenge {
        guard commitment.count == PairingVerificationCode.commitmentByteCount else {
            throw SecurityCoreError.pairingCodeMismatch
        }
        guard pending == nil else {
            throw SecurityCoreError.pairingAlreadyPending
        }
        let localContribution = PairingVerificationCode.randomContribution()
        let challenge = PairingChallenge(
            challengeID: challengeID,
            remoteIdentity: remoteIdentity,
            confirmationCode: "",
            expiresAt: now.addingTimeInterval(timeout),
            commitment: commitment
        )
        pending = PendingPairing(
            challenge: challenge,
            nonce: localContribution,
            localContribution: localContribution,
            remoteCommitment: commitment,
            remoteContribution: nil
        )
        currentState = .awaitingConfirmation
        return challenge
    }

    /// Returns the contribution generated for the adopted challenge. It is
    /// sent only over the authenticated bootstrap channel and never persisted.
    public func sessionResponse(
        challengeID: UInt64,
        remoteIdentity: PeerIdentity
    ) throws -> PairingSessionResponse {
        guard let pending,
              pending.challenge.challengeID == challengeID,
              pending.challenge.remoteIdentity == remoteIdentity,
              let contribution = pending.localContribution else {
            throw SecurityCoreError.noPendingPairing
        }
        return PairingSessionResponse(
            challengeID: challengeID,
            commitment: PairingVerificationCode.commitment(for: contribution)
        )
    }

    /// Records the Viewer's commitment and returns the Host reveal. The
    /// confirmation code is deliberately not available until the Viewer
    /// reveals its already-committed contribution.
    public func prepareSessionVerification(
        challengeID: UInt64,
        remoteIdentity: PeerIdentity,
        remoteCommitment: Data
    ) throws -> PairingSessionVerification {
        guard var pending,
              pending.challenge.challengeID == challengeID,
              pending.challenge.remoteIdentity == remoteIdentity,
              let localContribution = pending.localContribution,
              pending.challenge.commitment != nil,
              pending.remoteCommitment == nil,
              pending.remoteContribution == nil,
              remoteCommitment.count == PairingVerificationCode.commitmentByteCount else {
            throw SecurityCoreError.pairingCodeMismatch
        }
        pending.remoteCommitment = remoteCommitment
        self.pending = pending
        return PairingSessionVerification(
            challengeID: challengeID,
            contribution: localContribution
        )
    }

    /// Verifies the Host reveal against the initial commitment and derives the
    /// code locally. A changed Host contribution fails closed. The Viewer can
    /// now reveal its already-committed contribution.
    public func adoptRemoteSessionVerification(
        challengeID: UInt64,
        from remoteIdentity: PeerIdentity,
        remoteContribution: Data
    ) throws -> PairingChallenge {
        guard var pending,
              pending.challenge.challengeID == challengeID,
              pending.challenge.remoteIdentity == remoteIdentity,
              let localContribution = pending.localContribution,
              let remoteCommitment = pending.remoteCommitment,
              pending.remoteContribution == nil,
              remoteContribution.count == PairingVerificationCode.contributionByteCount,
              PairingVerificationCode.commitment(for: remoteContribution) == remoteCommitment else {
            throw SecurityCoreError.pairingCodeMismatch
        }
        let code = PairingVerificationCode.deriveCode(
            challengeID: challengeID,
            localIdentity: localIdentity,
            remoteIdentity: remoteIdentity,
            localContribution: localContribution,
            remoteContribution: remoteContribution
        )
        pending.challenge = PairingChallenge(
            challengeID: challengeID,
            remoteIdentity: remoteIdentity,
            confirmationCode: code,
            expiresAt: pending.challenge.expiresAt,
            commitment: remoteCommitment
        )
        pending.remoteContribution = remoteContribution
        self.pending = pending
        return pending.challenge
    }

    /// Returns the Viewer's reveal after the Host contribution was verified.
    public func sessionReveal(
        challengeID: UInt64,
        remoteIdentity: PeerIdentity
    ) throws -> PairingSessionReveal {
        guard let pending,
              pending.challenge.challengeID == challengeID,
              pending.challenge.remoteIdentity == remoteIdentity,
              let contribution = pending.localContribution,
              pending.remoteCommitment != nil,
              pending.remoteContribution != nil else {
            throw SecurityCoreError.noPendingPairing
        }
        return PairingSessionReveal(challengeID: challengeID, contribution: contribution)
    }

    /// Verifies and records the Viewer's reveal, then derives the Host-side
    /// code. The Viewer contribution was committed before the Host reveal.
    public func adoptRemoteSessionReveal(
        challengeID: UInt64,
        from remoteIdentity: PeerIdentity,
        remoteContribution: Data
    ) throws -> PairingChallenge {
        guard var pending,
              pending.challenge.challengeID == challengeID,
              pending.challenge.remoteIdentity == remoteIdentity,
              let localContribution = pending.localContribution,
              pending.remoteCommitment != nil,
              pending.remoteContribution == nil,
              remoteContribution.count == PairingVerificationCode.contributionByteCount,
              PairingVerificationCode.commitment(for: remoteContribution) == pending.remoteCommitment else {
            throw SecurityCoreError.pairingCodeMismatch
        }
        let code = PairingVerificationCode.deriveCode(
            challengeID: challengeID,
            localIdentity: localIdentity,
            remoteIdentity: remoteIdentity,
            localContribution: localContribution,
            remoteContribution: remoteContribution
        )
        pending.challenge = PairingChallenge(
            challengeID: challengeID,
            remoteIdentity: remoteIdentity,
            confirmationCode: code,
            expiresAt: pending.challenge.expiresAt,
            commitment: pending.challenge.commitment
        )
        pending.remoteContribution = remoteContribution
        self.pending = pending
        return pending.challenge
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
        guard pending.challenge.isVerificationReady,
              confirmationCode == pending.challenge.confirmationCode else {
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
        guard pending.challenge.isVerificationReady,
              confirmationCode == pending.challenge.confirmationCode else {
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
