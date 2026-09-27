import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class H264Encoder: @unchecked Sendable {
    private struct PendingRequest {
        let generation: UInt64
        let captureTimestamp: UInt64
        let presentationTimestamp: UInt64
        let forceKeyframe: Bool
        let completion: @Sendable (Result<EncodedH264Frame, CodecError>) -> Void
    }

    private let configuration: H264EncoderConfiguration
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var generation: UInt64?
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: PendingRequest] = [:]
    private var latestDecoderConfiguration: H264DecoderConfiguration?

    public init(configuration: H264EncoderConfiguration = .default) throws {
        try configuration.validate()
        self.configuration = configuration
    }

    deinit {
        reset()
    }

    public func start(generation: UInt64) throws {
        try start(
            width: configuration.width,
            height: configuration.height,
            generation: generation
        )
    }

    public func start(width: UInt32, height: UInt32, generation: UInt64) throws {
        guard width > 0, height > 0 else {
            throw CodecError.invalidConfiguration("dimensions must be positive")
        }
        lock.lock()
        guard session == nil else {
            lock.unlock()
            throw CodecError.alreadyStarted
        }
        lock.unlock()

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw CodecError.videoToolboxFailure(status)
        }

        do {
            try setProperty(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue, on: newSession)
            // B-frame reordering delays output by at least one frame; the
            // interactive stream must emit each frame as soon as it is encoded.
            try setProperty(
                kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanFalse,
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_Main_AutoLevel as CFTypeRef,
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: configuration.averageBitrate),
                on: newSession
            )
            // A hard cap keeps keyframe and scene-change bursts from filling
            // the TCP send buffer. Not every encoder honors it, so it is
            // best-effort; the average bitrate above remains mandatory.
            try setOptionalProperty(
                kVTCompressionPropertyKey_DataRateLimits,
                value: Self.dataRateLimits(for: configuration) as CFArray,
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_ExpectedFrameRate,
                value: NSNumber(value: configuration.frameRate),
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: NSNumber(value: configuration.keyframeInterval),
                on: newSession
            )
            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(newSession)
            guard prepareStatus == noErr else {
                throw CodecError.videoToolboxFailure(prepareStatus)
            }
        } catch {
            VTCompressionSessionInvalidate(newSession)
            throw error
        }

        lock.withLock {
            session = newSession
            self.generation = generation
            latestDecoderConfiguration = nil
        }
    }

    public func encode(
        pixelBuffer: CVPixelBuffer,
        captureTimestamp: UInt64,
        presentationTimestamp: UInt64,
        forceKeyframe: Bool = false,
        completion: @escaping @Sendable (Result<EncodedH264Frame, CodecError>) -> Void
    ) throws {
        let requestID: UInt64
        let activeSession: VTCompressionSession
        let activeGeneration: UInt64

        lock.lock()
        guard let session, let generation else {
            lock.unlock()
            throw CodecError.notStarted
        }
        guard pending.count < configuration.maxInFlightFrames else {
            lock.unlock()
            throw CodecError.queueFull
        }
        requestID = nextRequestID
        nextRequestID = nextRequestID == UInt64.max ? 1 : nextRequestID + 1
        activeSession = session
        activeGeneration = generation
        pending[requestID] = PendingRequest(
            generation: activeGeneration,
            captureTimestamp: captureTimestamp,
            presentationTimestamp: presentationTimestamp,
            forceKeyframe: forceKeyframe,
            completion: completion
        )
        lock.unlock()

        let frameProperties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        var infoFlags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            activeSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: Int64(presentationTimestamp), timescale: 1_000_000_000),
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, sampleBuffer in
            self?.complete(
                requestID: requestID,
                status: status,
                sampleBuffer: sampleBuffer
            )
        }
        guard status == noErr else {
            let wasPending = lock.withLock {
                pending.removeValue(forKey: requestID) != nil
            }
            // If VideoToolbox already invoked the callback, that callback owns
            // the completion result. Otherwise the synchronous error is the
            // only result and is surfaced to the caller without a callback.
            guard wasPending else { return }
            throw CodecError.videoToolboxFailure(status)
        }
    }

    /// Changes the target bitrate of the running session in place. It takes
    /// effect on subsequent frames without a new session or keyframe, which
    /// lets the Host adapt to congestion mid-stream.
    public func updateAverageBitrate(_ averageBitrate: UInt32) throws {
        guard averageBitrate > 0 else {
            throw CodecError.invalidConfiguration("bitrate must be positive")
        }
        guard let activeSession = lock.withLock({ session }) else {
            throw CodecError.notStarted
        }
        try setProperty(
            kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: averageBitrate),
            on: activeSession
        )
        try setOptionalProperty(
            kVTCompressionPropertyKey_DataRateLimits,
            value: Self.dataRateLimits(averageBitrate: averageBitrate) as CFArray,
            on: activeSession
        )
    }

    public func reset() {
        let oldSession: VTCompressionSession?
        let completions: [@Sendable (Result<EncodedH264Frame, CodecError>) -> Void]
        lock.lock()
        oldSession = session
        session = nil
        generation = nil
        latestDecoderConfiguration = nil
        completions = pending.values.map(\.completion)
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
        if let oldSession {
            VTCompressionSessionInvalidate(oldSession)
        }
        completions.forEach { $0(.failure(.cancelled)) }
    }

    private func complete(
        requestID: UInt64,
        status: OSStatus,
        sampleBuffer: CMSampleBuffer?
    ) {
        let request: PendingRequest?
        lock.lock()
        request = pending.removeValue(forKey: requestID)
        lock.unlock()
        guard let request else { return }

        guard status == noErr, let sampleBuffer else {
            request.completion(.failure(.videoToolboxFailure(status)))
            return
        }
        do {
            let result = try makeFrame(from: sampleBuffer, request: request)
            request.completion(.success(result))
        } catch let error as CodecError {
            request.completion(.failure(error))
        } catch {
            request.completion(.failure(.invalidAccessUnit))
        }
    }

    private func makeFrame(
        from sampleBuffer: CMSampleBuffer,
        request: PendingRequest
    ) throws -> EncodedH264Frame {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw CodecError.invalidAccessUnit
        }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard pointerStatus == kCMBlockBufferNoErr,
              let dataPointer,
              totalLength > 0 else {
            throw CodecError.invalidAccessUnit
        }
        let accessUnit = Data(bytes: dataPointer, count: totalLength)
        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        let decoderConfiguration = try formatDescription.flatMap {
            try H264Encoder.decoderConfiguration(from: $0)
        }
        if let decoderConfiguration {
            lock.withLock { latestDecoderConfiguration = decoderConfiguration }
        }
        let keyframe = request.forceKeyframe || Self.isKeyframe(sampleBuffer)
        let dimensions = formatDescription.map(CMVideoFormatDescriptionGetDimensions)
        return try EncodedH264Frame(
            generation: request.generation,
            captureTimestamp: request.captureTimestamp,
            presentationTimestamp: request.presentationTimestamp,
            width: UInt32(max(1, dimensions?.width ?? Int32(configuration.width))),
            height: UInt32(max(1, dimensions?.height ?? Int32(configuration.height))),
            keyframe: keyframe,
            accessUnit: accessUnit,
            decoderConfiguration: keyframe ? decoderConfiguration : nil
        )
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) else {
            return false
        }
        let array = attachments as NSArray
        let dictionary = array.firstObject as? NSDictionary
        return (dictionary?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private static func decoderConfiguration(
        from description: CMFormatDescription
    ) throws -> H264DecoderConfiguration? {
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let firstStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard firstStatus == noErr, let firstPointer = pointer, size > 0, parameterSetCount >= 2 else {
            return nil
        }
        let sps = Data(bytes: firstPointer, count: size)
        var secondPointer: UnsafePointer<UInt8>?
        var secondSize = 0
        let secondStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 1,
            parameterSetPointerOut: &secondPointer,
            parameterSetSizeOut: &secondSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard secondStatus == noErr, let secondPointer, secondSize > 0 else {
            return nil
        }
        return try H264DecoderConfiguration(
            sequenceParameterSet: sps,
            pictureParameterSet: Data(bytes: secondPointer, count: secondSize)
        )
    }

    /// Peak-to-average ratio for `DataRateLimits`, measured over one second.
    static let peakBitrateMultiplier = 1.5

    /// Returns the VideoToolbox `DataRateLimits` pair: a byte budget and the
    /// window in seconds over which it applies.
    static func dataRateLimits(for configuration: H264EncoderConfiguration) -> [NSNumber] {
        dataRateLimits(averageBitrate: configuration.averageBitrate)
    }

    static func dataRateLimits(averageBitrate: UInt32) -> [NSNumber] {
        let peakBytesPerSecond = Double(averageBitrate) * peakBitrateMultiplier / 8
        return [NSNumber(value: peakBytesPerSecond.rounded(.down)), NSNumber(value: 1.0)]
    }

    private func setOptionalProperty(
        _ key: CFString,
        value: CFTypeRef,
        on session: VTCompressionSession
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr || status == kVTPropertyNotSupportedErr else {
            throw CodecError.videoToolboxFailure(status)
        }
    }

    private func setProperty(
        _ key: CFString,
        value: CFTypeRef,
        on session: VTCompressionSession
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw CodecError.videoToolboxFailure(status)
        }
    }
}
