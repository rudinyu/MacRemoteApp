@testable import CodecCore
import CoreGraphics
import CoreVideo
import Foundation
import XCTest

final class CodecCoreTests: XCTestCase {
    func testAdaptiveBitrateCutsOncePerHoldoffAndRespectsFloor() {
        var controller = AdaptiveBitrateController(configuration: .standard(maximumBitrate: 16_000_000))
        XCTAssertEqual(controller.bitrate, 16_000_000)
        XCTAssertEqual(controller.recordCongestion(atNanoseconds: 1_000_000_000), 11_200_000)
        // A burst inside the 500 ms holdoff counts once.
        XCTAssertNil(controller.recordCongestion(atNanoseconds: 1_200_000_000))
        XCTAssertEqual(controller.recordCongestion(atNanoseconds: 1_600_000_000), 7_840_000)
        var now: UInt64 = 1_600_000_000
        for _ in 0 ..< 20 {
            now += 600_000_000
            _ = controller.recordCongestion(atNanoseconds: now)
        }
        XCTAssertEqual(controller.bitrate, 2_000_000, "never below the floor")
        now += 600_000_000
        XCTAssertNil(controller.recordCongestion(atNanoseconds: now), "no change at the floor")
    }

    func testAdaptiveBitrateTreatsReportsAsCongestionOrRecovery() {
        var controller = AdaptiveBitrateController(configuration: .standard(maximumBitrate: 16_000_000))
        // High queuing delay or discards cut the bitrate.
        XCTAssertEqual(
            controller.recordReport(queuingDelayMicroseconds: 60_000, discardedFrames: 0, atNanoseconds: 1_000_000_000),
            11_200_000
        )
        XCTAssertEqual(
            controller.recordReport(queuingDelayMicroseconds: 0, discardedFrames: 3, atNanoseconds: 2_000_000_000),
            7_840_000
        )
        // Low delay does not raise it until 3 s after the last congestion.
        XCTAssertNil(controller.recordReport(queuingDelayMicroseconds: 5_000, discardedFrames: 0, atNanoseconds: 4_000_000_000))
        XCTAssertEqual(
            controller.recordReport(queuingDelayMicroseconds: 5_000, discardedFrames: 0, atNanoseconds: 5_000_000_000),
            9_440_000
        )
        // At most one increase per second, and none while delay is between
        // the clear and congestion thresholds.
        XCTAssertNil(controller.recordReport(queuingDelayMicroseconds: 5_000, discardedFrames: 0, atNanoseconds: 5_500_000_000))
        XCTAssertNil(controller.recordReport(queuingDelayMicroseconds: 25_000, discardedFrames: 0, atNanoseconds: 7_000_000_000))
        var now: UInt64 = 7_000_000_000
        for _ in 0 ..< 20 {
            now += 1_000_000_000
            _ = controller.recordReport(queuingDelayMicroseconds: 0, discardedFrames: 0, atNanoseconds: now)
        }
        XCTAssertEqual(controller.bitrate, 16_000_000, "recovers to, but not above, the maximum")
    }

    func testDefaultBitrateIsSixteenMegabitsWithTwentyFourMegabitPeak() {
        let configuration = H264EncoderConfiguration()
        XCTAssertEqual(configuration.averageBitrate, 16_000_000)
        let limits = H264Encoder.dataRateLimits(for: configuration)
        XCTAssertEqual(limits[0].doubleValue, 3_000_000, "24 Mbps peak is 3,000,000 bytes per second")
    }

    func testEncoderDataRateLimitCapsOneSecondPeakAboveAverage() {
        let configuration = H264EncoderConfiguration(averageBitrate: 8_000_000)
        let limits = H264Encoder.dataRateLimits(for: configuration)
        XCTAssertEqual(limits.count, 2)
        XCTAssertEqual(limits[0].doubleValue, 1_500_000)
        XCTAssertEqual(limits[1].doubleValue, 1.0)
    }

    func testM0FoundationMarker() {
        XCTAssertEqual(CodecCoreModule.name, "CodecCore")
    }

    func testDecoderConfigurationRoundTripRejectsTrailingBytes() throws {
        let configuration = try H264DecoderConfiguration(
            sequenceParameterSet: Data([0x67, 0x42, 0x00, 0x1F]),
            pictureParameterSet: Data([0x68, 0xCE, 0x06, 0xE2])
        )
        XCTAssertEqual(try H264DecoderConfiguration.decode(configuration.encoded()), configuration)

        var corrupt = configuration.encoded()
        corrupt.append(0x00)
        XCTAssertThrowsError(try H264DecoderConfiguration.decode(corrupt)) { error in
            XCTAssertEqual(error as? CodecError, .invalidDecoderConfiguration)
        }
    }

    func testBoundedVideoQueuePreservesKeyframes() async throws {
        let queue = try BoundedVideoFrameQueue(capacity: 2)
        let first = try makeFrame(sequence: 0, keyframe: true)
        let second = try makeFrame(sequence: 1, keyframe: false)
        let third = try makeFrame(sequence: 2, keyframe: false)
        let keyframe = try makeFrame(sequence: 3, keyframe: true)

        let firstResult = try await queue.enqueue(first)
        let secondResult = try await queue.enqueue(second)
        let thirdResult = try await queue.enqueue(third)
        XCTAssertEqual(firstResult, .queued)
        XCTAssertEqual(secondResult, .queued)
        XCTAssertEqual(thirdResult, .replacedNonKeyframe)
        let keyframeResult = try await queue.enqueue(keyframe)
        XCTAssertEqual(keyframeResult, .replacedNonKeyframe)
        let count = await queue.count()
        let firstDequeued = await queue.dequeue()
        let secondDequeued = await queue.dequeue()
        let emptyDequeued = await queue.dequeue()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(firstDequeued, first)
        XCTAssertEqual(secondDequeued, keyframe)
        XCTAssertNil(emptyDequeued)
    }

    func testAspectFitLayoutMaintainsContentAspectRatio() {
        let rect = VideoContentLayout.aspectFitRect(
            contentWidth: 1920,
            contentHeight: 1080,
            in: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )
        XCTAssertEqual(rect.width, 1000, accuracy: 0.001)
        XCTAssertEqual(rect.height, 562.5, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 500, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 500, accuracy: 0.001)
    }

    func testM4VideoToolboxEncodeDecodeSmokeWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["MACREMOTEAPP_RUN_M4_CODEC_SMOKE"] == "1" else {
            throw XCTSkip("set MACREMOTEAPP_RUN_M4_CODEC_SMOKE=1 to use VideoToolbox")
        }
        // BGRA is the historical input; 4:2:0 video range is the M8 capture
        // default and must encode without a format conversion failure.
        for pixelFormat in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            try await runEncodeDecodeSmoke(pixelFormat: pixelFormat)
        }
    }

    private func runEncodeDecodeSmoke(pixelFormat: OSType) async throws {
        let encoder = try H264Encoder(
            configuration: H264EncoderConfiguration(
                width: 64,
                height: 64,
                frameRate: 30,
                averageBitrate: 250_000,
                keyframeInterval: 1
            )
        )
        try encoder.start(generation: 7)
        defer { encoder.reset() }
        let pixelBuffer = try makePixelBuffer(width: 64, height: 64, pixelFormat: pixelFormat)
        let encoded: EncodedH264Frame = try await withCheckedThrowingContinuation { continuation in
            do {
                try encoder.encode(
                    pixelBuffer: pixelBuffer,
                    captureTimestamp: 100,
                    presentationTimestamp: 200,
                    forceKeyframe: true
                ) { result in
                    continuation.resume(with: result)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        XCTAssertEqual(encoded.generation, 7)
        XCTAssertEqual(encoded.captureTimestamp, 100)
        XCTAssertEqual(encoded.presentationTimestamp, 200)
        XCTAssertTrue(encoded.keyframe)
        // Congestion adaptation changes the bitrate on the live session.
        try encoder.updateAverageBitrate(125_000)
        let decoderConfiguration = try XCTUnwrap(encoded.decoderConfiguration)

        let decoder = H264Decoder()
        try decoder.configure(configuration: decoderConfiguration, generation: 7)
        let decoded: DecodedH264Frame = try await withCheckedThrowingContinuation { continuation in
            do {
                try decoder.decode(encoded) { result in
                    continuation.resume(with: result)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        XCTAssertEqual(decoded.generation, 7)
        XCTAssertEqual(decoded.captureTimestamp, 100)
        XCTAssertEqual(decoded.presentationTimestamp, 200)
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 64)
        decoder.reset()
    }

    private func makeFrame(sequence: UInt64, keyframe: Bool) throws -> EncodedH264Frame {
        try EncodedH264Frame(
            generation: 1,
            captureTimestamp: sequence,
            presentationTimestamp: sequence,
            width: 64,
            height: 64,
            keyframe: keyframe,
            accessUnit: Data([UInt8(sequence & 0xFF), 0x01])
        )
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            pixelFormat,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CodecError.videoToolboxFailure(status)
        }
        return pixelBuffer
    }
}
