import Foundation

public struct ProtocolVersion: Equatable, Hashable, Sendable {
    public let major: UInt8
    public let minor: UInt8

    /// M10 changes the pairing challenge from the legacy confirmation-code
    /// exchange to a mandatory commit/reveal flow. Keep that wire break
    /// explicit so a 1.x peer is rejected before any pairing payload is
    /// interpreted.
    public static let current = ProtocolVersion(major: 2, minor: 0)

    public init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }

    public func isCompatible(with supportedVersion: ProtocolVersion = .current) -> Bool {
        major == supportedVersion.major && minor <= supportedVersion.minor
    }
}

public enum Channel: UInt8, Equatable, Hashable, Sendable {
    case control = 0
    case media = 1
}

public struct EnvelopeFlags: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let keyframe = EnvelopeFlags(rawValue: 1 << 0)
    public static let acknowledgement = EnvelopeFlags(rawValue: 1 << 1)
    public static let endOfStream = EnvelopeFlags(rawValue: 1 << 2)
    public static let mustUnderstand = EnvelopeFlags(rawValue: 1 << 3)

    public static let knownMask: EnvelopeFlags = [
        .keyframe,
        .acknowledgement,
        .endOfStream,
        .mustUnderstand
    ]

    public var containsUnknownBits: Bool {
        rawValue & ~Self.knownMask.rawValue != 0
    }
}

public enum MessageType: Equatable, Hashable, Sendable {
    case hello
    case capabilities
    case pairingChallenge
    case pairingConfirmation
    case pairingResponse
    case pairingVerification
    case pairingReveal
    case sessionAuthorize
    case windowList
    case windowSelection
    case streamConfig
    case videoConfig
    case videoFrame
    case inputEvent
    case clipboardOffer
    case clipboardText
    case clipboardAcknowledgement
    case ping
    case pong
    case sessionState
    case error
    case close
    case keyframeRequest
    case unknown(UInt16)

    public init(rawValue: UInt16) {
        switch rawValue {
        case 0x0001: self = .hello
        case 0x0002: self = .capabilities
        case 0x0003: self = .pairingChallenge
        case 0x0004: self = .pairingConfirmation
        case 0x0014: self = .pairingResponse
        case 0x0015: self = .pairingVerification
        case 0x0016: self = .pairingReveal
        case 0x0005: self = .sessionAuthorize
        case 0x0006: self = .windowList
        case 0x0007: self = .windowSelection
        case 0x0008: self = .streamConfig
        case 0x0009: self = .videoConfig
        case 0x000A: self = .videoFrame
        case 0x000B: self = .inputEvent
        case 0x000C: self = .clipboardOffer
        case 0x000D: self = .clipboardText
        case 0x0013: self = .clipboardAcknowledgement
        case 0x000E: self = .ping
        case 0x000F: self = .pong
        case 0x0010: self = .sessionState
        case 0x0011: self = .error
        case 0x0012: self = .close
        case 0x0017: self = .keyframeRequest
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt16 {
        switch self {
        case .hello: return 0x0001
        case .capabilities: return 0x0002
        case .pairingChallenge: return 0x0003
        case .pairingConfirmation: return 0x0004
        case .pairingResponse: return 0x0014
        case .pairingVerification: return 0x0015
        case .pairingReveal: return 0x0016
        case .sessionAuthorize: return 0x0005
        case .windowList: return 0x0006
        case .windowSelection: return 0x0007
        case .streamConfig: return 0x0008
        case .videoConfig: return 0x0009
        case .videoFrame: return 0x000A
        case .inputEvent: return 0x000B
        case .clipboardOffer: return 0x000C
        case .clipboardText: return 0x000D
        case .clipboardAcknowledgement: return 0x0013
        case .ping: return 0x000E
        case .pong: return 0x000F
        case .sessionState: return 0x0010
        case .error: return 0x0011
        case .close: return 0x0012
        case .keyframeRequest: return 0x0017
        case let .unknown(rawValue): return rawValue
        }
    }

    public var defaultChannel: Channel {
        switch self {
        case .videoConfig, .videoFrame:
            return .media
        default:
            return .control
        }
    }
}

public enum DeviceRole: UInt8, Equatable, Hashable, Sendable {
    case host = 1
    case viewer = 2
}

public enum Capability: Equatable, Hashable, Sendable {
    case h264Video
    case windowSelection
    case mouseInput
    case keyboardInput
    case textClipboard
    case pingPong
    /// Optional: the Viewer may send `KeyframeRequest`. Peers that do not
    /// advertise it never receive the message.
    case keyframeRequest
    case unknown(UInt16)

    public init(rawValue: UInt16) {
        switch rawValue {
        case 0x0001: self = .h264Video
        case 0x0002: self = .windowSelection
        case 0x0003: self = .mouseInput
        case 0x0004: self = .keyboardInput
        case 0x0005: self = .textClipboard
        case 0x0006: self = .pingPong
        case 0x0007: self = .keyframeRequest
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt16 {
        switch self {
        case .h264Video: return 0x0001
        case .windowSelection: return 0x0002
        case .mouseInput: return 0x0003
        case .keyboardInput: return 0x0004
        case .textClipboard: return 0x0005
        case .pingPong: return 0x0006
        case .keyframeRequest: return 0x0007
        case let .unknown(rawValue): return rawValue
        }
    }
}

/// Why a Viewer asks the Host for a new keyframe. Diagnostic only; the Host
/// treats every reason the same way.
public enum KeyframeRequestReason: UInt8, Equatable, Hashable, Sendable {
    /// A media sequence gap or local queue discard; delta frames are being
    /// skipped until the next keyframe.
    case mediaGap = 1
    /// The decoder rejected a frame.
    case decodeFailure = 2
}

/// The reason attached to a clipboard offer acknowledgement is deliberately
/// a bounded enum. It never carries clipboard text or an untrusted diagnostic.
public enum ClipboardAcknowledgementReason: UInt8, Equatable, Hashable, Sendable {
    case accepted = 1
    case disabled = 2
    case tooLarge = 3
    case conflict = 4
    case stale = 5
    case unsupported = 6
}

public enum CodecIdentifier: UInt16, Equatable, Hashable, Sendable {
    case h264 = 1
}

public enum InputEventKind: UInt8, Equatable, Hashable, Sendable {
    case pointerMove = 1
    case pointerButton = 2
    case scroll = 3
    case keyDown = 4
    case keyUp = 5
    case focusIntent = 6
}

public enum SessionState: UInt8, Equatable, Hashable, Sendable {
    case discovered = 1
    case connecting = 2
    case authenticated = 3
    case pairingRequired = 4
    case trusted = 5
    case capabilitiesNegotiated = 6
    case windowSelectionAuthorized = 7
    case streaming = 8
    case stopping = 9
    case reconnecting = 10
    case failed = 11
}

public enum PermissionState: UInt8, Equatable, Hashable, Sendable {
    case unknown = 0
    case missing = 1
    case granted = 2
    case revoked = 3
}

public enum ErrorCode: UInt16, Equatable, Hashable, Sendable {
    case unsupportedVersion = 1
    case authenticationFailed = 2
    case pairingRequired = 3
    case authorizationDenied = 4
    case permissionMissing = 5
    case windowUnavailable = 6
    case codecNotSupported = 7
    case messageTooLarge = 8
    case invalidSequence = 9
    case backpressure = 10
    case transportClosed = 11
    case internalFailure = 12
}

public enum CloseReason: UInt16, Equatable, Hashable, Sendable {
    case normal = 1
    case permissionRevoked = 2
    case authorizationLost = 3
    case protocolError = 4
    case shutdown = 5
    case replaced = 6
}

public struct ProtocolLimits: Equatable, Sendable {
    public static let `default` = ProtocolLimits()
    public static let clipboardTextPayloadOverhead = 21

    public let maxPayloadLength: Int
    public let maxControlPayloadLength: Int
    public let maxClipboardTextBytes: Int
    public let maxFieldLength: Int
    public let maxIdentifierBytes: Int
    public let maxWindowEntries: Int
    public let maxCapabilities: Int

    public init(
        maxPayloadLength: Int = 1_048_576,
        maxControlPayloadLength: Int = 65_536,
        maxClipboardTextBytes: Int = 65_515,
        maxFieldLength: Int = 1_048_576,
        maxIdentifierBytes: Int = 256,
        maxWindowEntries: Int = 256,
        maxCapabilities: Int = 128
    ) {
        self.maxPayloadLength = maxPayloadLength
        self.maxControlPayloadLength = maxControlPayloadLength
        self.maxClipboardTextBytes = maxClipboardTextBytes
        self.maxFieldLength = maxFieldLength
        self.maxIdentifierBytes = maxIdentifierBytes
        self.maxWindowEntries = maxWindowEntries
        self.maxCapabilities = maxCapabilities
    }

    internal var isSane: Bool {
        maxPayloadLength >= 0 &&
            maxControlPayloadLength >= 0 &&
            maxClipboardTextBytes >= 0 &&
            maxFieldLength >= 0 &&
            maxIdentifierBytes >= 0 &&
            maxWindowEntries >= 0 &&
            maxCapabilities >= 0 &&
            maxControlPayloadLength >= Self.clipboardTextPayloadOverhead &&
            maxControlPayloadLength <= maxPayloadLength &&
            maxClipboardTextBytes <= maxPayloadLength &&
            maxClipboardTextBytes <= maxControlPayloadLength - Self.clipboardTextPayloadOverhead &&
            maxFieldLength <= maxPayloadLength &&
            maxPayloadLength <= Int(UInt32.max)
    }
}

public enum ProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidLimits
    case invalidMagic
    case truncated(expected: Int, actual: Int)
    case trailingBytes(count: Int)
    case unsupportedVersion(major: UInt8, minor: UInt8)
    case invalidChannel(rawValue: UInt8)
    case unknownFlags(rawValue: UInt16)
    case unknownMandatoryMessageType(rawValue: UInt16)
    case unknownMandatoryCapability(rawValue: UInt16)
    case invalidPayloadLength(rawValue: UInt32)
    case payloadTooLarge(actual: Int, maximum: Int)
    case controlPayloadTooLarge(actual: Int, maximum: Int)
    case invalidSequence(expected: UInt64, actual: UInt64)
    case sequenceOverflow
    case invalidSchemaVersion(message: MessageType, rawValue: UInt8)
    case unknownMandatoryField(message: MessageType, fieldID: UInt8)
    case unknownFieldFlags(message: MessageType, fieldID: UInt8, rawValue: UInt8)
    case duplicateField(message: MessageType, fieldID: UInt8)
    case fieldsOutOfOrder(message: MessageType, previous: UInt8, current: UInt8)
    case missingRequiredField(message: MessageType, fieldID: UInt8)
    case invalidFieldValue(message: MessageType, fieldID: UInt8)
    case invalidUTF8(message: MessageType, fieldID: UInt8)
    case invalidCount(message: MessageType, fieldID: UInt8)
    case unsupportedMessageType(rawValue: UInt16)

    public var description: String {
        switch self {
        case .invalidLimits: return "protocol limits are invalid"
        case .invalidMagic: return "invalid protocol magic"
        case let .truncated(expected, actual): return "truncated frame: expected at least \(expected) bytes, received \(actual)"
        case let .trailingBytes(count): return "frame contains \(count) trailing bytes"
        case let .unsupportedVersion(major, minor): return "unsupported protocol version \(major).\(minor)"
        case let .invalidChannel(rawValue): return "invalid channel \(rawValue)"
        case let .unknownFlags(rawValue): return "unknown envelope flags 0x\(String(rawValue, radix: 16))"
        case let .unknownMandatoryMessageType(rawValue): return "unknown mandatory message type 0x\(String(rawValue, radix: 16))"
        case let .unknownMandatoryCapability(rawValue): return "unknown mandatory capability 0x\(String(rawValue, radix: 16))"
        case let .invalidPayloadLength(rawValue): return "invalid payload length \(rawValue)"
        case let .payloadTooLarge(actual, maximum): return "payload length \(actual) exceeds maximum \(maximum)"
        case let .controlPayloadTooLarge(actual, maximum): return "control payload length \(actual) exceeds maximum \(maximum)"
        case let .invalidSequence(expected, actual): return "invalid sequence: expected \(expected), received \(actual)"
        case .sequenceOverflow: return "sequence number overflow"
        case let .invalidSchemaVersion(message, rawValue): return "invalid schema version \(rawValue) for \(message)"
        case let .unknownMandatoryField(message, fieldID): return "unknown mandatory field \(fieldID) for \(message)"
        case let .unknownFieldFlags(message, fieldID, rawValue): return "unknown flags 0x\(String(rawValue, radix: 16)) for field \(fieldID) of \(message)"
        case let .duplicateField(message, fieldID): return "duplicate field \(fieldID) for \(message)"
        case let .fieldsOutOfOrder(message, previous, current): return "fields out of order for \(message): \(previous) then \(current)"
        case let .missingRequiredField(message, fieldID): return "missing required field \(fieldID) for \(message)"
        case let .invalidFieldValue(message, fieldID): return "invalid value for field \(fieldID) of \(message)"
        case let .invalidUTF8(message, fieldID): return "invalid UTF-8 in field \(fieldID) of \(message)"
        case let .invalidCount(message, fieldID): return "invalid count in field \(fieldID) of \(message)"
        case let .unsupportedMessageType(rawValue): return "unsupported message type 0x\(String(rawValue, radix: 16))"
        }
    }
}
