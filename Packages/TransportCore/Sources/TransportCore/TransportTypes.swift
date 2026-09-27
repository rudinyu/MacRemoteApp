@preconcurrency import Network
import Foundation
import RemoteProtocol
import SecurityCore

public enum TransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case notStarted
    case alreadyClosed
    case connectionFailed(String)
    case connectionTimeout
    case controlBackpressure
    case mediaBackpressure
    case malformedFrame
    case authenticationRequired
    case authenticationFailed
    case pairingRequired
    case identityMismatch
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .notStarted: return "transport has not started"
        case .alreadyClosed: return "transport is closed"
        case let .connectionFailed(detail): return "connection failed: \(detail)"
        case .connectionTimeout: return "connection establishment timed out"
        case .controlBackpressure: return "control queue is full"
        case .mediaBackpressure: return "required media queue is full"
        case .malformedFrame: return "malformed transport frame"
        case .authenticationRequired: return "authenticated transport is required"
        case .authenticationFailed: return "transport authentication failed"
        case .pairingRequired: return "peer pairing is required"
        case .identityMismatch: return "peer identity mismatch"
        case let .protocolViolation(detail): return "protocol violation: \(detail)"
        }
    }
}

public enum TransportLifecycleState: Equatable, Sendable {
    case idle
    case starting
    case ready
    case closing
    case closed
    case failed(String)
}

public enum PeerAuthenticationState: Equatable, Sendable {
    case pending
    case pairingRequired(PeerIdentity)
    case trusted(PeerIdentity)
    case rejected
}

public enum TransportSendResult: Equatable, Sendable {
    case queued
    /// Media was discarded and the keyframe-aware queue now skips delta
    /// frames until the next keyframe, so a sender should force one to end
    /// the gap quickly.
    case replacedMedia
}

public struct BonjourConfiguration: Equatable, Sendable {
    public static let `default` = BonjourConfiguration()

    public let serviceType: String
    public let domain: String

    public init(serviceType: String = "_macremote._tcp", domain: String = "local.") {
        self.serviceType = serviceType
        self.domain = domain
    }
}

public struct DiscoveredService: @unchecked Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let type: String
    public let domain: String

    public let endpoint: NWEndpoint

    public init(
        identifier: String,
        name: String,
        type: String,
        domain: String,
        endpoint: NWEndpoint
    ) {
        self.identifier = identifier
        self.name = name
        self.type = type
        self.domain = domain
        self.endpoint = endpoint
    }

    public static func == (lhs: DiscoveredService, rhs: DiscoveredService) -> Bool {
        lhs.identifier == rhs.identifier &&
            lhs.name == rhs.name &&
            lhs.type == rhs.type &&
            lhs.domain == rhs.domain
    }
}

public struct TransportSnapshot: Equatable, Sendable {
    public let state: TransportLifecycleState
    public let queuedControlFrames: Int
    public let queuedMediaFrames: Int
    public let authentication: PeerAuthenticationState

    public init(
        state: TransportLifecycleState,
        queuedControlFrames: Int,
        queuedMediaFrames: Int,
        authentication: PeerAuthenticationState
    ) {
        self.state = state
        self.queuedControlFrames = queuedControlFrames
        self.queuedMediaFrames = queuedMediaFrames
        self.authentication = authentication
    }
}

public protocol SessionTransport: AnyObject, Sendable {
    var incoming: EnvelopeStream { get }

    func start() async throws
    func send(_ envelope: Envelope) async throws -> TransportSendResult
    /// Drops protected payloads that have not yet been delivered. A frame
    /// already handed to Network.framework cannot be recalled; an admitted
    /// protected control envelope is replaced with an optional tombstone so
    /// strict control sequencing remains valid.
    func invalidateProtectedMessages() async
    func close() async
    func authentication() async -> PeerAuthenticationState
    func snapshot() async -> TransportSnapshot
}
