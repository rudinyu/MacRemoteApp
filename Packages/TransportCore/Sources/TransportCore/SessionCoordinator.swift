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
    case incomingMessageBackpressure(Channel)
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
        case let .incomingMessageBackpressure(channel):
            let channelName = channel == .control ? "control" : "media"
            return "incoming \(channelName) message delivery is backpressured"
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
    public let pairingTimeoutNanoseconds: UInt64

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
        handshakeTimeoutNanoseconds: UInt64 = 30_000_000_000,
        pairingTimeoutNanoseconds: UInt64 = 300_000_000_000
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
        self.pairingTimeoutNanoseconds = pairingTimeoutNanoseconds
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
    public let authorizationGeneration: UInt64
    public let effectiveProtocolLimits: ProtocolLimits
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
        negotiatedMaxFrameRate: UInt16? = nil,
        authorizationGeneration: UInt64 = 0,
        effectiveProtocolLimits: ProtocolLimits = .default
    ) {
        self.state = state
        self.peerIdentity = peerIdentity
        self.negotiatedCapabilities = negotiatedCapabilities
        self.authorized = authorized
        self.authorizedWindowGeneration = authorizedWindowGeneration
        self.authorizedCapabilities = authorizedCapabilities
        self.reconnectGeneration = reconnectGeneration
        self.authorizationGeneration = authorizationGeneration
        self.effectiveProtocolLimits = effectiveProtocolLimits
        self.lastHeartbeatAt = lastHeartbeatAt
        self.negotiatedMaxVideoWidth = negotiatedMaxVideoWidth
        self.negotiatedMaxVideoHeight = negotiatedMaxVideoHeight
        self.negotiatedMaxFrameRate = negotiatedMaxFrameRate
    }
}

/// An admission issued for one authenticated input epoch.
///
/// The token is intentionally opaque to callers.  A Viewer may prepare an
/// input message while the actor is reentrant, but the token must still match
/// the receive, transport, authorization, window, and capability generations
/// when the message is admitted to the wire.
public struct SessionInputAdmissionToken: Equatable, Sendable {
    fileprivate let receiveGeneration: UInt64
    fileprivate let reconnectGeneration: UInt64
    fileprivate let authorizationGeneration: UInt64
    fileprivate let windowGeneration: UInt64
    fileprivate let capability: Capability
}

public actor SessionCoordinator {
    private static let incomingControlMessageCapacity = 64
    private static let incomingMediaMessageCapacity = 3

    private static let protectedMessageTypes: Set<MessageType> = [
        .windowList,
        .windowSelection,
        .streamConfig,
        .videoConfig,
        .videoFrame,
        .inputEvent,
        .clipboardOffer,
        .clipboardText,
        .clipboardAcknowledgement
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
        .clipboardAcknowledgement,
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
        .clipboardAcknowledgement,
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
        .clipboardAcknowledgement,
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
        .clipboardAcknowledgement,
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
    private var capabilitiesSendInFlight = false
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
    private var pairingDeadlineTask: Task<Void, Never>?
    private var pairingDeadlineGeneration: UInt64 = 0
    private var lastFailure: SessionError?

    public nonisolated let incomingMessages: MessageStream
    private let incomingMessageStorage: MessageStreamStorage

    public init(
        configuration: SessionConfiguration,
        transport: any SessionTransport,
        pairingCoordinator: PairingCoordinator? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.pairingCoordinator = pairingCoordinator
        let stream = try! MessageStream.makeBounded(
            maxControlMessages: Self.incomingControlMessageCapacity,
            maxMediaMessages: Self.incomingMediaMessageCapacity
        )
        self.incomingMessages = stream.stream
        self.incomingMessageStorage = stream.storage
    }

    deinit {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        handshakeTask?.cancel()
        pairingDeadlineTask?.cancel()
        incomingMessageStorage.finish()
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
            negotiatedMaxFrameRate: negotiatedMaxFrameRate,
            authorizationGeneration: authorizationGeneration,
            effectiveProtocolLimits: effectiveProtocolLimits()
        )
    }

    /// Returns the terminal failure that caused this session to enter the
    /// failed state. Runtime composition layers use this to distinguish an
    /// explicit pairing denial from a transient transport failure.
    public func failureReason() -> SessionError? {
        lastFailure
    }

    /// Drops input records that were buffered before a local Host safety
    /// transition. This does not affect unrelated control messages or the
    /// session's wire sequence state.
    public func discardPendingInputMessages() {
        incomingMessageStorage.removePendingInputMessages()
    }

    public func start() async throws {
        guard state == .connecting || state == .reconnecting else {
            throw SessionError.invalidState(state)
        }

        let startReconnectGeneration = reconnectGeneration
        let startReceiveGeneration = receiveGeneration
        let startAuthorizationGeneration = authorizationGeneration
        lastFailure = nil

        do {
            try await transport.start()
            guard isCurrent(
                receiveGeneration: startReceiveGeneration,
                reconnectGeneration: startReconnectGeneration,
                authorizationGeneration: startAuthorizationGeneration
            ) else {
                throw SessionError.reconnectRequired
            }
            let authentication = await transport.authentication()
            guard isCurrent(
                receiveGeneration: startReceiveGeneration,
                reconnectGeneration: startReconnectGeneration,
                authorizationGeneration: startAuthorizationGeneration
            ) else {
                throw SessionError.reconnectRequired
            }
            switch authentication {
            case .trusted(let identity):
                peerIdentity = identity
                state = .trusted
            case .pairingRequired(let identity):
                guard let pairingCoordinator else {
                    throw SessionError.pairingFailed
                }
                peerIdentity = identity
                switch try await pairingCoordinator.trustDecision(for: identity) {
                case .trusted:
                    // TLS bootstrap deliberately authenticates the presented
                    // certificate without making it trusted. Keep the
                    // challenge in the wire flow even when this side already
                    // trusts the peer: the other endpoint may have lost its
                    // record and still needs a chance to show consent UI.
                    // Local trust auto-consents below, so two matching records
                    // complete silently after both sides exchange the proof.
                    state = .pairingRequired
                    if configuration.role == .host {
                        let challenge = try await sendPairingChallenge(
                            to: identity,
                            receiveGeneration: startReceiveGeneration,
                            reconnectGeneration: startReconnectGeneration,
                            authorizationGeneration: startAuthorizationGeneration
                        )
                        try await confirmPairing(
                            confirmationCode: challenge.confirmationCode,
                            accepted: true,
                            displayName: configuration.role == .host
                                ? "MacRemoteApp Viewer"
                                : "MacRemoteApp Host"
                        )
                    }
                case .pairingRequired:
                    state = .pairingRequired
                    if configuration.role == .host {
                        _ = try await sendPairingChallenge(
                            to: identity,
                            receiveGeneration: startReceiveGeneration,
                            reconnectGeneration: startReconnectGeneration,
                            authorizationGeneration: startAuthorizationGeneration
                        )
                    }
                case .identityMismatch:
                    throw SessionError.pairingFailed
                }
            case .pending:
                throw SessionError.transportFailure("TLS authentication is still pending")
            case .rejected:
                throw SessionError.transportFailure("TLS peer authentication was rejected")
            }

            try await sendHelloIfNeeded(
                receiveGeneration: startReceiveGeneration,
                reconnectGeneration: startReconnectGeneration,
                authorizationGeneration: startAuthorizationGeneration
            )
            guard isCurrent(
                receiveGeneration: startReceiveGeneration,
                reconnectGeneration: startReconnectGeneration,
                authorizationGeneration: startAuthorizationGeneration
            ) else {
                throw SessionError.reconnectRequired
            }
            startReceiving()
            startHandshakeDeadline()
        } catch let error as SessionError {
            await fail(
                error,
                expectedReceiveGeneration: startReceiveGeneration,
                expectedReconnectGeneration: startReconnectGeneration,
                expectedAuthorizationGeneration: startAuthorizationGeneration
            )
            throw error
        } catch {
            let sessionError = SessionError.transportFailure(String(describing: error))
            await fail(
                sessionError,
                expectedReceiveGeneration: startReceiveGeneration,
                expectedReconnectGeneration: startReconnectGeneration,
                expectedAuthorizationGeneration: startAuthorizationGeneration
            )
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
        let sessionReconnectGeneration = reconnectGeneration
        let sessionAuthorizationGeneration = authorizationGeneration
        guard let challenge = await pairingCoordinator.pendingChallenge() else {
            throw SessionError.pairingFailed
        }
        guard isCurrent(
            receiveGeneration: sessionGeneration,
            reconnectGeneration: sessionReconnectGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else {
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
            guard isCurrent(
                receiveGeneration: sessionGeneration,
                reconnectGeneration: sessionReconnectGeneration,
                authorizationGeneration: sessionAuthorizationGeneration
            ) else {
                throw SessionError.reconnectRequired
            }
            let confirmation = PairingConfirmationMessage(
                challengeID: challenge.challengeID,
                accepted: false
            )
            _ = try? await sendUnrestricted(
                .pairingConfirmation(confirmation),
                expectedReceiveGeneration: sessionGeneration,
                expectedReconnectGeneration: sessionReconnectGeneration,
                expectedAuthorizationGeneration: sessionAuthorizationGeneration
            )
            guard isCurrent(
                receiveGeneration: sessionGeneration,
                reconnectGeneration: sessionReconnectGeneration,
                authorizationGeneration: sessionAuthorizationGeneration
            ) else {
                throw SessionError.reconnectRequired
            }
            await fail(
                .pairingDenied,
                expectedReceiveGeneration: sessionGeneration,
                expectedReconnectGeneration: sessionReconnectGeneration,
                expectedAuthorizationGeneration: sessionAuthorizationGeneration
            )
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
            guard isCurrent(
                receiveGeneration: sessionGeneration,
                reconnectGeneration: sessionReconnectGeneration,
                authorizationGeneration: sessionAuthorizationGeneration
            ) else {
                throw SessionError.reconnectRequired
            }
            await fail(
                .pairingFailed,
                expectedReceiveGeneration: sessionGeneration,
                expectedReconnectGeneration: sessionReconnectGeneration,
                expectedAuthorizationGeneration: sessionAuthorizationGeneration
            )
            throw SessionError.pairingFailed
        }
        guard isCurrent(
            receiveGeneration: sessionGeneration,
            reconnectGeneration: sessionReconnectGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        let confirmation = PairingConfirmationMessage(
            challengeID: challenge.challengeID,
            accepted: true,
            confirmationCode: confirmationCode
        )
        do {
            _ = try await sendUnrestricted(
                .pairingConfirmation(confirmation),
                expectedReceiveGeneration: sessionGeneration,
                expectedReconnectGeneration: sessionReconnectGeneration,
                expectedAuthorizationGeneration: sessionAuthorizationGeneration
            )
        } catch {
            guard isCurrent(
                receiveGeneration: sessionGeneration,
                reconnectGeneration: sessionReconnectGeneration,
                authorizationGeneration: sessionAuthorizationGeneration
            ) else {
                throw SessionError.reconnectRequired
            }
            await fail(
                .transportFailure(String(describing: error)),
                expectedReceiveGeneration: sessionGeneration,
                expectedReconnectGeneration: sessionReconnectGeneration,
                expectedAuthorizationGeneration: sessionAuthorizationGeneration
            )
            throw error
        }
        try await synchronizePairingState(
            generation: sessionGeneration,
            reconnectGeneration: sessionReconnectGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        )
        try await sendCapabilitiesIfNeeded(
            receiveGeneration: sessionGeneration,
            reconnectGeneration: sessionReconnectGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        )
        guard isCurrent(
            receiveGeneration: sessionGeneration,
            reconnectGeneration: sessionReconnectGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
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
        let sessionReceiveGeneration = receiveGeneration
        let sessionAuthorizationGeneration = authorizationGeneration
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
        guard isCurrent(
            receiveGeneration: sessionReceiveGeneration,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        let operationAuthorizationGeneration = sessionAuthorizationGeneration &+ 1
        authorizationGeneration = operationAuthorizationGeneration
        clearAuthorization()
        await transport.invalidateProtectedMessages()
        guard isCurrent(
            receiveGeneration: sessionReceiveGeneration,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: operationAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        _ = try await sendUnrestrictedAfterAdmission(
            .sessionAuthorize(authorization),
            flags: [],
            operationGeneration: sessionGeneration,
            operationReceiveGeneration: sessionReceiveGeneration,
            operationAuthorizationGeneration: operationAuthorizationGeneration
        )
        guard isCurrent(
            receiveGeneration: sessionReceiveGeneration,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: operationAuthorizationGeneration
        ) else {
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
        let sessionGeneration = reconnectGeneration
        let sessionReceiveGeneration = receiveGeneration
        let sessionAuthorizationGeneration = authorizationGeneration
        await outboundMutex.acquire()
        guard isCurrent(
            receiveGeneration: sessionReceiveGeneration,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else {
            outboundMutex.release()
            throw SessionError.reconnectRequired
        }
        authorizationGeneration &+= 1
        let operationAuthorizationGeneration = authorizationGeneration
        clearAuthorization()
        await transport.invalidateProtectedMessages()
        guard isCurrent(
            receiveGeneration: sessionReceiveGeneration,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: operationAuthorizationGeneration
        ) else {
            outboundMutex.release()
            throw SessionError.reconnectRequired
        }
        let message = SessionAuthorizeMessage(authorized: false, capabilities: [])
        do {
            _ = try await sendUnrestrictedAfterAdmission(
                .sessionAuthorize(message),
                flags: [],
                operationGeneration: sessionGeneration,
                operationReceiveGeneration: sessionReceiveGeneration,
                operationAuthorizationGeneration: operationAuthorizationGeneration
            )
        } catch {
            outboundMutex.release()
            await fail(
                .transportFailure(String(describing: error)),
                expectedReceiveGeneration: sessionReceiveGeneration,
                expectedReconnectGeneration: sessionGeneration,
                expectedAuthorizationGeneration: operationAuthorizationGeneration
            )
            throw error
        }
        outboundMutex.release()
    }

    public func send(
        _ payload: MessagePayload,
        flags: EnvelopeFlags = [],
        expectedAuthorizationGeneration: UInt64? = nil,
        localAdmission: (@MainActor @Sendable () -> Bool)? = nil
    ) async throws {
        try validateMessageDirection(for: payload.messageType, incoming: false)
        try validateAuthorization(for: payload)
        guard let localAdmission else {
            _ = try await sendUnrestricted(
                payload,
                flags: flags,
                expectedAuthorizationGeneration: expectedAuthorizationGeneration
            )
            return
        }

        let operationReceiveGeneration = receiveGeneration
        let operationReconnectGeneration = reconnectGeneration
        let operationAuthorizationGeneration = expectedAuthorizationGeneration ?? authorizationGeneration
        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        guard isCurrent(
            receiveGeneration: operationReceiveGeneration,
            reconnectGeneration: operationReconnectGeneration,
            authorizationGeneration: operationAuthorizationGeneration
        ) else {
            if operationReceiveGeneration != receiveGeneration ||
                operationReconnectGeneration != reconnectGeneration {
                throw SessionError.reconnectRequired
            }
            throw SessionError.authorizationChanged
        }
        guard await localAdmission() else {
            throw SessionError.authorizationChanged
        }
        try validateAuthorization(for: payload)
        _ = try await sendUnrestrictedAfterAdmission(
            payload,
            flags: flags,
            operationGeneration: operationReconnectGeneration,
            operationReceiveGeneration: operationReceiveGeneration,
            operationAuthorizationGeneration: operationAuthorizationGeneration
        )
    }

    /// Runs the native pasteboard commit while the outbound authorization
    /// mutex is held. Authorization, revoke, reconnect, and stop transitions
    /// use the same mutex, so a MainActor pasteboard write cannot be preceded
    /// by one authorization snapshot and followed by a different epoch.
    public func withIncomingClipboardAdmission<T: Sendable>(
        expectedAuthorizationGeneration: UInt64,
        operation: @MainActor @Sendable () throws -> T
    ) async throws -> T {
        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        guard authorized,
              authorizedCapabilities.contains(.textClipboard),
              authorizationGeneration == expectedAuthorizationGeneration else {
            throw SessionError.authorizationChanged
        }
        return try await operation()
    }

    /// Runs one Host-side input admission while the session actor remains
    /// non-reentrant. The operation is synchronous by design: a local revoke,
    /// reconnect, or stop cannot interleave between the authorization check
    /// and the platform injection performed by the caller.
    public func withIncomingInputAdmission<T: Sendable>(
        for input: InputEventMessage,
        operation: @Sendable () throws -> T
    ) throws -> T {
        let payload = MessagePayload.inputEvent(input)
        try validateMessageDirection(for: payload.messageType, incoming: true)
        try validateAuthorization(for: payload)
        return try operation()
    }

    /// Issues an opaque admission for a Viewer input message.  The caller may
    /// do local encoding or UI work after this returns, but the token is
    /// single-epoch: a reconnect or authorization transition invalidates it.
    public func makeInputAdmission(
        for input: InputEventMessage
    ) throws -> SessionInputAdmissionToken {
        let payload = MessagePayload.inputEvent(input)
        try validateMessageDirection(for: payload.messageType, incoming: false)
        try validateAuthorization(for: payload)
        guard let capability = requiredCapabilities(for: payload).first else {
            throw SessionError.unauthorizedMessage(.inputEvent)
        }
        return SessionInputAdmissionToken(
            receiveGeneration: receiveGeneration,
            reconnectGeneration: reconnectGeneration,
            authorizationGeneration: authorizationGeneration,
            windowGeneration: input.windowGeneration,
            capability: capability
        )
    }

    /// Admits and sends one Viewer input event under the same outbound mutex.
    /// The authorization and reconnect generations are checked both before
    /// admission and after the transport await, so a token issued for an old
    /// authorization epoch cannot enter a later epoch with the same window
    /// generation.
    public func sendInput(
        _ input: InputEventMessage,
        using admission: SessionInputAdmissionToken
    ) async throws {
        let payload = MessagePayload.inputEvent(input)
        try validateMessageDirection(for: payload.messageType, incoming: false)
        guard admission.windowGeneration == input.windowGeneration,
              admission.capability == requiredCapabilities(for: payload).first else {
            throw SessionError.authorizationChanged
        }

        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        guard admission.receiveGeneration == receiveGeneration,
              admission.reconnectGeneration == reconnectGeneration else {
            throw SessionError.reconnectRequired
        }
        guard admission.authorizationGeneration == authorizationGeneration else {
            throw SessionError.authorizationChanged
        }
        try validateAuthorization(for: payload)
        _ = try await sendUnrestrictedAfterAdmission(
            payload,
            flags: [],
            operationGeneration: admission.reconnectGeneration,
            operationReceiveGeneration: admission.receiveGeneration,
            operationAuthorizationGeneration: admission.authorizationGeneration
        )
    }

    public func stop(reason: CloseReason = .normal) async {
        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        guard state != .stopping else { return }
        await stopWhileHoldingOutboundMutex(reason: reason)
    }

    /// Stops the session only if the caller still owns the same authenticated
    /// transport epoch. The generation check is performed after acquiring the
    /// outbound mutex so a stale clipboard/send failure cannot close a
    /// replacement connection that was established while the failure was
    /// unwinding.
    @discardableResult
    public func stopIfCurrent(
        reason: CloseReason = .normal,
        expectedAuthorizationGeneration: UInt64,
        expectedReconnectGeneration: UInt64
    ) async -> Bool {
        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        guard state != .stopping,
              authorizationGeneration == expectedAuthorizationGeneration,
              reconnectGeneration == expectedReconnectGeneration else {
            return false
        }
        await stopWhileHoldingOutboundMutex(reason: reason)
        return true
    }

    private func stopWhileHoldingOutboundMutex(reason: CloseReason) async {
        state = .stopping
        incomingMessageStorage.finish()
        authorizationGeneration &+= 1
        clearAuthorization()
        receiveGeneration &+= 1
        let closeReceiveGeneration = receiveGeneration
        heartbeatGeneration &+= 1
        heartbeatTask?.cancel()
        handshakeTask?.cancel()
        cancelPairingDeadline()
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
            operationReceiveGeneration: closeReceiveGeneration,
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
        cancelPairingDeadline()
        receiveTask?.cancel()
        heartbeatTask = nil
        receiveTask = nil
        handshakeTask = nil
        await pairingCoordinator?.abortPendingPairing()
        await transport.invalidateProtectedMessages()
        await transport.close()
        incomingMessageStorage.reset()
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
        capabilitiesSendInFlight = false
        incomingSequence.removeAll()
        outgoingSequence.removeAll()
        pendingPing = nil
        lastHeartbeatAt = nil
        outboundMutex.release()
        try await start()
    }

    private func sendPairingChallenge(
        to identity: PeerIdentity,
        receiveGeneration expectedReceiveGeneration: UInt64,
        reconnectGeneration expectedReconnectGeneration: UInt64,
        authorizationGeneration expectedAuthorizationGeneration: UInt64
    ) async throws -> PairingChallenge {
        guard let pairingCoordinator else { throw SessionError.pairingFailed }
        guard isCurrent(
            receiveGeneration: expectedReceiveGeneration,
            reconnectGeneration: expectedReconnectGeneration,
            authorizationGeneration: expectedAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        let challengeID = UInt64.random(in: 1 ... UInt64.max)
        let challenge = try await pairingCoordinator.beginSessionPairing(
            with: identity,
            challengeID: challengeID,
            timeout: pairingTimeoutSeconds()
        )
        guard isCurrent(
            receiveGeneration: expectedReceiveGeneration,
            reconnectGeneration: expectedReconnectGeneration,
            authorizationGeneration: expectedAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        let message = PairingChallengeMessage(
            challengeID: challenge.challengeID,
            confirmationCode: challenge.confirmationCode
        )
        _ = try await sendUnrestricted(
            .pairingChallenge(message),
            expectedReceiveGeneration: expectedReceiveGeneration,
            expectedReconnectGeneration: expectedReconnectGeneration,
            expectedAuthorizationGeneration: expectedAuthorizationGeneration
        )
        startPairingDeadline(expiresAt: challenge.expiresAt)
        guard isCurrent(
            receiveGeneration: expectedReceiveGeneration,
            reconnectGeneration: expectedReconnectGeneration,
            authorizationGeneration: expectedAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        return challenge
    }

    private func sendHelloIfNeeded(
        receiveGeneration expectedReceiveGeneration: UInt64,
        reconnectGeneration expectedReconnectGeneration: UInt64,
        authorizationGeneration expectedAuthorizationGeneration: UInt64
    ) async throws {
        guard !helloSent else { return }
        guard isCurrent(
            receiveGeneration: expectedReceiveGeneration,
            reconnectGeneration: expectedReconnectGeneration,
            authorizationGeneration: expectedAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        let hello = HelloMessage(
            protocolVersion: .current,
            role: configuration.role,
            implementationIdentifier: configuration.implementationIdentifier,
            limits: configuration.limits
        )
        _ = try await sendUnrestricted(
            .hello(hello),
            expectedReceiveGeneration: expectedReceiveGeneration,
            expectedReconnectGeneration: expectedReconnectGeneration,
            expectedAuthorizationGeneration: expectedAuthorizationGeneration
        )
        guard isCurrent(
            receiveGeneration: expectedReceiveGeneration,
            reconnectGeneration: expectedReconnectGeneration,
            authorizationGeneration: expectedAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        helloSent = true
    }

    private func sendCapabilitiesIfNeeded(
        receiveGeneration expectedReceiveGeneration: UInt64,
        reconnectGeneration expectedReconnectGeneration: UInt64,
        authorizationGeneration expectedAuthorizationGeneration: UInt64
    ) async throws {
        guard !capabilitiesSent, !capabilitiesSendInFlight else { return }
        guard state == .trusted || state == .capabilitiesNegotiated || state == .windowSelectionAuthorized else {
            return
        }
        guard isCurrent(
            receiveGeneration: expectedReceiveGeneration,
            reconnectGeneration: expectedReconnectGeneration,
            authorizationGeneration: expectedAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        let capabilities = CapabilitiesMessage(
            capabilities: configuration.capabilities.sorted { $0.rawValue < $1.rawValue },
            maxVideoWidth: configuration.maxVideoWidth,
            maxVideoHeight: configuration.maxVideoHeight,
            maxFrameRate: configuration.maxFrameRate,
            mandatoryCapabilities: configuration.mandatoryCapabilities
        )
        capabilitiesSendInFlight = true
        do {
            _ = try await sendUnrestricted(
                .capabilities(capabilities),
                expectedReceiveGeneration: expectedReceiveGeneration,
                expectedReconnectGeneration: expectedReconnectGeneration,
                expectedAuthorizationGeneration: expectedAuthorizationGeneration
            )
        } catch {
            capabilitiesSendInFlight = false
            throw error
        }
        capabilitiesSendInFlight = false
        guard isCurrent(
            receiveGeneration: expectedReceiveGeneration,
            reconnectGeneration: expectedReconnectGeneration,
            authorizationGeneration: expectedAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        capabilitiesSent = true
    }

    private func sendUnrestricted(
        _ payload: MessagePayload,
        flags: EnvelopeFlags = [],
        expectedReceiveGeneration: UInt64? = nil,
        expectedReconnectGeneration: UInt64? = nil,
        expectedAuthorizationGeneration: UInt64? = nil
    ) async throws -> TransportSendResult {
        try validateMessageDirection(for: payload.messageType, incoming: false)
        let operationGeneration = expectedReconnectGeneration ?? reconnectGeneration
        let operationReceiveGeneration = expectedReceiveGeneration ?? receiveGeneration
        let operationAuthorizationGeneration = expectedAuthorizationGeneration ?? authorizationGeneration
        await outboundMutex.acquire()
        defer { outboundMutex.release() }

        guard isCurrent(
            receiveGeneration: operationReceiveGeneration,
            reconnectGeneration: operationGeneration,
            authorizationGeneration: operationAuthorizationGeneration
        ) else {
            if operationReceiveGeneration != receiveGeneration ||
                operationGeneration != reconnectGeneration {
                throw SessionError.reconnectRequired
            }
            throw SessionError.authorizationChanged
        }
        if Self.protectedMessageTypes.contains(payload.messageType) {
            try validateAuthorization(for: payload)
        }

        return try await sendUnrestrictedAfterAdmission(
            payload,
            flags: flags,
            operationGeneration: operationGeneration,
            operationReceiveGeneration: operationReceiveGeneration,
            operationAuthorizationGeneration: operationAuthorizationGeneration
        )
    }

    private func sendUnrestrictedAfterAdmission(
        _ payload: MessagePayload,
        flags: EnvelopeFlags,
        operationGeneration: UInt64,
        operationReceiveGeneration: UInt64,
        operationAuthorizationGeneration: UInt64
    ) async throws -> TransportSendResult {
        guard operationReceiveGeneration == receiveGeneration,
              operationGeneration == reconnectGeneration else {
            throw SessionError.reconnectRequired
        }
        guard operationAuthorizationGeneration == authorizationGeneration else {
            throw SessionError.authorizationChanged
        }
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
        do {
            let result = try await targetTransport.send(envelope)
            // Keep sequence numbers monotonic for an unchanged transport even
            // when an authorization transition invalidates a queued media
            // frame. Reconnect resets the sequence space for the new transport.
            guard isCurrent(
                receiveGeneration: operationReceiveGeneration,
                reconnectGeneration: operationGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            ) else {
                if operationReceiveGeneration != receiveGeneration ||
                    operationGeneration != reconnectGeneration {
                    throw SessionError.reconnectRequired
                }
                throw SessionError.authorizationChanged
            }
            outgoingSequence[channel] = sequence + 1
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
        let sessionGeneration = reconnectGeneration
        let stream = transport.incoming
        receiveTask = Task { [weak self] in
            do {
                for try await envelope in stream {
                    await self?.handle(
                        envelope,
                        generation: generation,
                        reconnectGeneration: sessionGeneration
                    )
                }
                await self?.handleTransportEOF(
                    generation: generation,
                    reconnectGeneration: sessionGeneration
                )
            } catch {
                await self?.handleTransportFailure(
                    String(describing: error),
                    generation: generation,
                    reconnectGeneration: sessionGeneration
                )
            }
        }
    }

    private func handle(
        _ envelope: Envelope,
        generation: UInt64,
        reconnectGeneration sessionGeneration: UInt64
    ) async {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration
        ) else { return }
        guard state != .stopping, state != .failed else { return }
        let operationAuthorizationGeneration = authorizationGeneration
        do {
            try validateIncomingSequence(envelope)
            if case .unknown = envelope.messageType,
               !envelope.flags.contains(.mustUnderstand) {
                return
            }
            let message = try envelope.decodedMessage(using: effectiveProtocolLimits())
            try await handle(
                message,
                generation: generation,
                reconnectGeneration: sessionGeneration
            )
        } catch let error as SessionError {
            guard isCurrent(
                receiveGeneration: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            ) else { return }
            await fail(
                error,
                expectedReceiveGeneration: generation,
                expectedReconnectGeneration: sessionGeneration,
                expectedAuthorizationGeneration: operationAuthorizationGeneration
            )
        } catch {
            guard isCurrent(
                receiveGeneration: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            ) else { return }
            await fail(
                .transportFailure(String(describing: error)),
                expectedReceiveGeneration: generation,
                expectedReconnectGeneration: sessionGeneration,
                expectedAuthorizationGeneration: operationAuthorizationGeneration
            )
        }
    }

    private func handle(
        _ message: MessagePayload,
        generation: UInt64,
        reconnectGeneration sessionGeneration: UInt64
    ) async throws {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration
        ) else { return }
        let operationAuthorizationGeneration = authorizationGeneration
        try validateMessageDirection(for: message.messageType, incoming: true)
        try validateAuthorization(for: message)
        switch message {
        case let .hello(hello):
            try await handleHello(
                hello,
                generation: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            )
        case let .capabilities(capabilities):
            try await handleCapabilities(
                capabilities,
                generation: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            )
        case let .pairingChallenge(challenge):
            guard state == .pairingRequired,
                  configuration.role == .viewer,
                  let peerIdentity,
                  let pairingCoordinator else {
                throw SessionError.pairingFailed
            }
            let hasPendingChallenge = await pairingCoordinator.pendingChallenge() != nil
            guard isCurrent(
                receiveGeneration: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            ) else { return }
            guard !hasPendingChallenge else {
                throw SessionError.invalidState(state)
            }
            guard isCurrent(
                receiveGeneration: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            ) else { return }
            let adoptedChallenge = try await pairingCoordinator.adoptRemoteSessionChallenge(
                challengeID: challenge.challengeID,
                from: peerIdentity,
                confirmationCode: challenge.confirmationCode,
                timeout: pairingTimeoutSeconds()
            )
            startPairingDeadline(expiresAt: adoptedChallenge.expiresAt)
            guard isCurrent(
                receiveGeneration: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            ) else { return }
            if try await pairingCoordinator.trustDecision(for: peerIdentity) == .trusted {
                try await confirmPairing(
                    confirmationCode: adoptedChallenge.confirmationCode,
                    accepted: true,
                    displayName: configuration.role == .host
                        ? "MacRemoteApp Viewer"
                        : "MacRemoteApp Host"
                )
            }
        case let .pairingConfirmation(confirmation):
            try await handlePairingConfirmation(
                confirmation,
                generation: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            )
        case let .sessionAuthorize(authorizationMessage):
            try await handleAuthorization(
                authorizationMessage,
                generation: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            )
        case let .ping(ping):
            _ = try await sendUnrestricted(
                .pong(PongMessage(nonce: ping.nonce)),
                expectedReceiveGeneration: generation,
                expectedReconnectGeneration: sessionGeneration,
                expectedAuthorizationGeneration: operationAuthorizationGeneration
            )
        case let .pong(pong):
            guard pendingPing?.nonce == pong.nonce else { throw SessionError.replayDetected }
            pendingPing = nil
            lastHeartbeatAt = Date()
        case let .sessionState(sessionState):
            try await handleSessionState(
                sessionState,
                message: message,
                generation: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            )
        case .error:
            try publish(message)
            await fail(
                .transportFailure("peer reported a session error"),
                expectedReceiveGeneration: generation,
                expectedReconnectGeneration: sessionGeneration,
                expectedAuthorizationGeneration: operationAuthorizationGeneration
            )
        case .close:
            try await handleClose(
                message,
                generation: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            )
        default:
            try publish(message)
        }
    }

    private func handleSessionState(
        _ sessionState: SessionStateMessage,
        message: MessagePayload,
        generation: UInt64,
        reconnectGeneration sessionGeneration: UInt64,
        authorizationGeneration sessionAuthorizationGeneration: UInt64
    ) async throws {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }

        guard sessionState.state == .stopping || sessionState.state == .failed else {
            try publish(message)
            return
        }

        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }
        authorizationGeneration &+= 1
        let operationAuthorizationGeneration = authorizationGeneration
        clearAuthorization()
        await transport.invalidateProtectedMessages()
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: operationAuthorizationGeneration
        ) else { return }
        try publish(message)
    }

    private func handleClose(
        _ message: MessagePayload,
        generation: UInt64,
        reconnectGeneration sessionGeneration: UInt64,
        authorizationGeneration sessionAuthorizationGeneration: UInt64
    ) async throws {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }
        try publish(message)

        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }

        authorizationGeneration &+= 1
        clearAuthorization()
        state = .stopping
        incomingMessageStorage.finish()
        receiveGeneration &+= 1
        heartbeatGeneration &+= 1
        handshakeGeneration &+= 1
        heartbeatTask?.cancel()
        handshakeTask?.cancel()
        cancelPairingDeadline()
        receiveTask?.cancel()
        heartbeatTask = nil
        handshakeTask = nil
        receiveTask = nil
        await pairingCoordinator?.abortPendingPairing()
        await transport.invalidateProtectedMessages()
        await transport.close()
    }

    private func handleHello(
        _ hello: HelloMessage,
        generation: UInt64,
        reconnectGeneration sessionGeneration: UInt64,
        authorizationGeneration sessionAuthorizationGeneration: UInt64
    ) async throws {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }
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
        try await sendCapabilitiesIfNeeded(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        )
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }
    }

    private func handleCapabilities(
        _ capabilities: CapabilitiesMessage,
        generation: UInt64,
        reconnectGeneration sessionGeneration: UInt64,
        authorizationGeneration sessionAuthorizationGeneration: UInt64
    ) async throws {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }
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
        try await sendCapabilitiesIfNeeded(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        )
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }
        startHeartbeatIfReady()
    }

    private func handlePairingConfirmation(
        _ confirmation: PairingConfirmationMessage,
        generation: UInt64,
        reconnectGeneration sessionGeneration: UInt64,
        authorizationGeneration sessionAuthorizationGeneration: UInt64
    ) async throws {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }
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
            guard isCurrent(
                receiveGeneration: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: sessionAuthorizationGeneration
            ) else { return }
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
            guard isCurrent(
                receiveGeneration: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: sessionAuthorizationGeneration
            ) else { return }
            throw SessionError.pairingFailed
        }
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }
        try await synchronizePairingState(
            generation: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        )
        try await sendCapabilitiesIfNeeded(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        )
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }
    }

    private func handleAuthorization(
        _ authorization: SessionAuthorizeMessage,
        generation: UInt64,
        reconnectGeneration sessionGeneration: UInt64,
        authorizationGeneration sessionAuthorizationGeneration: UInt64
    ) async throws {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else { return }
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
        // Authorization changes are serialized with reconnect, stop, and all
        // outbound admissions. The receive generation is checked again after
        // every await so an old receive task cannot authorize a new session.
        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        let operationAuthorizationGeneration = sessionAuthorizationGeneration &+ 1
        authorizationGeneration = operationAuthorizationGeneration
        clearAuthorization()
        await transport.invalidateProtectedMessages()
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: operationAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        guard operationAuthorizationGeneration == authorizationGeneration else {
            throw SessionError.authorizationChanged
        }
        authorized = authorization.authorized
        authorizedWindowGeneration = authorization.authorized ? authorization.windowGeneration : nil
        authorizedCapabilities = authorization.authorized ? requested : []
        state = authorization.authorized ? .windowSelectionAuthorized : .capabilitiesNegotiated
    }

    private func synchronizePairingState(
        generation: UInt64,
        reconnectGeneration sessionGeneration: UInt64,
        authorizationGeneration sessionAuthorizationGeneration: UInt64
    ) async throws {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        guard let pairingCoordinator else {
            throw SessionError.pairingFailed
        }
        let pairingState = await pairingCoordinator.state()
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        switch pairingState {
        case .paired:
            cancelPairingDeadline()
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
        incomingMessageStorage.removeProtectedMessages()
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
        case .clipboardOffer, .clipboardText, .clipboardAcknowledgement:
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

    private func publish(_ message: MessagePayload) throws {
        do {
            _ = try incomingMessageStorage.yield(message)
        } catch TransportError.controlBackpressure {
            throw SessionError.incomingMessageBackpressure(.control)
        } catch TransportError.mediaBackpressure {
            throw SessionError.incomingMessageBackpressure(.media)
        }
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

    private func pairingTimeoutSeconds() -> TimeInterval {
        Double(configuration.pairingTimeoutNanoseconds) / 1_000_000_000
    }

    private func startPairingDeadline(expiresAt: Date) {
        pairingDeadlineTask?.cancel()
        pairingDeadlineGeneration &+= 1
        let generation = pairingDeadlineGeneration
        let nanoseconds = UInt64(
            max(
                0,
                min(
                    expiresAt.timeIntervalSinceNow * 1_000_000_000,
                    Double(UInt64.max)
                )
            )
        )
        pairingDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await self?.pairingDeadlineReached(generation: generation)
        }
    }

    private func pairingDeadlineReached(generation: UInt64) async {
        guard generation == pairingDeadlineGeneration,
              state == .pairingRequired else { return }
        pairingDeadlineTask = nil
        let sessionReceiveGeneration = receiveGeneration
        let sessionReconnectGeneration = reconnectGeneration
        let sessionAuthorizationGeneration = authorizationGeneration
        await fail(
            .pairingFailed,
            expectedReceiveGeneration: sessionReceiveGeneration,
            expectedReconnectGeneration: sessionReconnectGeneration,
            expectedAuthorizationGeneration: sessionAuthorizationGeneration
        )
    }

    private func cancelPairingDeadline() {
        pairingDeadlineGeneration &+= 1
        pairingDeadlineTask?.cancel()
        pairingDeadlineTask = nil
    }

    private func handshakeDeadlineReached(generation: UInt64) async {
        guard generation == handshakeGeneration else { return }
        guard state != .capabilitiesNegotiated,
              state != .windowSelectionAuthorized,
              // Once a challenge is active, the pairing-specific deadline
              // owns teardown so a synchronous consent prompt cannot outlive
              // the bounded challenge. Before the challenge arrives, the
              // generic handshake deadline still protects the session.
              state != .pairingRequired || pairingDeadlineTask == nil,
              state != .stopping,
              state != .failed else {
            return
        }
        let sessionReceiveGeneration = receiveGeneration
        let sessionReconnectGeneration = reconnectGeneration
        let sessionAuthorizationGeneration = authorizationGeneration
        await fail(
            .handshakeTimeout,
            expectedReceiveGeneration: sessionReceiveGeneration,
            expectedReconnectGeneration: sessionReconnectGeneration,
            expectedAuthorizationGeneration: sessionAuthorizationGeneration,
            expectedHandshakeGeneration: generation
        )
    }

    private func heartbeatTick(generation: UInt64) async {
        guard generation == heartbeatGeneration else { return }
        guard state != .stopping, state != .failed else { return }
        let sessionReceiveGeneration = receiveGeneration
        let sessionReconnectGeneration = reconnectGeneration
        let sessionAuthorizationGeneration = authorizationGeneration
        let now = Date()
        if let pendingPing,
           now.timeIntervalSince(pendingPing.sentAt) * 1_000_000_000 >= Double(configuration.heartbeatTimeoutNanoseconds) {
            await fail(
                .heartbeatTimeout,
                expectedReceiveGeneration: sessionReceiveGeneration,
                expectedReconnectGeneration: sessionReconnectGeneration,
                expectedAuthorizationGeneration: sessionAuthorizationGeneration,
                expectedHeartbeatGeneration: generation
            )
            return
        }
        guard pendingPing == nil else { return }
        let nonce = nextPingNonce
        nextPingNonce = nextPingNonce == UInt64.max ? 1 : nextPingNonce + 1
        pendingPing = (nonce: nonce, sentAt: now)
        do {
            _ = try await sendUnrestricted(
                .ping(PingMessage(nonce: nonce)),
                expectedReceiveGeneration: sessionReceiveGeneration,
                expectedReconnectGeneration: sessionReconnectGeneration,
                expectedAuthorizationGeneration: sessionAuthorizationGeneration
            )
        } catch {
            await fail(
                .transportFailure(String(describing: error)),
                expectedReceiveGeneration: sessionReceiveGeneration,
                expectedReconnectGeneration: sessionReconnectGeneration,
                expectedAuthorizationGeneration: sessionAuthorizationGeneration,
                expectedHeartbeatGeneration: generation
            )
        }
    }

    private func handleTransportFailure(
        _ detail: String,
        generation: UInt64,
        reconnectGeneration sessionGeneration: UInt64
    ) async {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration
        ) else { return }
        guard state != .stopping, state != .failed else { return }
        let sessionAuthorizationGeneration = authorizationGeneration
        await fail(
            .transportFailure(detail),
            expectedReceiveGeneration: generation,
            expectedReconnectGeneration: sessionGeneration,
            expectedAuthorizationGeneration: sessionAuthorizationGeneration
        )
    }

    private func handleTransportEOF(
        generation: UInt64,
        reconnectGeneration sessionGeneration: UInt64
    ) async {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration
        ) else { return }
        guard state != .stopping, state != .failed else { return }
        let sessionAuthorizationGeneration = authorizationGeneration
        await fail(
            .transportFailure("transport reached EOF"),
            expectedReceiveGeneration: generation,
            expectedReconnectGeneration: sessionGeneration,
            expectedAuthorizationGeneration: sessionAuthorizationGeneration
        )
    }

    private func fail(
        _ error: SessionError,
        expectedReceiveGeneration: UInt64? = nil,
        expectedReconnectGeneration: UInt64? = nil,
        expectedAuthorizationGeneration: UInt64? = nil,
        expectedHeartbeatGeneration: UInt64? = nil,
        expectedHandshakeGeneration: UInt64? = nil
    ) async {
        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        if let expectedReceiveGeneration,
           expectedReceiveGeneration != receiveGeneration {
            return
        }
        if let expectedReconnectGeneration,
           expectedReconnectGeneration != reconnectGeneration {
            return
        }
        if let expectedAuthorizationGeneration,
           expectedAuthorizationGeneration != authorizationGeneration {
            return
        }
        if let expectedHeartbeatGeneration,
           expectedHeartbeatGeneration != heartbeatGeneration {
            return
        }
        if let expectedHandshakeGeneration,
           expectedHandshakeGeneration != handshakeGeneration {
            return
        }
        authorizationGeneration &+= 1
        clearAuthorization()
        lastFailure = error
        state = .failed
        incomingMessageStorage.finish(throwing: error)
        receiveGeneration &+= 1
        heartbeatGeneration &+= 1
        handshakeGeneration &+= 1
        heartbeatTask?.cancel()
        handshakeTask?.cancel()
        cancelPairingDeadline()
        receiveTask?.cancel()
        heartbeatTask = nil
        handshakeTask = nil
        receiveTask = nil
        await pairingCoordinator?.abortPendingPairing()
        await transport.invalidateProtectedMessages()
        await transport.close()
        _ = error
    }

    private func isCurrent(
        receiveGeneration expectedReceiveGeneration: UInt64,
        reconnectGeneration expectedReconnectGeneration: UInt64,
        authorizationGeneration expectedAuthorizationGeneration: UInt64? = nil
    ) -> Bool {
        expectedReceiveGeneration == receiveGeneration &&
            expectedReconnectGeneration == reconnectGeneration &&
            (expectedAuthorizationGeneration == nil ||
                expectedAuthorizationGeneration == authorizationGeneration)
    }

}
