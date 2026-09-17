import Foundation

public struct Envelope: Equatable, Sendable {
    public static let magic = Data([0x4D, 0x52, 0x50, 0x31])
    public static let headerSize = 31

    public let version: ProtocolVersion
    public let channel: Channel
    public let messageType: MessageType
    public let flags: EnvelopeFlags
    public let payload: Data
    public let sequence: UInt64
    public let timestamp: UInt64

    public init(
        version: ProtocolVersion = .current,
        channel: Channel,
        messageType: MessageType,
        flags: EnvelopeFlags = [],
        sequence: UInt64,
        timestamp: UInt64,
        payload: Data = Data(),
        limits: ProtocolLimits = .default
    ) throws {
        try Self.validate(
            version: version,
            channel: channel,
            messageType: messageType,
            flags: flags,
            payloadCount: payload.count,
            limits: limits
        )

        self.version = version
        self.channel = channel
        self.messageType = messageType
        self.flags = flags
        self.payload = payload
        self.sequence = sequence
        self.timestamp = timestamp
    }

    public init(
        message: MessagePayload,
        version: ProtocolVersion = .current,
        channel: Channel? = nil,
        flags: EnvelopeFlags = [],
        sequence: UInt64,
        timestamp: UInt64,
        limits: ProtocolLimits = .default
    ) throws {
        try self.init(
            version: version,
            channel: channel ?? message.messageType.defaultChannel,
            messageType: message.messageType,
            flags: flags,
            sequence: sequence,
            timestamp: timestamp,
            payload: try message.encoded(using: limits),
            limits: limits
        )
    }

    public func encoded(using limits: ProtocolLimits = .default) throws -> Data {
        try Self.validate(
            version: version,
            channel: channel,
            messageType: messageType,
            flags: flags,
            payloadCount: payload.count,
            limits: limits
        )

        var writer = WireWriter()
        writer.appendData(Self.magic)
        writer.appendByte(version.major)
        writer.appendByte(version.minor)
        writer.appendByte(channel.rawValue)
        writer.appendUInt16(messageType.rawValue)
        writer.appendUInt16(flags.rawValue)
        writer.appendUInt32(UInt32(payload.count))
        writer.appendUInt64(sequence)
        writer.appendUInt64(timestamp)
        writer.appendData(payload)
        return writer.data
    }

    public func decodedMessage(using limits: ProtocolLimits = .default) throws -> MessagePayload {
        try MessagePayload.decode(messageType: messageType, data: payload, using: limits)
    }

    public static func decode(
        _ data: Data,
        limits: ProtocolLimits = .default,
        supportedVersion: ProtocolVersion = .current
    ) throws -> Envelope {
        let normalizedData = Data(data)
        let header = try parseHeader(
            from: normalizedData,
            limits: limits,
            supportedVersion: supportedVersion
        )
        let totalLength = try totalFrameLength(payloadLength: header.payloadLength)
        guard normalizedData.count >= totalLength else {
            throw ProtocolError.truncated(expected: totalLength, actual: normalizedData.count)
        }
        guard normalizedData.count == totalLength else {
            throw ProtocolError.trailingBytes(count: normalizedData.count - totalLength)
        }

        let payloadStart = Self.headerSize
        let payload = normalizedData.subdata(in: payloadStart ..< totalLength)
        return try Envelope(
            version: header.version,
            channel: header.channel,
            messageType: header.messageType,
            flags: header.flags,
            sequence: header.sequence,
            timestamp: header.timestamp,
            payload: payload,
            limits: limits
        )
    }

    internal static func requiredFrameLength(
        in data: Data,
        limits: ProtocolLimits,
        supportedVersion: ProtocolVersion
    ) throws -> Int {
        let header = try parseHeader(
            from: data,
            limits: limits,
            supportedVersion: supportedVersion
        )
        return try totalFrameLength(payloadLength: header.payloadLength)
    }

    private struct Header {
        let version: ProtocolVersion
        let channel: Channel
        let messageType: MessageType
        let flags: EnvelopeFlags
        let payloadLength: UInt32
        let sequence: UInt64
        let timestamp: UInt64
    }

    private static func parseHeader(
        from data: Data,
        limits: ProtocolLimits,
        supportedVersion: ProtocolVersion
    ) throws -> Header {
        guard limits.isSane else {
            throw ProtocolError.invalidLimits
        }
        guard data.count >= Self.headerSize else {
            throw ProtocolError.truncated(expected: Self.headerSize, actual: data.count)
        }
        guard data.prefix(Self.magic.count) == Self.magic else {
            throw ProtocolError.invalidMagic
        }

        var reader = WireReader(data: data)
        _ = try reader.readData(count: Self.magic.count)
        let version = ProtocolVersion(major: try reader.readByte(), minor: try reader.readByte())
        guard version.isCompatible(with: supportedVersion) else {
            throw ProtocolError.unsupportedVersion(major: version.major, minor: version.minor)
        }
        let rawChannel = try reader.readByte()
        guard let channel = Channel(rawValue: rawChannel) else {
            throw ProtocolError.invalidChannel(rawValue: rawChannel)
        }
        let messageType = MessageType(rawValue: try reader.readUInt16())
        let flags = EnvelopeFlags(rawValue: try reader.readUInt16())
        guard !flags.containsUnknownBits else {
            throw ProtocolError.unknownFlags(rawValue: flags.rawValue)
        }
        let payloadLength = try reader.readUInt32()
        try validatePayloadLength(
            payloadLength,
            channel: channel,
            limits: limits
        )
        let sequence = try reader.readUInt64()
        let timestamp = try reader.readUInt64()

        if case let .unknown(rawValue) = messageType,
           flags.contains(.mustUnderstand) {
            throw ProtocolError.unknownMandatoryMessageType(rawValue: rawValue)
        }

        return Header(
            version: version,
            channel: channel,
            messageType: messageType,
            flags: flags,
            payloadLength: payloadLength,
            sequence: sequence,
            timestamp: timestamp
        )
    }

    private static func totalFrameLength(payloadLength: UInt32) throws -> Int {
        let payloadCount = Int(payloadLength)
        let (totalLength, overflow) = Self.headerSize.addingReportingOverflow(payloadCount)
        guard !overflow else {
            throw ProtocolError.invalidPayloadLength(rawValue: payloadLength)
        }
        return totalLength
    }

    private static func validate(
        version: ProtocolVersion,
        channel: Channel,
        messageType: MessageType,
        flags: EnvelopeFlags,
        payloadCount: Int,
        limits: ProtocolLimits
    ) throws {
        guard limits.isSane else {
            throw ProtocolError.invalidLimits
        }
        guard version.isCompatible() else {
            throw ProtocolError.unsupportedVersion(major: version.major, minor: version.minor)
        }
        guard !flags.containsUnknownBits else {
            throw ProtocolError.unknownFlags(rawValue: flags.rawValue)
        }
        try validatePayloadLength(
            UInt32(exactly: payloadCount) ?? UInt32.max,
            channel: channel,
            limits: limits
        )
        if case let .unknown(rawValue) = messageType,
           flags.contains(.mustUnderstand) {
            throw ProtocolError.unknownMandatoryMessageType(rawValue: rawValue)
        }
    }

    private static func validatePayloadLength(
        _ payloadLength: UInt32,
        channel: Channel,
        limits: ProtocolLimits
    ) throws {
        let length = Int(payloadLength)
        guard length <= limits.maxPayloadLength else {
            throw ProtocolError.payloadTooLarge(actual: length, maximum: limits.maxPayloadLength)
        }
        if channel == .control, length > limits.maxControlPayloadLength {
            throw ProtocolError.controlPayloadTooLarge(
                actual: length,
                maximum: limits.maxControlPayloadLength
            )
        }
    }
}
