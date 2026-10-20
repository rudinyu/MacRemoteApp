import Foundation

public protocol MessagePayloadValue: Equatable, Sendable {
    static var messageType: MessageType { get }

    func encoded(using limits: ProtocolLimits) throws -> Data
    static func decode(_ data: Data, using limits: ProtocolLimits) throws -> Self
}

public struct HelloMessage: MessagePayloadValue {
    public static let messageType: MessageType = .hello
    public static let maximumDeviceNameUTF8Bytes = 63

    public let protocolVersion: ProtocolVersion
    public let role: DeviceRole
    public let implementationIdentifier: String
    public let limits: ProtocolLimits
    /// Untrusted, user-facing peer label. Authentication is always bound to
    /// the TLS identity, never this display-only value.
    public let deviceName: String?

    public init(
        protocolVersion: ProtocolVersion,
        role: DeviceRole,
        implementationIdentifier: String,
        limits: ProtocolLimits,
        deviceName: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.role = role
        self.implementationIdentifier = implementationIdentifier
        self.limits = limits
        self.deviceName = deviceName
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
        if let deviceName {
            guard Self.isValidDeviceName(deviceName) else {
                throw ProtocolError.invalidFieldValue(message: .hello, fieldID: 7)
            }
            try fields.append(
                fieldID: 7,
                mandatory: false,
                value: try WireValue.string(
                    deviceName,
                    message: .hello,
                    fieldID: 7,
                    maximumBytes: Self.maximumDeviceNameUTF8Bytes
                )
            )
        }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> HelloMessage {
        let fields = try MessageFieldReader(data: data, message: .hello, limits: limits)
        try fields.ensureKnown(Set(1 ... 7))
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
        let deviceName = try fields.optional(7).map {
            try WireValue.decodeString(
                $0,
                message: .hello,
                fieldID: 7,
                maximumBytes: Self.maximumDeviceNameUTF8Bytes
            )
        }
        guard deviceName.map(Self.isValidDeviceName) ?? true else {
            throw ProtocolError.invalidFieldValue(message: .hello, fieldID: 7)
        }
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
            limits: advertisedLimits,
            deviceName: deviceName
        )
    }

    private static func isValidDeviceName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            value.utf8.count <= maximumDeviceNameUTF8Bytes &&
            value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
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
    public let confirmationCode: String?
    public let commitment: Data?

    public init(challengeID: UInt64, confirmationCode: String) {
        self.challengeID = challengeID
        self.confirmationCode = confirmationCode
        self.commitment = nil
    }

    public init(challengeID: UInt64, commitment: Data) {
        self.challengeID = challengeID
        self.confirmationCode = nil
        self.commitment = commitment
    }

    public init(challengeID: UInt64, commitment: Data, confirmationCode: String?) {
        self.challengeID = challengeID
        self.confirmationCode = confirmationCode
        self.commitment = commitment
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .pairingChallenge, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(challengeID))
        if let confirmationCode {
            try fields.append(
                fieldID: 2,
                mandatory: commitment == nil,
                value: try WireValue.string(
                    confirmationCode,
                    message: .pairingChallenge,
                    fieldID: 2,
                    maximumBytes: limits.maxIdentifierBytes
                )
            )
        }
        if let commitment {
            guard commitment.count == 32 else {
                throw ProtocolError.invalidFieldValue(message: .pairingChallenge, fieldID: 3)
            }
            try fields.append(fieldID: 3, mandatory: false, value: commitment)
        }
        guard confirmationCode != nil || commitment != nil else {
            throw ProtocolError.invalidFieldValue(message: .pairingChallenge, fieldID: 2)
        }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> PairingChallengeMessage {
        let fields = try MessageFieldReader(data: data, message: .pairingChallenge, limits: limits)
        try fields.ensureKnown(Set(1 ... 3))
        let confirmationCode = try fields.optional(2).map {
            try WireValue.decodeString(
                $0,
                message: .pairingChallenge,
                fieldID: 2,
                maximumBytes: limits.maxIdentifierBytes
            )
        }
        let commitment = fields.optional(3)
        if let commitment, commitment.count != 32 {
            throw ProtocolError.invalidFieldValue(message: .pairingChallenge, fieldID: 3)
        }
        guard confirmationCode != nil || commitment != nil else {
            throw ProtocolError.invalidFieldValue(message: .pairingChallenge, fieldID: 2)
        }
        let challengeID = try WireValue.decodeUInt64(
            try fields.required(1),
            message: .pairingChallenge,
            fieldID: 1
        )
        if let commitment {
            return PairingChallengeMessage(
                challengeID: challengeID,
                commitment: commitment,
                confirmationCode: confirmationCode
            )
        }
        return PairingChallengeMessage(
            challengeID: challengeID,
            confirmationCode: confirmationCode ?? ""
        )
    }
}

public struct PairingResponseMessage: MessagePayloadValue {
    public static let messageType: MessageType = .pairingResponse

    public let challengeID: UInt64
    public let commitment: Data

    public init(challengeID: UInt64, commitment: Data) {
        self.challengeID = challengeID
        self.commitment = commitment
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        guard commitment.count == 32 else {
            throw ProtocolError.invalidFieldValue(message: .pairingResponse, fieldID: 2)
        }
        var fields = try MessageFieldWriter(message: .pairingResponse, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(challengeID))
        try fields.append(fieldID: 2, mandatory: true, value: commitment)
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> PairingResponseMessage {
        let fields = try MessageFieldReader(data: data, message: .pairingResponse, limits: limits)
        try fields.ensureKnown(Set([1, 2]))
        let commitment = try fields.required(2)
        guard commitment.count == 32 else {
            throw ProtocolError.invalidFieldValue(message: .pairingResponse, fieldID: 2)
        }
        return PairingResponseMessage(
            challengeID: try WireValue.decodeUInt64(try fields.required(1), message: .pairingResponse, fieldID: 1),
            commitment: commitment
        )
    }
}

public struct PairingVerificationMessage: MessagePayloadValue {
    public static let messageType: MessageType = .pairingVerification

    public let challengeID: UInt64
    public let contribution: Data

    public init(challengeID: UInt64, contribution: Data) {
        self.challengeID = challengeID
        self.contribution = contribution
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        guard contribution.count == 32 else {
            throw ProtocolError.invalidFieldValue(message: .pairingVerification, fieldID: 2)
        }
        var fields = try MessageFieldWriter(message: .pairingVerification, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(challengeID))
        try fields.append(fieldID: 2, mandatory: true, value: contribution)
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> PairingVerificationMessage {
        let fields = try MessageFieldReader(data: data, message: .pairingVerification, limits: limits)
        try fields.ensureKnown(Set([1, 2]))
        let contribution = try fields.required(2)
        guard contribution.count == 32 else {
            throw ProtocolError.invalidFieldValue(message: .pairingVerification, fieldID: 2)
        }
        return PairingVerificationMessage(
            challengeID: try WireValue.decodeUInt64(try fields.required(1), message: .pairingVerification, fieldID: 1),
            contribution: contribution
        )
    }
}

public struct PairingRevealMessage: MessagePayloadValue {
    public static let messageType: MessageType = .pairingReveal

    public let challengeID: UInt64
    public let contribution: Data

    public init(challengeID: UInt64, contribution: Data) {
        self.challengeID = challengeID
        self.contribution = contribution
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        guard contribution.count == 32 else {
            throw ProtocolError.invalidFieldValue(message: .pairingReveal, fieldID: 2)
        }
        var fields = try MessageFieldWriter(message: .pairingReveal, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(challengeID))
        try fields.append(fieldID: 2, mandatory: true, value: contribution)
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> PairingRevealMessage {
        let fields = try MessageFieldReader(data: data, message: .pairingReveal, limits: limits)
        try fields.ensureKnown(Set([1, 2]))
        let contribution = try fields.required(2)
        guard contribution.count == 32 else {
            throw ProtocolError.invalidFieldValue(message: .pairingReveal, fieldID: 2)
        }
        return PairingRevealMessage(
            challengeID: try WireValue.decodeUInt64(try fields.required(1), message: .pairingReveal, fieldID: 1),
            contribution: contribution
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
    /// Identifies the exact catalog snapshot from which a Viewer may select.
    /// This is independent from the selected-window authorization generation.
    public let catalogGeneration: UInt64

    public init(windows: [WindowDescriptor], catalogGeneration: UInt64 = 1) {
        self.windows = windows
        self.catalogGeneration = catalogGeneration
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        guard catalogGeneration > 0 else {
            throw ProtocolError.invalidFieldValue(message: .windowList, fieldID: 2)
        }
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
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.uint64(catalogGeneration))
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> WindowListMessage {
        let fields = try MessageFieldReader(data: data, message: .windowList, limits: limits)
        try fields.ensureKnown(Set([1, 2]))
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
        let catalogGeneration = try WireValue.decodeUInt64(
            try fields.required(2),
            message: .windowList,
            fieldID: 2
        )
        guard catalogGeneration > 0 else {
            throw ProtocolError.invalidFieldValue(message: .windowList, fieldID: 2)
        }
        return WindowListMessage(windows: windows, catalogGeneration: catalogGeneration)
    }
}

public struct WindowSelectionMessage: MessagePayloadValue {
    public static let messageType: MessageType = .windowSelection

    public let windowIdentifier: UInt64
    public let windowGeneration: UInt64
    public let catalogGeneration: UInt64

    public init(
        windowIdentifier: UInt64,
        windowGeneration: UInt64,
        catalogGeneration: UInt64 = 1
    ) {
        self.windowIdentifier = windowIdentifier
        self.windowGeneration = windowGeneration
        self.catalogGeneration = catalogGeneration
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        guard catalogGeneration > 0 else {
            throw ProtocolError.invalidFieldValue(message: .windowSelection, fieldID: 3)
        }
        var fields = try MessageFieldWriter(message: .windowSelection, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(windowIdentifier))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.uint64(windowGeneration))
        try fields.append(fieldID: 3, mandatory: true, value: WireValue.uint64(catalogGeneration))
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> WindowSelectionMessage {
        let fields = try MessageFieldReader(data: data, message: .windowSelection, limits: limits)
        try fields.ensureKnown(Set(1 ... 3))
        let catalogGeneration = try WireValue.decodeUInt64(
            try fields.required(3),
            message: .windowSelection,
            fieldID: 3
        )
        guard catalogGeneration > 0 else {
            throw ProtocolError.invalidFieldValue(message: .windowSelection, fieldID: 3)
        }
        return WindowSelectionMessage(
            windowIdentifier: try WireValue.decodeUInt64(try fields.required(1), message: .windowSelection, fieldID: 1),
            windowGeneration: try WireValue.decodeUInt64(try fields.required(2), message: .windowSelection, fieldID: 2),
            catalogGeneration: catalogGeneration
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
    /// P6 local-control epoch. Legacy sessions omit this optional field.
    public let controlGeneration: UInt64?
    /// Committed text for kind `text` only (ADR-0008): 1–256 UTF-8 bytes
    /// with no control characters. Never logged.
    public let text: String?

    /// Upper bound for one `text` event; longer commits are split by the
    /// Viewer on character boundaries.
    public static let maximumTextBytes = 256

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
        modifiers: UInt32? = nil,
        controlGeneration: UInt64? = nil,
        text: String? = nil
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
        self.controlGeneration = controlGeneration
        self.text = text
    }

    /// Whether `text` is an acceptable committed-text payload.
    public static func isValidText(_ text: String) -> Bool {
        let byteCount = text.utf8.count
        guard byteCount > 0, byteCount <= maximumTextBytes else { return false }
        return !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
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
        if let controlGeneration {
            try fields.append(fieldID: 11, mandatory: false, value: WireValue.uint64(controlGeneration))
        }
        if let text {
            try fields.append(
                fieldID: 12,
                mandatory: false,
                value: try WireValue.string(
                    text,
                    message: .inputEvent,
                    fieldID: 12,
                    maximumBytes: Self.maximumTextBytes
                )
            )
        }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> InputEventMessage {
        let fields = try MessageFieldReader(data: data, message: .inputEvent, limits: limits)
        try fields.ensureKnown(Set(1 ... 12))
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
            modifiers: try fields.optional(10).map { try WireValue.decodeUInt32($0, message: .inputEvent, fieldID: 10) },
            controlGeneration: try fields.optional(11).map {
                try WireValue.decodeUInt64($0, message: .inputEvent, fieldID: 11)
            },
            text: try fields.optional(12).map {
                try WireValue.decodeString(
                    $0,
                    message: .inputEvent,
                    fieldID: 12,
                    maximumBytes: Self.maximumTextBytes
                )
            }
        )
        try message.validateShape()
        return message
    }

    private func validateShape() throws {
        if let controlGeneration, controlGeneration == 0 {
            throw ProtocolError.invalidFieldValue(message: .inputEvent, fieldID: 11)
        }
        if kind == .text {
            guard let text, Self.isValidText(text),
                  x == nil, y == nil,
                  button == nil, pressed == nil,
                  deltaX == nil, deltaY == nil,
                  keyCode == nil, modifiers == nil else {
                throw ProtocolError.invalidFieldValue(message: .inputEvent, fieldID: 12)
            }
            return
        }
        guard text == nil else {
            throw ProtocolError.invalidFieldValue(message: .inputEvent, fieldID: 12)
        }
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
        case .text:
            // Validated above.
            break
        }
    }
}

private func validateInputSourceMessagePayload(
    _ data: Data,
    limits: ProtocolLimits
) throws {
    guard limits.isSane else { throw ProtocolError.invalidLimits }
    let maximum = min(512, limits.maxControlPayloadLength, limits.maxPayloadLength)
    guard data.count <= maximum else {
        throw ProtocolError.controlPayloadTooLarge(actual: data.count, maximum: maximum)
    }
}

private func validateInputSourceIdentifier(
    _ identifier: String,
    message: MessageType,
    limits: ProtocolLimits
) throws {
    guard limits.isSane else { throw ProtocolError.invalidLimits }
    let maximum = min(256, min(limits.maxIdentifierBytes, limits.maxFieldLength))
    guard !identifier.isEmpty,
          identifier.utf8.count <= maximum,
          !identifier.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw ProtocolError.invalidFieldValue(message: message, fieldID: 4)
    }
}

public struct InputSourceSelectionMessage: MessagePayloadValue {
    public static let messageType: MessageType = .inputSourceSelection
    public static let maximumPayloadLength = 512
    public static let maximumSourceIdentifierLength = 256

    public let windowGeneration: UInt64
    public let requestID: UInt64
    public let kind: KeyboardInputSourceKind
    public let sourceIdentifier: String
    /// P6 local-control epoch. Legacy sessions omit this optional field.
    public let controlGeneration: UInt64?

    public init(
        windowGeneration: UInt64,
        requestID: UInt64,
        kind: KeyboardInputSourceKind,
        sourceIdentifier: String,
        controlGeneration: UInt64? = nil
    ) {
        self.windowGeneration = windowGeneration
        self.requestID = requestID
        self.kind = kind
        self.sourceIdentifier = sourceIdentifier
        self.controlGeneration = controlGeneration
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        try validate(using: limits)
        var fields = try MessageFieldWriter(message: .inputSourceSelection, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(windowGeneration))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.uint64(requestID))
        try fields.append(
            fieldID: 3,
            mandatory: true,
            value: WireValue.byte(kind.rawValue, message: .inputSourceSelection, fieldID: 3)
        )
        try fields.append(
            fieldID: 4,
            mandatory: true,
            value: WireValue.string(
                sourceIdentifier,
                message: .inputSourceSelection,
                fieldID: 4,
                maximumBytes: min(Self.maximumSourceIdentifierLength, limits.maxIdentifierBytes)
            )
        )
        if let controlGeneration {
            try fields.append(fieldID: 5, mandatory: false, value: WireValue.uint64(controlGeneration))
        }
        let data = fields.data
        try validateInputSourceMessagePayload(data, limits: limits)
        return data
    }

    public static func decode(
        _ data: Data,
        using limits: ProtocolLimits = .default
    ) throws -> InputSourceSelectionMessage {
        try validateInputSourceMessagePayload(data, limits: limits)
        let fields = try MessageFieldReader(data: data, message: .inputSourceSelection, limits: limits)
        try fields.ensureKnown(Set(1 ... 5))
        guard let kind = KeyboardInputSourceKind(
            rawValue: try WireValue.decodeByte(
                try fields.required(3),
                message: .inputSourceSelection,
                fieldID: 3
            )
        ) else {
            throw ProtocolError.invalidFieldValue(message: .inputSourceSelection, fieldID: 3)
        }
        let message = InputSourceSelectionMessage(
            windowGeneration: try WireValue.decodeUInt64(
                try fields.required(1),
                message: .inputSourceSelection,
                fieldID: 1
            ),
            requestID: try WireValue.decodeUInt64(
                try fields.required(2),
                message: .inputSourceSelection,
                fieldID: 2
            ),
            kind: kind,
            sourceIdentifier: try WireValue.decodeString(
                try fields.required(4),
                message: .inputSourceSelection,
                fieldID: 4,
                maximumBytes: min(
                    Self.maximumSourceIdentifierLength,
                    min(limits.maxIdentifierBytes, limits.maxFieldLength)
                )
            ),
            controlGeneration: try fields.optional(5).map {
                try WireValue.decodeUInt64($0, message: .inputSourceSelection, fieldID: 5)
            }
        )
        try message.validate(using: limits)
        return message
    }

    private func validate(using limits: ProtocolLimits) throws {
        guard windowGeneration > 0 else {
            throw ProtocolError.invalidFieldValue(message: .inputSourceSelection, fieldID: 1)
        }
        guard requestID > 0 else {
            throw ProtocolError.invalidFieldValue(message: .inputSourceSelection, fieldID: 2)
        }
        if let controlGeneration, controlGeneration == 0 {
            throw ProtocolError.invalidFieldValue(message: .inputSourceSelection, fieldID: 5)
        }
        try validateInputSourceIdentifier(sourceIdentifier, message: .inputSourceSelection, limits: limits)
    }
}

public struct InputSourceAcknowledgementMessage: MessagePayloadValue {
    public static let messageType: MessageType = .inputSourceAcknowledgement
    public static let maximumPayloadLength = 512

    public let windowGeneration: UInt64
    public let requestID: UInt64
    public let status: InputSourceSelectionStatus

    public init(
        windowGeneration: UInt64,
        requestID: UInt64,
        status: InputSourceSelectionStatus
    ) {
        self.windowGeneration = windowGeneration
        self.requestID = requestID
        self.status = status
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        try validate()
        var fields = try MessageFieldWriter(message: .inputSourceAcknowledgement, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(windowGeneration))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.uint64(requestID))
        try fields.append(
            fieldID: 3,
            mandatory: true,
            value: WireValue.byte(status.rawValue, message: .inputSourceAcknowledgement, fieldID: 3)
        )
        let data = fields.data
        try validateInputSourceMessagePayload(data, limits: limits)
        return data
    }

    public static func decode(
        _ data: Data,
        using limits: ProtocolLimits = .default
    ) throws -> InputSourceAcknowledgementMessage {
        try validateInputSourceMessagePayload(data, limits: limits)
        let fields = try MessageFieldReader(data: data, message: .inputSourceAcknowledgement, limits: limits)
        try fields.ensureKnown(Set(1 ... 3))
        guard let status = InputSourceSelectionStatus(
            rawValue: try WireValue.decodeByte(
                try fields.required(3),
                message: .inputSourceAcknowledgement,
                fieldID: 3
            )
        ) else {
            throw ProtocolError.invalidFieldValue(message: .inputSourceAcknowledgement, fieldID: 3)
        }
        let message = InputSourceAcknowledgementMessage(
            windowGeneration: try WireValue.decodeUInt64(
                try fields.required(1),
                message: .inputSourceAcknowledgement,
                fieldID: 1
            ),
            requestID: try WireValue.decodeUInt64(
                try fields.required(2),
                message: .inputSourceAcknowledgement,
                fieldID: 2
            ),
            status: status
        )
        try message.validate()
        return message
    }

    private func validate() throws {
        guard windowGeneration > 0 else {
            throw ProtocolError.invalidFieldValue(message: .inputSourceAcknowledgement, fieldID: 1)
        }
        guard requestID > 0 else {
            throw ProtocolError.invalidFieldValue(message: .inputSourceAcknowledgement, fieldID: 2)
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

/// Viewer request for the Host to encode its next frame as a keyframe.
/// Sent only when both endpoints negotiated `Capability.keyframeRequest`;
/// the Host rate-limits honored requests.
public struct KeyframeRequestMessage: MessagePayloadValue {
    public static let messageType: MessageType = .keyframeRequest
    /// Selected-window generation of the stream the Viewer is decoding.
    public let generation: UInt64
    public let reason: KeyframeRequestReason

    public init(generation: UInt64, reason: KeyframeRequestReason) {
        self.generation = generation
        self.reason = reason
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .keyframeRequest, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(generation))
        try fields.append(
            fieldID: 2,
            mandatory: true,
            value: WireValue.byte(reason.rawValue, message: .keyframeRequest, fieldID: 2)
        )
        return fields.data
    }

    public static func decode(
        _ data: Data,
        using limits: ProtocolLimits = .default
    ) throws -> KeyframeRequestMessage {
        let fields = try MessageFieldReader(data: data, message: .keyframeRequest, limits: limits)
        try fields.ensureKnown(Set([1, 2]))
        guard let reason = KeyframeRequestReason(
            rawValue: try WireValue.decodeByte(try fields.required(2), message: .keyframeRequest, fieldID: 2)
        ) else {
            throw ProtocolError.invalidFieldValue(message: .keyframeRequest, fieldID: 2)
        }
        return KeyframeRequestMessage(
            generation: try WireValue.decodeUInt64(try fields.required(1), message: .keyframeRequest, fieldID: 1),
            reason: reason
        )
    }
}

/// Periodic Viewer congestion feedback for Host bitrate adaptation. Sent only
/// when both endpoints negotiated `Capability.receiverReport`. It carries
/// aggregate counts and delay only, never frame content.
public struct ReceiverReportMessage: MessagePayloadValue {
    public static let messageType: MessageType = .receiverReport
    /// Selected-window generation of the stream being reported.
    public let generation: UInt64
    /// Mean queuing delay over the report interval: how far the one-way
    /// send-to-receive time rose above its recent minimum.
    public let queuingDelayMicroseconds: UInt32
    /// Video frames received during the interval.
    public let receivedFrames: UInt32
    /// Video frames lost during the interval: media sequence gaps plus
    /// frames the Viewer's own bounded queues discarded.
    public let discardedFrames: UInt32

    public init(
        generation: UInt64,
        queuingDelayMicroseconds: UInt32,
        receivedFrames: UInt32,
        discardedFrames: UInt32
    ) {
        self.generation = generation
        self.queuingDelayMicroseconds = queuingDelayMicroseconds
        self.receivedFrames = receivedFrames
        self.discardedFrames = discardedFrames
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .receiverReport, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(generation))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.uint32(queuingDelayMicroseconds))
        try fields.append(fieldID: 3, mandatory: true, value: WireValue.uint32(receivedFrames))
        try fields.append(fieldID: 4, mandatory: true, value: WireValue.uint32(discardedFrames))
        return fields.data
    }

    public static func decode(
        _ data: Data,
        using limits: ProtocolLimits = .default
    ) throws -> ReceiverReportMessage {
        let fields = try MessageFieldReader(data: data, message: .receiverReport, limits: limits)
        try fields.ensureKnown(Set(1 ... 4))
        return ReceiverReportMessage(
            generation: try WireValue.decodeUInt64(try fields.required(1), message: .receiverReport, fieldID: 1),
            queuingDelayMicroseconds: try WireValue.decodeUInt32(
                try fields.required(2), message: .receiverReport, fieldID: 2
            ),
            receivedFrames: try WireValue.decodeUInt32(try fields.required(3), message: .receiverReport, fieldID: 3),
            discardedFrames: try WireValue.decodeUInt32(try fields.required(4), message: .receiverReport, fieldID: 4)
        )
    }
}

public struct PongMessage: MessagePayloadValue {
    public static let messageType: MessageType = .pong
    public let nonce: UInt64
    /// Monotonic timestamp taken by the receiver of the corresponding Ping.
    /// It is optional for compatibility with older peers; a four-timestamp
    /// clock probe is only accepted when this field is present.
    public let receiverTimestampNanoseconds: UInt64?

    public init(nonce: UInt64, receiverTimestampNanoseconds: UInt64? = nil) {
        self.nonce = nonce
        self.receiverTimestampNanoseconds = receiverTimestampNanoseconds
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        var fields = try MessageFieldWriter(message: .pong, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.uint64(nonce))
        if let receiverTimestampNanoseconds {
            try fields.append(
                fieldID: 2,
                mandatory: false,
                value: WireValue.uint64(receiverTimestampNanoseconds)
            )
        }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> PongMessage {
        let fields = try MessageFieldReader(data: data, message: .pong, limits: limits)
        try fields.ensureKnown(Set([1, 2]))
        return PongMessage(
            nonce: try WireValue.decodeUInt64(try fields.required(1), message: .pong, fieldID: 1),
            receiverTimestampNanoseconds: try fields.optional(2).map {
                try WireValue.decodeUInt64($0, message: .pong, fieldID: 2)
            }
        )
    }
}

public struct SessionStateMessage: MessagePayloadValue {
    public static let messageType: MessageType = .sessionState

    public let state: SessionState
    public let permission: PermissionState
    public let focusEligible: Bool
    public let windowGeneration: UInt64?
    public let controlState: ControlAuthorizationState?
    /// Live Host-side target safety, independent of foreground eligibility.
    public let processTargetEligible: Bool?
    /// Host-local P6 pause/resume/revoke epoch. It does not change media authorization.
    public let controlGeneration: UInt64?

    public init(
        state: SessionState,
        permission: PermissionState,
        focusEligible: Bool,
        windowGeneration: UInt64? = nil,
        controlState: ControlAuthorizationState? = nil,
        processTargetEligible: Bool? = nil,
        controlGeneration: UInt64? = nil
    ) {
        self.state = state
        self.permission = permission
        self.focusEligible = focusEligible
        self.windowGeneration = windowGeneration
        self.controlState = controlState
        self.processTargetEligible = processTargetEligible
        self.controlGeneration = controlGeneration
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        try validate()
        var fields = try MessageFieldWriter(message: .sessionState, limits: limits)
        try fields.append(fieldID: 1, mandatory: true, value: WireValue.byte(state.rawValue, message: .sessionState, fieldID: 1))
        try fields.append(fieldID: 2, mandatory: true, value: WireValue.byte(permission.rawValue, message: .sessionState, fieldID: 2))
        try fields.append(fieldID: 3, mandatory: true, value: WireValue.bool(focusEligible, message: .sessionState, fieldID: 3))
        if let windowGeneration {
            try fields.append(fieldID: 4, mandatory: false, value: WireValue.uint64(windowGeneration))
        }
        if let controlState {
            try fields.append(
                fieldID: 5,
                mandatory: false,
                value: WireValue.byte(controlState.rawValue, message: .sessionState, fieldID: 5)
            )
        }
        if let processTargetEligible {
            try fields.append(
                fieldID: 6,
                mandatory: false,
                value: WireValue.bool(processTargetEligible, message: .sessionState, fieldID: 6)
            )
        }
        if let controlGeneration {
            try fields.append(fieldID: 7, mandatory: false, value: WireValue.uint64(controlGeneration))
        }
        return fields.data
    }

    public static func decode(_ data: Data, using limits: ProtocolLimits = .default) throws -> SessionStateMessage {
        let fields = try MessageFieldReader(data: data, message: .sessionState, limits: limits)
        try fields.ensureKnown(Set(1 ... 7))
        guard let state = SessionState(rawValue: try WireValue.decodeByte(try fields.required(1), message: .sessionState, fieldID: 1)) else {
            throw ProtocolError.invalidFieldValue(message: .sessionState, fieldID: 1)
        }
        guard let permission = PermissionState(rawValue: try WireValue.decodeByte(try fields.required(2), message: .sessionState, fieldID: 2)) else {
            throw ProtocolError.invalidFieldValue(message: .sessionState, fieldID: 2)
        }
        let message = SessionStateMessage(
            state: state,
            permission: permission,
            focusEligible: try WireValue.decodeBool(try fields.required(3), message: .sessionState, fieldID: 3),
            windowGeneration: try fields.optional(4).map {
                try WireValue.decodeUInt64($0, message: .sessionState, fieldID: 4)
            },
            controlState: try fields.optional(5).map {
                guard let value = ControlAuthorizationState(
                    rawValue: try WireValue.decodeByte($0, message: .sessionState, fieldID: 5)
                ) else {
                    throw ProtocolError.invalidFieldValue(message: .sessionState, fieldID: 5)
                }
                return value
            },
            processTargetEligible: try fields.optional(6).map {
                try WireValue.decodeBool($0, message: .sessionState, fieldID: 6)
            },
            controlGeneration: try fields.optional(7).map {
                try WireValue.decodeUInt64($0, message: .sessionState, fieldID: 7)
            }
        )
        try message.validate()
        return message
    }

    private func validate() throws {
        if let controlGeneration, controlGeneration == 0 {
            throw ProtocolError.invalidFieldValue(message: .sessionState, fieldID: 7)
        }
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
    case pairingResponse(PairingResponseMessage)
    case pairingVerification(PairingVerificationMessage)
    case pairingReveal(PairingRevealMessage)
    case sessionAuthorize(SessionAuthorizeMessage)
    case windowList(WindowListMessage)
    case windowSelection(WindowSelectionMessage)
    case streamConfig(StreamConfigMessage)
    case videoConfig(VideoConfigMessage)
    case videoFrame(VideoFrameMessage)
    case inputEvent(InputEventMessage)
    case inputSourceSelection(InputSourceSelectionMessage)
    case inputSourceAcknowledgement(InputSourceAcknowledgementMessage)
    case clipboardOffer(ClipboardOfferMessage)
    case clipboardText(ClipboardTextMessage)
    case clipboardAcknowledgement(ClipboardAcknowledgementMessage)
    case ping(PingMessage)
    case pong(PongMessage)
    case sessionState(SessionStateMessage)
    case error(ErrorMessage)
    case close(CloseMessage)
    case keyframeRequest(KeyframeRequestMessage)
    case receiverReport(ReceiverReportMessage)

    public var messageType: MessageType {
        switch self {
        case .hello: return .hello
        case .capabilities: return .capabilities
        case .pairingChallenge: return .pairingChallenge
        case .pairingConfirmation: return .pairingConfirmation
        case .pairingResponse: return .pairingResponse
        case .pairingVerification: return .pairingVerification
        case .pairingReveal: return .pairingReveal
        case .sessionAuthorize: return .sessionAuthorize
        case .windowList: return .windowList
        case .windowSelection: return .windowSelection
        case .streamConfig: return .streamConfig
        case .videoConfig: return .videoConfig
        case .videoFrame: return .videoFrame
        case .inputEvent: return .inputEvent
        case .inputSourceSelection: return .inputSourceSelection
        case .inputSourceAcknowledgement: return .inputSourceAcknowledgement
        case .clipboardOffer: return .clipboardOffer
        case .clipboardText: return .clipboardText
        case .clipboardAcknowledgement: return .clipboardAcknowledgement
        case .ping: return .ping
        case .pong: return .pong
        case .sessionState: return .sessionState
        case .error: return .error
        case .close: return .close
        case .keyframeRequest: return .keyframeRequest
        case .receiverReport: return .receiverReport
        }
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        switch self {
        case let .hello(value): return try value.encoded(using: limits)
        case let .capabilities(value): return try value.encoded(using: limits)
        case let .pairingChallenge(value): return try value.encoded(using: limits)
        case let .pairingConfirmation(value): return try value.encoded(using: limits)
        case let .pairingResponse(value): return try value.encoded(using: limits)
        case let .pairingVerification(value): return try value.encoded(using: limits)
        case let .pairingReveal(value): return try value.encoded(using: limits)
        case let .sessionAuthorize(value): return try value.encoded(using: limits)
        case let .windowList(value): return try value.encoded(using: limits)
        case let .windowSelection(value): return try value.encoded(using: limits)
        case let .streamConfig(value): return try value.encoded(using: limits)
        case let .videoConfig(value): return try value.encoded(using: limits)
        case let .videoFrame(value): return try value.encoded(using: limits)
        case let .inputEvent(value): return try value.encoded(using: limits)
        case let .inputSourceSelection(value): return try value.encoded(using: limits)
        case let .inputSourceAcknowledgement(value): return try value.encoded(using: limits)
        case let .clipboardOffer(value): return try value.encoded(using: limits)
        case let .clipboardText(value): return try value.encoded(using: limits)
        case let .clipboardAcknowledgement(value): return try value.encoded(using: limits)
        case let .ping(value): return try value.encoded(using: limits)
        case let .pong(value): return try value.encoded(using: limits)
        case let .sessionState(value): return try value.encoded(using: limits)
        case let .error(value): return try value.encoded(using: limits)
        case let .close(value): return try value.encoded(using: limits)
        case let .keyframeRequest(value): return try value.encoded(using: limits)
        case let .receiverReport(value): return try value.encoded(using: limits)
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
        case .pairingResponse: return .pairingResponse(try PairingResponseMessage.decode(data, using: limits))
        case .pairingVerification: return .pairingVerification(try PairingVerificationMessage.decode(data, using: limits))
        case .pairingReveal: return .pairingReveal(try PairingRevealMessage.decode(data, using: limits))
        case .sessionAuthorize: return .sessionAuthorize(try SessionAuthorizeMessage.decode(data, using: limits))
        case .windowList: return .windowList(try WindowListMessage.decode(data, using: limits))
        case .windowSelection: return .windowSelection(try WindowSelectionMessage.decode(data, using: limits))
        case .streamConfig: return .streamConfig(try StreamConfigMessage.decode(data, using: limits))
        case .videoConfig: return .videoConfig(try VideoConfigMessage.decode(data, using: limits))
        case .videoFrame: return .videoFrame(try VideoFrameMessage.decode(data, using: limits))
        case .inputEvent: return .inputEvent(try InputEventMessage.decode(data, using: limits))
        case .inputSourceSelection:
            return .inputSourceSelection(try InputSourceSelectionMessage.decode(data, using: limits))
        case .inputSourceAcknowledgement:
            return .inputSourceAcknowledgement(try InputSourceAcknowledgementMessage.decode(data, using: limits))
        case .clipboardOffer: return .clipboardOffer(try ClipboardOfferMessage.decode(data, using: limits))
        case .clipboardText: return .clipboardText(try ClipboardTextMessage.decode(data, using: limits))
        case .clipboardAcknowledgement:
            return .clipboardAcknowledgement(try ClipboardAcknowledgementMessage.decode(data, using: limits))
        case .ping: return .ping(try PingMessage.decode(data, using: limits))
        case .pong: return .pong(try PongMessage.decode(data, using: limits))
        case .sessionState: return .sessionState(try SessionStateMessage.decode(data, using: limits))
        case .error: return .error(try ErrorMessage.decode(data, using: limits))
        case .close: return .close(try CloseMessage.decode(data, using: limits))
        case .keyframeRequest: return .keyframeRequest(try KeyframeRequestMessage.decode(data, using: limits))
        case .receiverReport: return .receiverReport(try ReceiverReportMessage.decode(data, using: limits))
        case let .unknown(rawValue): throw ProtocolError.unsupportedMessageType(rawValue: rawValue)
        }
    }
}
