import CodecCore
import Foundation
import XCTest
@testable import Host

final class HostEncodedFrameRelayTests: XCTestCase {
    func testPreGapQueueDoesNotLetItsKeyframeRepairTheLaterGap() async throws {
        let relay = HostEncodedFrameRelay()
        relay.submit(.success(try makeFrame(sequence: 0, keyframe: true)))
        for sequence in 1..<HostEncodedFrameRelay.capacity {
            relay.submit(.success(try makeFrame(sequence: UInt64(sequence), keyframe: false)))
        }
        relay.submit(.success(try makeFrame(sequence: 8, keyframe: false)))

        var iterator = relay.frames.makeAsyncIterator()
        var continuity = HostEncodedFrameContinuity()

        // The consumer starts only after the overflow. The queued keyframe and
        // deltas precede the gap and remain valid in FIFO order.
        let maybeOldKeyframe = await iterator.next()
        let oldKeyframe = try XCTUnwrap(maybeOldKeyframe)
        XCTAssertFalse(oldKeyframe.followsDroppedFrame)
        let oldKeyframeDecision = continuity.consume(
            oldKeyframe,
            droppedFrameObserved: relay.takeDroppedFrame()
        )
        XCTAssertTrue(oldKeyframeDecision.requestKeyframe, "overflow still requests a keyframe")
        XCTAssertTrue(oldKeyframeDecision.shouldSend)
        XCTAssertFalse(continuity.awaitingKeyframe)

        // Freeing one slot allows the first result submitted after the gap in.
        relay.submit(.success(try makeFrame(sequence: 9, keyframe: false)))
        for _ in 1..<HostEncodedFrameRelay.capacity {
            let maybeQueuedFrame = await iterator.next()
            let queuedFrame = try XCTUnwrap(maybeQueuedFrame)
            XCTAssertFalse(queuedFrame.followsDroppedFrame)
            let decision = continuity.consume(
                queuedFrame,
                droppedFrameObserved: relay.takeDroppedFrame()
            )
            XCTAssertTrue(decision.shouldSend)
        }

        let maybePostGapDelta = await iterator.next()
        let postGapDelta = try XCTUnwrap(maybePostGapDelta)
        XCTAssertTrue(postGapDelta.followsDroppedFrame)
        let postGapDecision = continuity.consume(
            postGapDelta,
            droppedFrameObserved: relay.takeDroppedFrame()
        )
        XCTAssertFalse(postGapDecision.shouldSend)
        XCTAssertTrue(continuity.awaitingKeyframe)

        relay.submit(.success(try makeFrame(sequence: 10, keyframe: false)))
        let maybeAnotherDelta = await iterator.next()
        let anotherDelta = try XCTUnwrap(maybeAnotherDelta)
        XCTAssertFalse(anotherDelta.followsDroppedFrame)
        XCTAssertFalse(
            continuity.consume(
                anotherDelta,
                droppedFrameObserved: relay.takeDroppedFrame()
            ).shouldSend
        )

        relay.submit(.success(try makeFrame(sequence: 11, keyframe: true)))
        let maybeRecoveryKeyframe = await iterator.next()
        let recoveryKeyframe = try XCTUnwrap(maybeRecoveryKeyframe)
        XCTAssertTrue(
            continuity.consume(
                recoveryKeyframe,
                droppedFrameObserved: relay.takeDroppedFrame()
            ).shouldSend
        )
        XCTAssertFalse(continuity.awaitingKeyframe)

        relay.submit(.success(try makeFrame(sequence: 12, keyframe: false)))
        let maybeRecoveredDelta = await iterator.next()
        let recoveredDelta = try XCTUnwrap(maybeRecoveredDelta)
        XCTAssertTrue(
            continuity.consume(
                recoveredDelta,
                droppedFrameObserved: relay.takeDroppedFrame()
            ).shouldSend
        )
    }

    func testDroppedCodecErrorAndDroppedKeyframeBothMarkTheNextAcceptedFrame() async throws {
        let droppedResults: [HostEncodedFrameRelay.ResultElement] = [
            .failure(.queueFull),
            .success(try makeFrame(sequence: 8, keyframe: true))
        ]

        for (index, droppedResult) in droppedResults.enumerated() {
            let relay = HostEncodedFrameRelay()
            relay.submit(.success(try makeFrame(sequence: 0, keyframe: true)))
            for sequence in 1..<HostEncodedFrameRelay.capacity {
                relay.submit(.success(try makeFrame(sequence: UInt64(sequence), keyframe: false)))
            }
            relay.submit(droppedResult)

            var iterator = relay.frames.makeAsyncIterator()
            var continuity = HostEncodedFrameContinuity()
            let maybeOldKeyframe = await iterator.next()
            let oldKeyframe = try XCTUnwrap(maybeOldKeyframe)
            let oldKeyframeDecision = continuity.consume(
                oldKeyframe,
                droppedFrameObserved: relay.takeDroppedFrame()
            )
            XCTAssertTrue(oldKeyframeDecision.requestKeyframe)
            XCTAssertTrue(oldKeyframeDecision.shouldSend)

            let postGapSequence = UInt64(20 + index)
            relay.submit(.success(try makeFrame(sequence: postGapSequence, keyframe: false)))
            for _ in 1..<HostEncodedFrameRelay.capacity {
                let maybeQueuedFrame = await iterator.next()
                let queuedFrame = try XCTUnwrap(maybeQueuedFrame)
                XCTAssertTrue(
                    continuity.consume(
                        queuedFrame,
                        droppedFrameObserved: relay.takeDroppedFrame()
                    ).shouldSend
                )
            }

            let maybePostGapFrame = await iterator.next()
            let postGapFrame = try XCTUnwrap(maybePostGapFrame)
            XCTAssertTrue(postGapFrame.followsDroppedFrame)
            XCTAssertFalse(
                continuity.consume(
                    postGapFrame,
                    droppedFrameObserved: relay.takeDroppedFrame()
                ).shouldSend
            )
            XCTAssertTrue(continuity.awaitingKeyframe)
        }
    }

    func testConcurrentSubmissionsKeepTheRecoveryMarkerOnAnAcceptedFrame() async throws {
        let relay = HostEncodedFrameRelay()
        relay.submit(.success(try makeFrame(sequence: 0, keyframe: true)))
        for sequence in 1..<HostEncodedFrameRelay.capacity {
            relay.submit(.success(try makeFrame(sequence: UInt64(sequence), keyframe: false)))
        }
        relay.submit(.failure(.queueFull))

        var iterator = relay.frames.makeAsyncIterator()
        let maybeFirstQueuedFrame = await iterator.next()
        _ = try XCTUnwrap(maybeFirstQueuedFrame)

        let concurrentFrames = try (0..<16).map { index in
            try makeFrame(sequence: UInt64(100 + index), keyframe: false)
        }
        DispatchQueue.concurrentPerform(iterations: concurrentFrames.count) { index in
            relay.submit(.success(concurrentFrames[index]))
        }

        var acceptedAfterGap: [HostEncodedFrameRelay.Frame] = []
        for _ in 0..<HostEncodedFrameRelay.capacity {
            let maybeFrame = await iterator.next()
            acceptedAfterGap.append(try XCTUnwrap(maybeFrame))
        }

        XCTAssertEqual(acceptedAfterGap.filter(\.followsDroppedFrame).count, 1)
        XCTAssertTrue(acceptedAfterGap.last?.followsDroppedFrame == true)
    }

    private func makeFrame(sequence: UInt64, keyframe: Bool) throws -> EncodedH264Frame {
        try EncodedH264Frame(
            generation: 1,
            captureTimestamp: sequence,
            presentationTimestamp: sequence,
            width: 16,
            height: 16,
            keyframe: keyframe,
            accessUnit: Data([UInt8(sequence % 255 + 1)])
        )
    }
}
