import Foundation

internal struct MessageFieldWriter {
    private let message: MessageType
    private let limits: ProtocolLimits
    private var writer = WireWriter()
    private var previousFieldID: UInt8 = 0

    internal init(message: MessageType, limits: ProtocolLimits) throws {
        guard limits.isSane else {
            throw ProtocolError.invalidLimits
        }
        self.message = message
        self.limits = limits
        writer.appendByte(1)
    }

    internal mutating func append(
        fieldID: UInt8,
        mandatory: Bool,
        value: Data
    ) throws {
        guard fieldID > 0 else {
            throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
        }
        guard fieldID > previousFieldID else {
            if fieldID == previousFieldID {
                throw ProtocolError.duplicateField(message: message, fieldID: fieldID)
            }
            throw ProtocolError.fieldsOutOfOrder(
                message: message,
                previous: previousFieldID,
                current: fieldID
            )
        }
        guard value.count <= limits.maxFieldLength,
              UInt32(exactly: value.count) != nil else {
            throw ProtocolError.payloadTooLarge(
                actual: value.count,
                maximum: limits.maxFieldLength
            )
        }

        writer.appendByte(fieldID)
        writer.appendByte(mandatory ? 1 : 0)
        writer.appendUInt32(UInt32(value.count))
        writer.appendData(value)
        previousFieldID = fieldID
    }

    internal var data: Data {
        writer.data
    }
}

internal struct MessageField {
    internal let fieldID: UInt8
    internal let mandatory: Bool
    internal let value: Data
}

internal struct MessageFieldReader {
    private let message: MessageType
    private let fields: [UInt8: MessageField]

    internal init(
        data: Data,
        message: MessageType,
        limits: ProtocolLimits
    ) throws {
        guard limits.isSane else {
            throw ProtocolError.invalidLimits
        }
        guard data.count <= limits.maxPayloadLength else {
            throw ProtocolError.payloadTooLarge(
                actual: data.count,
                maximum: limits.maxPayloadLength
            )
        }

        self.message = message
        var reader = WireReader(data: data)
        let schemaVersion = try reader.readByte()
        guard schemaVersion == 1 else {
            throw ProtocolError.invalidSchemaVersion(
                message: message,
                rawValue: schemaVersion
            )
        }

        var parsed: [UInt8: MessageField] = [:]
        var previousFieldID: UInt8 = 0
        while !reader.isAtEnd {
            let fieldID = try reader.readByte()
            guard fieldID > 0 else {
                throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
            }
            guard fieldID > previousFieldID else {
                if fieldID == previousFieldID {
                    throw ProtocolError.duplicateField(message: message, fieldID: fieldID)
                }
                throw ProtocolError.fieldsOutOfOrder(
                    message: message,
                    previous: previousFieldID,
                    current: fieldID
                )
            }

            let rawFlags = try reader.readByte()
            guard rawFlags & ~UInt8(1) == 0 else {
                throw ProtocolError.unknownFieldFlags(
                    message: message,
                    fieldID: fieldID,
                    rawValue: rawFlags
                )
            }
            let fieldLength = try reader.readUInt32()
            guard fieldLength <= UInt32(limits.maxFieldLength) else {
                throw ProtocolError.payloadTooLarge(
                    actual: Int(fieldLength),
                    maximum: limits.maxFieldLength
                )
            }
            let value = try reader.readData(count: Int(fieldLength))
            parsed[fieldID] = MessageField(
                fieldID: fieldID,
                mandatory: rawFlags & 1 == 1,
                value: value
            )
            previousFieldID = fieldID
        }
        fields = parsed
    }

    internal func ensureKnown(_ knownFieldIDs: Set<UInt8>) throws {
        for field in fields.values where field.mandatory && !knownFieldIDs.contains(field.fieldID) {
            throw ProtocolError.unknownMandatoryField(
                message: message,
                fieldID: field.fieldID
            )
        }
    }

    internal func required(_ fieldID: UInt8) throws -> Data {
        guard let field = fields[fieldID] else {
            throw ProtocolError.missingRequiredField(message: message, fieldID: fieldID)
        }
        return field.value
    }

    internal func optional(_ fieldID: UInt8) -> Data? {
        fields[fieldID]?.value
    }
}

internal enum WireValue {
    internal static func byte(
        _ value: UInt8,
        message: MessageType,
        fieldID: UInt8
    ) -> Data {
        Data([value])
    }

    internal static func bool(
        _ value: Bool,
        message: MessageType,
        fieldID: UInt8
    ) -> Data {
        Data([value ? 1 : 0])
    }

    internal static func uint16(_ value: UInt16) -> Data {
        var writer = WireWriter()
        writer.appendUInt16(value)
        return writer.data
    }

    internal static func uint32(_ value: UInt32) -> Data {
        var writer = WireWriter()
        writer.appendUInt32(value)
        return writer.data
    }

    internal static func uint64(_ value: UInt64) -> Data {
        var writer = WireWriter()
        writer.appendUInt64(value)
        return writer.data
    }

    internal static func int32(_ value: Int32) -> Data {
        var writer = WireWriter()
        writer.appendInt32(value)
        return writer.data
    }

    internal static func string(
        _ value: String,
        message: MessageType,
        fieldID: UInt8,
        maximumBytes: Int
    ) throws -> Data {
        let data = Data(value.utf8)
        guard data.count <= maximumBytes else {
            throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
        }
        return data
    }

    internal static func decodeByte(
        _ data: Data,
        message: MessageType,
        fieldID: UInt8
    ) throws -> UInt8 {
        guard data.count == 1 else {
            throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
        }
        return data[data.startIndex]
    }

    internal static func decodeBool(
        _ data: Data,
        message: MessageType,
        fieldID: UInt8
    ) throws -> Bool {
        switch try decodeByte(data, message: message, fieldID: fieldID) {
        case 0: return false
        case 1: return true
        default: throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
        }
    }

    internal static func decodeUInt16(
        _ data: Data,
        message: MessageType,
        fieldID: UInt8
    ) throws -> UInt16 {
        guard data.count == 2 else {
            throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
        }
        var reader = WireReader(data: data)
        return try reader.readUInt16()
    }

    internal static func decodeUInt32(
        _ data: Data,
        message: MessageType,
        fieldID: UInt8
    ) throws -> UInt32 {
        guard data.count == 4 else {
            throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
        }
        var reader = WireReader(data: data)
        return try reader.readUInt32()
    }

    internal static func decodeUInt64(
        _ data: Data,
        message: MessageType,
        fieldID: UInt8
    ) throws -> UInt64 {
        guard data.count == 8 else {
            throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
        }
        var reader = WireReader(data: data)
        return try reader.readUInt64()
    }

    internal static func decodeInt32(
        _ data: Data,
        message: MessageType,
        fieldID: UInt8
    ) throws -> Int32 {
        guard data.count == 4 else {
            throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
        }
        var reader = WireReader(data: data)
        return try reader.readInt32()
    }

    internal static func decodeString(
        _ data: Data,
        message: MessageType,
        fieldID: UInt8,
        maximumBytes: Int
    ) throws -> String {
        guard data.count <= maximumBytes,
              let value = String(data: data, encoding: .utf8) else {
            throw ProtocolError.invalidUTF8(message: message, fieldID: fieldID)
        }
        return value
    }
}

internal enum CapabilityCodec {
    internal struct Decoded {
        internal let capabilities: [Capability]
        internal let mandatoryCapabilities: Set<Capability>
    }

    internal static func encode(
        _ capabilities: [Capability],
        message: MessageType,
        fieldID: UInt8,
        limits: ProtocolLimits,
        mandatory: Set<Capability> = []
    ) throws -> Data {
        guard capabilities.count <= limits.maxCapabilities,
              capabilities.count <= Int(UInt16.max) else {
            throw ProtocolError.invalidCount(message: message, fieldID: fieldID)
        }
        guard mandatory.isSubset(of: Set(capabilities)) else {
            throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
        }
        let sortedCapabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        guard sortedCapabilities.allSatisfy({
            $0.rawValue > 0 && $0.rawValue & 0x8000 == 0
        }) else {
            throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
        }
        guard zip(sortedCapabilities, sortedCapabilities.dropFirst()).allSatisfy({ $0.rawValue != $1.rawValue }) else {
            throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
        }
        var writer = WireWriter()
        writer.appendUInt16(UInt16(sortedCapabilities.count))
        for capability in sortedCapabilities {
            let mandatoryBit: UInt16 = mandatory.contains(capability) ? 0x8000 : 0
            writer.appendUInt16(capability.rawValue | mandatoryBit)
        }
        return writer.data
    }

    internal static func decode(
        _ data: Data,
        message: MessageType,
        fieldID: UInt8,
        limits: ProtocolLimits
    ) throws -> Decoded {
        var reader = WireReader(data: data)
        let count = Int(try reader.readUInt16())
        guard count <= limits.maxCapabilities,
              reader.remaining == count * 2 else {
            throw ProtocolError.invalidCount(message: message, fieldID: fieldID)
        }
        var result: [Capability] = []
        result.reserveCapacity(count)
        var mandatoryCapabilities: Set<Capability> = []
        var previous: UInt16?
        for _ in 0 ..< count {
            let wireValue = try reader.readUInt16()
            let rawValue = wireValue & 0x7FFF
            if rawValue == 0 {
                throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
            }
            if let previous, rawValue <= previous {
                throw ProtocolError.invalidFieldValue(message: message, fieldID: fieldID)
            }
            let capability = Capability(rawValue: rawValue)
            let isMandatory = wireValue & 0x8000 != 0
            if isMandatory {
                if case .unknown = capability {
                    throw ProtocolError.unknownMandatoryCapability(rawValue: rawValue)
                }
                mandatoryCapabilities.insert(capability)
            }
            result.append(capability)
            previous = rawValue
        }
        return Decoded(
            capabilities: result,
            mandatoryCapabilities: mandatoryCapabilities
        )
    }
}
