import Foundation

internal struct WireWriter {
    internal private(set) var data = Data()

    internal mutating func appendByte(_ value: UInt8) {
        data.append(value)
    }

    internal mutating func appendUInt16(_ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    internal mutating func appendUInt32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    internal mutating func appendUInt64(_ value: UInt64) {
        appendUInt32(UInt32((value >> 32) & 0xFFFF_FFFF))
        appendUInt32(UInt32(value & 0xFFFF_FFFF))
    }

    internal mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    internal mutating func appendData(_ value: Data) {
        data.append(value)
    }
}

internal struct WireReader {
    private let data: Data
    private(set) var offset: Int = 0

    internal init(data: Data) {
        // Data slices can retain a non-zero startIndex after an incremental
        // parser removes a completed frame. Normalize the backing indices so
        // the integer wire offset remains a valid Data index.
        self.data = Data(data)
    }

    internal var remaining: Int {
        data.count - offset
    }

    internal var isAtEnd: Bool {
        offset == data.count
    }

    internal mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else {
            throw ProtocolError.truncated(expected: offset + 1, actual: data.count)
        }
        defer { offset += 1 }
        return data[offset]
    }

    internal mutating func readUInt16() throws -> UInt16 {
        let first = UInt16(try readByte())
        let second = UInt16(try readByte())
        return (first << 8) | second
    }

    internal mutating func readUInt32() throws -> UInt32 {
        let first = UInt32(try readByte())
        let second = UInt32(try readByte())
        let third = UInt32(try readByte())
        let fourth = UInt32(try readByte())
        return (first << 24) | (second << 16) | (third << 8) | fourth
    }

    internal mutating func readUInt64() throws -> UInt64 {
        let high = UInt64(try readUInt32())
        let low = UInt64(try readUInt32())
        return (high << 32) | low
    }

    internal mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    internal mutating func readData(count: Int) throws -> Data {
        guard count >= 0, remaining >= count else {
            throw ProtocolError.truncated(expected: offset + max(count, 0), actual: data.count)
        }
        let result = data.subdata(in: offset ..< offset + count)
        offset += count
        return result
    }
}
