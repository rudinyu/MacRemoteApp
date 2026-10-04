import Foundation
import RemoteProtocol
@testable import TransportCore
import XCTest

final class ProtectionInvalidationTests: XCTestCase {
    func testBoundedFrameQueueTombstonesM8ControlAndPreservesSequence() async throws {
        let queue = try BoundedFrameQueue(maxControlFrames: 8, maxMediaFrames: 2)
        let envelopes = try makeControlEnvelopes()

        for envelope in envelopes {
            _ = try await queue.enqueue(envelope)
        }
        await queue.removeProtectedMessages()

        let keyframeTombstoneCandidate = await queue.dequeue()
        let reportTombstoneCandidate = await queue.dequeue()
        let keyframeTombstone = try XCTUnwrap(keyframeTombstoneCandidate)
        let reportTombstone = try XCTUnwrap(reportTombstoneCandidate)
        let ping = await queue.dequeue()
        let pong = await queue.dequeue()
        let empty = await queue.dequeue()

        XCTAssertEqual(keyframeTombstone.messageType, .unknown(0x7FFE))
        XCTAssertEqual(keyframeTombstone.sequence, envelopes[0].sequence)
        XCTAssertThrowsError(try keyframeTombstone.decodedMessage())
        XCTAssertEqual(reportTombstone.messageType, .unknown(0x7FFE))
        XCTAssertEqual(reportTombstone.sequence, envelopes[1].sequence)
        XCTAssertThrowsError(try reportTombstone.decodedMessage())
        XCTAssertEqual(ping, envelopes[2])
        XCTAssertEqual(pong, envelopes[3])
        XCTAssertNil(empty)
    }

    func testEnvelopeStreamStorageTombstonesM8ControlAndPreservesSequence() async throws {
        let output = try EnvelopeStream.makeBounded(maxControlFrames: 8, maxMediaFrames: 2)
        let envelopes = try makeControlEnvelopes()

        for envelope in envelopes {
            _ = try output.storage.yield(envelope)
        }
        output.storage.removeProtectedMessages()

        let keyframeTombstoneCandidate = try await output.storage.next()
        let reportTombstoneCandidate = try await output.storage.next()
        let keyframeTombstone = try XCTUnwrap(keyframeTombstoneCandidate)
        let reportTombstone = try XCTUnwrap(reportTombstoneCandidate)
        let ping = try await output.storage.next()
        let pong = try await output.storage.next()

        XCTAssertEqual(keyframeTombstone.messageType, .unknown(0x7FFE))
        XCTAssertEqual(keyframeTombstone.sequence, envelopes[0].sequence)
        XCTAssertThrowsError(try keyframeTombstone.decodedMessage())
        XCTAssertEqual(reportTombstone.messageType, .unknown(0x7FFE))
        XCTAssertEqual(reportTombstone.sequence, envelopes[1].sequence)
        XCTAssertThrowsError(try reportTombstone.decodedMessage())
        XCTAssertEqual(ping, envelopes[2])
        XCTAssertEqual(pong, envelopes[3])
        XCTAssertEqual(output.storage.counts().control, 0)
        XCTAssertEqual(output.storage.counts().media, 0)
    }

    func testMessageStreamStoragePurgesM8ControlAndPreservesUnprotectedMessages() async throws {
        let output = try MessageStream.makeBounded(maxControlMessages: 8, maxMediaMessages: 2)
        let payloads = makeControlPayloads()

        for payload in payloads {
            _ = try output.storage.yield(payload)
        }
        output.storage.removeProtectedMessages()

        let ping = try await output.storage.next()
        let pong = try await output.storage.next()

        XCTAssertEqual(ping, payloads[2])
        XCTAssertEqual(pong, payloads[3])
        XCTAssertEqual(output.storage.counts().control, 0)
        XCTAssertEqual(output.storage.counts().media, 0)
    }

    private func makeControlPayloads() -> [MessagePayload] {
        [
            .keyframeRequest(KeyframeRequestMessage(generation: 17, reason: .mediaGap)),
            .receiverReport(
                ReceiverReportMessage(
                    generation: 17,
                    queuingDelayMicroseconds: 20_000,
                    receivedFrames: 60,
                    discardedFrames: 2
                )
            ),
            .ping(PingMessage(nonce: 23)),
            .pong(PongMessage(nonce: 29, receiverTimestampNanoseconds: 31))
        ]
    }

    private func makeControlEnvelopes() throws -> [Envelope] {
        try makeControlPayloads().enumerated().map { index, payload in
            try Envelope(
                message: payload,
                sequence: UInt64(index + 1),
                timestamp: UInt64(index + 11)
            )
        }
    }
}
