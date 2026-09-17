import CoreGraphics
import CoreVideo
import Foundation

public enum CodecError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)
    case notStarted
    case alreadyStarted
    case missingDecoderConfiguration
    case invalidDecoderConfiguration
    case invalidAccessUnit
    case staleGeneration(expected: UInt64, actual: UInt64)
    case queueFull
    case cancelled
    case videoToolboxFailure(OSStatus)

    public var description: String {
        switch self {
        case let .invalidConfiguration(detail): return "invalid codec configuration: \(detail)"
        case .notStarted: return "codec is not started"
        case .alreadyStarted: return "codec is already started"
        case .missingDecoderConfiguration: return "decoder configuration is required"
        case .invalidDecoderConfiguration: return "decoder configuration is invalid"
        case .invalidAccessUnit: return "H.264 access unit is invalid"
        case let .staleGeneration(expected, actual):
            return "stale codec generation: expected \(expected), received \(actual)"
        case .queueFull: return "codec frame queue is full"
        case .cancelled: return "codec operation was cancelled"
        case let .videoToolboxFailure(status): return "VideoToolbox failed with status \(status)"
        }
    }
}

public struct H264EncoderConfiguration: Equatable, Sendable {
    public static let `default` = H264EncoderConfiguration()

    public let width: UInt32
    public let height: UInt32
    public let frameRate: UInt16
    public let averageBitrate: UInt32
    public let keyframeInterval: UInt32
    public let maxInFlightFrames: Int

    public init(
        width: UInt32 = 1920,
        height: UInt32 = 1080,
        frameRate: UInt16 = 60,
        averageBitrate: UInt32 = 8_000_000,
        keyframeInterval: UInt32 = 60,
        maxInFlightFrames: Int = 2
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.averageBitrate = averageBitrate
        self.keyframeInterval = keyframeInterval
        self.maxInFlightFrames = maxInFlightFrames
    }

    public func validate() throws {
        guard width > 0, height > 0 else {
            throw CodecError.invalidConfiguration("dimensions must be positive")
        }
        guard frameRate > 0 else {
            throw CodecError.invalidConfiguration("frame rate must be positive")
        }
        guard averageBitrate > 0 else {
            throw CodecError.invalidConfiguration("bitrate must be positive")
        }
        guard keyframeInterval > 0 else {
            throw CodecError.invalidConfiguration("keyframe interval must be positive")
        }
        guard maxInFlightFrames > 0 else {
            throw CodecError.invalidConfiguration("in-flight frame limit must be positive")
        }
    }
}

/// The compact decoder-configuration payload carried in VideoConfigMessage.
/// It deliberately contains only one SPS and one PPS, which is sufficient for
/// the V1 H.264 baseline and keeps the wire contract bounded and deterministic.
public struct H264DecoderConfiguration: Equatable, Sendable {
    private static let magic = Data([0x4D, 0x52, 0x41, 0x48, 0x32, 0x36, 0x34, 0x01])
    private static let maximumParameterSetBytes = 1_048_576

    public let sequenceParameterSet: Data
    public let pictureParameterSet: Data

    public init(sequenceParameterSet: Data, pictureParameterSet: Data) throws {
        guard !sequenceParameterSet.isEmpty,
              !pictureParameterSet.isEmpty,
              sequenceParameterSet.count <= Self.maximumParameterSetBytes,
              pictureParameterSet.count <= Self.maximumParameterSetBytes else {
            throw CodecError.invalidDecoderConfiguration
        }
        self.sequenceParameterSet = sequenceParameterSet
        self.pictureParameterSet = pictureParameterSet
    }

    public func encoded() -> Data {
        var data = Self.magic
        appendUInt32(UInt32(sequenceParameterSet.count), to: &data)
        data.append(sequenceParameterSet)
        appendUInt32(UInt32(pictureParameterSet.count), to: &data)
        data.append(pictureParameterSet)
        return data
    }

    public static func decode(_ data: Data) throws -> H264DecoderConfiguration {
        guard data.count >= magic.count + 8,
              data.prefix(magic.count) == magic else {
            throw CodecError.invalidDecoderConfiguration
        }
        var reader = ByteReader(data: data.dropFirst(magic.count))
        let spsLength = try reader.readUInt32()
        guard spsLength > 0, spsLength <= maximumParameterSetBytes else {
            throw CodecError.invalidDecoderConfiguration
        }
        let sps = try reader.readData(count: Int(spsLength))
        let ppsLength = try reader.readUInt32()
        guard ppsLength > 0, ppsLength <= maximumParameterSetBytes else {
            throw CodecError.invalidDecoderConfiguration
        }
        let pps = try reader.readData(count: Int(ppsLength))
        guard reader.isAtEnd else {
            throw CodecError.invalidDecoderConfiguration
        }
        return try H264DecoderConfiguration(
            sequenceParameterSet: sps,
            pictureParameterSet: pps
        )
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

public struct EncodedH264Frame: Equatable, Sendable {
    public let generation: UInt64
    public let captureTimestamp: UInt64
    public let presentationTimestamp: UInt64
    public let width: UInt32
    public let height: UInt32
    public let keyframe: Bool
    public let accessUnit: Data
    public let decoderConfiguration: H264DecoderConfiguration?

    public init(
        generation: UInt64,
        captureTimestamp: UInt64,
        presentationTimestamp: UInt64,
        width: UInt32,
        height: UInt32,
        keyframe: Bool,
        accessUnit: Data,
        decoderConfiguration: H264DecoderConfiguration? = nil
    ) throws {
        guard width > 0, height > 0, !accessUnit.isEmpty else {
            throw CodecError.invalidAccessUnit
        }
        self.generation = generation
        self.captureTimestamp = captureTimestamp
        self.presentationTimestamp = presentationTimestamp
        self.width = width
        self.height = height
        self.keyframe = keyframe
        self.accessUnit = accessUnit
        self.decoderConfiguration = decoderConfiguration
    }
}

public struct DecodedH264Frame: @unchecked Sendable {
    public let generation: UInt64
    public let captureTimestamp: UInt64
    public let presentationTimestamp: UInt64
    public let width: UInt32
    public let height: UInt32
    public let pixelBuffer: CVPixelBuffer

    public init(
        generation: UInt64,
        captureTimestamp: UInt64,
        presentationTimestamp: UInt64,
        width: UInt32,
        height: UInt32,
        pixelBuffer: CVPixelBuffer
    ) {
        self.generation = generation
        self.captureTimestamp = captureTimestamp
        self.presentationTimestamp = presentationTimestamp
        self.width = width
        self.height = height
        self.pixelBuffer = pixelBuffer
    }
}

public enum VideoFrameQueueResult: Equatable, Sendable {
    case queued
    case replacedNonKeyframe
}

public actor BoundedVideoFrameQueue {
    private let capacity: Int
    private var frames: [EncodedH264Frame] = []

    public init(capacity: Int = 3) throws {
        guard capacity > 0 else {
            throw CodecError.invalidConfiguration("frame queue capacity must be positive")
        }
        self.capacity = capacity
    }

    @discardableResult
    public func enqueue(_ frame: EncodedH264Frame) throws -> VideoFrameQueueResult {
        guard frames.count < capacity else {
            guard let oldIndex = frames.firstIndex(where: { !$0.keyframe }) else {
                throw CodecError.queueFull
            }
            frames.remove(at: oldIndex)
            frames.append(frame)
            return .replacedNonKeyframe
        }
        frames.append(frame)
        return .queued
    }

    public func dequeue() -> EncodedH264Frame? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    public func count() -> Int {
        frames.count
    }

    public func removeAll() {
        frames.removeAll(keepingCapacity: true)
    }
}

public enum VideoContentLayout {
    public static func aspectFitRect(
        contentWidth: CGFloat,
        contentHeight: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        guard contentWidth > 0, contentHeight > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / contentWidth, bounds.height / contentHeight)
        let size = CGSize(width: contentWidth * scale, height: contentHeight * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct ByteReader {
    private let data: Data
    private var offset = 0

    init(data: Data.SubSequence) {
        self.data = Data(data)
    }

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readUInt32() throws -> UInt32 {
        guard data.count - offset >= 4 else {
            throw CodecError.invalidDecoderConfiguration
        }
        let value = (UInt32(data[offset]) << 24) |
            (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) |
            UInt32(data[offset + 3])
        offset += 4
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, data.count - offset >= count else {
            throw CodecError.invalidDecoderConfiguration
        }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }
}
