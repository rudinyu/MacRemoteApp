import Foundation
import RemoteProtocol
import SecurityCore

/// Stable, privacy-safe categories for session failures written to Debug
/// diagnostics. Associated values are deliberately excluded.
public enum SessionFailureCategory: String, Equatable, Sendable {
    case invalidState = "invalid_state"
    case peerRoleMismatch = "peer_role_mismatch"
    case unsupportedVersion = "unsupported_version"
    case mandatoryCapabilityMissing = "mandatory_capability_missing"
    case pairingRequired = "pairing_required"
    case pairingDenied = "pairing_denied"
    case pairingFailed = "pairing_failed"
    case unauthorizedMessage = "unauthorized_message"
    case replayDetected = "replay_detected"
    case authorizationWindowGenerationRequired = "authorization_window_generation_required"
    case handshakeTimeout = "handshake_timeout"
    case heartbeatTimeout = "heartbeat_timeout"
    case authorizationReceiptTimeout = "authorization_receipt_timeout"
    case reconnectRequired = "reconnect_required"
    case authorizationChanged = "authorization_changed"
    case incomingMessageBackpressure = "incoming_message_backpressure"
    case videoBoundsExceeded = "video_bounds_exceeded"
    case transportEOF = "transport_eof"
    case transportFailure = "transport_failure"
}

/// The fixed class of a terminal transport signal, with no framework error
/// details or peer-provided strings.
public enum TransportTerminationClass: String, Equatable, Sendable {
    case endOfStream = "end_of_stream"
    case failure
}

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
    case authorizationReceiptTimeout
    case reconnectRequired
    case authorizationChanged
    case incomingMessageBackpressure(Channel)
    case videoBoundsExceeded
    case transportEOF
    case transportFailure(String)

    public var failureCategory: SessionFailureCategory {
        switch self {
        case .invalidState: return .invalidState
        case .peerRoleMismatch: return .peerRoleMismatch
        case .unsupportedVersion: return .unsupportedVersion
        case .mandatoryCapabilityMissing: return .mandatoryCapabilityMissing
        case .pairingRequired: return .pairingRequired
        case .pairingDenied: return .pairingDenied
        case .pairingFailed: return .pairingFailed
        case .unauthorizedMessage: return .unauthorizedMessage
        case .replayDetected: return .replayDetected
        case .authorizationWindowGenerationRequired: return .authorizationWindowGenerationRequired
        case .handshakeTimeout: return .handshakeTimeout
        case .heartbeatTimeout: return .heartbeatTimeout
        case .authorizationReceiptTimeout: return .authorizationReceiptTimeout
        case .reconnectRequired: return .reconnectRequired
        case .authorizationChanged: return .authorizationChanged
        case .incomingMessageBackpressure: return .incomingMessageBackpressure
        case .videoBoundsExceeded: return .videoBoundsExceeded
        case .transportEOF: return .transportEOF
        case .transportFailure: return .transportFailure
        }
    }

    public var transportTerminationClass: TransportTerminationClass? {
        switch self {
        case .transportEOF: return .endOfStream
        case .transportFailure: return .failure
        default: return nil
        }
    }

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
        case .authorizationReceiptTimeout: return "authorization receipt barrier timed out"
        case .reconnectRequired: return "session must reconnect before authorization"
        case .authorizationChanged: return "session authorization changed while sending"
        case let .incomingMessageBackpressure(channel):
            let channelName = channel == .control ? "control" : "media"
            return "incoming \(channelName) message delivery is backpressured"
        case .videoBoundsExceeded: return "video parameters exceed negotiated bounds"
        case .transportEOF: return "transport reached EOF"
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
    public let deviceName: String?
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
        deviceName: String? = nil,
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
        self.deviceName = deviceName
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
    public let peerDeviceName: String?
    public let negotiatedCapabilities: Set<Capability>
    public let authorized: Bool
    public let authorizedWindowGeneration: UInt64?
    public let authorizedCapabilities: Set<Capability>
    public let receiveGeneration: UInt64
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
        peerDeviceName: String? = nil,
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
        effectiveProtocolLimits: ProtocolLimits = .default,
        receiveGeneration: UInt64 = 0
    ) {
        self.state = state
        self.peerIdentity = peerIdentity
        self.peerDeviceName = peerDeviceName
        self.negotiatedCapabilities = negotiatedCapabilities
        self.authorized = authorized
        self.authorizedWindowGeneration = authorizedWindowGeneration
        self.authorizedCapabilities = authorizedCapabilities
        self.receiveGeneration = receiveGeneration
        self.reconnectGeneration = reconnectGeneration
        self.authorizationGeneration = authorizationGeneration
        self.effectiveProtocolLimits = effectiveProtocolLimits
        self.lastHeartbeatAt = lastHeartbeatAt
        self.negotiatedMaxVideoWidth = negotiatedMaxVideoWidth
        self.negotiatedMaxVideoHeight = negotiatedMaxVideoHeight
        self.negotiatedMaxFrameRate = negotiatedMaxFrameRate
    }
}

/// The exact authorization epoch written by one successful Host authorization
/// operation. This contains transport-neutral numeric metadata only.
public struct SessionAuthorizationTransition: Equatable, Sendable {
    public let previousAuthorizationGeneration: UInt64
    public let authorizationGeneration: UInt64
    public let reconnectGeneration: UInt64
    public let receiveGeneration: UInt64

    public init(
        previousAuthorizationGeneration: UInt64,
        authorizationGeneration: UInt64,
        reconnectGeneration: UInt64,
        receiveGeneration: UInt64
    ) {
        self.previousAuthorizationGeneration = previousAuthorizationGeneration
        self.authorizationGeneration = authorizationGeneration
        self.reconnectGeneration = reconnectGeneration
        self.receiveGeneration = receiveGeneration
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
    fileprivate let capabilities: Set<Capability>
}

/// Reports whether an input send crossed into the session transport.
public enum SessionInputSendState: Equatable, Sendable {
    /// Session validation failed before the transport was invoked.
    case notStarted
    /// The session invoked `SessionTransport.send`; delivery may be uncertain.
    case transportSendStarted
}

/// Bounded reasons a send may be rejected before the transport boundary.
public enum SessionInputSendRejection: String, CaseIterable, Equatable, Sendable {
    /// The admission token does not match this message's window or capabilities.
    case admissionTokenMismatch
    /// The authorization epoch advanced while this token waited for the outbound mutex.
    case authorizationEpochChangedAfterAdmission
}

/// Thread-safe observation for one input send attempt.
///
/// A `SessionCoordinator` updates this immediately before invoking the
/// underlying transport. Callers can therefore distinguish local admission
/// failures from errors that happened after transport delivery began.
public final class SessionInputSendObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedState: SessionInputSendState = .notStarted
    private var storedPreTransportRejection: SessionInputSendRejection?

    public init() {}

    public var state: SessionInputSendState {
        lock.withLock { storedState }
    }

    public var preTransportRejection: SessionInputSendRejection? {
        lock.withLock { storedPreTransportRejection }
    }

    fileprivate func markPreTransportRejection(_ rejection: SessionInputSendRejection) {
        lock.withLock { storedPreTransportRejection = rejection }
    }

    fileprivate func markTransportSendStarted() {
        lock.withLock { storedState = .transportSendStarted }
    }
}

/// The result of a synchronous Host input-source selection admission. The
/// authorization and reconnect generations are captured atomically with the
/// operation and can fence its acknowledgement send.
public struct InputSourceSelectionAdmissionResult<Value: Sendable>: Sendable {
    public let value: Value
    public let authorizationGeneration: UInt64
    public let reconnectGeneration: UInt64
    public let windowGeneration: UInt64
    public let requestID: UInt64
}

typealias AuthorizationReceiptStamp = EnvelopeReceiptStamp

/// Captures which Host authorization epoch was active when a transport
/// envelope entered the receive task, before actor scheduling can delay its
/// validation until after a local reauthorization completes.
final class AuthorizationReceiptFence: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var transitionInFlight = false

    func beginLocalTransition() -> UInt64 {
        lock.withLock {
            epoch &+= 1
            transitionInFlight = true
            return epoch
        }
    }

    func endLocalTransition(epoch expectedEpoch: UInt64) {
        lock.withLock {
            guard epoch == expectedEpoch else { return }
            transitionInFlight = false
        }
    }

    func cancelLocalTransition() {
        lock.withLock {
            epoch &+= 1
            transitionInFlight = false
        }
    }

    func capture() -> AuthorizationReceiptStamp {
        lock.withLock {
            AuthorizationReceiptStamp(epoch: epoch, transitionInFlight: transitionInFlight)
        }
    }

    func shouldDiscardProtectedMessage(receivedAt stamp: AuthorizationReceiptStamp) -> Bool {
        lock.withLock {
            stamp.transitionInFlight || transitionInFlight || stamp.epoch != epoch
        }
    }
}

public actor SessionCoordinator {
    private static let incomingControlMessageCapacity = 64
    private static let incomingMediaMessageCapacity = 3
    private static let inputSourceSelectionAdmissionCapacity = incomingControlMessageCapacity
    private static let maximumClockSyncProbes = 64
    /// Minimum spacing between Viewer keyframe requests. One forced keyframe
    /// recovers every gap that occurred before it, so closer requests only
    /// cost bandwidth.
    static let keyframeRequestMinimumIntervalNanoseconds: UInt64 = 250_000_000

    private static let protectedMessageTypes: Set<MessageType> = [
        .windowList,
        .windowSelection,
        .streamConfig,
        .videoConfig,
        .videoFrame,
        .inputEvent,
        .inputSourceSelection,
        .inputSourceAcknowledgement,
        .clipboardOffer,
        .clipboardText,
        .clipboardAcknowledgement,
        .keyframeRequest,
        .receiverReport
    ]

    private static let windowBoundCapabilities: Set<Capability> = [
        .windowSelection,
        .h264Video,
        .keyframeRequest,
        .receiverReport,
        .inputSourceSync,
        .mouseInput,
        .keyboardInput,
        .backgroundControl
    ]

    private static let hostOutboundMessageTypes: Set<MessageType> = [
        .hello,
        .capabilities,
        .pairingChallenge,
        .pairingConfirmation,
        .pairingVerification,
        .sessionAuthorize,
        .windowList,
        .streamConfig,
        .videoConfig,
        .videoFrame,
        .clipboardOffer,
        .clipboardText,
        .clipboardAcknowledgement,
        .inputSourceAcknowledgement,
        .ping,
        .pong,
        .sessionState,
        .error,
        .close
    ]

    private static let viewerOutboundMessageTypes: Set<MessageType> = [
        .hello,
        .capabilities,
        .pairingResponse,
        .pairingReveal,
        .pairingConfirmation,
        .windowSelection,
        .inputEvent,
        .inputSourceSelection,
        .keyframeRequest,
        .receiverReport,
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
        .pairingResponse,
        .pairingReveal,
        .pairingConfirmation,
        .windowSelection,
        .inputEvent,
        .inputSourceSelection,
        .keyframeRequest,
        .receiverReport,
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
        .pairingVerification,
        .pairingConfirmation,
        .sessionAuthorize,
        .windowList,
        .streamConfig,
        .videoConfig,
        .videoFrame,
        .inputSourceAcknowledgement,
        .clipboardOffer,
        .clipboardText,
        .clipboardAcknowledgement,
        .ping,
        .pong,
        .sessionState,
        .error,
        .close
    ]

    private struct InputSourceSelectionAdmissionScope: Equatable {
        let receiveGeneration: UInt64
        let reconnectGeneration: UInt64
        let authorizationGeneration: UInt64
        let discardGeneration: UInt64
        let windowGeneration: UInt64
        let localAdmissionGeneration: UInt64?
        let controlGeneration: UInt64?
    }

    private struct PendingInputSourceSelectionAdmission {
        let selection: InputSourceSelectionMessage
        let scope: InputSourceSelectionAdmissionScope
    }

    private struct PendingInputAdmission {
        let input: InputEventMessage
        let generation: UInt64
    }

    private struct InputSourceSelectionRequestFence {
        let receiveGeneration: UInt64
        let reconnectGeneration: UInt64
        let requestID: UInt64
    }

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
    /// Extra Host-local gate for P6. It deliberately does not alter the wire
    /// authorization epoch, so pausing control cannot interrupt protected video.
    private var localInputAdmissionEnabled = false
    private var localInputAdmissionRevision: UInt64 = 0
    private var localInputAdmissionGeneration: UInt64 = 0
    private var pendingInputAdmissions: [PendingInputAdmission] = []
    private var pendingInputSourceSelectionAdmissions: [PendingInputSourceSelectionAdmission] = []
    private var lastInputSourceSelectionRequest: InputSourceSelectionRequestFence?
    private var inputSourceSelectionDiscardGeneration: UInt64 = 0
    private var lastKeyframeRequestNanoseconds: UInt64?
    private var congestionMonitor = ReceiverCongestionMonitor()
    private var helloSent = false
    private var capabilitiesSent = false
    private var capabilitiesSendInFlight = false
    private var incomingSequence: [Channel: UInt64] = [:]
    private var outgoingSequence: [Channel: UInt64] = [:]
    private var pendingPing: (
        nonce: UInt64,
        sentAt: Date,
        sentTimestampNanoseconds: UInt64
    )?
    // A receipt barrier is separate from the periodic heartbeat probe. A
    // heartbeat Pong already in flight when authorization changes must not
    // release the authorization receipt fence.
    private var authorizationReceiptBarrierNonce: UInt64?
    private var completedAuthorizationReceiptBarrierNonce: UInt64?
    private var clockSyncEstimator = ClockSyncEstimator()
    private var nextPingNonce: UInt64 = 1
    private var lastHeartbeatAt: Date?
    private var reconnectGeneration: UInt64 = 0
    private var authorizationGeneration: UInt64 = 0
    private let authorizationReceiptFence = AuthorizationReceiptFence()
    private var receiveGeneration: UInt64 = 0
    private var heartbeatGeneration: UInt64 = 0
    private var handshakeGeneration: UInt64 = 0
    private let authorizationTransitionMutex = AsyncMutex()
#if DEBUG
    private var authorizationTransitionMutexWaitersForTesting = 0

    var authorizationTransitionMutexWaiterCountForTesting: Int {
        authorizationTransitionMutexWaitersForTesting
    }
#endif
    private let outboundMutex = AsyncMutex()
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var pairingDeadlineTask: Task<Void, Never>?
    private var pairingDeadlineGeneration: UInt64 = 0
    private let pairingDeadlineSleep: PairingDeadlineSleep
    private var lastFailure: SessionError?

    public nonisolated let incomingMessages: MessageStream
    private let incomingMessageStorage: MessageStreamStorage

    public init(
        configuration: SessionConfiguration,
        transport: any SessionTransport,
        pairingCoordinator: PairingCoordinator? = nil
    ) {
        self.init(
            configuration: configuration,
            transport: transport,
            pairingCoordinator: pairingCoordinator,
            pairingDeadlineSleep: { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        )
    }

    /// Waits for the pairing challenge expiry. It must throw when the calling
    /// task is cancelled so a completed or superseded challenge never tears
    /// down the session. Tests inject a manual deadline so pairing expiry is
    /// driven by explicit state instead of wall-clock scheduling.
    typealias PairingDeadlineSleep = @Sendable (_ nanoseconds: UInt64) async throws -> Void

    init(
        configuration: SessionConfiguration,
        transport: any SessionTransport,
        pairingCoordinator: PairingCoordinator?,
        pairingDeadlineSleep: @escaping PairingDeadlineSleep
    ) {
        self.configuration = configuration
        self.transport = transport
        self.pairingCoordinator = pairingCoordinator
        self.pairingDeadlineSleep = pairingDeadlineSleep
        let stream = try! MessageStream.makeBounded(
            maxControlMessages: Self.incomingControlMessageCapacity,
            maxMediaMessages: Self.incomingMediaMessageCapacity
        )
        self.incomingMessages = stream.stream
        self.incomingMessageStorage = stream.storage
        let receiptFence = self.authorizationReceiptFence
        transport.incoming.installReceiptStampProvider { receiptFence.capture() }
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
            peerDeviceName: peerHello?.deviceName,
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
            effectiveProtocolLimits: effectiveProtocolLimits(),
            receiveGeneration: receiveGeneration
        )
    }

    /// Returns the terminal failure that caused this session to enter the
    /// failed state. Runtime composition layers use this to distinguish an
    /// explicit pairing denial from a transient transport failure.
    public func failureReason() -> SessionError? {
        lastFailure
    }

    /// Returns the bounded authenticated clock estimate collected from the
    /// session's Ping/Pong exchanges. A nil or ineligible estimate must never
    /// be used to label one-way production latency as verified.
    public func clockSyncEstimate() -> ClockSyncEstimate? {
        clockSyncEstimator.estimate()
    }

    /// Drops input records that were buffered before a local Host safety
    /// transition. This does not affect unrelated control messages or the
    /// session's wire sequence state.
    public func discardPendingInputMessages() {
        incomingMessageStorage.removePendingInputMessages()
        pendingInputAdmissions.removeAll(keepingCapacity: true)
        pendingInputSourceSelectionAdmissions.removeAll(keepingCapacity: true)
        inputSourceSelectionDiscardGeneration &+= 1
        localInputAdmissionGeneration &+= 1
    }

    /// Host-only immediate input fence for locally granted process control.
    /// Legacy sessions that did not negotiate P6 retain their existing policy.
    public func setLocalInputAdmission(_ enabled: Bool, revision: UInt64? = nil) {
        guard configuration.role == .host else { return }
        if let revision {
            guard revision >= localInputAdmissionRevision else { return }
            localInputAdmissionRevision = revision
        } else {
            localInputAdmissionRevision &+= 1
        }
        let didChange = localInputAdmissionEnabled != enabled
        localInputAdmissionEnabled = enabled
        if negotiatedCapabilities.contains(.backgroundControl), didChange || revision != nil {
            discardPendingInputMessages()
        }
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
                        // The Host's local trust may auto-consent, but it must
                        // wait for the Viewer contribution and the Host reveal
                        // before the final code exists.
                        _ = try await sendPairingChallenge(
                            to: identity,
                            receiveGeneration: startReceiveGeneration,
                            reconnectGeneration: startReconnectGeneration,
                            authorizationGeneration: startAuthorizationGeneration
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
        let trustedPeerDisplayName = displayName ?? remotePeerDisplayName
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
                displayName: trustedPeerDisplayName
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
                displayName: trustedPeerDisplayName
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

    @discardableResult
    public func authorize(
        windowGeneration: UInt64? = nil,
        capabilities: Set<Capability>? = nil
    ) async throws -> SessionAuthorizationTransition {
        guard configuration.role == .host else {
            throw SessionError.invalidState(state)
        }
        let invocationReceiveGeneration = receiveGeneration
        let invocationReconnectGeneration = reconnectGeneration
        // Keep auth changes ordered while the receipt fence is open, but do
        // not hold outboundMutex while waiting for the peer's Pong. The
        // receive task may need that mutex to answer an earlier Ping.
#if DEBUG
        authorizationTransitionMutexWaitersForTesting += 1
#endif
        await authorizationTransitionMutex.acquire()
#if DEBUG
        authorizationTransitionMutexWaitersForTesting -= 1
#endif
        defer { authorizationTransitionMutex.release() }

        // Keep the invocation bound to the transport it entered on while it
        // waited for the transition mutex. A queued request must not rebind
        // itself to a replacement transport. Authorization generation is
        // read after the mutex so same-session requests still serialize.
        guard isCurrent(
            receiveGeneration: invocationReceiveGeneration,
            reconnectGeneration: invocationReconnectGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        let requestReceiveGeneration = invocationReceiveGeneration
        let requestReconnectGeneration = invocationReconnectGeneration
        let requestAuthorizationGeneration = authorizationGeneration
        guard state == .capabilitiesNegotiated || state == .windowSelectionAuthorized else {
            throw SessionError.invalidState(state)
        }
        let sessionGeneration = requestReconnectGeneration
        let sessionReceiveGeneration = requestReceiveGeneration
        let sessionAuthorizationGeneration = requestAuthorizationGeneration
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
        var holdsOutboundMutex = true
        defer {
            if holdsOutboundMutex {
                outboundMutex.release()
            }
        }
        guard isCurrent(
            receiveGeneration: sessionReceiveGeneration,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        let operationAuthorizationGeneration = sessionAuthorizationGeneration &+ 1
        authorizationGeneration = operationAuthorizationGeneration
        let authorizationReceiptEpoch = authorizationReceiptFence.beginLocalTransition()
        defer { authorizationReceiptFence.endLocalTransition(epoch: authorizationReceiptEpoch) }
        clearAuthorization()
        await transport.invalidateProtectedMessages()
        guard isCurrent(
            receiveGeneration: sessionReceiveGeneration,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: operationAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        do {
            _ = try await sendUnrestrictedAfterAdmission(
                .sessionAuthorize(authorization),
                flags: [],
                operationGeneration: sessionGeneration,
                operationReceiveGeneration: sessionReceiveGeneration,
                operationAuthorizationGeneration: operationAuthorizationGeneration
            )
            let receiptBarrier = try await enqueueAuthorizationReceiptBarrier(
                operationGeneration: sessionGeneration,
                operationReceiveGeneration: sessionReceiveGeneration,
                operationAuthorizationGeneration: operationAuthorizationGeneration
            )
            outboundMutex.release()
            holdsOutboundMutex = false
            try await awaitAuthorizationReceiptBarrier(
                nonce: receiptBarrier.nonce,
                sentAtUptimeNanoseconds: receiptBarrier.sentAtUptimeNanoseconds,
                operationGeneration: sessionGeneration,
                operationReceiveGeneration: sessionReceiveGeneration,
                operationAuthorizationGeneration: operationAuthorizationGeneration
            )
        } catch {
            let failure = authorizationTransitionFailure(for: error)
            if holdsOutboundMutex {
                outboundMutex.release()
                holdsOutboundMutex = false
            }
            await fail(
                failure,
                expectedReceiveGeneration: sessionReceiveGeneration,
                expectedReconnectGeneration: sessionGeneration,
                expectedAuthorizationGeneration: operationAuthorizationGeneration
            )
            throw failure
        }
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
        return SessionAuthorizationTransition(
            previousAuthorizationGeneration: sessionAuthorizationGeneration,
            authorizationGeneration: operationAuthorizationGeneration,
            reconnectGeneration: sessionGeneration,
            receiveGeneration: sessionReceiveGeneration
        )
    }

    public func revokeAuthorization() async throws {
        guard configuration.role == .host else {
            throw SessionError.invalidState(state)
        }
        await authorizationTransitionMutex.acquire()
        defer { authorizationTransitionMutex.release() }

        let requestReceiveGeneration = receiveGeneration
        let requestReconnectGeneration = reconnectGeneration
        let requestAuthorizationGeneration = authorizationGeneration

        guard isCurrent(
            receiveGeneration: requestReceiveGeneration,
            reconnectGeneration: requestReconnectGeneration,
            authorizationGeneration: requestAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        let sessionGeneration = requestReconnectGeneration
        let sessionReceiveGeneration = requestReceiveGeneration
        let sessionAuthorizationGeneration = requestAuthorizationGeneration
        await outboundMutex.acquire()
        var holdsOutboundMutex = true
        defer {
            if holdsOutboundMutex {
                outboundMutex.release()
            }
        }
        guard isCurrent(
            receiveGeneration: sessionReceiveGeneration,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: sessionAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }
        authorizationGeneration &+= 1
        let operationAuthorizationGeneration = authorizationGeneration
        let authorizationReceiptEpoch = authorizationReceiptFence.beginLocalTransition()
        defer { authorizationReceiptFence.endLocalTransition(epoch: authorizationReceiptEpoch) }
        clearAuthorization()
        await transport.invalidateProtectedMessages()
        guard isCurrent(
            receiveGeneration: sessionReceiveGeneration,
            reconnectGeneration: sessionGeneration,
            authorizationGeneration: operationAuthorizationGeneration
        ) else {
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
            let receiptBarrier = try await enqueueAuthorizationReceiptBarrier(
                operationGeneration: sessionGeneration,
                operationReceiveGeneration: sessionReceiveGeneration,
                operationAuthorizationGeneration: operationAuthorizationGeneration
            )
            outboundMutex.release()
            holdsOutboundMutex = false
            try await awaitAuthorizationReceiptBarrier(
                nonce: receiptBarrier.nonce,
                sentAtUptimeNanoseconds: receiptBarrier.sentAtUptimeNanoseconds,
                operationGeneration: sessionGeneration,
                operationReceiveGeneration: sessionReceiveGeneration,
                operationAuthorizationGeneration: operationAuthorizationGeneration
            )
        } catch {
            if holdsOutboundMutex {
                outboundMutex.release()
                holdsOutboundMutex = false
            }
            let failure = authorizationTransitionFailure(for: error)
            await fail(
                failure,
                expectedReceiveGeneration: sessionReceiveGeneration,
                expectedReconnectGeneration: sessionGeneration,
                expectedAuthorizationGeneration: operationAuthorizationGeneration
            )
            throw failure
        }
    }

    /// Returns `.replacedMedia` when the keyframe-aware media queue discarded
    /// video; a media sender should then force its next frame to a keyframe.
    @discardableResult
    public func send(
        _ payload: MessagePayload,
        flags: EnvelopeFlags = [],
        expectedAuthorizationGeneration: UInt64? = nil,
        localAdmission: (@MainActor @Sendable () -> Bool)? = nil
    ) async throws -> TransportSendResult {
        try validateMessageDirection(for: payload.messageType, incoming: false)
        try validateAuthorization(for: payload)
        guard let localAdmission else {
            return try await sendUnrestricted(
                payload,
                flags: flags,
                expectedAuthorizationGeneration: expectedAuthorizationGeneration
            )
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
        return try await sendUnrestrictedAfterAdmission(
            payload,
            flags: flags,
            operationGeneration: operationReconnectGeneration,
            operationReceiveGeneration: operationReceiveGeneration,
            operationAuthorizationGeneration: operationAuthorizationGeneration
        )
    }

    /// Viewer only: asks the Host to encode its next frame as a keyframe.
    ///
    /// Best-effort. Returns `false` without sending when the Host did not
    /// authorize `Capability.keyframeRequest` for the current window, when a
    /// request was sent within `keyframeRequestMinimumIntervalNanoseconds`,
    /// or when the send fails. A media sequence gap or a local media discard
    /// triggers this automatically; the app calls it after a decode failure.
    @discardableResult
    public func requestKeyframe(reason: KeyframeRequestReason) async -> Bool {
        guard configuration.role == .viewer,
              authorized,
              authorizedCapabilities.contains(.keyframeRequest),
              let generation = authorizedWindowGeneration else {
            return false
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if let last = lastKeyframeRequestNanoseconds,
           now &- last < Self.keyframeRequestMinimumIntervalNanoseconds {
            return false
        }
        lastKeyframeRequestNanoseconds = now
        do {
            _ = try await sendUnrestricted(
                .keyframeRequest(KeyframeRequestMessage(generation: generation, reason: reason))
            )
            return true
        } catch {
            return false
        }
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
        if negotiatedCapabilities.contains(.backgroundControl) {
            guard localInputAdmissionEnabled,
                  let admissionIndex = pendingInputAdmissions.firstIndex(where: { $0.input == input }) else {
                throw SessionError.authorizationChanged
            }
            guard input.controlGeneration == localInputAdmissionRevision else {
                throw SessionError.authorizationChanged
            }
            let admission = pendingInputAdmissions.remove(at: admissionIndex)
            guard admission.generation == localInputAdmissionGeneration else {
                throw SessionError.authorizationChanged
            }
        }
        try validateAuthorization(for: payload)
        return try operation()
    }

    /// Runs one actually received Host-side input-source selection while the
    /// session actor remains non-reentrant. The receive path creates a bounded
    /// lease with the authorization scope that was current when the message
    /// arrived. Reauthorization, even for the same window, invalidates that
    /// lease before an app callback can use it. A request ID is accepted only
    /// once and in increasing order within the current receive/reconnect
    /// session, including across same-session authorization, window, and
    /// input-discard invalidations. The ID is consumed before
    /// invoking `operation`, including when the platform operation fails.
    ///
    /// Use the returned authorization generation when sending the matching
    /// acknowledgement; a later authorization transition then rejects that
    /// send instead of attaching the result to a newer epoch.
    public func withIncomingInputSourceSelectionAdmission<T: Sendable>(
        for selection: InputSourceSelectionMessage,
        operation: @Sendable () throws -> T
    ) throws -> InputSourceSelectionAdmissionResult<T> {
        let payload = MessagePayload.inputSourceSelection(selection)
        try validateMessageDirection(for: payload.messageType, incoming: true)
        if negotiatedCapabilities.contains(.backgroundControl), !localInputAdmissionEnabled {
            throw SessionError.authorizationChanged
        }

        guard let leaseIndex = pendingInputSourceSelectionAdmissions.firstIndex(where: {
            $0.selection == selection
        }) else {
            throw SessionError.authorizationChanged
        }
        let lease = pendingInputSourceSelectionAdmissions.remove(at: leaseIndex)
        let scope = InputSourceSelectionAdmissionScope(
            receiveGeneration: receiveGeneration,
            reconnectGeneration: reconnectGeneration,
            authorizationGeneration: authorizationGeneration,
            discardGeneration: inputSourceSelectionDiscardGeneration,
            windowGeneration: selection.windowGeneration,
            localAdmissionGeneration: negotiatedCapabilities.contains(.backgroundControl)
                ? localInputAdmissionGeneration
                : nil,
            controlGeneration: negotiatedCapabilities.contains(.backgroundControl)
                ? selection.controlGeneration
                : nil
        )
        guard lease.scope == scope else {
            throw SessionError.authorizationChanged
        }
        if negotiatedCapabilities.contains(.backgroundControl) {
            guard localInputAdmissionEnabled,
                  selection.controlGeneration == localInputAdmissionRevision else {
                throw SessionError.authorizationChanged
            }
        }
        try validateAuthorization(for: payload)
        _ = try selection.encoded(using: effectiveProtocolLimits())

        if let previous = lastInputSourceSelectionRequest,
           previous.receiveGeneration == scope.receiveGeneration,
           previous.reconnectGeneration == scope.reconnectGeneration,
           selection.requestID <= previous.requestID {
            throw SessionError.replayDetected
        }
        lastInputSourceSelectionRequest = InputSourceSelectionRequestFence(
            receiveGeneration: scope.receiveGeneration,
            reconnectGeneration: scope.reconnectGeneration,
            requestID: selection.requestID
        )
        let value = try operation()
        return InputSourceSelectionAdmissionResult(
            value: value,
            authorizationGeneration: scope.authorizationGeneration,
            reconnectGeneration: scope.reconnectGeneration,
            windowGeneration: scope.windowGeneration,
            requestID: selection.requestID
        )
    }

    /// Issues an opaque admission for a Viewer input message.  The caller may
    /// do local encoding or UI work after this returns, but the token is
    /// single-epoch: a reconnect or authorization transition invalidates it.
    /// Supplying the epoch observed when input was queued rejects stale input
    /// before a token for a newer authorization can be issued.
    public func makeInputAdmission(
        for input: InputEventMessage,
        expectedAuthorizationGeneration: UInt64? = nil
    ) throws -> SessionInputAdmissionToken {
        let payload = MessagePayload.inputEvent(input)
        try validateMessageDirection(for: payload.messageType, incoming: false)
        if let expectedAuthorizationGeneration,
           expectedAuthorizationGeneration != authorizationGeneration {
            throw SessionError.authorizationChanged
        }
        try validateAuthorization(for: payload)
        let capabilities = requiredCapabilities(for: payload)
        guard !capabilities.isEmpty else {
            throw SessionError.unauthorizedMessage(.inputEvent)
        }
        return SessionInputAdmissionToken(
            receiveGeneration: receiveGeneration,
            reconnectGeneration: reconnectGeneration,
            authorizationGeneration: authorizationGeneration,
            windowGeneration: input.windowGeneration,
            capabilities: capabilities
        )
    }

    /// Admits and sends one Viewer input event under the same outbound mutex.
    /// The authorization and reconnect generations are checked both before
    /// admission and after the transport await, so a token issued for an old
    /// authorization epoch cannot enter a later epoch with the same window
    /// generation.
    public func sendInput(
        _ input: InputEventMessage,
        using admission: SessionInputAdmissionToken,
        observation: SessionInputSendObservation? = nil
    ) async throws {
        let payload = MessagePayload.inputEvent(input)
        try validateMessageDirection(for: payload.messageType, incoming: false)
        guard admission.windowGeneration == input.windowGeneration,
              admission.capabilities == requiredCapabilities(for: payload) else {
            observation?.markPreTransportRejection(.admissionTokenMismatch)
            throw SessionError.authorizationChanged
        }

        await outboundMutex.acquire()
        defer { outboundMutex.release() }
        guard admission.receiveGeneration == receiveGeneration,
              admission.reconnectGeneration == reconnectGeneration else {
            throw SessionError.reconnectRequired
        }
        guard admission.authorizationGeneration == authorizationGeneration else {
            observation?.markPreTransportRejection(.authorizationEpochChangedAfterAdmission)
            throw SessionError.authorizationChanged
        }
        try validateAuthorization(for: payload)
        _ = try await sendUnrestrictedAfterAdmission(
            payload,
            flags: [],
            operationGeneration: admission.reconnectGeneration,
            operationReceiveGeneration: admission.receiveGeneration,
            operationAuthorizationGeneration: admission.authorizationGeneration,
            inputSendObservation: observation
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
        authorizationReceiptFence.cancelLocalTransition()
        clearAuthorization()
        authorizationReceiptBarrierNonce = nil
        completedAuthorizationReceiptBarrierNonce = nil
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
        authorizationReceiptFence.cancelLocalTransition()
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
        let receiptFence = authorizationReceiptFence
        newTransport.incoming.installReceiptStampProvider { receiptFence.capture() }
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
        lastKeyframeRequestNanoseconds = nil
        congestionMonitor = ReceiverCongestionMonitor()
        pendingPing = nil
        authorizationReceiptBarrierNonce = nil
        completedAuthorizationReceiptBarrierNonce = nil
        clockSyncEstimator = ClockSyncEstimator()
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
        guard let commitment = challenge.commitment, commitment.count == PairingVerificationCode.commitmentByteCount else {
            throw SessionError.pairingFailed
        }
        let message = PairingChallengeMessage(
            challengeID: challenge.challengeID,
            commitment: commitment
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
            limits: configuration.limits,
            deviceName: configuration.deviceName
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
        expectedAuthorizationGeneration: UInt64? = nil,
        timestampNanoseconds: UInt64? = nil
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
            operationAuthorizationGeneration: operationAuthorizationGeneration,
            timestampNanoseconds: timestampNanoseconds
        )
    }

    private func sendUnrestrictedAfterAdmission(
        _ payload: MessagePayload,
        flags: EnvelopeFlags,
        operationGeneration: UInt64,
        operationReceiveGeneration: UInt64,
        operationAuthorizationGeneration: UInt64,
        timestampNanoseconds: UInt64? = nil,
        inputSendObservation: SessionInputSendObservation? = nil
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
            timestamp: timestampNanoseconds ?? DispatchTime.now().uptimeNanoseconds,
            limits: limits
        )
        let targetTransport = transport
        do {
            inputSendObservation?.markTransportSendStarted()
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
        let authorizationReceiptFence = self.authorizationReceiptFence
        receiveTask = Task { [weak self] in
            do {
                var iterator = stream.makeReceiptAwareAsyncIterator()
                while let item = try await iterator.next() {
                    await self?.handle(
                        item.envelope,
                        generation: generation,
                        reconnectGeneration: sessionGeneration,
                        authorizationReceiptStamp: item.receiptStamp ?? authorizationReceiptFence.capture()
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
        reconnectGeneration sessionGeneration: UInt64,
        authorizationReceiptStamp: AuthorizationReceiptStamp
    ) async {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration
        ) else { return }
        guard state != .stopping, state != .failed else { return }
        let operationAuthorizationGeneration = authorizationGeneration
        let inputSourceSelectionDiscardGenerationAtReceipt = inputSourceSelectionDiscardGeneration
        let localInputAdmissionGenerationAtReceipt = localInputAdmissionGeneration
        let localInputAdmissionRevisionAtReceipt = localInputAdmissionRevision
        let localInputAdmissionEnabledAtReceipt = localInputAdmissionEnabled
        do {
            try validateIncomingSequence(envelope)
            if case .unknown = envelope.messageType,
               !envelope.flags.contains(.mustUnderstand) {
                return
            }
            let receivedTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds
            if configuration.role == .viewer, envelope.messageType == .videoFrame {
                congestionMonitor.recordFrame(
                    senderTimestamp: envelope.timestamp,
                    receivedAt: receivedTimestampNanoseconds
                )
                sendReceiverReportIfDue(at: receivedTimestampNanoseconds)
            }
            let message = try envelope.decodedMessage(using: effectiveProtocolLimits())
            try await handle(
                message,
                generation: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGenerationAtReceipt: operationAuthorizationGeneration,
                authorizationReceiptStamp: authorizationReceiptStamp,
                inputSourceSelectionDiscardGenerationAtReceipt: inputSourceSelectionDiscardGenerationAtReceipt,
                localInputAdmissionGenerationAtReceipt: localInputAdmissionGenerationAtReceipt,
                localInputAdmissionRevisionAtReceipt: localInputAdmissionRevisionAtReceipt,
                localInputAdmissionEnabledAtReceipt: localInputAdmissionEnabledAtReceipt,
                senderTimestampNanoseconds: envelope.timestamp,
                receivedTimestampNanoseconds: receivedTimestampNanoseconds
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
        reconnectGeneration sessionGeneration: UInt64,
        authorizationGenerationAtReceipt: UInt64,
        authorizationReceiptStamp: AuthorizationReceiptStamp,
        inputSourceSelectionDiscardGenerationAtReceipt: UInt64,
        localInputAdmissionGenerationAtReceipt: UInt64,
        localInputAdmissionRevisionAtReceipt: UInt64,
        localInputAdmissionEnabledAtReceipt: Bool,
        senderTimestampNanoseconds: UInt64,
        receivedTimestampNanoseconds: UInt64
    ) async throws {
        guard isCurrent(
            receiveGeneration: generation,
            reconnectGeneration: sessionGeneration
        ) else { return }
        let operationAuthorizationGeneration = authorizationGeneration
        try validateMessageDirection(for: message.messageType, incoming: true)
        if configuration.role == .host,
           Self.protectedMessageTypes.contains(message.messageType),
           authorizationReceiptFence.shouldDiscardProtectedMessage(receivedAt: authorizationReceiptStamp) {
            // The Viewer can still be sending valid traffic from the previous
            // epoch until the replacement SessionAuthorize reaches it. Drop
            // protected payloads received during that transition or queued
            // for actor handling from an older epoch; sequence, schema, and
            // direction errors remain terminal, and traffic received outside
            // the transition still goes through ordinary authorization.
            return
        }
        if configuration.role == .host,
           negotiatedCapabilities.contains(.backgroundControl) {
            switch message {
            case let .inputEvent(input):
                // Pause/revoke drops P6 input in the same authenticated
                // session. The wire token also rejects messages already in
                // TCP or a callback queue when a later resume opens the gate.
                guard localInputAdmissionEnabledAtReceipt,
                      localInputAdmissionEnabled,
                      localInputAdmissionGenerationAtReceipt == localInputAdmissionGeneration,
                      localInputAdmissionRevisionAtReceipt == localInputAdmissionRevision,
                      input.controlGeneration == localInputAdmissionRevision else {
                    return
                }
            case let .inputSourceSelection(selection):
                // Source selection mutates the Host's global TIS state. Fence
                // it before authorization validation as well, so a stale
                // request cannot fail an otherwise healthy view-only session.
                guard localInputAdmissionEnabledAtReceipt,
                      localInputAdmissionEnabled,
                      localInputAdmissionGenerationAtReceipt == localInputAdmissionGeneration,
                      localInputAdmissionRevisionAtReceipt == localInputAdmissionRevision,
                      selection.controlGeneration == localInputAdmissionRevision else {
                    return
                }
            default:
                break
            }
        }
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
            guard let commitment = challenge.commitment else {
                throw SessionError.pairingFailed
            }
            let adoptedChallenge = try await pairingCoordinator.adoptRemoteSessionChallenge(
                challengeID: challenge.challengeID,
                from: peerIdentity,
                commitment: commitment,
                timeout: pairingTimeoutSeconds()
            )
            startPairingDeadline(expiresAt: adoptedChallenge.expiresAt)
            guard isCurrent(
                receiveGeneration: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            ) else { return }
            let response = try await pairingCoordinator.sessionResponse(
                challengeID: adoptedChallenge.challengeID,
                remoteIdentity: peerIdentity
            )
            _ = try await sendUnrestricted(
                .pairingResponse(
                    PairingResponseMessage(
                        challengeID: response.challengeID,
                        commitment: response.commitment
                    )
                ),
                expectedReceiveGeneration: generation,
                expectedReconnectGeneration: sessionGeneration,
                expectedAuthorizationGeneration: operationAuthorizationGeneration
            )
        case let .pairingResponse(response):
            guard state == .pairingRequired,
                  configuration.role == .host,
                  let peerIdentity,
                  let pairingCoordinator else {
                throw SessionError.pairingFailed
            }
            let verification = try await pairingCoordinator.prepareSessionVerification(
                challengeID: response.challengeID,
                remoteIdentity: peerIdentity,
                remoteCommitment: response.commitment
            )
            _ = try await sendUnrestricted(
                .pairingVerification(
                    PairingVerificationMessage(
                        challengeID: verification.challengeID,
                        contribution: verification.contribution
                    )
                ),
                expectedReceiveGeneration: generation,
                expectedReconnectGeneration: sessionGeneration,
                expectedAuthorizationGeneration: operationAuthorizationGeneration
            )
        case let .pairingVerification(verification):
            guard state == .pairingRequired,
                  configuration.role == .viewer,
                  let peerIdentity,
                  let pairingCoordinator else {
                throw SessionError.pairingFailed
            }
            let adoptedChallenge = try await pairingCoordinator.adoptRemoteSessionVerification(
                challengeID: verification.challengeID,
                from: peerIdentity,
                remoteContribution: verification.contribution
            )
            startPairingDeadline(expiresAt: adoptedChallenge.expiresAt)
            let reveal = try await pairingCoordinator.sessionReveal(
                challengeID: adoptedChallenge.challengeID,
                remoteIdentity: peerIdentity
            )
            _ = try await sendUnrestricted(
                .pairingReveal(
                    PairingRevealMessage(
                        challengeID: reveal.challengeID,
                        contribution: reveal.contribution
                    )
                ),
                expectedReceiveGeneration: generation,
                expectedReconnectGeneration: sessionGeneration,
                expectedAuthorizationGeneration: operationAuthorizationGeneration
            )
            if try await pairingCoordinator.trustDecision(for: peerIdentity) == .trusted {
                try await confirmPairing(
                    confirmationCode: adoptedChallenge.confirmationCode,
                    accepted: true,
                    displayName: remotePeerDisplayName
                )
            }
        case let .pairingReveal(reveal):
            guard state == .pairingRequired,
                  configuration.role == .host,
                  let peerIdentity,
                  let pairingCoordinator else {
                throw SessionError.pairingFailed
            }
            let adoptedChallenge = try await pairingCoordinator.adoptRemoteSessionReveal(
                challengeID: reveal.challengeID,
                from: peerIdentity,
                remoteContribution: reveal.contribution
            )
            startPairingDeadline(expiresAt: adoptedChallenge.expiresAt)
            if try await pairingCoordinator.trustDecision(for: peerIdentity) == .trusted {
                try await confirmPairing(
                    confirmationCode: adoptedChallenge.confirmationCode,
                    accepted: true,
                    displayName: remotePeerDisplayName
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
                .pong(
                    PongMessage(
                        nonce: ping.nonce,
                        receiverTimestampNanoseconds: receivedTimestampNanoseconds
                    )
                ),
                expectedReceiveGeneration: generation,
                expectedReconnectGeneration: sessionGeneration,
                expectedAuthorizationGeneration: operationAuthorizationGeneration
            )
        case let .pong(pong):
            if authorizationReceiptBarrierNonce == pong.nonce {
                authorizationReceiptBarrierNonce = nil
                completedAuthorizationReceiptBarrierNonce = pong.nonce
                return
            }
            guard let pendingProbe = pendingPing, pendingProbe.nonce == pong.nonce else {
                throw SessionError.replayDetected
            }
            pendingPing = nil
            lastHeartbeatAt = Date()
            if let remoteReceivedTimestamp = pong.receiverTimestampNanoseconds {
                let probe: ClockSyncProbe
                switch configuration.role {
                case .viewer:
                    // Viewer initiated the probe:
                    // Viewer V1 -> Host H2/H3 -> Viewer V4.
                    // ClockSyncProbe keeps the actual role timestamps and uses
                    // the direction to select the corresponding validation
                    // and round-trip formula.
                    probe = ClockSyncProbe(
                        hostSentNanoseconds: senderTimestampNanoseconds,
                        viewerReceivedNanoseconds: receivedTimestampNanoseconds,
                        viewerSentNanoseconds: pendingProbe.sentTimestampNanoseconds,
                        hostReceivedNanoseconds: remoteReceivedTimestamp,
                        direction: .viewerInitiated
                    )
                case .host:
                    // Host initiated the probe:
                    // Host H1 -> Viewer V2/V3 -> Host H4.
                    probe = ClockSyncProbe(
                        hostSentNanoseconds: pendingProbe.sentTimestampNanoseconds,
                        viewerReceivedNanoseconds: remoteReceivedTimestamp,
                        viewerSentNanoseconds: senderTimestampNanoseconds,
                        hostReceivedNanoseconds: receivedTimestampNanoseconds
                    )
                }
                if clockSyncEstimator.probeCount < Self.maximumClockSyncProbes {
                    _ = clockSyncEstimator.append(probe)
                }
            }
        case let .sessionState(sessionState):
            try await handleSessionState(
                sessionState,
                message: message,
                generation: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            )
        case let .inputSourceSelection(selection):
            guard authorizationGenerationAtReceipt == authorizationGeneration else {
                throw SessionError.authorizationChanged
            }
            guard inputSourceSelectionDiscardGenerationAtReceipt == inputSourceSelectionDiscardGeneration else {
                return
            }
            let requiresLocalAdmission = configuration.role == .host &&
                negotiatedCapabilities.contains(.backgroundControl)
            if requiresLocalAdmission {
                guard localInputAdmissionEnabledAtReceipt,
                      localInputAdmissionEnabled,
                      localInputAdmissionGenerationAtReceipt == localInputAdmissionGeneration,
                      localInputAdmissionRevisionAtReceipt == localInputAdmissionRevision,
                      selection.controlGeneration == localInputAdmissionRevision else {
                    return
                }
            }
            let scope = InputSourceSelectionAdmissionScope(
                receiveGeneration: generation,
                reconnectGeneration: sessionGeneration,
                authorizationGeneration: authorizationGenerationAtReceipt,
                discardGeneration: inputSourceSelectionDiscardGenerationAtReceipt,
                windowGeneration: selection.windowGeneration,
                localAdmissionGeneration: requiresLocalAdmission
                    ? localInputAdmissionGenerationAtReceipt
                    : nil,
                controlGeneration: requiresLocalAdmission ? selection.controlGeneration : nil
            )
            try publish(
                message,
                inputSourceSelectionScope: scope
            )
        case .inputEvent:
            if configuration.role == .host,
               negotiatedCapabilities.contains(.backgroundControl) {
                try publish(
                    message,
                    inputAdmissionGeneration: localInputAdmissionGenerationAtReceipt
                )
            } else {
                try publish(message)
            }
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
        authorizationReceiptFence.cancelLocalTransition()
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
            if envelope.sequence != previous + 1 {
                // The sender discarded media; its queue skips delta frames
                // until a keyframe, so ask for one instead of waiting for
                // the periodic keyframe.
                congestionMonitor.recordDiscarded(
                    envelope.sequence - previous - 1,
                    at: DispatchTime.now().uptimeNanoseconds
                )
                noteIncomingMediaGap()
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
        pendingInputAdmissions.removeAll(keepingCapacity: true)
        pendingInputSourceSelectionAdmissions.removeAll(keepingCapacity: true)
        localInputAdmissionGeneration &+= 1
        inputSourceSelectionDiscardGeneration &+= 1
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
        case .keyframeRequest:
            return [.h264Video, .keyframeRequest]
        case .receiverReport:
            return [.h264Video, .receiverReport]
        case let .inputEvent(input):
            let controlRequirement: Set<Capability> = negotiatedCapabilities.contains(.backgroundControl)
                ? [.backgroundControl]
                : []
            switch input.kind {
            case .keyDown, .keyUp:
                return Set<Capability>([.keyboardInput]).union(controlRequirement)
            case .pointerMove, .pointerButton, .scroll, .focusIntent:
                return Set<Capability>([.mouseInput]).union(controlRequirement)
            }
        case .inputSourceSelection, .inputSourceAcknowledgement:
            let controlRequirement: Set<Capability> = negotiatedCapabilities.contains(.backgroundControl)
                ? [.backgroundControl]
                : []
            return Set<Capability>([.keyboardInput, .inputSourceSync]).union(controlRequirement)
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
        case let .keyframeRequest(request):
            return request.generation
        case let .receiverReport(report):
            return report.generation
        case let .inputEvent(input):
            return input.windowGeneration
        case let .inputSourceSelection(selection):
            return selection.windowGeneration
        case let .inputSourceAcknowledgement(acknowledgement):
            return acknowledgement.windowGeneration
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

    private var remotePeerDisplayName: String {
        if let deviceName = peerHello?.deviceName,
           !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return deviceName
        }
        return configuration.role == .host ? "MacRemoteApp Viewer" : "MacRemoteApp Host"
    }

    private func publish(
        _ message: MessagePayload,
        inputSourceSelectionScope: InputSourceSelectionAdmissionScope? = nil,
        inputAdmissionGeneration: UInt64? = nil
    ) throws {
        if inputSourceSelectionScope != nil {
            guard configuration.role == .host,
                  pendingInputSourceSelectionAdmissions.count < Self.inputSourceSelectionAdmissionCapacity else {
                throw SessionError.incomingMessageBackpressure(.control)
            }
        }
        if inputAdmissionGeneration != nil {
            guard configuration.role == .host,
                  pendingInputAdmissions.count < Self.incomingControlMessageCapacity else {
                throw SessionError.incomingMessageBackpressure(.control)
            }
        }
        do {
            let result = try incomingMessageStorage.yield(message)
            if let inputSourceSelectionScope,
               case let .inputSourceSelection(selection) = message {
                pendingInputSourceSelectionAdmissions.append(
                    PendingInputSourceSelectionAdmission(
                        selection: selection,
                        scope: inputSourceSelectionScope
                    )
                )
            }
            if let inputAdmissionGeneration,
               case let .inputEvent(input) = message {
                pendingInputAdmissions.append(
                    PendingInputAdmission(
                        input: input,
                        generation: inputAdmissionGeneration
                    )
                )
            }
            if result == .replacedMedia {
                congestionMonitor.recordDiscarded(1, at: DispatchTime.now().uptimeNanoseconds)
                noteIncomingMediaGap()
            }
        } catch TransportError.controlBackpressure {
            throw SessionError.incomingMessageBackpressure(.control)
        } catch TransportError.mediaBackpressure {
            throw SessionError.incomingMessageBackpressure(.media)
        }
    }

    /// Viewer only: sends congestion feedback about every 500 ms while video
    /// arrives, when the Host authorized `Capability.receiverReport`. Sent
    /// from a separate task for the same reason as `noteIncomingMediaGap`.
    private func sendReceiverReportIfDue(at now: UInt64) {
        guard configuration.role == .viewer,
              authorized,
              authorizedCapabilities.contains(.receiverReport),
              let generation = authorizedWindowGeneration,
              let report = congestionMonitor.takeReport(generation: generation, at: now) else {
            return
        }
        Task { [weak self] in
            _ = try? await self?.sendUnrestricted(.receiverReport(report))
        }
    }

    /// Sends from a separate task: the receive path must not wait on the
    /// outbound mutex while it is validating an incoming envelope.
    private func noteIncomingMediaGap() {
        guard configuration.role == .viewer else { return }
        Task { [weak self] in
            await self?.requestKeyframe(reason: .mediaGap)
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

    /// Enqueues a control Ping after SessionAuthorize while the caller owns
    /// outboundMutex. The returned Ping must be answered before the caller
    /// ends the receipt fence.
    private func enqueueAuthorizationReceiptBarrier(
        operationGeneration: UInt64,
        operationReceiveGeneration: UInt64,
        operationAuthorizationGeneration: UInt64
    ) async throws -> (nonce: UInt64, sentAtUptimeNanoseconds: UInt64) {
        guard isCurrent(
            receiveGeneration: operationReceiveGeneration,
            reconnectGeneration: operationGeneration,
            authorizationGeneration: operationAuthorizationGeneration
        ) else {
            throw SessionError.reconnectRequired
        }

        // pingPong negotiates periodic heartbeats. The current protocol
        // receive path still answers one-shot control Pings without that
        // capability; if a peer does not answer, this transition fails closed.
        // In particular, local queue admission never ends the receipt fence.

        var nonce = nextPingNonce
        if pendingPing?.nonce == nonce {
            nonce = nonce == UInt64.max ? 1 : nonce + 1
        }
        nextPingNonce = nonce == UInt64.max ? 1 : nonce + 1
        authorizationReceiptBarrierNonce = nonce
        completedAuthorizationReceiptBarrierNonce = nil
        let sentAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await sendUnrestrictedAfterAdmission(
                .ping(PingMessage(nonce: nonce)),
                flags: [],
                operationGeneration: operationGeneration,
                operationReceiveGeneration: operationReceiveGeneration,
                operationAuthorizationGeneration: operationAuthorizationGeneration
            )
        } catch {
            clearAuthorizationReceiptBarrier(nonce: nonce)
            throw error
        }
        return (nonce, sentAtUptimeNanoseconds)
    }

    /// Waits until the Viewer has processed the ordered authorization message.
    /// NetworkFramedTransport.send only confirms local queue admission, so a
    /// Pong to the later control Ping is the receipt boundary that lets the
    /// Host release its stale-message fence. The caller must not own
    /// outboundMutex while this wait is in progress.
    private func awaitAuthorizationReceiptBarrier(
        nonce: UInt64,
        sentAtUptimeNanoseconds: UInt64,
        operationGeneration: UInt64,
        operationReceiveGeneration: UInt64,
        operationAuthorizationGeneration: UInt64
    ) async throws {
        defer { clearAuthorizationReceiptBarrier(nonce: nonce) }
        let timeoutNanoseconds = configuration.heartbeatTimeoutNanoseconds
        let pollIntervalNanoseconds: UInt64 = 10_000_000
        while true {
            guard isCurrent(
                receiveGeneration: operationReceiveGeneration,
                reconnectGeneration: operationGeneration,
                authorizationGeneration: operationAuthorizationGeneration
            ), state != .stopping, state != .failed else {
                throw SessionError.reconnectRequired
            }
            if completedAuthorizationReceiptBarrierNonce == nonce {
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsedNanoseconds = now &- sentAtUptimeNanoseconds
            guard elapsedNanoseconds < timeoutNanoseconds else {
                throw SessionError.authorizationReceiptTimeout
            }
            let remainingNanoseconds = timeoutNanoseconds - elapsedNanoseconds
            try await Task.sleep(
                nanoseconds: min(pollIntervalNanoseconds, remainingNanoseconds)
            )
        }
    }

    private func clearAuthorizationReceiptBarrier(nonce: UInt64) {
        if authorizationReceiptBarrierNonce == nonce {
            authorizationReceiptBarrierNonce = nil
        }
        if completedAuthorizationReceiptBarrierNonce == nonce {
            completedAuthorizationReceiptBarrierNonce = nil
        }
    }

    private func authorizationTransitionFailure(for error: Error) -> SessionError {
        if let sessionError = error as? SessionError {
            return sessionError
        }
        if error is CancellationError {
            return .reconnectRequired
        }
        return .transportFailure(String(describing: error))
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
        let sleep = pairingDeadlineSleep
        pairingDeadlineTask = Task { [weak self] in
            do {
                try await sleep(nanoseconds)
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
        // A pre-transition heartbeat Pong may still be in flight, but no new
        // heartbeat may overtake the authorization receipt barrier.
        if authorizationReceiptFence.capture().transitionInFlight { return }
        guard pendingPing == nil else { return }
        let nonce = nextPingNonce
        nextPingNonce = nextPingNonce == UInt64.max ? 1 : nextPingNonce + 1
        let sentTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds
        pendingPing = (
            nonce: nonce,
            sentAt: now,
            sentTimestampNanoseconds: sentTimestampNanoseconds
        )
        do {
            _ = try await sendUnrestricted(
                .ping(PingMessage(nonce: nonce)),
                expectedReceiveGeneration: sessionReceiveGeneration,
                expectedReconnectGeneration: sessionReconnectGeneration,
                expectedAuthorizationGeneration: sessionAuthorizationGeneration,
                timestampNanoseconds: sentTimestampNanoseconds
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
            .transportEOF,
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
        authorizationReceiptFence.cancelLocalTransition()
        clearAuthorization()
        authorizationReceiptBarrierNonce = nil
        completedAuthorizationReceiptBarrierNonce = nil
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
