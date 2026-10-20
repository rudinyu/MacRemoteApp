import Foundation
import RemoteProtocol

public final class InMemoryTransport: SessionTransport, @unchecked Sendable {
    public let incoming: EnvelopeStream

    private let lock = NSLock()
    private let incomingStorage: EnvelopeStreamStorage
    private var peer: InMemoryTransport?
    private var lifecycle: TransportLifecycleState = .idle
    private let authenticationState: PeerAuthenticationState

    private init(
        authentication: PeerAuthenticationState,
        maxControlFrames: Int,
        maxMediaFrames: Int
    ) throws {
        let stream = try EnvelopeStream.makeBounded(
            maxControlFrames: maxControlFrames,
            maxMediaFrames: maxMediaFrames
        )
        self.incoming = stream.stream
        self.incomingStorage = stream.storage
        self.authenticationState = authentication
    }

    public static func makePair(
        firstAuthentication: PeerAuthenticationState,
        secondAuthentication: PeerAuthenticationState,
        maxControlFrames: Int = 128,
        maxMediaFrames: Int = 3
    ) -> (first: InMemoryTransport, second: InMemoryTransport) {
        let first = try! InMemoryTransport(
            authentication: firstAuthentication,
            maxControlFrames: maxControlFrames,
            maxMediaFrames: maxMediaFrames
        )
        let second = try! InMemoryTransport(
            authentication: secondAuthentication,
            maxControlFrames: maxControlFrames,
            maxMediaFrames: maxMediaFrames
        )
        first.lock.lock()
        first.peer = second
        first.lock.unlock()
        second.lock.lock()
        second.peer = first
        second.lock.unlock()
        return (first, second)
    }

    public func start() async throws {
        try lock.withLock {
            switch lifecycle {
            case .idle:
                lifecycle = .ready
            case .ready:
                return
            case .closed:
                throw TransportError.alreadyClosed
            case .starting, .closing, .failed:
                throw TransportError.connectionFailed("in-memory transport is unavailable")
            }
        }
    }

    public func send(_ envelope: Envelope) async throws -> TransportSendResult {
        let result: Result<InMemoryTransport, TransportError> = lock.withLock {
            guard lifecycle == .ready else {
                return .failure(lifecycle == .idle ? .notStarted : .alreadyClosed)
            }
            guard let peer else {
                return .failure(.connectionFailed("in-memory peer is missing"))
            }
            return .success(peer)
        }
        let peer = try result.get()
        return try peer.receive(envelope)
    }

    public func invalidateProtectedMessages() async {
        let peer = lock.withLock { self.peer }
        incomingStorage.removeProtectedMessages()
        peer?.incomingStorage.removeProtectedMessages()
    }

    public func close() async {
        let peerToNotify: InMemoryTransport? = lock.withLock {
            guard lifecycle != .closed else { return nil }
            lifecycle = .closed
            return peer
        }
        incomingStorage.finish()
        peerToNotify?.finishFromPeer()
    }

    public func authentication() async -> PeerAuthenticationState {
        authenticationState
    }

    public func snapshot() async -> TransportSnapshot {
        let counts = incomingStorage.counts()
        return lock.withLock {
            TransportSnapshot(
                state: lifecycle,
                queuedControlFrames: counts.control,
                queuedMediaFrames: counts.media,
                authentication: authenticationState
            )
        }
    }

    private func receive(_ envelope: Envelope) throws -> TransportSendResult {
        let lifecycle = lock.withLock { self.lifecycle }
        // A connected endpoint buffers peer data before its own start(), as a
        // socket does. Two sessions started concurrently otherwise race: the
        // first Hello could reach a peer that is still idle and be reported
        // as a closed transport.
        switch lifecycle {
        case .idle, .starting, .ready:
            break
        case .closing, .closed, .failed:
            throw TransportError.alreadyClosed
        }
        do {
            let result = try incomingStorage.yield(envelope)
            switch result {
            case .queued:
                return .queued
            case .replacedMedia:
                return .replacedMedia
            }
        } catch {
            lock.withLock {
                if let transportError = error as? TransportError {
                    switch transportError {
                    case .controlBackpressure, .mediaBackpressure:
                        self.lifecycle = .failed(transportError.description)
                    default:
                        break
                    }
                }
            }
            throw error
        }
    }

    private func finishFromPeer() {
        let shouldFinish = lock.withLock { () -> Bool in
            guard lifecycle != .closed else { return false }
            lifecycle = .closed
            return true
        }
        if shouldFinish {
            incomingStorage.finish()
        }
    }
}
