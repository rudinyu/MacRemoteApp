import Foundation

public struct FrameParser: Sendable {
    private var buffer = Data()
    private var lastSequenceByChannel: [Channel: UInt64] = [:]

    public let limits: ProtocolLimits
    public let supportedVersion: ProtocolVersion

    public init(
        limits: ProtocolLimits = .default,
        supportedVersion: ProtocolVersion = .current
    ) throws {
        guard limits.isSane else {
            throw ProtocolError.invalidLimits
        }
        self.limits = limits
        self.supportedVersion = supportedVersion
    }

    public var bufferedByteCount: Int {
        buffer.count
    }

    public mutating func append(_ bytes: Data) throws -> [Envelope] {
        guard !bytes.isEmpty else {
            return []
        }
        buffer.append(bytes)

        var envelopes: [Envelope] = []
        while buffer.count >= Envelope.headerSize {
            let frameLength = try Envelope.requiredFrameLength(
                in: buffer,
                limits: limits,
                supportedVersion: supportedVersion
            )
            guard buffer.count >= frameLength else {
                break
            }

            let frameData = buffer.prefix(frameLength)
            let envelope = try Envelope.decode(
                Data(frameData),
                limits: limits,
                supportedVersion: supportedVersion
            )
            try validateSequence(envelope)
            envelopes.append(envelope)
            buffer = Data(buffer.dropFirst(frameLength))
        }
        return envelopes
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        lastSequenceByChannel.removeAll(keepingCapacity: false)
    }

    private mutating func validateSequence(_ envelope: Envelope) throws {
        guard let previous = lastSequenceByChannel[envelope.channel] else {
            lastSequenceByChannel[envelope.channel] = envelope.sequence
            return
        }
        guard previous < UInt64.max else {
            throw ProtocolError.sequenceOverflow
        }
        let expected = previous + 1
        guard envelope.sequence == expected else {
            throw ProtocolError.invalidSequence(
                expected: expected,
                actual: envelope.sequence
            )
        }
        lastSequenceByChannel[envelope.channel] = envelope.sequence
    }
}
