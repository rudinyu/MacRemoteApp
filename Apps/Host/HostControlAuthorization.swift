import Foundation
import SecurityCore

enum HostControlStatus: Sendable, Equatable, CustomStringConvertible {
    case unavailable
    case negotiating
    case unsupported
    case requiresConsent
    case active
    case paused
    case revoked
    case persistenceFailure

    var description: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .negotiating: return "Checking paired Viewer…"
        case .unsupported: return "Unsupported by Viewer"
        case .requiresConsent: return "Pair Viewer to enable control"
        case .active: return "Active"
        case .paused: return "Paused"
        case .revoked: return "Viewer pairing revoked"
        case .persistenceFailure: return "Blocked — Keychain update failed"
        }
    }
}

struct HostControlAuthorizationSnapshot: Sendable, Equatable {
    let sessionID: UUID?
    let peerIdentifier: String?
    let status: HostControlStatus
    /// The authenticated peer has a locally accepted pairing record.
    let trusted: Bool
    /// P6 control is admitted for this session. A pause keeps pairing trust
    /// while closing the local input-admission fence.
    let granted: Bool
    let paused: Bool
    let revision: UInt64
}

struct HostControlRevocationTicket: Sendable, Equatable {
    let sessionID: UUID
    let peerIdentifier: String
    let revision: UInt64
}

/// Serializes Keychain operations while the coordinator is reentrant across
/// awaits. A trust lookup already in flight must finish before a later revoke
/// touches the same record.
private actor HostControlPersistenceGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

/// Pairing is the Host-local trust decision for input. This coordinator only
/// reads that durable trust record, applies session-scoped pause state, and
/// removes the trust record on explicit revocation. It never presents a
/// second control-consent prompt or writes a parallel grant record.
actor HostControlAuthorizationCoordinator {
    private let trustStore: any TrustStore
    private let persistenceGate = HostControlPersistenceGate()
    private var revision: UInt64 = 0
    private var sessionID: UUID?
    private var peerIdentifier: String?
    private var supported = false
    private var trusted = false
    private var granted = false
    private var paused = false
    private var status: HostControlStatus = .unavailable
    private var revocationFailurePeerIdentifiers = Set<String>()
    private var pendingRevocationRevisionsByPeer: [String: UInt64] = [:]

    init(trustStore: any TrustStore) {
        self.trustStore = trustStore
    }

    func beginSession(
        sessionID: UUID,
        peerIdentifier: String?,
        peerName: String?,
        supportsControl: Bool
    ) -> HostControlAuthorizationSnapshot {
        _ = peerName
        advanceRevision()
        self.sessionID = sessionID
        self.peerIdentifier = peerIdentifier
        supported = supportsControl
        trusted = false
        granted = false
        paused = false

        if let peerIdentifier,
           pendingRevocationRevisionsByPeer[peerIdentifier] != nil {
            status = .revoked
        } else if let peerIdentifier,
                  revocationFailurePeerIdentifiers.contains(peerIdentifier) {
            status = .persistenceFailure
        } else if peerIdentifier == nil {
            status = supportsControl ? .requiresConsent : .unsupported
        } else {
            status = .negotiating
        }
        return snapshot()
    }

    /// Reads the pairing trust record. A locally accepted pairing therefore
    /// enables P6 on the first authenticated session and on reconnect without
    /// another control-consent prompt.
    func resolvePairingTrust(for sessionID: UUID) async -> HostControlAuthorizationSnapshot {
        guard self.sessionID == sessionID,
              let peerIdentifier,
              status == .negotiating else {
            return snapshot()
        }
        let operationRevision = revision
        guard pendingRevocationRevisionsByPeer[peerIdentifier] == nil,
              !revocationFailurePeerIdentifiers.contains(peerIdentifier) else {
            status = .persistenceFailure
            return snapshot()
        }

        await persistenceGate.acquire()
        guard isCurrent(
            sessionID: sessionID,
            peerIdentifier: peerIdentifier,
            revision: operationRevision
        ) else {
            await persistenceGate.release()
            return snapshot()
        }
        do {
            let record = try await trustStore.trustedPeer(for: peerIdentifier)
            await persistenceGate.release()
            guard isCurrent(
                sessionID: sessionID,
                peerIdentifier: peerIdentifier,
                revision: operationRevision
            ) else {
                return snapshot()
            }
            guard pendingRevocationRevisionsByPeer[peerIdentifier] == nil,
                  !revocationFailurePeerIdentifiers.contains(peerIdentifier) else {
                trusted = false
                granted = false
                paused = true
                status = .persistenceFailure
                return snapshot()
            }
            trusted = record != nil
            granted = trusted && supported
            paused = false
            if supported {
                status = trusted ? .active : .requiresConsent
            } else {
                status = .unsupported
            }
        } catch {
            await persistenceGate.release()
            guard isCurrent(
                sessionID: sessionID,
                peerIdentifier: peerIdentifier,
                revision: operationRevision
            ) else {
                return snapshot()
            }
            trusted = false
            granted = false
            paused = true
            status = .persistenceFailure
        }
        return snapshot()
    }

    func togglePause(for sessionID: UUID) -> HostControlAuthorizationSnapshot {
        guard self.sessionID == sessionID, granted else { return snapshot() }
        advanceRevision()
        paused.toggle()
        status = paused ? .paused : .active
        return snapshot()
    }

    func beginRevocation(for sessionID: UUID) -> HostControlRevocationTicket? {
        guard self.sessionID == sessionID,
              supported,
              let peerIdentifier,
              status == .active || status == .paused || status == .persistenceFailure else {
            return nil
        }
        advanceRevision()
        trusted = false
        granted = false
        paused = true
        status = .revoked
        pendingRevocationRevisionsByPeer[peerIdentifier] = revision
        return HostControlRevocationTicket(
            sessionID: sessionID,
            peerIdentifier: peerIdentifier,
            revision: revision
        )
    }

    /// Removes pairing trust. A successful caller must close the active
    /// authenticated session; on failure, the in-process peer fence blocks a
    /// reconnect from reusing the record until the operator completes a new
    /// pairing reset.
    func completeRevocation(
        _ ticket: HostControlRevocationTicket
    ) async -> HostControlAuthorizationSnapshot {
        await persistenceGate.acquire()
        guard pendingRevocationRevisionsByPeer[ticket.peerIdentifier] == ticket.revision else {
            await persistenceGate.release()
            return snapshot()
        }
        do {
            try await trustStore.revoke(peerIdentifier: ticket.peerIdentifier)
            if pendingRevocationRevisionsByPeer[ticket.peerIdentifier] == ticket.revision {
                pendingRevocationRevisionsByPeer.removeValue(forKey: ticket.peerIdentifier)
            }
            revocationFailurePeerIdentifiers.remove(ticket.peerIdentifier)
            if peerIdentifier == ticket.peerIdentifier {
                trusted = false
                granted = false
                paused = true
                if sessionID == ticket.sessionID && revision == ticket.revision {
                    status = .revoked
                } else {
                    advanceRevision()
                    status = .revoked
                }
            }
        } catch {
            if pendingRevocationRevisionsByPeer[ticket.peerIdentifier] == ticket.revision {
                pendingRevocationRevisionsByPeer.removeValue(forKey: ticket.peerIdentifier)
            }
            revocationFailurePeerIdentifiers.insert(ticket.peerIdentifier)
            if peerIdentifier == ticket.peerIdentifier {
                trusted = false
                granted = false
                paused = true
                if sessionID != ticket.sessionID || revision != ticket.revision {
                    advanceRevision()
                }
                status = .persistenceFailure
            }
        }
        await persistenceGate.release()
        return snapshot()
    }

    func endSession(_ sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        advanceRevision()
        self.sessionID = nil
        peerIdentifier = nil
        supported = false
        trusted = false
        granted = false
        paused = false
        status = .unavailable
    }

    /// An explicit all-pairings reset is the recovery boundary after a failed
    /// single-peer Keychain revoke.
    func clearRevocationFailuresAfterPairingReset() {
        revocationFailurePeerIdentifiers.removeAll()
        pendingRevocationRevisionsByPeer.removeAll()
    }

    func snapshot() -> HostControlAuthorizationSnapshot {
        HostControlAuthorizationSnapshot(
            sessionID: sessionID,
            peerIdentifier: peerIdentifier,
            status: status,
            trusted: trusted,
            granted: granted,
            paused: paused,
            revision: revision
        )
    }

    private func isCurrent(
        sessionID expectedSessionID: UUID,
        peerIdentifier expectedPeerIdentifier: String,
        revision expectedRevision: UInt64
    ) -> Bool {
        sessionID == expectedSessionID &&
            peerIdentifier == expectedPeerIdentifier &&
            revision == expectedRevision
    }

    private func advanceRevision() {
        revision &+= 1
    }
}
