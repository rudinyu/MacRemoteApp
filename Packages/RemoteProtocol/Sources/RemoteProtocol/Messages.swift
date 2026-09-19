import Foundation

public protocol MessagePayloadValue: Equatable, Sendable {
    static var messageType: MessageType { get }

    func encoded(using limits: ProtocolLimits) throws -> Data
    static func decode(_ data: Data, using limits: ProtocolLimits) throws -> Self
}

public struct HelloMessage: MessagePayloadValue {
    public static let messageType: MessageType = .hello

    public let protocolVersion: ProtocolVersion
    public let role: DeviceRole
    public let implementationIdentifier: String
    public let limits: ProtocolLimits

    public init(
        protocolVersion: ProtocolVersion,
        role: DeviceRole,
        implementationIdentifier: String,
        limits: ProtocolLimits
    ) {
        self.protocolVersion = protocolVersion
        self.role = role
        self.implementationIdentifier = implementationIdentifier
        self.limits = limits
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .hello, limits: limits)
        var version = WireWriter()
        version.appendByte(protocolVersion.major)
        version.appendByte(protocolVersion.minor)
        try fields.append(fieldID: 1, mandatory: true, value: version.data)
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.byte(role.rawValue, message: .hello, fieldID: 2))
        try fields.append(
            fieldID: 3,
            mandatory: true,
            value: try WireValue.string(
                implementationIdentifier,
                message: .hello,
                fieldID: 3,
                maximumBytes: limits.maxIdentifierBytes
            )
        )
        guard limits.isSane, self.limits.isSane else {
            throw ProtocolError.invalidLimits
        }
        try fields.append(fieldID: 4, mandatory: true, value: WireValue.uint32(UInt32(self.limits.maxPayloadLength)))
        try fields.append(fieldID: 5, mandatory: true, value: WireValue.uint32(UInt32(self.limits.maxControlPayloadLength)))
        try fields.append(fieldID: 6, mandatory: true, value: WireValue.uint32(UInt32(self.limits.maxClipboardTextBytes)))
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> HelloMessage {
        let fields = try MessageFieldReader(data: data, message: .hello, limits: limits)
        try fields.ensureKnown(Set(1 ... 6))
        let versionData = try fields.required(1)
        guard versionData.count == 2 else {
            throw ProtocolError.invalidFieldValue(message: .hello, fieldID: 1)
        }
        let version = ProtocolVersion(major: versionData[0], minor: versionData[1])
        guard let role = DeviceRole(rawValue: try WireValue.decodeByte(try fields.required(2), message: .hello, fieldID: 2)) else {
            throw ProtocolError.invalidFieldValue(message: .hello, fieldID: 2)
        }
        let identifier = try WireValue.decodeString(
            try fields.required(3),
            message: .hello,
            fieldID: 3,
            maximumBytes: limits.maxIdentifierBytes
        )
        let maxPayload = Int(try WireValue.decodeUInt32(try fields.required(4), message: .hello, fieldID: 4))
        let maxControlPayload = Int(try WireValue.decodeUInt32(try fields.required(5), message: .hello, fieldID: 5))
        let maxClipboard = Int(try WireValue.decodeUInt32(try fields.required(6), message: .hello, fieldID: 6))
        let advertisedLimits = ProtocolLimits(
            maxPayloadLength: maxPayload,
            maxControlPayloadLength: maxControlPayload,
            maxClipboardTextBytes: maxClipboard,
            maxFieldLength: min(maxPayload, ProtocolLimits.default.maxFieldLength),
            maxIdentifierBytes: limits.maxIdentifierBytes,
            maxWindowEntries: limits.maxWindowEntries,
            maxCapabilities: limits.maxCapabilities
        )
        guard advertisedLimits.isSane else {
            throw ProtocolError.invalidFieldValue(message: .hello, fieldID: 4)
        }
        return HelloMessage(
            protocolVersion: version,
            role: role,
            implementationIdentifier: identifier,
            limits: advertisedLimits
        )
    }
}

public struct CapabilitiesMessage: MessagePayloadValue {
    public static let messageType: MessageType = .capabilities

    public let capabilities: [Capability]
    public let mandatoryCapabilities: Set<Capability>
    public let maxVideoWidth: UInt32?
    public let maxVideoHeight: UInt32?
    public let maxFrameRate: UInt16?

    public init(
        capabilities: [Capability],
        maxVideoWidth: UInt32? = nil,
        maxVideoHeight: UInt32? = nil,
        maxFrameRate: UInt16? = nil,
        mandatoryCapabilities: Set<Capability> = []
    ) {
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.mandatoryCapabilities = mandatoryCapabilities
        self.maxVideoWidth = maxVideoWidth
        self.maxVideoHeight = maxVideoHeight
        self.maxFrameRate = maxFrameRate
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .capabilities, limits: limits)
        try fields.append(
            fieldID: 1,
            mandatory: true,
            value: try CapabilityCodec.encode(
                capabilities,
                message: .capabilities,
                fieldID: 1,
                limits: limits,
                mandatory: mandatoryCapabilities
            )
        )
        if let maxVideoWidth {
            try fields.append(fieldID: 2, mandatory: false, value: WireValue.uint32(maxVideoWidth))
        }
        if let maxVideoHeight {
            try fields.append(fieldID: 3, mandatory: false, value: WireValue.uint32(maxVideoHeight))
        }
        if let maxFrameRate {
            try fields.append(fieldID: 4, mandatory: false, value: WireValue.uint16(maxFrameRate))
        }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> CapabilitiesMessage {
        let fields = try MessageFieldReader(data: data, message: .capabilities, limits: limits)
        try fields.ensureKnown(Set(1 ... 4))
        let decodedCapabilities = try CapabilityCodec.decode(
                try fields.required(1),
                message: .capabilities,
                fieldID: 1,
                limits: limits
            )
        return CapabilitiesMessage(
            capabilities: decodedCapabilities.capabilities,
            maxVideoWidth: try fields.optional(2).map {
                try WireValue.decodeUInt32($0, message: .capabilities, fieldID: 2)
            },
            maxVideoHeight: try fields.optional(3).map {
                try WireValue.decodeUInt32($0, message: .capabilities, fieldID: 3)
            },
            maxFrameRate: try fields.optional(4).map {
                try WireValue.decodeUInt16($0, message: .capabilities, fieldID: 4)
            },
            mandatoryCapabilities: decodedCapabilities.mandatoryCapabilities
        )
    }
}

public struct PairingChallengeMessage: MessagePayloadValue {
    public static let messageType: MessageType = .pairingChallenge

    public let challengeID: UInt64
    public let confirmationCode: String

    public init(challengeID: UInt64, confirmationCode: String) {
        self.challengeID = challengeID
        self.confirmationCode = confirmationCode
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .pairingChallenge, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(challengeID))
        try fields.append(
            fieldID: 2,
            mandatory: true,
            value: try WireValue.string(
                confirmationCode,
                message: .pairingChallenge,
                fieldID: 2,
                maximumBytes: limits.maxIdentifierBytes
            )
        )
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> PairingChallengeMessage {
        let fields = try MessageFieldReader(data: data, message: .pairingChallenge, limits: limits)
        try fields.ensureKnown(Set(1 ... 2))
        return PairingChallengeMessage(
            challengeID: try WireValue.decodeUInt64(try fields.required(1), message: .pairingChallenge, fieldID: 1),
            confirmationCode: try WireValue.decodeString(
                try fields.required(2),
                message: .pairingChallenge,
                fieldID: 2,
                maximumBytes: limits.maxIdentifierBytes
            )
        )
    }
}

public struct PairingConfirmationMessage: MessagePayloadValue {
    public static let messageType: MessageType = .pairingConfirmation

    public let challengeID: UInt64
    public let accepted: Bool
    public let confirmationCode: String?

    public init(challengeID: UInt64, accepted: Bool, confirmationCode: String? = nil) {
        self.challengeID = challengeID
        self.accepted = accepted
        self.confirmationCode = confirmationCode
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .pairingConfirmation, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(challengeID))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.bool(accepted, message: .pairingConfirmation, fieldID: 2))
        if let confirmationCode {
            try fields.append(
                fieldID: 3,
                mandatory: false,
                value: try WireValue.string(
                    confirmationCode,
                    message: .pairingConfirmation,
                    fieldID: 3,
                    maximumBytes: limits.maxIdentifierBytes
                )
            )
        }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> PairingConfirmationMessage {
        let fields = try MessageFieldReader(data: data, message: .pairingConfirmation, limits: limits)
        try fields.ensureKnown(Set(1 ... 3))
        return PairingConfirmationMessage(
            challengeID: try WireValue.decodeUInt64(try fields.required(1), message: .pairingConfirmation, fieldID: 1),
            accepted: try WireValue.decodeBool(try fields.required(2), message: .pairingConfirmation, fieldID: 2),
            confirmationCode: try fields.optional(3).map {
                try WireValue.decodeString(
                    $0,
                    message: .pairingConfirmation,
                    fieldID: 3,
                    maximumBytes: limits.maxIdentifierBytes
                )
            }
        )
    }
}

public struct SessionAuthorizeMessage: MessagePayloadValue {
    public static let messageType: MessageType = .sessionAuthorize

    public let authorized: Bool
    public let windowGeneration: UInt64?
    public let capabilities: [Capability]
    public let mandatoryCapabilities: Set<Capability>

    public init(
        authorized: Bool,
        windowGeneration: UInt64? = nil,
        capabilities: [Capability],
        mandatoryCapabilities: Set<Capability> = []
    ) {
        self.authorized = authorized
        self.windowGeneration = windowGeneration
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.mandatoryCapabilities = mandatoryCapabilities
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .sessionAuthorize, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.bool(authorized, message: .sessionAuthorize, fieldID: 1))
        if let windowGeneration {
            try fields.append(fieldID: 2, mandatory: false, value: WireValue.uint64(windowGeneration))
        }
        try fields.append(
            fieldID: 3,
            mandatory: true,
            value: try CapabilityCodec.encode(
                capabilities,
                message: .sessionAuthorize,
                fieldID: 3,
                limits: limits,
                mandatory: mandatoryCapabilities
            )
        )
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> SessionAuthorizeMessage {
        let fields = try MessageFieldReader(data: data, message: .sessionAuthorize, limits: limits)
        try fields.ensureKnown(Set([1, 2, 3]))
        let decodedCapabilities = try CapabilityCodec.decode(
            try fields.required(3),
            message: .sessionAuthorize,
            fieldID: 3,
            limits: limits
        )
        return SessionAuthorizeMessage(
            authorized: try WireValue.decodeBool(try fields.required(1), message: .sessionAuthorize, fieldID: 1),
            windowGeneration: try fields.optional(2).map {
                try WireValue.decodeUInt64($0, message: .sessionAuthorize, fieldID: 2)
            },
            capabilities: decodedCapabilities.capabilities,
            mandatoryCapabilities: decodedCapabilities.mandatoryCapabilities
        )
    }
}

public struct WindowDescriptor: Equatable, Sendable {
    public let identifier: UInt64
    public let applicationIdentifier: String
    public let title: String?
    public let width: UInt32
    public let height: UInt32
    public let eligible: Bool

    public init(
        identifier: UInt64,
        applicationIdentifier: String,
        title: String? = nil,
        width: UInt32,
        height: UInt32,
        eligible: Bool
    ) {
        self.identifier = identifier
        self.applicationIdentifier = applicationIdentifier
        self.title = title
        self.width = width
        self.height = height
        self.eligible = eligible
    }

    fileprivate func encoded(using limits: ProtocolLimits) throws -> Data {
        var fields = try MessageFieldWriter(message: .windowList, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(identifier))
        try fields.append(
            fieldID: 2,
            mandatory: true,
            value: try WireValue.string(
                applicationIdentifier,
                message: .windowList,
                fieldID: 2,
                maximumBytes: limits.maxIdentifierBytes
            )
        )
        if let title {
            try fields.append(
                fieldID: 3,
                mandatory: false,
                value: try WireValue.string(
                    title,
                    message: .windowList,
                    fieldID: 3,
                    maximumBytes: limits.maxIdentifierBytes
                )
            )
        }
        try fields.append(fieldID: 4, mandatory: true, value: WireValue.uint32(width))
        try fields.append(fieldID: 5, mandatory: true, value: WireValue.uint32(height))
        try fields.append(fieldID: 6, mandatory: true, value: WireValue.bool(eligible, message: .windowList, fieldID: 6))
        return fields.data
    }

    fileprivate static func decode(_ data: Data, using limits: ProtocolLimits) throws -> WindowDescriptor {
        let fields = try MessageFieldReader(data: data, message: .windowList, limits: limits)
        try fields.ensureKnown(Set(1 ... 6))
        return WindowDescriptor(
            identifier: try WireValue.decodeUInt64(try fields.required(1), message: .windowList, fieldID: 1),
            applicationIdentifier: try WireValue.decodeString(
                try fields.required(2),
                message: .windowList,
                fieldID: 2,
                maximumBytes: limits.maxIdentifierBytes
            ),
            title: try fields.optional(3).map {
                try WireValue.decodeString(
                    $0,
                    message: .windowList,
                    fieldID: 3,
                    maximumBytes: limits.maxIdentifierBytes
                )
            },
            width: try WireValue.decodeUInt32(try fields.required(4), message: .windowList, fieldID: 4),
            height: try WireValue.decodeUInt32(try fields.required(5), message: .windowList, fieldID: 5),
            eligible: try WireValue.decodeBool(try fields.required(6), message: .windowList, fieldID: 6)
        )
    }
}

public struct WindowListMessage: MessagePayloadValue {
    public static let messageType: MessageType = .windowList

    public let windows: [WindowDescriptor]

    public init(windows: [WindowDescriptor]) {
        self.windows = windows
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        guard windows.count <= limits.maxWindowEntries,
              windows.count <= Int(UInt16.max) else {
            throw ProtocolError.invalidCount(message: .windowList, fieldID: 1)
        }
        var entries = WireWriter()
        entries.appendUInt16(UInt16(windows.count))
        for window in windows {
            let encodedWindow = try window.encoded(using: limits)
            guard encodedWindow.count <= limits.maxFieldLength,
                  UInt32(exactly: encodedWindow.count) != nil else {
                throw ProtocolError.payloadTooLarge(
                    actual: encodedWindow.count,
                    maximum: limits.maxFieldLength
                )
            }
            entries.appendUInt32(UInt32(encodedWindow.count))
            entries.appendData(encodedWindow)
        }
        var fields = try MessageFieldWriter(message: .windowList, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: entries.data)
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> WindowListMessage {
        let fields = try MessageFieldReader(data: data, message: .windowList, limits: limits)
        try fields.ensureKnown(Set([1]))
        var reader = WireReader(data: try fields.required(1))
        let count = Int(try reader.readUInt16())
        guard count <= limits.maxWindowEntries else {
            throw ProtocolError.invalidCount(message: .windowList, fieldID: 1)
        }
        var windows: [WindowDescriptor] = []
        windows.reserveCapacity(count)
        for _ in 0 ..< count {
            let length = Int(try reader.readUInt32())
            guard length <= limits.maxFieldLength else {
                throw ProtocolError.payloadTooLarge(actual: length, maximum: limits.maxFieldLength)
            }
            windows.append(try WindowDescriptor.decode(try reader.readData(count: length), using: limits))
        }
        guard reader.isAtEnd else {
            throw ProtocolError.invalidFieldValue(message: .windowList, fieldID: 1)
        }
        return WindowListMessage(windows: windows)
    }
}

public struct WindowSelectionMessage: MessagePayloadValue {
    public static let messageType: MessageType = .windowSelection

    public let windowIdentifier: UInt64
    public let windowGeneration: UInt64

    public init(windowIdentifier: UInt64, windowGeneration: UInt64) {
        self.windowIdentifier = windowIdentifier
        self.windowGeneration = windowGeneration
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .windowSelection, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(windowIdentifier))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.uint64(windowGeneration))
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> WindowSelectionMessage {
        let fields = try MessageFieldReader(data: data, message: .windowSelection, limits: limits)
        try fields.ensureKnown(Set(1 ... 2))
        return WindowSelectionMessage(
            windowIdentifier: try WireValue.decodeUInt64(try fields.required(1), message: .windowSelection, fieldID: 1),
            windowGeneration: try WireValue.decodeUInt64(try fields.required(2), message: .windowSelection, fieldID: 2)
        )
    }
}

public struct StreamConfigMessage: MessagePayloadValue {
    public static let messageType: MessageType = .streamConfig

    public let width: UInt32
    public let height: UInt32
    public let frameRate: UInt16
    public let codec: CodecIdentifier
    public let generation: UInt64

    public init(width: UInt32, height: UInt32, frameRate: UInt16, codec: CodecIdentifier, generation: UInt64) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.generation = generation
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .streamConfig, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint32(width))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.uint32(height))
        try fields.append(fieldID: 3, mandatory: true, value: WireValue.uint16(frameRate))
        try fields.append(fieldID: 4, mandatory: true, value: WireValue.uint16(codec.rawValue))
        try fields.append(fieldID: 5, mandatory: true, value: WireValue.uint64(generation))
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> StreamConfigMessage {
        let fields = try MessageFieldReader(data: data, message: .streamConfig, limits: limits)
        try fields.ensureKnown(Set(1 ... 5))
        let rawCodec = try WireValue.decodeUInt16(try fields.required(4), message: .streamConfig, fieldID: 4)
        guard let codec = CodecIdentifier(rawValue: rawCodec) else {
            throw ProtocolError.invalidFieldValue(message: .streamConfig, fieldID: 4)
        }
        return StreamConfigMessage(
            width: try WireValue.decodeUInt32(try fields.required(1), message: .streamConfig, fieldID: 1),
            height: try WireValue.decodeUInt32(try fields.required(2), message: .streamConfig, fieldID: 2),
            frameRate: try WireValue.decodeUInt16(try fields.required(3), message: .streamConfig, fieldID: 3),
            codec: codec,
            generation: try WireValue.decodeUInt64(try fields.required(5), message: .streamConfig, fieldID: 5)
        )
    }
}

public struct VideoConfigMessage: MessagePayloadValue {
    public static let messageType: MessageType = .videoConfig

    public let generation: UInt64
    public let decoderConfiguration: Data

    public init(generation: UInt64, decoderConfiguration: Data) {
        self.generation = generation
        self.decoderConfiguration = decoderConfiguration
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .videoConfig, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(generation))
        try fields.append(fieldID: 2, mandatory: true, value: decoderConfiguration)
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> VideoConfigMessage {
        let fields = try MessageFieldReader(data: data, message: .videoConfig, limits: limits)
        try fields.ensureKnown(Set(1 ... 2))
        return VideoConfigMessage(
            generation: try WireValue.decodeUInt64(try fields.required(1), message: .videoConfig, fieldID: 1),
            decoderConfiguration: try fields.required(2)
        )
    }
}

public struct VideoFrameMessage: MessagePayloadValue {
    public static let messageType: MessageType = .videoFrame

    public let generation: UInt64
    public let captureTimestamp: UInt64
    public let presentationTimestamp: UInt64
    public let width: UInt32
    public let height: UInt32
    public let keyframe: Bool
    public let accessUnit: Data

    public init(
        generation: UInt64,
        captureTimestamp: UInt64,
        presentationTimestamp: UInt64,
        width: UInt32,
        height: UInt32,
        keyframe: Bool,
        accessUnit: Data
    ) {
        self.generation = generation
        self.captureTimestamp = captureTimestamp
        self.presentationTimestamp = presentationTimestamp
        self.width = width
        self.height = height
        self.keyframe = keyframe
        self.accessUnit = accessUnit
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .videoFrame, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(generation))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.uint64(captureTimestamp))
        try fields.append(fieldID: 3, mandatory: true, value: WireValue.uint64(presentationTimestamp))
        try fields.append(fieldID: 4, mandatory: true, value: WireValue.uint32(width))
        try fields.append(fieldID: 5, mandatory: true, value: WireValue.uint32(height))
        try fields.append(fieldID: 6, mandatory: true, value: WireValue.bool(keyframe, message: .videoFrame, fieldID: 6))
        try fields.append(fieldID: 7, mandatory: true, value: accessUnit)
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> VideoFrameMessage {
        let fields = try MessageFieldReader(data: data, message: .videoFrame, limits: limits)
        try fields.ensureKnown(Set(1 ... 7))
        return VideoFrameMessage(
            generation: try WireValue.decodeUInt64(try fields.required(1), message: .videoFrame, fieldID: 1),
            captureTimestamp: try WireValue.decodeUInt64(try fields.required(2), message: .videoFrame, fieldID: 2),
            presentationTimestamp: try WireValue.decodeUInt64(try fields.required(3), message: .videoFrame, fieldID: 3),
            width: try WireValue.decodeUInt32(try fields.required(4), message: .videoFrame, fieldID: 4),
            height: try WireValue.decodeUInt32(try fields.required(5), message: .videoFrame, fieldID: 5),
            keyframe: try WireValue.decodeBool(try fields.required(6), message: .videoFrame, fieldID: 6),
            accessUnit: try fields.required(7)
        )
    }
}

public struct InputEventMessage: MessagePayloadValue {
    public static let messageType: MessageType = .inputEvent

    public let kind: InputEventKind
    public let windowGeneration: UInt64
    public let x: UInt16?
    public let y: UInt16?
    public let button: UInt8?
    public let pressed: Bool?
    public let deltaX: Int32?
    public let deltaY: Int32?
    public let keyCode: UInt16?
    public let modifiers: UInt32?

    public init(
        kind: InputEventKind,
        windowGeneration: UInt64,
        x: UInt16? = nil,
        y: UInt16? = nil,
        button: UInt8? = nil,
        pressed: Bool? = nil,
        deltaX: Int32? = nil,
        deltaY: Int32? = nil,
        keyCode: UInt16? = nil,
        modifiers: UInt32? = nil
    ) {
        self.kind = kind
        self.windowGeneration = windowGeneration
        self.x = x
        self.y = y
        self.button = button
        self.pressed = pressed
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        try validateShape()
        var fields = try MessageFieldWriter(message: .inputEvent, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.byte(kind.rawValue, message: .inputEvent, fieldID: 1))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.uint64(windowGeneration))
        if let x { try fields.append(fieldID: 3, mandatory: false, value: WireValue.uint16(x)) }
        if let y { try fields.append(fieldID: 4, mandatory: false, value: WireValue.uint16(y)) }
        if let button { try fields.append(fieldID: 5, mandatory: false, value: WireValue.byte(button, message: .inputEvent, fieldID: 5)) }
        if let pressed { try fields.append(fieldID: 6, mandatory: false, value: WireValue.bool(pressed, message: .inputEvent, fieldID: 6)) }
        if let deltaX { try fields.append(fieldID: 7, mandatory: false, value: WireValue.int32(deltaX)) }
        if let deltaY { try fields.append(fieldID: 8, mandatory: false, value: WireValue.int32(deltaY)) }
        if let keyCode { try fields.append(fieldID: 9, mandatory: false, value: WireValue.uint16(keyCode)) }
        if let modifiers { try fields.append(fieldID: 10, mandatory: false, value: WireValue.uint32(modifiers)) }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> InputEventMessage {
        let fields = try MessageFieldReader(data: data, message: .inputEvent, limits: limits)
        try fields.ensureKnown(Set(1 ... 10))
        guard let kind = InputEventKind(rawValue: try WireValue.decodeByte(try fields.required(1), message: .inputEvent, fieldID: 1)) else {
            throw ProtocolError.invalidFieldValue(message: .inputEvent, fieldID: 1)
        }
        let message = InputEventMessage(
            kind: kind,
            windowGeneration: try WireValue.decodeUInt64(try fields.required(2), message: .inputEvent, fieldID: 2),
            x: try fields.optional(3).map { try WireValue.decodeUInt16($0, message: .inputEvent, fieldID: 3) },
            y: try fields.optional(4).map { try WireValue.decodeUInt16($0, message: .inputEvent, fieldID: 4) },
            button: try fields.optional(5).map { try WireValue.decodeByte($0, message: .inputEvent, fieldID: 5) },
            pressed: try fields.optional(6).map { try WireValue.decodeBool($0, message: .inputEvent, fieldID: 6) },
            deltaX: try fields.optional(7).map { try WireValue.decodeInt32($0, message: .inputEvent, fieldID: 7) },
            deltaY: try fields.optional(8).map { try WireValue.decodeInt32($0, message: .inputEvent, fieldID: 8) },
            keyCode: try fields.optional(9).map { try WireValue.decodeUInt16($0, message: .inputEvent, fieldID: 9) },
            modifiers: try fields.optional(10).map { try WireValue.decodeUInt32($0, message: .inputEvent, fieldID: 10) }
        )
        try message.validateShape()
        return message
    }

    private func validateShape() throws {
        switch kind {
        case .pointerMove:
            guard x != nil, y != nil,
                  button == nil, pressed == nil,
                  deltaX == nil, deltaY == nil,
                  keyCode == nil, modifiers == nil else {
                throw ProtocolError.invalidFieldValue(message: .inputEvent, fieldID: 3)
            }
        case .pointerButton:
            guard x != nil, y != nil, button != nil, pressed != nil,
                  deltaX == nil, deltaY == nil,
                  keyCode == nil, modifiers == nil else {
                throw ProtocolError.invalidFieldValue(message: .inputEvent, fieldID: 5)
            }
        case .scroll:
            guard x != nil, y != nil, deltaX != nil, deltaY != nil,
                  button == nil, pressed == nil,
                  keyCode == nil, modifiers == nil else {
                throw ProtocolError.invalidFieldValue(message: .inputEvent, fieldID: 7)
            }
        case .keyDown, .keyUp:
            guard keyCode != nil, modifiers != nil,
                  x == nil, y == nil,
                  button == nil, pressed == nil,
                  deltaX == nil, deltaY == nil else {
                throw ProtocolError.invalidFieldValue(message: .inputEvent, fieldID: 9)
            }
        case .focusIntent:
            guard x == nil, y == nil,
                  button == nil, pressed == nil,
                  deltaX == nil, deltaY == nil,
                  keyCode == nil, modifiers == nil else {
                throw ProtocolError.invalidFieldValue(message: .inputEvent, fieldID: 3)
            }
        }
    }
}

public struct ClipboardOfferMessage: MessagePayloadValue {
    public static let messageType: MessageType = .clipboardOffer

    public let generation: UInt64
    public let origin: DeviceRole
    public let textByteCount: UInt32
    public let enabled: Bool
    /// `false` represents an enable/disable status update without a pending
    /// clipboard text payload. The field is optional on the wire so existing
    /// M1 offers remain canonical and decode as `true`.
    public let hasText: Bool

    public init(
        generation: UInt64,
        origin: DeviceRole,
        textByteCount: UInt32,
        enabled: Bool,
        hasText: Bool? = nil
    ) {
        self.generation = generation
        self.origin = origin
        self.textByteCount = textByteCount
        self.enabled = enabled
        // Preserve the M1 initializer semantics for callers that do not know
        // about the optional status-only field: an enabled offer carries text
        // (including an empty string), while a disabled offer is status-only.
        self.hasText = hasText ?? enabled
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        guard Int(textByteCount) <= limits.maxClipboardTextBytes else {
            throw ProtocolError.payloadTooLarge(actual: Int(textByteCount), maximum: limits.maxClipboardTextBytes)
        }
        guard hasText || textByteCount == 0 else {
            throw ProtocolError.invalidFieldValue(message: .clipboardOffer, fieldID: 5)
        }
        guard enabled || (!hasText && textByteCount == 0) else {
            throw ProtocolError.invalidFieldValue(message: .clipboardOffer, fieldID: 4)
        }
        var fields = try MessageFieldWriter(message: .clipboardOffer, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(generation))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.byte(origin.rawValue, message: .clipboardOffer, fieldID: 2))
        try fields.append(fieldID: 3, mandatory: true, value: WireValue.uint32(textByteCount))
        try fields.append(fieldID: 4, mandatory: true, value: WireValue.bool(enabled, message: .clipboardOffer, fieldID: 4))
        if !hasText {
            try fields.append(fieldID: 5, mandatory: false, value: WireValue.bool(false, message: .clipboardOffer, fieldID: 5))
        }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> ClipboardOfferMessage {
        let fields = try MessageFieldReader(data: data, message: .clipboardOffer, limits: limits)
        try fields.ensureKnown(Set(1 ... 5))
        let rawOrigin = try WireValue.decodeByte(try fields.required(2), message: .clipboardOffer, fieldID: 2)
        guard let origin = DeviceRole(rawValue: rawOrigin) else {
            throw ProtocolError.invalidFieldValue(message: .clipboardOffer, fieldID: 2)
        }
        let textByteCount = try WireValue.decodeUInt32(try fields.required(3), message: .clipboardOffer, fieldID: 3)
        guard Int(textByteCount) <= limits.maxClipboardTextBytes else {
            throw ProtocolError.payloadTooLarge(actual: Int(textByteCount), maximum: limits.maxClipboardTextBytes)
        }
        let enabled = try WireValue.decodeBool(try fields.required(4), message: .clipboardOffer, fieldID: 4)
        // M1 offers did not have field 5. A legacy disabled status offer has
        // no text, so infer false only for that form while preserving the
        // original enabled/text form as true.
        let hasText = try fields.optional(5).map {
            try WireValue.decodeBool($0, message: .clipboardOffer, fieldID: 5)
        } ?? enabled
        guard hasText || textByteCount == 0 else {
            throw ProtocolError.invalidFieldValue(message: .clipboardOffer, fieldID: 5)
        }
        guard enabled || (!hasText && textByteCount == 0) else {
            throw ProtocolError.invalidFieldValue(message: .clipboardOffer, fieldID: 4)
        }
        return ClipboardOfferMessage(
            generation: try WireValue.decodeUInt64(try fields.required(1), message: .clipboardOffer, fieldID: 1),
            origin: origin,
            textByteCount: textByteCount,
            enabled: enabled,
            hasText: hasText
        )
    }
}

public struct ClipboardTextMessage: MessagePayloadValue {
    public static let messageType: MessageType = .clipboardText

    public let generation: UInt64
    public let text: Data

    public init(generation: UInt64, text: Data) {
        self.generation = generation
        self.text = text
    }

    public init(generation: UInt64, text: String) {
        self.init(generation: generation, text: Data(text.utf8))
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        guard text.count <= limits.maxClipboardTextBytes else {
            throw ProtocolError.payloadTooLarge(
                actual: text.count,
                maximum: limits.maxClipboardTextBytes
            )
        }
        guard String(data: text, encoding: .utf8) != nil else {
            throw ProtocolError.invalidUTF8(message: .clipboardText, fieldID: 2)
        }
        var fields = try MessageFieldWriter(message: .clipboardText, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(generation))
        try fields.append(fieldID: 2, mandatory: true, value: text)
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> ClipboardTextMessage {
        let fields = try MessageFieldReader(data: data, message: .clipboardText, limits: limits)
        try fields.ensureKnown(Set([1, 2]))
        let text = try fields.required(2)
        guard text.count <= limits.maxClipboardTextBytes else {
            throw ProtocolError.payloadTooLarge(
                actual: text.count,
                maximum: limits.maxClipboardTextBytes
            )
        }
        guard String(data: text, encoding: .utf8) != nil else {
            throw ProtocolError.invalidUTF8(message: .clipboardText, fieldID: 2)
        }
        return ClipboardTextMessage(
            generation: try WireValue.decodeUInt64(try fields.required(1), message: .clipboardText, fieldID: 1),
            text: text
        )
    }
}

public struct ClipboardAcknowledgementMessage: MessagePayloadValue {
    public static let messageType: MessageType = .clipboardAcknowledgement

    public let generation: UInt64
    public let origin: DeviceRole
    public let accepted: Bool
    public let reason: ClipboardAcknowledgementReason

    public init(
        generation: UInt64,
        origin: DeviceRole,
        accepted: Bool,
        reason: ClipboardAcknowledgementReason
    ) {
        self.generation = generation
        self.origin = origin
        self.accepted = accepted
        self.reason = reason
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        guard (accepted && reason == .accepted) || (!accepted && reason != .accepted) else {
            throw ProtocolError.invalidFieldValue(message: .clipboardAcknowledgement, fieldID: 4)
        }
        var fields = try MessageFieldWriter(message: .clipboardAcknowledgement, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(generation))
        try fields.append(
            fieldID: 2,
            mandatory: true,
            value: WireValue.byte(origin.rawValue, message: .clipboardAcknowledgement, fieldID: 2)
        )
        try fields.append(
            fieldID: 3,
            mandatory: true,
            value: WireValue.bool(accepted, message: .clipboardAcknowledgement, fieldID: 3)
        )
        try fields.append(
            fieldID: 4,
            mandatory: true,
            value: WireValue.byte(reason.rawValue, message: .clipboardAcknowledgement, fieldID: 4)
        )
        return fields.data
    }

    public static func decode(
        _ data: Data,
        using limits: ProtocolLimits = .default
    ) throws -> ClipboardAcknowledgementMessage {
        let fields = try MessageFieldReader(data: data, message: .clipboardAcknowledgement, limits: limits)
        try fields.ensureKnown(Set(1 ... 4))
        let rawOrigin = try WireValue.decodeByte(
            try fields.required(2),
            message: .clipboardAcknowledgement,
            fieldID: 2
        )
        guard let origin = DeviceRole(rawValue: rawOrigin) else {
            throw ProtocolError.invalidFieldValue(message: .clipboardAcknowledgement, fieldID: 2)
        }
        let rawReason = try WireValue.decodeByte(
            try fields.required(4),
            message: .clipboardAcknowledgement,
            fieldID: 4
        )
        guard let reason = ClipboardAcknowledgementReason(rawValue: rawReason) else {
            throw ProtocolError.invalidFieldValue(message: .clipboardAcknowledgement, fieldID: 4)
        }
        let accepted = try WireValue.decodeBool(
            try fields.required(3),
            message: .clipboardAcknowledgement,
            fieldID: 3
        )
        guard (accepted && reason == .accepted) || (!accepted && reason != .accepted) else {
            throw ProtocolError.invalidFieldValue(message: .clipboardAcknowledgement, fieldID: 4)
        }
        return ClipboardAcknowledgementMessage(
            generation: try WireValue.decodeUInt64(
                try fields.required(1),
                message: .clipboardAcknowledgement,
                fieldID: 1
            ),
            origin: origin,
            accepted: accepted,
            reason: reason
        )
    }
}

public struct PingMessage: MessagePayloadValue {
    public static let messageType: MessageType = .ping
    public let nonce: UInt64

    public init(nonce: UInt64) {
        self.nonce = nonce
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .ping, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(nonce))
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> PingMessage {
        let fields = try MessageFieldReader(data: data, message: .ping, limits: limits)
        try fields.ensureKnown(Set([1]))
        return PingMessage(nonce: try WireValue.decodeUInt64(try fields.required(1), message: .ping, fieldID: 1))
    }
}

public struct PongMessage: MessagePayloadValue {
    public static let messageType: MessageType = .pong
    public let nonce: UInt64

    public init(nonce: UInt64) {
        self.nonce = nonce
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .pong, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(nonce))
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> PongMessage {
        let fields = try MessageFieldReader(data: data, message: .pong, limits: limits)
        try fields.ensureKnown(Set([1]))
        return PongMessage(nonce: try WireValue.decodeUInt64(try fields.required(1), message: .pong, fieldID: 1))
    }
}

public struct SessionStateMessage: MessagePayloadValue {
    public static let messageType: MessageType = .sessionState

    public let state: SessionState
    public let permission: PermissionState
    public let focusEligible: Bool
    public let windowGeneration: UInt64?

    public init(state: SessionState, permission: PermissionState, focusEligible: Bool, windowGeneration: UInt64? = nil) {
        self.state = state
        self.permission = permission
        self.focusEligible = focusEligible
        self.windowGeneration = windowGeneration
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .sessionState, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.byte(state.rawValue, message: .sessionState, fieldID: 1))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.byte(permission.rawValue, message: .sessionState, fieldID: 2))
        try fields.append(fieldID: 3, mandatory: true, value: WireValue.bool(focusEligible, message: .sessionState, fieldID: 3))
        if let windowGeneration {
            try fields.append(fieldID: 4, mandatory: false, value: WireValue.uint64(windowGeneration))
        }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> SessionStateMessage {
        let fields = try MessageFieldReader(data: data, message: .sessionState, limits: limits)
        try fields.ensureKnown(Set(1 ... 4))
        guard let state = SessionState(rawValue: try WireValue.decodeByte(try fields.required(1), message: .sessionState, fieldID: 1)) else {
            throw ProtocolError.invalidFieldValue(message: .sessionState, fieldID: 1)
        }
        guard let permission = PermissionState(rawValue: try WireValue.decodeByte(try fields.required(2), message: .sessionState, fieldID: 2)) else {
            throw ProtocolError.invalidFieldValue(message: .sessionState, fieldID: 2)
        }
        return SessionStateMessage(
            state: state,
            permission: permission,
            focusEligible: try WireValue.decodeBool(try fields.required(3), message: .sessionState, fieldID: 3),
            windowGeneration: try fields.optional(4).map {
                try WireValue.decodeUInt64($0, message: .sessionState, fieldID: 4)
            }
        )
    }
}

public struct ErrorMessage: MessagePayloadValue {
    public static let messageType: MessageType = .error

    public let code: ErrorCode
    public let retryable: Bool
    public let detailCode: String?

    public init(code: ErrorCode, retryable: Bool, detailCode: String? = nil) {
        self.code = code
        self.retryable = retryable
        self.detailCode = detailCode
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .error, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint16(code.rawValue))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.bool(retryable, message: .error, fieldID: 2))
        if let detailCode {
            try fields.append(
                fieldID: 3,
                mandatory: false,
                value: try WireValue.string(
                    detailCode,
                    message: .error,
                    fieldID: 3,
                    maximumBytes: limits.maxIdentifierBytes
                )
            )
        }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> ErrorMessage {
        let fields = try MessageFieldReader(data: data, message: .error, limits: limits)
        try fields.ensureKnown(Set(1 ... 3))
        guard let code = ErrorCode(rawValue: try WireValue.decodeUInt16(try fields.required(1), message: .error, fieldID: 1)) else {
            throw ProtocolError.invalidFieldValue(message: .error, fieldID: 1)
        }
        return ErrorMessage(
            code: code,
            retryable: try WireValue.decodeBool(try fields.required(2), message: .error, fieldID: 2),
            detailCode: try fields.optional(3).map {
                try WireValue.decodeString(
                    $0,
                    message: .error,
                    fieldID: 3,
                    maximumBytes: limits.maxIdentifierBytes
                )
            }
        )
    }
}

public struct CloseMessage: MessagePayloadValue {
    public static let messageType: MessageType = .close

    public let reason: CloseReason
    public let detailCode: String?

    public init(reason: CloseReason, detailCode: String? = nil) {
        self.reason = reason
        self.detailCode = detailCode
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .close, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint16(reason.rawValue))
        if let detailCode {
            try fields.append(
                fieldID: 2,
                mandatory: false,
                value: try WireValue.string(
                    detailCode,
                    message: .close,
                    fieldID: 2,
                    maximumBytes: limits.maxIdentifierBytes
                )
            )
        }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> CloseMessage {
        let fields = try MessageFieldReader(data: data, message: .close, limits: limits)
        try fields.ensureKnown(Set([1, 2]))
        guard let reason = CloseReason(rawValue: try WireValue.decodeUInt16(try fields.required(1), message: .close, fieldID: 1)) else {
            throw ProtocolError.invalidFieldValue(message: .close, fieldID: 1)
        }
        return CloseMessage(
            reason: reason,
            detailCode: try fields.optional(2).map {
                try WireValue.decodeString(
                    $0,
                    message: .close,
                    fieldID: 2,
                    maximumBytes: limits.maxIdentifierBytes
                )
            }
        )
    }
}

public enum MessagePayload: Equatable, Sendable {
    case hello(HelloMessage)
    case capabilities(CapabilitiesMessage)
    case pairingChallenge(PairingChallengeMessage)
    case pairingConfirmation(PairingConfirmationMessage)
    case sessionAuthorize(SessionAuthorizeMessage)
    case windowList(WindowListMessage)
    case windowSelection(WindowSelectionMessage)
    case streamConfig(StreamConfigMessage)
    case videoConfig(VideoConfigMessage)
    case videoFrame(VideoFrameMessage)
    case inputEvent(InputEventMessage)
    case clipboardOffer(ClipboardOfferMessage)
    case clipboardText(ClipboardTextMessage)
    case clipboardAcknowledgement(ClipboardAcknowledgementMessage)
    case ping(PingMessage)
    case pong(PongMessage)
    case sessionState(SessionStateMessage)
    case error(ErrorMessage)
    case close(CloseMessage)

    public var messageType: MessageType {
        switch self {
        case .hello: return .hello
        case .capabilities: return .capabilities
        case .pairingChallenge: return .pairingChallenge
        case .pairingConfirmation: return .pairingConfirmation
        case .sessionAuthorize: return .sessionAuthorize
        case .windowList: return .windowList
        case .windowSelection: return .windowSelection
        case .streamConfig: return .streamConfig
        case .videoConfig: return .videoConfig
        case .videoFrame: return .videoFrame
        case .inputEvent: return .inputEvent
        case .clipboardOffer: return .clipboardOffer
        case .clipboardText: return .clipboardText
        case .clipboardAcknowledgement: return .clipboardAcknowledgement
        case .ping: return .ping
        case .pong: return .pong
        case .sessionState: return .sessionState
        case .error: return .error
        case .close: return .close
        }
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        switch self {
        case let .hello(value): return try value.encoded(using: limits)
        case let .capabilities(value): return try value.encoded(using: limits)
        case let .pairingChallenge(value): return try value.encoded(using: limits)
        case let .pairingConfirmation(value): return try value.encoded(using: limits)
        case let .sessionAuthorize(value): return try value.encoded(using: limits)
        case let .windowList(value): return try value.encoded(using: limits)
        case let .windowSelection(value): return try value.encoded(using: limits)
        case let .streamConfig(value): return try value.encoded(using: limits)
        case let .videoConfig(value): return try value.encoded(using: limits)
        case let .videoFrame(value): return try value.encoded(using: limits)
        case let .inputEvent(value): return try value.encoded(using: limits)
        case let .clipboardOffer(value): return try value.encoded(using: limits)
        case let .clipboardText(value): return try value.encoded(using: limits)
        case let .clipboardAcknowledgement(value): return try value.encoded(using: limits)
        case let .ping(value): return try value.encoded(using: limits)
        case let .pong(value): return try value.encoded(using: limits)
        case let .sessionState(value): return try value.encoded(using: limits)
        case let .error(value): return try value.encoded(using: limits)
        case let .close(value): return try value.encoded(using: limits)
        }
    }

    public static func decode(
        messageType: MessageType,
        data: Data,
        using limits: ProtocolLimits = .default
    ) throws -> MessagePayload {
        switch messageType {
        case .hello: return .hello(try HelloMessage.decode(data, using: limits))
        case .capabilities: return .capabilities(try CapabilitiesMessage.decode(data, using: limits))
        case .pairingChallenge: return .pairingChallenge(try PairingChallengeMessage.decode(data, using: limits))
        case .pairingConfirmation: return .pairingConfirmation(try PairingConfirmationMessage.decode(data, using: limits))
        case .sessionAuthorize: return .sessionAuthorize(try SessionAuthorizeMessage.decode(data, using: limits))
        case .windowList: return .windowList(try WindowListMessage.decode(data, using: limits))
        case .windowSelection: return .windowSelection(try WindowSelectionMessage.decode(data, using: limits))
        case .streamConfig: return .streamConfig(try StreamConfigMessage.decode(data, using: limits))
        case .videoConfig: return .videoConfig(try VideoConfigMessage.decode(data, using: limits))
        case .videoFrame: return .videoFrame(try VideoFrameMessage.decode(data, using: limits))
        case .inputEvent: return .inputEvent(try InputEventMessage.decode(data, using: limits))
        case .clipboardOffer: return .clipboardOffer(try ClipboardOfferMessage.decode(data, using: limits))
        case .clipboardText: return .clipboardText(try ClipboardTextMessage.decode(data, using: limits))
        case .clipboardAcknowledgement:
            return .clipboardAcknowledgement(try ClipboardAcknowledgementMessage.decode(data, using: limits))
        case .ping: return .ping(try PingMessage.decode(data, using: limits))
        case .pong: return .pong(try PongMessage.decode(data, using: limits))
        case .sessionState: return .sessionState(try SessionStateMessage.decode(data, using: limits))
        case .error: return .error(try ErrorMessage.decode(data, using: limits))
        case .close: return .close(try CloseMessage.decode(data, using: limits))
        case let .unknown(rawValue): throw ProtocolError.unsupportedMessageType(rawValue: rawValue)
        }
    }
}
