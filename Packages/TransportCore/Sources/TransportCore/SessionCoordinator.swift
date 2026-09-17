import Foundation
import RemoteProtocol
import SecurityCore

public enum SessionError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidState(SessionState)
    case peerRoleMismatch
    case unsupportedVersion
    case mandatoryCapabilityMissing(Capability)
    case pairingRequired
    case pairingDenied
    case pairingFailed
    case unauthorizedMessage(MessageType)
    case replayDetected
    case authorizationWindowGenerationRequired
    case handshakeTimeout
    case heartbeatTimeout
    case reconnectRequired
    case authorizationChanged
    case videoBoundsExceeded
    case transportFailure(String)

    public var description: String {
        switch self {
        case let .invalidState(state): return "invalid session state \(state)"
        case .peerRoleMismatch: return "peer role mismatch"
        case .unsupportedVersion: return "unsupported protocol version"
        case let .mandatoryCapabilityMissing(capability):
            return "mandatory capability missing: \(capability.rawValue)"
        case .pairingRequired: return "pairing is required"
        case .pairingDenied: return "pairing was denied"
        case .pairingFailed: return "pairing failed"
        case let .unauthorizedMessage(messageType):
            return "message is not authorized: \(messageType.rawValue)"
        case .replayDetected: return "replayed or out-of-order session message"
        case .authorizationWindowGenerationRequired:
            return "authorization requires a selected window generation"
        case .handshakeTimeout: return "session handshake timed out"
        case .heartbeatTimeout: return "heartbeat timed out"
        case .reconnectRequired: return "session must reconnect before authorization"
        case .authorizationChanged: return "session authorization changed while sending"
        case .videoBoundsExceeded: return "video parameters exceed negotiated bounds"
        case let .transportFailure(detail): return "transport failure: \(detail)"
        }
    }
}

public struct SessionConfiguration: Sendable {
    public static let `default` = SessionConfiguration(
        role: .viewer,
        implementationIdentifier: "MacRemoteApp-M2",
        capabilities: [.pingPong]
    )

    public let role: DeviceRole
    public let implementationIdentifier: String
    public let limits: ProtocolLimits
    public let capabilities: Set<Capability>
    public let mandatoryCapabilities: Set<Capability>
    public let maxVideoWidth: UInt32?
    public let maxVideoHeight: UInt32?
    public let maxFrameRate: UInt16?
    public let heartbeatIntervalNanoseconds: UInt64
    public let heartbeatTimeoutNanoseconds: UInt64
    public let handshakeTimeoutNanoseconds: UInt64

    public init(
        role: DeviceRole,
        implementationIdentifier: String,
        limits: ProtocolLimits = .default,
        capabilities: Set<Capability>,
        mandatoryCapabilities: Set<Capability> = [],
        maxVideoWidth: UInt32? = nil,
        maxVideoHeight: UInt32? = nil,
        maxFrameRate: UInt16? = nil,
        heartbeatIntervalNanoseconds: UInt64 = 5_000_000_000,
        heartbeatTimeoutNanoseconds: UInt64 = 15_000_000_000,
        handshakeTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.role = role
        self.implementationIdentifier = implementationIdentifier
        self.limits = limits
        self.capabilities = capabilities
        self.mandatoryCapabilities = mandatoryCapabilities
        self.maxVideoWidth = maxVideoWidth
        self.maxVideoHeight = maxVideoHeight
        self.maxFrameRate = maxFrameRate
        self.heartbeatIntervalNanoseconds = heartbeatIntervalNanoseconds
        self.heartbeatTimeoutNanoseconds = heartbeatTimeoutNanoseconds
        self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
    }
}

public struct SessionSnapshot: Equatable, Sendable {
    public let state: SessionState
    public let peerIdentity: PeerIdentity?
    public let negotiatedCapabilities: Set<Capability>
    public let authorized: Bool
    public let authorizedWindowGeneration: UInt64?
    public let authorizedCapabilities: Set<Capability>
    public let reconnectGeneration: UInt64
    public let lastHeartbeatAt: Date?
    public let negotiatedMaxVideoWidth: UInt32?
    public let negotiatedMaxVideoHeight: UInt32?
    public let negotiatedMaxFrameRate: UInt16?

    public init(
        state: SessionState,
        peerIdentity: PeerIdentity?,
        negotiatedCapabilities: Set<Capability>,
        authorized: Bool,
        authorizedWindowGeneration: UInt64?,
        authorizedCapabilities: Set<Capability>,
        reconnectGeneration: UInt64,
        lastHeartbeatAt: Date?,
        negotiatedMaxVideoWidth: UInt32? = nil,
        negotiatedMaxVideoHeight: UInt32? = nil,
        negotiatedMaxFrameRate: UInt16? = nil
    ) {
        self.state = state
        self.peerIdentity = peerIdentity
        self.negotiatedCapabilities = negotiatedCapabilities
        self.authorized = authorized
        self.authorizedWindowGeneration = authorizedWindowGeneration
        self.authorizedCapabilities = authorizedCapabilities
        self.reconnectGeneration = reconnectGeneration
        self.lastHeartbeatAt = lastHeartbeatAt
        self.negotiatedMaxVideoWidth = negotiatedMaxVideoWidth
        self.negotiatedMaxVideoHeight = negotiatedMaxVideoHeight
        self.negotiatedMaxFrameRate = negotiatedMaxFrameRate
    }
}

public actor SessionCoordinator {
    private static let protectedMessageTypes: Set<MessageType> = [
        .windowList,
        .windowSelection,
        .streamConfig,
        .videoConfig,
        .videoFrame,
        .inputEvent,
        .clipboardOffer,
        .clipboardText
    ]

    private static let windowBoundCapabilities: Set<Capability> = [
        .windowSelection,
        .h264Video,
        .mouseInput,
        .keyboardInput
    ]

    private static let hostOutboundMessageTypes: Set<MessageType> = [
        .hello,
        .capabilities,
        .pairingChallenge,
        .pairingConfirmation,
        .sessionAuthorize,
        .windowList,
        .streamConfig,
        .videoConfig,
        .videoFrame,
        .clipboardOffer,
        .clipboardText,
        .ping,
        .pong,
        .sessionState,
        .error,
        .close
    ]

    private static let viewerOutboundMessageTypes: Set<MessageType> = [
        .hello,
        .capabilities,
        .pairingConfirmation,
        .windowSelection,
        .inputEvent,
        .clipboardOffer,
        .clipboardText,
        .ping,
        .pong,
        .sessionState,
        .error,
        .close
    ]

    private static let hostInboundMessageTypes: Set<MessageType> = [
        .hello,
        .capabilities,
        .pairingConfirmation,
        .windowSelection,
        .inputEvent,
        .clipboardOffer,
        .clipboardText,
        .ping,
        .pong,
        .sessionState,
        .error,
        .close
    ]

    private static let viewerInboundMessageTypes: Set<MessageType> = [
        .hello,
        .capabilities,
        .pairingChallenge,
        .pairingConfirmation,
        .sessionAuthorize,
        .windowList,
        .streamConfig,
        .videoConfig,
        .videoFrame,
        .clipboardOffer,
        .clipboardText,
        .ping,
        .pong,
        .sessionState,
        .error,
        .close
    ]

    private var configuration: SessionConfiguration
    private var transport: any SessionTransport
    private let pairingCoordinator: PairingCoordinator?

    private var state: SessionState = .connecting
    private var peerIdentity: PeerIdentity?
    private var peerHello: HelloMessage?
    private var peerCapabilities: CapabilitiesMessage?
    private var negotiatedCapabilities: Set<Capability> = []
    private var negotiatedMaxVideoWidth: UInt32?
    private var negotiatedMaxVideoHeight: UInt32?
    private var negotiatedMaxFrameRate: UInt16?
    private var authorized = false
    private var authorizedWindowGeneration: UInt64?
    private var authorizedCapabilities: Set<Capability> = []
    private var helloSent = false
    private var capabilitiesSent = false
    private var incomingSequence: [Channel: UInt64] = [:]
    private var outgoingSequence: [Channel: UInt64] = [:]
    private var pendingPing: (nonce: UInt64, sentAt: Date)?
    private var nextPingNonce: UInt64 = 1
    private var lastHeartbeatAt: Date?
    private var reconnectGeneration: UInt64 = 0
    private var authorizationGeneration: UInt64 = 0
    private var receiveGeneration: UInt64 = 0
    private var heartbeatGeneration: UInt64 = 0
    private var handshakeGeneration: UInt64 = 0
    private let outboundMutex = AsyncMutex()
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?

    public nonisolated let incomingMessages: AsyncThrowingStream<MessagePayload, Error>
    private let incomingMessageContinuation: AsyncThrowingStream<MessagePayload, Error>.Continuation

    public init(
        configuration: SessionConfiguration,
        transport: any SessionTransport,
        pairingCoordinator: PairingCoordinator? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.pairingCoordinator = pairingCoordinator
        let stream = AsyncThrowingStream<MessagePayload, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.incomingMessages = stream.stream
        self.incomingMessageContinuation = stream.continuation
    }

    deinit {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        handshakeTask?.cancel()
        incomingMessageContinuation.finish()
    }

    public func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            state: state,
            peerIdentity: peerIdentity,
            negotiatedCapabilities: negotiatedCapabilities,
            authorized: authorized,
            authorizedWindowGeneration: authorizedWindowGeneration,
            authorizedCapabilities: authorizedCapabilities,
            reconnectGeneration: reconnectGeneration,
            lastHeartbeatAt: lastHeartbeatAt,
            negotiatedMaxVideoWidth: negotiatedMaxVideoWidth,
            negotiatedMaxVideoHeight: negotiatedMaxVideoHeight,
            negotiatedMaxFrameRate: negotiatedMaxFrameRate
        )
    }

    public func start() async throws {
        guard state == .connecting || state == .reconnecting else {
            throw SessionError.invalidState(state)
        }

        do {
            try await transport.start()
            let authentication = await transport.authentication()
            switch authentication {
            case .trusted(let identity):
                peerIdentity = identity
                state = .trusted
            case .pairingRequired(let identity):
                guard pairingCoordinator != nil else {
                    throw SessionError.pairingFailed
                }
                peerIdentity = identity
                state = .pairingRequired
                if configuration.role == .host {
                    try await sendPairingChallenge(to: identity)
                }
            case .pending:
                throw SessionError.transportFailure("TLS authentication is still pending")
            case .rejected:
                throw SessionError.transportFailure("TLS peer authentication was rejected")
            }

            try await sendHelloIfNeeded()
            startReceiving()
            startHandshakeDeadline()
        } catch let error as SessionError {
            await fail(error)
            throw error
        } catch {
            let sessionError = SessionError.transportFailure(String(describing: error))
            await fail(sessionError)
            throw sessionError
        }
    }

    public func confirmPairing(
        confirmationCode: String,
        accepted: Bool,
        displayName: String? = nil
    ) async throws {
        guard state == .pairingRequired,
              let peerIdentity,
              let pairingCoordinator else {
            throw SessionError.pairingFailed
        }
        let sessionGeneration = receiveGeneration
        guard let challenge = await pairingCoordinator.pendingChallenge() else {
            throw SessionError.pairingFailed
        }
        guard sessionGeneration == receiveGeneration else {
            throw SessionError.reconnectRequired
        }

        guard accepted else {
            _ = try? await pairingCoordinator.confirmLocalConsent(
                challengeID: challenge.challengeID,
                remoteIdentity: peerIdentity,
                confirmationCode: "",
                accepted: false,
                displayName: displayName
            )
            guard sessionGeneration == receiveGeneration else {
                throw SessionError.reconnectRequired
            }
            let confirmation = PairingConfirmationMessage(
                challengeID: challenge.challengeID,
                accepted: false
            )
            _ = try? await sendUnrestricted(.pairingConfirmation(confirmation))
            state = .failed
            authorized = false
            await pairingCoordinator.abortPendingPairing()
            await fail(.pairingDenied)
            throw SessionError.pairingDenied
        }

        do {
            _ = try await pairingCoordinator.confirmLocalConsent(
                challengeID: challenge.challengeID,
                remoteIdentity: peerIdentity,
                confirmationCode: confirmationCode,
                accepted: true,
                displayName: displayName
            )
        } catch {
            guard sessionGeneration == receiveGeneration else {
                throw SessionError.reconnectRequired
            }
            await fail(.pairingFailed)
            throw SessionError.pairingFailed
        }
        guard sessionGeneration == receiveGeneration else {
            throw SessionError.reconnectRequired
        }
        let confirmation = PairingConfirmationMessage(
            challengeID: challenge.challengeID,
            accepted: true,
            confirmationCode: confirmationCode
        )
        do {
            _ = try await sendUnrestricted(.pairingConfirmation(confirmation))
        } catch {
            guard sessionGeneration == receiveGeneration else {
                throw SessionError.reconnectRequired
            }
            await fail(.transportFailure(String(describing: error)))
            throw error
        }
        try await synchronizePairingState(generation: sessionGeneration)
        try await sendCapabilitiesIfNeeded()
    }

    public func authorize(
        windowGeneration: UInt64? = nil,
        capabilities: Set<Capability>? = nil
    ) async throws {
        guard configuration.role == .host else {
            throw SessionError.invalidState(state)
        }
        guard state == .capabilitiesNegotiated || state == .windowSelectionAuthorized else {
            throw SessionError.invalidState(state)
        }
        let sessionGeneration = reconnectGeneration
        let requested = capabilities ?? negotiatedCapabilities
        guard requested.isSubset(of: negotiatedCapabilities) else {
            let missing = requested.subtracting(negotiatedCapabilities).sorted { $0.rawValue < $1.rawValue }
            throw SessionError.mandatoryCapabilityMissing(missing[0])
        }
        let authorization = SessionAuthorizeMessage(
            authorized: true,
            windowGeneration: windowGeneration,
            capabilities: requested.sorted { $0.rawValue < $1.rawValue }
        )
        try validateAuthorizationScope(
            authorized: true,
            windowGeneration: windowGeneration,
            capabilities: requested,
            mandatoryCapabilities: []
        )
        // Serialize the authorization transition with every outbound
        // admission so an already-waiting send cannot be admitted after the
        // new authorization epoch begins.
        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        let operationAuthorizationGeneration = authorizationGeneration &+ 1
        authorizationGeneration = operationAuthorizationGeneration
        clearAuthorization()
        await transport.invalidateProtectedMessages()
        guard sessionGeneration == reconnectGeneration else {
            throw SessionError.reconnectRequired
        }
        _ = try await sendUnrestrictedAfterAdmission(
            .sessionAuthorize(authorization),
            flags: [],
            operationGeneration: sessionGeneration,
            operationAuthorizationGeneration: operationAuthorizationGeneration
        )
        guard sessionGeneration == reconnectGeneration else {
            throw SessionError.reconnectRequired
        }
        guard operationAuthorizationGeneration == authorizationGeneration else {
            throw SessionError.authorizationChanged
        }
        authorized = true
        authorizedWindowGeneration = windowGeneration
        authorizedCapabilities = requested
        state = .windowSelectionAuthorized
    }

    public func revokeAuthorization() async throws {
        guard configuration.role == .host else {
            throw SessionError.invalidState(state)
        }
        await outboundMutex.acquire()
        authorizationGeneration &+= 1
        authorized = false
        authorizedWindowGeneration = nil
        authorizedCapabilities.removeAll()
        if state == .windowSelectionAuthorized {
            state = .capabilitiesNegotiated
        }
        await transport.invalidateProtectedMessages()
        let message = SessionAuthorizeMessage(authorized: false, capabilities: [])
        do {
            _ = try await sendUnrestrictedAfterAdmission(
                .sessionAuthorize(message),
                flags: [],
                operationGeneration: reconnectGeneration,
                operationAuthorizationGeneration: authorizationGeneration
            )
        } catch {
            outboundMutex.release()
            await fail(.transportFailure(String(describing: error)))
            throw error
        }
        outboundMutex.release()
    }

    public func send(_ payload: MessagePayload, flags: EnvelopeFlags = []) async throws {
        try validateAuthorization(for: payload)
        _ = try await sendUnrestricted(payload, flags: flags)
    }

    public func stop(reason: CloseReason = .normal) async {
        guard state != .stopping else { return }
        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        state = .stopping
        authorizationGeneration &+= 1
        clearAuthorization()
        receiveGeneration &+= 1
        heartbeatGeneration &+= 1
        heartbeatTask?.cancel()
        handshakeTask?.cancel()
        receiveTask?.cancel()
        heartbeatTask = nil
        receiveTask = nil
        handshakeTask = nil
        await transport.invalidateProtectedMessages()
        await pairingCoordinator?.abortPendingPairing()
        let close = CloseMessage(reason: reason)
        _ = try? await sendUnrestrictedAfterAdmission(
            .close(close),
            flags: [],
            operationGeneration: reconnectGeneration,
            operationAuthorizationGeneration: authorizationGeneration
        )
        await transport.close()
    }

    public func reconnect(using newTransport: any SessionTransport) async throws {
        await outboundMutex.acquire()
        receiveGeneration &+= 1
        heartbeatGeneration &+= 1
        reconnectGeneration &+= 1
        authorizationGeneration &+= 1
        clearAuthorization()
        state = .reconnecting
        heartbeatTask?.cancel()
        handshakeTask?.cancel()
        receiveTask?.cancel()
        heartbeatTask = nil
        receiveTask = nil
        handshakeTask = nil
        await pairingCoordinator?.abortPendingPairing()
        await transport.invalidateProtectedMessages()
        await transport.close()
        transport = newTransport
        peerIdentity = nil
        peerHello = nil
        peerCapabilities = nil
        negotiatedCapabilities.removeAll()
        negotiatedMaxVideoWidth = nil
        negotiatedMaxVideoHeight = nil
        negotiatedMaxFrameRate = nil
        helloSent = false
        capabilitiesSent = false
        incomingSequence.removeAll()
        outgoingSequence.removeAll()
        pendingPing = nil
        lastHeartbeatAt = nil
        outboundMutex.release()
        try await start()
    }

    private func sendPairingChallenge(to identity: PeerIdentity) async throws {
        guard let pairingCoordinator else { return }
        let challengeID = UInt64.random(in: 1 ... UInt64.max)
        let challenge = try await pairingCoordinator.beginSessionPairing(
            with: identity,
            challengeID: challengeID
        )
        let message = PairingChallengeMessage(
            challengeID: challenge.challengeID,
            confirmationCode: challenge.confirmationCode
        )
        _ = try await sendUnrestricted(.pairingChallenge(message))
    }

    private func sendHelloIfNeeded() async throws {
        guard !helloSent else { return }
        let hello = HelloMessage(
            protocolVersion: .current,
            role: configuration.role,
            implementationIdentifier: configuration.implementationIdentifier,
            limits: configuration.limits
        )
        _ = try await sendUnrestricted(.hello(hello))
        helloSent = true
    }

    private func sendCapabilitiesIfNeeded() async throws {
        guard !capabilitiesSent else { return }
        guard state == .trusted || state == .capabilitiesNegotiated || state == .windowSelectionAuthorized else {
            return
        }
        let capabilities = CapabilitiesMessage(
            capabilities: configuration.capabilities.sorted { $0.rawValue < $1.rawValue },
            maxVideoWidth: configuration.maxVideoWidth,
            maxVideoHeight: configuration.maxVideoHeight,
            maxFrameRate: configuration.maxFrameRate,
            mandatoryCapabilities: configuration.mandatoryCapabilities
        )
        _ = try await sendUnrestricted(.capabilities(capabilities))
        capabilitiesSent = true
    }

    private func sendUnrestricted(
        _ payload: MessagePayload,
        flags: EnvelopeFlags = []
    ) async throws -> TransportSendResult {
        try validateMessageDirection(for: payload.messageType, incoming: false)
        let operationGeneration = reconnectGeneration
        let operationAuthorizationGeneration = authorizationGeneration
        await outboundMutex.acquire()
        defer { outboundMutex.release() }

        guard operationGeneration == reconnectGeneration else {
            throw SessionError.reconnectRequired
        }
        if Self.protectedMessageTypes.contains(payload.messageType) {
            guard operationAuthorizationGeneration == authorizationGeneration else {
                throw SessionError.authorizationChanged
            }
            try validateAuthorization(for: payload)
        }

        return try await sendUnrestrictedAfterAdmission(
            payload,
            flags: flags,
            operationGeneration: operationGeneration,
            operationAuthorizationGeneration: operationAuthorizationGeneration
        )
    }

    private func sendUnrestrictedAfterAdmission(
        _ payload: MessagePayload,
        flags: EnvelopeFlags,
        operationGeneration: UInt64,
        operationAuthorizationGeneration: UInt64
    ) async throws -> TransportSendResult {
        let channel = payload.messageType.defaultChannel
        let sequence = outgoingSequence[channel] ?? 0
        guard sequence < UInt64.max else {
            throw SessionError.transportFailure("sequence overflow")
        }
        let limits = effectiveProtocolLimits()
        let envelope = try Envelope(
            message: payload,
            channel: channel,
            flags: flags,
            sequence: sequence,
            timestamp: DispatchTime.now().uptimeNanoseconds,
            limits: limits
        )
        let targetTransport = transport
        let isProtected = Self.protectedMessageTypes.contains(payload.messageType)
        do {
            let result = try await targetTransport.send(envelope)
            // Keep sequence numbers monotonic for an unchanged transport even
            // when an authorization transition invalidates a queued media
            // frame. Reconnect resets the sequence space for the new transport.
            if operationGeneration == reconnectGeneration {
                outgoingSequence[channel] = sequence + 1
            }
            guard operationGeneration == reconnectGeneration else {
                throw SessionError.reconnectRequired
            }
            if isProtected, operationAuthorizationGeneration != authorizationGeneration {
                throw SessionError.authorizationChanged
            }
            return result
        } catch let error as SessionError {
            throw error
        } catch {
            throw SessionError.transportFailure(String(describing: error))
        }
    }

    private func startReceiving() {
        receiveTask?.cancel()
        receiveGeneration &+= 1
        let generation = receiveGeneration
        let stream = transport.incoming
        receiveTask = Task { [weak self] in
            do {
                for try await envelope in stream {
                    await self?.handle(envelope, generation: generation)
                }
                await self?.handleTransportEOF(generation: generation)
            } catch {
                await self?.handleTransportFailure(String(describing: error), generation: generation)
            }
        }
    }

    private func handle(_ envelope: Envelope, generation: UInt64) async {
        guard generation == receiveGeneration else { return }
        guard state != .stopping, state != .failed else { return }
        do {
            try validateIncomingSequence(envelope)
            if case .unknown = envelope.messageType,
               !envelope.flags.contains(.mustUnderstand) {
                return
            }
            let message = try envelope.decodedMessage(using: effectiveProtocolLimits())
            try await handle(message, generation: generation)
        } catch let error as SessionError {
            guard generation == receiveGeneration else { return }
            await fail(error)
        } catch {
            guard generation == receiveGeneration else { return }
            await fail(.transportFailure(String(describing: error)))
        }
    }

    private func handle(_ message: MessagePayload, generation: UInt64) async throws {
        guard generation == receiveGeneration else { return }
        try validateMessageDirection(for: message.messageType, incoming: true)
        try validateAuthorization(for: message)
        switch message {
        case let .hello(hello):
            try await handleHello(hello, generation: generation)
        case let .capabilities(capabilities):
            try await handleCapabilities(capabilities, generation: generation)
        case let .pairingChallenge(challenge):
            guard state == .pairingRequired,
                  configuration.role == .viewer,
                  let peerIdentity,
                  let pairingCoordinator else {
                throw SessionError.pairingFailed
            }
            guard await pairingCoordinator.pendingChallenge() == nil else {
                throw SessionError.invalidState(state)
            }
            guard generation == receiveGeneration else { return }
            _ = try await pairingCoordinator.adoptRemoteSessionChallenge(
                challengeID: challenge.challengeID,
                from: peerIdentity,
                confirmationCode: challenge.confirmationCode
            )
            guard generation == receiveGeneration else { return }
        case let .pairingConfirmation(confirmation):
            try await handlePairingConfirmation(confirmation, generation: generation)
        case let .sessionAuthorize(authorizationMessage):
            try await handleAuthorization(authorizationMessage)
        case let .ping(ping):
            _ = try await sendUnrestricted(.pong(PongMessage(nonce: ping.nonce)))
        case let .pong(pong):
            guard pendingPing?.nonce == pong.nonce else { throw SessionError.replayDetected }
            pendingPing = nil
            lastHeartbeatAt = Date()
        case let .sessionState(sessionState):
            if sessionState.state == .stopping || sessionState.state == .failed {
                authorizationGeneration &+= 1
                clearAuthorization()
                await outboundMutex.acquire()
                await transport.invalidateProtectedMessages()
                outboundMutex.release()
            }
            publish(message)
        case .error:
            publish(message)
            await fail(.transportFailure("peer reported a session error"))
        case .close:
            publish(message)
            authorizationGeneration &+= 1
            clearAuthorization()
            state = .stopping
            heartbeatTask?.cancel()
            handshakeTask?.cancel()
            receiveTask?.cancel()
            heartbeatTask = nil
            handshakeTask = nil
            receiveTask = nil
            await pairingCoordinator?.abortPendingPairing()
            guard generation == receiveGeneration else { return }
            await outboundMutex.acquire()
            await transport.invalidateProtectedMessages()
            await transport.close()
            outboundMutex.release()
        default:
            publish(message)
        }
    }

    private func handleHello(_ hello: HelloMessage, generation: UInt64) async throws {
        guard hello.role != configuration.role else {
            throw SessionError.peerRoleMismatch
        }
        guard hello.protocolVersion.isCompatible(with: .current) else {
            throw SessionError.unsupportedVersion
        }
        guard peerHello == nil else {
            throw SessionError.invalidState(state)
        }
        peerHello = hello
        if state == .authenticated {
            state = .trusted
        }
        try await sendCapabilitiesIfNeeded()
        guard generation == receiveGeneration else { return }
    }

    private func handleCapabilities(_ capabilities: CapabilitiesMessage, generation: UInt64) async throws {
        guard peerHello != nil,
              peerCapabilities == nil,
              state == .trusted else {
            throw SessionError.invalidState(state)
        }
        peerCapabilities = capabilities
        let remoteCapabilities = Set(capabilities.capabilities)
        let allMandatory = configuration.mandatoryCapabilities.union(capabilities.mandatoryCapabilities)
        for capability in allMandatory where !configuration.capabilities.contains(capability) || !remoteCapabilities.contains(capability) {
            throw SessionError.mandatoryCapabilityMissing(capability)
        }
        negotiatedCapabilities = configuration.capabilities.intersection(remoteCapabilities)
        negotiatedMaxVideoWidth = negotiatedLimit(configuration.maxVideoWidth, capabilities.maxVideoWidth)
        negotiatedMaxVideoHeight = negotiatedLimit(configuration.maxVideoHeight, capabilities.maxVideoHeight)
        negotiatedMaxFrameRate = negotiatedLimit(configuration.maxFrameRate, capabilities.maxFrameRate)
        state = .capabilitiesNegotiated
        try await sendCapabilitiesIfNeeded()
        guard generation == receiveGeneration else { return }
        startHeartbeatIfReady()
    }

    private func handlePairingConfirmation(
        _ confirmation: PairingConfirmationMessage,
        generation: UInt64
    ) async throws {
        guard state == .pairingRequired,
              let peerIdentity,
              let pairingCoordinator else {
            throw SessionError.pairingFailed
        }
        guard confirmation.accepted else {
            _ = try? await pairingCoordinator.recordRemoteConsent(
                challengeID: confirmation.challengeID,
                remoteIdentity: peerIdentity,
                confirmationCode: confirmation.confirmationCode ?? "",
                accepted: false
            )
            throw SessionError.pairingDenied
        }
        do {
            _ = try await pairingCoordinator.recordRemoteConsent(
                challengeID: confirmation.challengeID,
                remoteIdentity: peerIdentity,
                confirmationCode: confirmation.confirmationCode ?? "",
                accepted: confirmation.accepted
            )
        } catch {
            throw SessionError.pairingFailed
        }
        guard generation == receiveGeneration else { return }
        try await synchronizePairingState(generation: generation)
        try await sendCapabilitiesIfNeeded()
    }

    private func handleAuthorization(_ authorization: SessionAuthorizeMessage) async throws {
        guard configuration.role == .viewer else {
            throw SessionError.invalidState(state)
        }
        guard state == .capabilitiesNegotiated || state == .windowSelectionAuthorized else {
            throw SessionError.invalidState(state)
        }
        let requested = Set(authorization.capabilities)
        guard requested.isSubset(of: negotiatedCapabilities),
              authorization.mandatoryCapabilities.isSubset(of: requested) else {
            throw SessionError.mandatoryCapabilityMissing(
                authorization.mandatoryCapabilities.subtracting(requested).first ?? .pingPong
            )
        }
        try validateAuthorizationScope(
            authorized: authorization.authorized,
            windowGeneration: authorization.windowGeneration,
            capabilities: requested,
            mandatoryCapabilities: authorization.mandatoryCapabilities
        )
        authorized = authorization.authorized
        authorizedWindowGeneration = authorization.authorized ? authorization.windowGeneration : nil
        authorizedCapabilities = authorization.authorized ? requested : []
        state = authorization.authorized ? .windowSelectionAuthorized : .capabilitiesNegotiated
    }

    private func synchronizePairingState(generation: UInt64) async throws {
        guard generation == receiveGeneration else {
            throw SessionError.reconnectRequired
        }
        guard let pairingCoordinator else {
            throw SessionError.pairingFailed
        }
        switch await pairingCoordinator.state() {
        case .paired:
            guard generation == receiveGeneration else {
                throw SessionError.reconnectRequired
            }
            state = .trusted
        case .awaitingConfirmation:
            state = .pairingRequired
        case .idle, .revoked:
            throw SessionError.pairingFailed
        }
    }

    private func validateIncomingSequence(_ envelope: Envelope) throws {
        guard let previous = incomingSequence[envelope.channel] else {
            incomingSequence[envelope.channel] = envelope.sequence
            return
        }
        guard previous < UInt64.max else {
            throw SessionError.replayDetected
        }
        if envelope.channel == .media {
            guard envelope.sequence > previous else {
                throw SessionError.replayDetected
            }
            incomingSequence[envelope.channel] = envelope.sequence
            return
        }
        guard envelope.sequence == previous + 1 else {
            throw SessionError.replayDetected
        }
        incomingSequence[envelope.channel] = envelope.sequence
    }

    private func clearAuthorization() {
        authorized = false
        authorizedWindowGeneration = nil
        authorizedCapabilities.removeAll()
        if state == .windowSelectionAuthorized {
            state = .capabilitiesNegotiated
        }
    }

    private func requiredCapabilities(for payload: MessagePayload) -> Set<Capability> {
        switch payload {
        case .windowList, .windowSelection:
            return [.windowSelection]
        case .streamConfig, .videoConfig, .videoFrame:
            return [.h264Video]
        case let .inputEvent(input):
            switch input.kind {
            case .keyDown, .keyUp:
                return [.keyboardInput]
            case .pointerMove, .pointerButton, .scroll, .focusIntent:
                return [.mouseInput]
            }
        case .clipboardOffer, .clipboardText:
            return [.textClipboard]
        default:
            return []
        }
    }

    private func requiredWindowGeneration(for payload: MessagePayload) -> UInt64? {
        switch payload {
        case let .windowSelection(selection):
            return selection.windowGeneration
        case let .streamConfig(config):
            return config.generation
        case let .videoConfig(config):
            return config.generation
        case let .videoFrame(frame):
            return frame.generation
        case let .inputEvent(input):
            return input.windowGeneration
        default:
            return nil
        }
    }

    private func validateAuthorization(for payload: MessagePayload) throws {
        guard Self.protectedMessageTypes.contains(payload.messageType) else { return }
        guard authorized else {
            throw SessionError.unauthorizedMessage(payload.messageType)
        }
        let required = requiredCapabilities(for: payload)
        guard required.isSubset(of: authorizedCapabilities) else {
            throw SessionError.unauthorizedMessage(payload.messageType)
        }
        if let requiredGeneration = requiredWindowGeneration(for: payload) {
            guard authorizedWindowGeneration == requiredGeneration else {
                throw SessionError.unauthorizedMessage(payload.messageType)
            }
        }
        try validateVideoBounds(for: payload)
    }

    private func validateVideoBounds(for payload: MessagePayload) throws {
        switch payload {
        case let .streamConfig(config):
            try validateVideoDimensions(width: config.width, height: config.height)
            try validateVideoFrameRate(config.frameRate)
        case let .videoFrame(frame):
            try validateVideoDimensions(width: frame.width, height: frame.height)
        default:
            break
        }
    }

    private func validateVideoDimensions(width: UInt32, height: UInt32) throws {
        if let negotiatedMaxVideoWidth, width > negotiatedMaxVideoWidth {
            throw SessionError.videoBoundsExceeded
        }
        if let negotiatedMaxVideoHeight, height > negotiatedMaxVideoHeight {
            throw SessionError.videoBoundsExceeded
        }
    }

    private func validateVideoFrameRate(_ frameRate: UInt16) throws {
        if let negotiatedMaxFrameRate, frameRate > negotiatedMaxFrameRate {
            throw SessionError.videoBoundsExceeded
        }
    }

    private func validateMessageDirection(for messageType: MessageType, incoming: Bool) throws {
        let allowed: Set<MessageType>
        switch (configuration.role, incoming) {
        case (.host, false):
            allowed = Self.hostOutboundMessageTypes
        case (.viewer, false):
            allowed = Self.viewerOutboundMessageTypes
        case (.host, true):
            allowed = Self.hostInboundMessageTypes
        case (.viewer, true):
            allowed = Self.viewerInboundMessageTypes
        }
        guard allowed.contains(messageType) else {
            throw SessionError.unauthorizedMessage(messageType)
        }
    }

    private func effectiveProtocolLimits() -> ProtocolLimits {
        guard let peerLimits = peerHello?.limits else {
            return configuration.limits
        }
        return ProtocolLimits(
            maxPayloadLength: min(configuration.limits.maxPayloadLength, peerLimits.maxPayloadLength),
            maxControlPayloadLength: min(configuration.limits.maxControlPayloadLength, peerLimits.maxControlPayloadLength),
            maxClipboardTextBytes: min(configuration.limits.maxClipboardTextBytes, peerLimits.maxClipboardTextBytes),
            maxFieldLength: min(configuration.limits.maxFieldLength, peerLimits.maxFieldLength),
            maxIdentifierBytes: min(configuration.limits.maxIdentifierBytes, peerLimits.maxIdentifierBytes),
            maxWindowEntries: min(configuration.limits.maxWindowEntries, peerLimits.maxWindowEntries),
            maxCapabilities: min(configuration.limits.maxCapabilities, peerLimits.maxCapabilities)
        )
    }

    private func publish(_ message: MessagePayload) {
        _ = incomingMessageContinuation.yield(message)
    }

    private func negotiatedLimit<T: Comparable>(_ local: T?, _ remote: T?) -> T? {
        switch (local, remote) {
        case let (local?, remote?): return min(local, remote)
        case let (local?, nil): return local
        case let (nil, remote?): return remote
        case (nil, nil): return nil
        }
    }

    private func validateAuthorizationScope(
        authorized: Bool,
        windowGeneration: UInt64?,
        capabilities: Set<Capability>,
        mandatoryCapabilities: Set<Capability>
    ) throws {
        guard mandatoryCapabilities.isSubset(of: capabilities) else {
            throw SessionError.mandatoryCapabilityMissing(
                mandatoryCapabilities.subtracting(capabilities).first ?? .pingPong
            )
        }
        if !authorized {
            guard capabilities.isEmpty, windowGeneration == nil else {
                throw SessionError.unauthorizedMessage(.sessionAuthorize)
            }
            return
        }
        guard Self.windowBoundCapabilities.isDisjoint(with: capabilities) || windowGeneration != nil else {
            throw SessionError.authorizationWindowGenerationRequired
        }
    }

    private func startHeartbeatIfReady() {
        guard negotiatedCapabilities.contains(.pingPong), heartbeatTask == nil else { return }
        heartbeatGeneration &+= 1
        let generation = heartbeatGeneration
        let interval = configuration.heartbeatIntervalNanoseconds
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                await self?.heartbeatTick(generation: generation)
            }
        }
    }

    private func startHandshakeDeadline() {
        handshakeTask?.cancel()
        handshakeGeneration &+= 1
        let generation = handshakeGeneration
        let timeout = configuration.handshakeTimeoutNanoseconds
        handshakeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            await self?.handshakeDeadlineReached(generation: generation)
        }
    }

    private func handshakeDeadlineReached(generation: UInt64) async {
        guard generation == handshakeGeneration else { return }
        guard state != .capabilitiesNegotiated,
              state != .windowSelectionAuthorized,
              state != .stopping,
              state != .failed else {
            return
        }
        await fail(.handshakeTimeout)
    }

    private func heartbeatTick(generation: UInt64) async {
        guard generation == heartbeatGeneration else { return }
        guard state != .stopping, state != .failed else { return }
        let now = Date()
        if let pendingPing,
           now.timeIntervalSince(pendingPing.sentAt) * 1_000_000_000 >= Double(configuration.heartbeatTimeoutNanoseconds) {
            await fail(.heartbeatTimeout)
            return
        }
        guard pendingPing == nil else { return }
        let nonce = nextPingNonce
        nextPingNonce = nextPingNonce == UInt64.max ? 1 : nextPingNonce + 1
        pendingPing = (nonce: nonce, sentAt: now)
        do {
            _ = try await sendUnrestricted(.ping(PingMessage(nonce: nonce)))
        } catch {
            await fail(.transportFailure(String(describing: error)))
        }
    }

    private func handleTransportFailure(_ detail: String, generation: UInt64) async {
        guard generation == receiveGeneration else { return }
        guard state != .stopping, state != .failed else { return }
        await fail(.transportFailure(detail))
    }

    private func handleTransportEOF(generation: UInt64) async {
        guard generation == receiveGeneration else { return }
        guard state != .stopping, state != .failed else { return }
        await fail(.transportFailure("transport reached EOF"))
    }

    private func fail(_ error: SessionError) async {
        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        authorizationGeneration &+= 1
        clearAuthorization()
        state = .failed
        receiveGeneration &+= 1
        heartbeatGeneration &+= 1
        handshakeGeneration &+= 1
        heartbeatTask?.cancel()
        handshakeTask?.cancel()
        receiveTask?.cancel()
        heartbeatTask = nil
        handshakeTask = nil
        receiveTask = nil
        await pairingCoordinator?.abortPendingPairing()
        await transport.invalidateProtectedMessages()
        await transport.close()
        _ = error
    }

}
