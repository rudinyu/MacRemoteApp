import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class H264Decoder: @unchecked Sendable {
    private final class DecodeRequest: @unchecked Sendable {
        let requestID: UInt64
        let frame: EncodedH264Frame
        let completion: @Sendable (Result<DecodedH264Frame, CodecError>) -> Void
        weak var owner: H264Decoder?
        private let completionLock = NSLock()
        private var completionClaimed = false
        private var refConClaimed = false

        init(
            requestID: UInt64,
            frame: EncodedH264Frame,
            completion: @escaping @Sendable (Result<DecodedH264Frame, CodecError>) -> Void,
            owner: H264Decoder
        ) {
            self.requestID = requestID
            self.frame = frame
            self.completion = completion
            self.owner = owner
        }

        func claimCompletion() -> Bool {
            completionLock.withLock {
                guard !completionClaimed else { return false }
                completionClaimed = true
                return true
            }
        }

        func claimRefCon() -> Bool {
            completionLock.withLock {
                guard !refConClaimed else { return false }
                refConClaimed = true
                return true
            }
        }
    }

    private static let outputCallback: VTDecompressionOutputCallback = {
        _, sourceFrameRefCon, status, _, imageBuffer, presentationTimeStamp, _ in
        guard let sourceFrameRefCon else { return }
        let unretainedRequest = Unmanaged<DecodeRequest>.fromOpaque(sourceFrameRefCon).takeUnretainedValue()
        guard unretainedRequest.claimRefCon() else { return }
        let request = Unmanaged<DecodeRequest>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
        guard let owner = request.owner,
              owner.claim(requestID: request.requestID),
              request.claimCompletion() else {
            return
        }
        guard status == noErr, let imageBuffer else {
            request.completion(.failure(.videoToolboxFailure(status)))
            return
        }
        let decoded = DecodedH264Frame(
            generation: request.frame.generation,
            captureTimestamp: request.frame.captureTimestamp,
            presentationTimestamp: request.frame.presentationTimestamp,
            width: UInt32(CVPixelBufferGetWidth(imageBuffer)),
            height: UInt32(CVPixelBufferGetHeight(imageBuffer)),
            pixelBuffer: imageBuffer
        )
        request.completion(.success(decoded))
        _ = presentationTimeStamp
    }

    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var generation: UInt64?
    private var decoderConfiguration: H264DecoderConfiguration?
    private var nextRequestID: UInt64 = 1
    private var pendingRequests: [UInt64: DecodeRequest] = [:]

    public init() {}

    deinit {
        reset()
    }

    public func configure(
        configuration: H264DecoderConfiguration,
        generation: UInt64
    ) throws {
        let newFormat = try Self.makeFormatDescription(configuration: configuration)
        var newSession: VTDecompressionSession?
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: newFormat,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw CodecError.videoToolboxFailure(status)
        }

        lock.lock()
        if let currentGeneration = self.generation, generation < currentGeneration {
            lock.unlock()
            VTDecompressionSessionInvalidate(newSession)
            throw CodecError.staleGeneration(expected: currentGeneration, actual: generation)
        }
        let oldSession = session
        let oldRequests = Array(pendingRequests.values)
        pendingRequests.removeAll(keepingCapacity: false)
        session = newSession
        formatDescription = newFormat
        self.generation = generation
        decoderConfiguration = configuration
        lock.unlock()
        if let oldSession {
            VTDecompressionSessionInvalidate(oldSession)
        }
        oldRequests.forEach { request in
            if request.claimCompletion() {
                request.completion(.failure(.cancelled))
            }
        }
    }

    public func decode(
        _ frame: EncodedH264Frame,
        completion: @escaping @Sendable (Result<DecodedH264Frame, CodecError>) -> Void
    ) throws {
        guard !frame.accessUnit.isEmpty else {
            throw CodecError.invalidAccessUnit
        }

        lock.lock()
        let activeGeneration = generation
        let activeSession = session
        let activeFormatDescription = formatDescription
        lock.unlock()

        if let activeGeneration, frame.generation < activeGeneration {
            throw CodecError.staleGeneration(expected: activeGeneration, actual: frame.generation)
        }
        if activeGeneration == nil || frame.generation > activeGeneration! {
            guard let configuration = frame.decoderConfiguration else {
                throw CodecError.missingDecoderConfiguration
            }
            try configure(configuration: configuration, generation: frame.generation)
            return try decode(frame, completion: completion)
        }
        guard let activeSession, let activeFormatDescription else {
            throw CodecError.missingDecoderConfiguration
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: frame.accessUnit.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.accessUnit.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw CodecError.videoToolboxFailure(blockStatus)
        }
        let copyStatus = frame.accessUnit.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return OSStatus(kCMBlockBufferBadCustomBlockSourceErr)
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: frame.accessUnit.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw CodecError.videoToolboxFailure(copyStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: Int64(frame.presentationTimestamp),
                timescale: 1_000_000_000
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = frame.accessUnit.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: activeFormatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw CodecError.videoToolboxFailure(sampleStatus)
        }

        let requestID: UInt64
        lock.lock()
        requestID = nextRequestID
        nextRequestID = nextRequestID == UInt64.max ? 1 : nextRequestID + 1
        let request = DecodeRequest(
            requestID: requestID,
            frame: frame,
            completion: completion,
            owner: self
        )
        pendingRequests[requestID] = request
        lock.unlock()
        let refcon = Unmanaged.passRetained(request).toOpaque()
        let status = VTDecompressionSessionDecodeFrame(
            activeSession,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: refcon,
            infoFlagsOut: nil
        )
        guard status == noErr else {
            // VideoToolbox may report a synchronous error without invoking
            // the callback, or invoke the callback before returning. Claim
            // the refcon exactly once and deliver exactly one completion in
            // either case; never both complete and throw for one request.
            let unretainedRequest = Unmanaged<DecodeRequest>.fromOpaque(refcon).takeUnretainedValue()
            guard unretainedRequest.claimRefCon() else { return }
            let request = Unmanaged<DecodeRequest>.fromOpaque(refcon).takeRetainedValue()
            _ = claim(requestID: requestID)
            if request.claimCompletion() {
                request.completion(.failure(.videoToolboxFailure(status)))
            }
            return
        }
    }

    public func reset() {
        let requests: [DecodeRequest]
        lock.lock()
        let oldSession = session
        requests = Array(pendingRequests.values)
        pendingRequests.removeAll(keepingCapacity: false)
        session = nil
        formatDescription = nil
        generation = nil
        decoderConfiguration = nil
        lock.unlock()
        if let oldSession {
            VTDecompressionSessionInvalidate(oldSession)
        }
        requests.forEach { request in
            if request.claimCompletion() {
                request.completion(.failure(.cancelled))
            }
        }
    }

    public func currentGeneration() -> UInt64? {
        lock.withLock { generation }
    }

    private func claim(requestID: UInt64) -> Bool {
        lock.withLock {
            pendingRequests.removeValue(forKey: requestID) != nil
        }
    }

    private static func makeFormatDescription(
        configuration: H264DecoderConfiguration
    ) throws -> CMVideoFormatDescription {
        var formatDescription: CMVideoFormatDescription?
        let status = configuration.sequenceParameterSet.withUnsafeBytes { spsBytes in
            configuration.pictureParameterSet.withUnsafeBytes { ppsBytes in
                guard let spsPointer = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPointer = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                let pointers = [spsPointer, ppsPointer]
                let sizes = [configuration.sequenceParameterSet.count, configuration.pictureParameterSet.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: nil,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }
            }
        }
        guard status == noErr, let formatDescription else {
            throw CodecError.videoToolboxFailure(status)
        }
        return formatDescription
    }
}
