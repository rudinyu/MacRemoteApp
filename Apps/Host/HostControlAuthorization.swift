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
        case .negotiating: return "Setting up Viewer control…"
        case .unsupported: return "Unsupported by Viewer"
        case .requiresConsent: return "Local approval required"
        case .active: return "Active"
        case .paused: return "Paused"
        case .revoked: return "Revoked"
        case .persistenceFailure: return "Blocked — Keychain update failed"
        }
    }
}

struct HostControlAuthorizationSnapshot: Sendable, Equatable {
    let sessionID: UUID?
    let peerIdentifier: String?
    let status: HostControlStatus
    /// A durable grant exists for this authenticated peer. Paused control
    /// keeps this true while the local admission fence remains closed.
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
/// awaits. A grant already in flight must finish before a later revoke or
/// remove-all operation touches the store.
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

private struct HostControlGrantIntent: Sendable {
    let revision: UInt64
    let granted: Bool
}

/// Owns the durable, per-peer P6 consent state. The Host runtime applies the
/// resulting snapshot to its local input and session gates. All async results
/// are revision-scoped so a late prompt or Keychain operation cannot revive a
/// grant after a newer revoke, reconnect, or session replacement.
actor HostControlAuthorizationCoordinator {
    typealias ConsentPrompt = @Sendable (_ peerName: String?, _ peerIdentifier: String) async -> Bool

    private let store: any ControlGrantStore
    private let prompt: ConsentPrompt
    private let persistenceGate = HostControlPersistenceGate()
    private var revision: UInt64 = 0
    private var sessionID: UUID?
    private var peerIdentifier: String?
    private var peerName: String?
    private var supported = false
    private var granted = false
    private var paused = false
    private var status: HostControlStatus = .unavailable
    private var revocationFailurePeerIdentifiers = Set<String>()
    private var pendingRevocationRevisionsByPeer: [String: UInt64] = [:]
    private var grantResetFailed = false
    private var grantResetInProgress = false
    private var durableIntentByPeer: [String: HostControlGrantIntent] = [:]

    init(
        store: any ControlGrantStore,
        prompt: @escaping ConsentPrompt
    ) {
        self.store = store
        self.prompt = prompt
    }

    func beginSession(
        sessionID: UUID,
        peerIdentifier: String?,
        peerName: String?,
        supportsControl: Bool
    ) -> HostControlAuthorizationSnapshot {
        advanceRevision()
        self.sessionID = sessionID
        self.peerIdentifier = peerIdentifier
        self.peerName = peerName
        supported = supportsControl
        granted = false
        paused = false
        if !supportsControl {
            status = .unsupported
        } else if grantResetInProgress || grantResetFailed ||
                    peerIdentifier.map(revocationFailurePeerIdentifiers.contains) == true {
            status = .persistenceFailure
        } else if let peerIdentifier,
                  pendingRevocationRevisionsByPeer[peerIdentifier] != nil {
            paused = true
            status = .revoked
        } else if peerIdentifier == nil {
            status = .requiresConsent
        } else {
            status = .negotiating
        }
        return snapshot()
    }

    /// Checks the durable grant and starts the local prompt if no grant exists.
    /// Call this from an unstructured session task so a modal consent prompt
    /// does not hold up window selection or the view-only video path.
    func resolveInitialConsent(for sessionID: UUID) async -> HostControlAuthorizationSnapshot {
        guard self.sessionID == sessionID, supported,
              let peerIdentifier,
              status == .negotiating else {
            return snapshot()
        }
        let operationRevision = revision
        if grantResetInProgress || grantResetFailed ||
            revocationFailurePeerIdentifiers.contains(peerIdentifier) {
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
        guard pendingRevocationRevisionsByPeer[peerIdentifier] == nil else {
            granted = false
            paused = true
            status = .revoked
            await persistenceGate.release()
            return snapshot()
        }
        do {
            let hasGrant = try await store.contains(peerIdentifier: peerIdentifier)
            await persistenceGate.release()
            guard isCurrent(sessionID: sessionID, peerIdentifier: peerIdentifier, revision: operationRevision) else {
                return snapshot()
            }
            guard !grantResetFailed,
                  !revocationFailurePeerIdentifiers.contains(peerIdentifier) else {
                granted = false
                paused = true
                status = .persistenceFailure
                return snapshot()
            }
            if hasGrant {
                granted = true
                paused = false
                status = .active
                return snapshot()
            }
            status = .requiresConsent
            return await requestConsent(for: sessionID)
        } catch {
            await persistenceGate.release()
            guard isCurrent(sessionID: sessionID, peerIdentifier: peerIdentifier, revision: operationRevision) else {
                return snapshot()
            }
            status = .persistenceFailure
            return snapshot()
        }
    }

    func requestConsent(for sessionID: UUID) async -> HostControlAuthorizationSnapshot {
        guard self.sessionID == sessionID, supported,
              let peerIdentifier,
              status == .requiresConsent || status == .revoked || status == .persistenceFailure else {
            return snapshot()
        }
        guard !grantResetInProgress, !grantResetFailed else {
            status = .persistenceFailure
            return snapshot()
        }
        guard pendingRevocationRevisionsByPeer[peerIdentifier] == nil else {
            granted = false
            paused = true
            status = .revoked
            return snapshot()
        }
        advanceRevision()
        let operationRevision = revision
        status = .negotiating
        let accepted = await prompt(peerName, peerIdentifier)
        guard isCurrent(sessionID: sessionID, peerIdentifier: peerIdentifier, revision: operationRevision) else {
            return snapshot()
        }
        guard accepted else {
            status = .requiresConsent
            return snapshot()
        }
        durableIntentByPeer[peerIdentifier] = HostControlGrantIntent(
            revision: operationRevision,
            granted: true
        )
        await persistenceGate.acquire()
        guard isCurrent(sessionID: sessionID, peerIdentifier: peerIdentifier, revision: operationRevision),
              durableIntentByPeer[peerIdentifier]?.revision == operationRevision,
              durableIntentByPeer[peerIdentifier]?.granted == true else {
            await persistenceGate.release()
            return snapshot()
        }
        do {
            try await store.grant(peerIdentifier: peerIdentifier)
            await persistenceGate.release()
            guard isCurrent(sessionID: sessionID, peerIdentifier: peerIdentifier, revision: operationRevision) else {
                return snapshot()
            }
            granted = true
            paused = false
            revocationFailurePeerIdentifiers.remove(peerIdentifier)
            status = .active
        } catch {
            await persistenceGate.release()
            guard isCurrent(sessionID: sessionID, peerIdentifier: peerIdentifier, revision: operationRevision) else {
                return snapshot()
            }
            granted = false
            paused = true
            revocationFailurePeerIdentifiers.insert(peerIdentifier)
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
        guard self.sessionID == sessionID, supported, let peerIdentifier,
              status != .unavailable, status != .unsupported else {
            return nil
        }
        advanceRevision()
        granted = false
        paused = true
        status = .revoked
        durableIntentByPeer[peerIdentifier] = HostControlGrantIntent(
            revision: revision,
            granted: false
        )
        pendingRevocationRevisionsByPeer[peerIdentifier] = revision
        return HostControlRevocationTicket(
            sessionID: sessionID,
            peerIdentifier: peerIdentifier,
            revision: revision
        )
    }

    func completeRevocation(
        _ ticket: HostControlRevocationTicket
    ) async -> HostControlAuthorizationSnapshot {
        await persistenceGate.acquire()
        let intent = durableIntentByPeer[ticket.peerIdentifier]
        guard intent?.revision == ticket.revision, intent?.granted == false else {
            if pendingRevocationRevisionsByPeer[ticket.peerIdentifier] == ticket.revision {
                pendingRevocationRevisionsByPeer.removeValue(forKey: ticket.peerIdentifier)
            }
            await persistenceGate.release()
            return snapshot()
        }
        do {
            try await store.revoke(peerIdentifier: ticket.peerIdentifier)
            if pendingRevocationRevisionsByPeer[ticket.peerIdentifier] == ticket.revision {
                pendingRevocationRevisionsByPeer.removeValue(forKey: ticket.peerIdentifier)
            }
            revocationFailurePeerIdentifiers.remove(ticket.peerIdentifier)
            if isCurrent(
                sessionID: ticket.sessionID,
                peerIdentifier: ticket.peerIdentifier,
                revision: ticket.revision
            ) {
                status = .revoked
            } else if peerIdentifier == ticket.peerIdentifier,
                      durableIntentByPeer[ticket.peerIdentifier]?.revision == ticket.revision {
                // A reconnect may have read the old saved grant while revoke
                // was waiting. Revoke still wins unless a newer explicit
                // consent intent superseded this ticket.
                advanceRevision()
                granted = false
                paused = true
                status = .revoked
            }
            await persistenceGate.release()
        } catch {
            // Keep this fence even if a reconnect replaced the session while
            // Keychain was suspended. A failed local revoke must not let the
            // next session silently reuse a stale durable grant.
            if pendingRevocationRevisionsByPeer[ticket.peerIdentifier] == ticket.revision {
                pendingRevocationRevisionsByPeer.removeValue(forKey: ticket.peerIdentifier)
                revocationFailurePeerIdentifiers.insert(ticket.peerIdentifier)
            }
            let ticketIsCurrent = isCurrent(
                sessionID: ticket.sessionID,
                peerIdentifier: ticket.peerIdentifier,
                revision: ticket.revision
            )
            if ticketIsCurrent {
                status = .persistenceFailure
            } else if peerIdentifier == ticket.peerIdentifier,
                      durableIntentByPeer[ticket.peerIdentifier]?.revision == ticket.revision {
                advanceRevision()
                granted = false
                paused = true
                status = .persistenceFailure
            }
            await persistenceGate.release()
        }
        return snapshot()
    }

    func endSession(_ sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        advanceRevision()
        self.sessionID = nil
        peerIdentifier = nil
        peerName = nil
        supported = false
        granted = false
        paused = false
        status = .unavailable
    }

    func removeAllGrants() async throws -> Int {
        advanceRevision()
        granted = false
        paused = true
        grantResetInProgress = true
        await persistenceGate.acquire()
        do {
            let count = try await store.removeAll()
            await persistenceGate.release()
            revocationFailurePeerIdentifiers.removeAll()
            pendingRevocationRevisionsByPeer.removeAll()
            grantResetFailed = false
            grantResetInProgress = false
            durableIntentByPeer.removeAll()
            return count
        } catch {
            await persistenceGate.release()
            // remove-all is the explicit recovery boundary for every saved
            // peer, including grants from sessions this process has not seen.
            grantResetFailed = true
            grantResetInProgress = false
            if sessionID != nil {
                advanceRevision()
                granted = false
                paused = true
                status = .persistenceFailure
            }
            throw error
        }
    }

    func snapshot() -> HostControlAuthorizationSnapshot {
        HostControlAuthorizationSnapshot(
            sessionID: sessionID,
            peerIdentifier: peerIdentifier,
            status: status,
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

    private func withSerializedStoreOperation<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await persistenceGate.acquire()
        do {
            let result = try await operation()
            await persistenceGate.release()
            return result
        } catch {
            await persistenceGate.release()
            throw error
        }
    }

    private func advanceRevision() {
        revision &+= 1
    }
}
