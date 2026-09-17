@preconcurrency import Network
import Foundation
import RemoteProtocol

public actor NetworkFramedTransport: SessionTransport {
    public nonisolated let incoming: EnvelopeStream

    private let connection: NWConnection
    private let limits: ProtocolLimits
    private let outgoing: BoundedFrameQueue
    private let incomingStorage: EnvelopeStreamStorage
    private let tlsOptions: TLSOptions
    private let connectionTimeoutNanoseconds: UInt64

    private var parser: FrameParser
    private var lifecycle: TransportLifecycleState = .idle
    private var authenticationState: PeerAuthenticationState
    private var isSending = false
    private var hasStartedReceiving = false
    private var startWaiters: [CheckedContinuation<Void, Error>] = []
    private var startDeadlineTask: Task<Void, Never>?

    public init(
        endpoint: NWEndpoint,
        tlsOptions: TLSOptions,
        limits: ProtocolLimits = .default,
        maxControlFrames: Int = 128,
        maxMediaFrames: Int = 3,
        connectionTimeoutNanoseconds: UInt64 = 15_000_000_000
    ) throws {
        let stream = try EnvelopeStream.makeBounded(
            maxControlFrames: maxControlFrames,
            maxMediaFrames: maxMediaFrames
        )
        self.incoming = stream.stream
        self.incomingStorage = stream.storage
        self.connection = NWConnection(to: endpoint, using: tlsOptions.makeParameters())
        self.limits = limits
        self.tlsOptions = tlsOptions
        self.connectionTimeoutNanoseconds = connectionTimeoutNanoseconds
        self.outgoing = try BoundedFrameQueue(
            maxControlFrames: maxControlFrames,
            maxMediaFrames: maxMediaFrames
        )
        self.parser = try FrameParser(limits: limits)
        self.authenticationState = tlsOptions.initialAuthentication
    }

    public init(
        connection: NWConnection,
        tlsOptions: TLSOptions,
        limits: ProtocolLimits = .default,
        authentication: PeerAuthenticationState,
        maxControlFrames: Int = 128,
        maxMediaFrames: Int = 3,
        connectionTimeoutNanoseconds: UInt64 = 15_000_000_000
    ) throws {
        let stream = try EnvelopeStream.makeBounded(
            maxControlFrames: maxControlFrames,
            maxMediaFrames: maxMediaFrames
        )
        self.incoming = stream.stream
        self.incomingStorage = stream.storage
        self.connection = connection
        self.limits = limits
        self.tlsOptions = tlsOptions
        self.connectionTimeoutNanoseconds = connectionTimeoutNanoseconds
        self.outgoing = try BoundedFrameQueue(
            maxControlFrames: maxControlFrames,
            maxMediaFrames: maxMediaFrames
        )
        self.parser = try FrameParser(limits: limits)
        self.authenticationState = authentication
    }

    public func start() async throws {
        switch lifecycle {
        case .ready:
            return
        case .starting:
            try await withCheckedThrowingContinuation { continuation in
                startWaiters.append(continuation)
            }
        case .idle:
            lifecycle = .starting
            try await withCheckedThrowingContinuation { continuation in
                startWaiters.append(continuation)
                connection.stateUpdateHandler = { [weak self] state in
                    Task { await self?.handleConnectionState(state) }
                }
                connection.start(queue: DispatchQueue(label: "MacRemoteApp.NetworkTransport"))
                startDeadlineTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: self?.connectionTimeoutNanoseconds ?? 0)
                    } catch {
                        return
                    }
                    await self?.handleConnectionDeadline()
                }
            }
        case .closing, .closed:
            throw TransportError.alreadyClosed
        case let .failed(detail):
            throw TransportError.connectionFailed(detail)
        }
    }

    public func send(_ envelope: Envelope) async throws -> TransportSendResult {
        guard lifecycle == .ready else {
            if lifecycle == .idle || lifecycle == .starting {
                throw TransportError.notStarted
            }
            throw TransportError.alreadyClosed
        }
        let result = try await outgoing.enqueue(envelope)
        if result == .replacedOldestMedia {
            await pump()
            return .replacedMedia
        }
        await pump()
        return .queued
    }

    public func invalidateProtectedMessages() async {
        await outgoing.removeProtectedMessages()
        incomingStorage.removeProtectedMessages()
    }

    public func close() {
        guard lifecycle != .closed else { return }
        lifecycle = .closing
        startDeadlineTask?.cancel()
        startDeadlineTask = nil
        resumeStartWaiters(with: .failure(TransportError.alreadyClosed))
        connection.cancel()
        incomingStorage.finish()
        lifecycle = .closed
        Task { await outgoing.removeAll() }
    }

    public func authentication() async -> PeerAuthenticationState {
        authenticationState
    }

    public func snapshot() async -> TransportSnapshot {
        let counts = await outgoing.counts()
        return TransportSnapshot(
            state: lifecycle,
            queuedControlFrames: counts.control,
            queuedMediaFrames: counts.media,
            authentication: authenticationState
        )
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        guard lifecycle != .closed, lifecycle != .closing else { return }
        switch state {
        case .ready:
            authenticationState = tlsOptions.resolvedAuthentication(for: connection)
            guard authenticationState != .pending,
                  authenticationState != .rejected else {
                fail(.authenticationFailed)
                return
            }
            startDeadlineTask?.cancel()
            startDeadlineTask = nil
            lifecycle = .ready
            resumeStartWaiters(with: .success(()))
            beginReceiving()
            Task { await pump() }
        case let .failed(error):
            fail(.connectionFailed(String(describing: error)))
        case .cancelled:
            fail(.connectionFailed("cancelled"))
        case .setup, .waiting, .preparing:
            break
        @unknown default:
            fail(.connectionFailed("unknown Network.framework connection state"))
        }
    }

    private func handleConnectionDeadline() {
        guard lifecycle == .starting else { return }
        fail(.connectionTimeout)
    }

    private func beginReceiving() {
        guard !hasStartedReceiving else { return }
        hasStartedReceiving = true
        receiveNext()
    }

    private func receiveNext() {
        guard lifecycle == .ready else { return }
        let maximumLength = Envelope.headerSize + limits.maxPayloadLength
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximumLength
        ) { [weak self] content, _, isComplete, error in
            let bytes = content.map(Data.init) ?? Data()
            Task {
                await self?.handleReceived(
                    bytes: bytes,
                    isComplete: isComplete,
                    error: error
                )
            }
        }
    }

    private func handleReceived(bytes: Data, isComplete: Bool, error: NWError?) {
        guard lifecycle == .ready else { return }
        if let error {
            fail(.connectionFailed(String(describing: error)))
            return
        }
        do {
            for envelope in try parser.append(bytes) {
                do {
                    _ = try incomingStorage.yield(envelope)
                } catch let error as TransportError {
                    fail(error)
                    return
                }
            }
        } catch {
            fail(TransportError.malformedFrame)
            return
        }
        if isComplete {
            if parser.bufferedByteCount != 0 {
                fail(.malformedFrame)
            } else {
                close()
            }
        } else {
            receiveNext()
        }
    }

    private func pump() async {
        guard lifecycle == .ready, !isSending else { return }
        isSending = true
        guard let envelope = await outgoing.dequeue() else {
            isSending = false
            return
        }
        guard lifecycle == .ready else {
            isSending = false
            return
        }
        do {
            let data = try envelope.encoded(using: limits)
            let context = NWConnection.ContentContext(identifier: "MacRemoteApp.Envelope")
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    Task { await self?.handleSendCompletion(error: error) }
                }
            )
        } catch {
            isSending = false
            fail(TransportError.malformedFrame)
        }
    }

    private func handleSendCompletion(error: NWError?) async {
        isSending = false
        if let error {
            fail(.connectionFailed(String(describing: error)))
            return
        }
        await pump()
    }

    private func fail(_ error: TransportError) {
        guard lifecycle != .closed, lifecycle != .closing else { return }
        startDeadlineTask?.cancel()
        startDeadlineTask = nil
        lifecycle = .failed(error.description)
        resumeStartWaiters(with: .failure(error))
        incomingStorage.finish(throwing: error)
        connection.cancel()
        Task { await outgoing.removeAll() }
    }

    private func resumeStartWaiters(with result: Result<Void, Error>) {
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}
