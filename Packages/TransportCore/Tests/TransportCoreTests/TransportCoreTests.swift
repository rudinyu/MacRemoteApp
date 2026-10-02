import Foundation
import RemoteProtocol
import SecurityCore
@testable import TransportCore
import XCTest

final class TransportCoreTests: XCTestCase {
    func testStreamGenerationGateRejectsStaleFramesAndRevokedInput() {
        var gate = StreamGenerationGate()
        XCTAssertFalse(gate.accepts(1))

        gate.advance(to: 7)
        XCTAssertTrue(gate.accepts(7))
        XCTAssertFalse(gate.accepts(6))

        gate.advance(to: 6)
        XCTAssertEqual(gate.generation, 7)

        gate.revoke()
        XCTAssertFalse(gate.accepts(7))
    }

    func testM0FoundationMarker() {
        XCTAssertEqual(TransportCoreModule.name, "TransportCore")
    }

    func testInMemoryBonjourDiscoveryPublishesReadinessSeparatelyFromResults() async {
        let discovery = InMemoryBonjourDiscovery()
        var stateIterator = discovery.stateUpdates.makeAsyncIterator()
        var resultIterator = discovery.updates.makeAsyncIterator()

        discovery.start()
        let readyState = await stateIterator.next()
        XCTAssertEqual(readyState, .ready)

        discovery.publish([])
        let emptyResults = await resultIterator.next()
        XCTAssertEqual(emptyResults, [])
        discovery.cancel()
        let cancelledState = await stateIterator.next()
        XCTAssertEqual(cancelledState, .cancelled)
        let finishedState = await stateIterator.next()
        XCTAssertNil(finishedState)
    }

    func testMessageStreamCanDiscardOnlyQueuedInputMessages() async throws {
        let stream = try MessageStream.makeBounded(
            maxControlMessages: 8,
            maxMediaMessages: 2
        )
        _ = try stream.storage.yield(
            .inputEvent(
                InputEventMessage(
                    kind: .pointerMove,
                    windowGeneration: 1,
                    x: 1,
                    y: 2
                )
            )
        )
        _ = try stream.storage.yield(.ping(PingMessage(nonce: 7)))

        stream.storage.removePendingInputMessages()

        var iterator = stream.stream.makeAsyncIterator()
        let message = try await iterator.next()
        XCTAssertEqual(message, .ping(PingMessage(nonce: 7)))
    }

    func testBoundedQueuesPrioritizeControlAndDropMediaOnlyUntilNextKeyframe() async throws {
        let queue = try BoundedFrameQueue(maxControlFrames: 2, maxMediaFrames: 2)
        let control = try Envelope(
            channel: .control,
            messageType: .ping,
            sequence: 0,
            timestamp: 0
        )
        let mediaOne = try makeVideoEnvelope(sequence: 0, keyframe: false)
        let mediaTwo = try makeVideoEnvelope(sequence: 1, keyframe: false)
        let mediaThree = try makeVideoEnvelope(sequence: 2, keyframe: false)
        let mediaFour = try makeVideoEnvelope(sequence: 3, keyframe: false)
        let keyframe = try makeVideoEnvelope(sequence: 4, keyframe: true)
        let videoConfig = try Envelope(
            message: .videoConfig(
                VideoConfigMessage(generation: 9, decoderConfiguration: Data([0x01]))
            ),
            sequence: 5,
            timestamp: 5
        )

        let firstResult = try await queue.enqueue(mediaOne)
        let secondResult = try await queue.enqueue(mediaTwo)
        let droppedResult = try await queue.enqueue(mediaThree)
        let controlResult = try await queue.enqueue(control)
        XCTAssertEqual(firstResult, .queued)
        XCTAssertEqual(secondResult, .queued)
        // The incoming delta frame is dropped, never a queued one, so the
        // queued frames still decode.
        XCTAssertEqual(droppedResult, .discardedMedia)
        XCTAssertEqual(controlResult, .queued)

        // After a drop, delta frames are skipped until a keyframe even though
        // the queue now has room.
        let firstDequeued = await queue.dequeue()
        let secondDequeued = await queue.dequeue()
        XCTAssertEqual(firstDequeued, control)
        XCTAssertEqual(secondDequeued, mediaOne)
        let skippedResult = try await queue.enqueue(mediaFour)
        XCTAssertEqual(skippedResult, .discardedMedia)

        // A keyframe supersedes the queued delta frame and ends the gap. It
        // reports `.queued` so the sender does not force yet another keyframe.
        let keyframeResult = try await queue.enqueue(keyframe)
        XCTAssertEqual(keyframeResult, .queued)
        let configResult = try await queue.enqueue(videoConfig)
        XCTAssertEqual(configResult, .queued)

        let thirdDequeued = await queue.dequeue()
        let fourthDequeued = await queue.dequeue()
        let emptyDequeued = await queue.dequeue()
        XCTAssertEqual(thirdDequeued, keyframe)
        XCTAssertEqual(fourthDequeued, videoConfig)
        XCTAssertNil(emptyDequeued)
    }

    func testBoundedQueueFailsExplicitlyWhenRequiredMediaHasNoRoom() async throws {
        let queue = try BoundedFrameQueue(maxControlFrames: 1, maxMediaFrames: 1)
        let firstKeyframe = try makeVideoEnvelope(sequence: 0, keyframe: true)
        let secondKeyframe = try makeVideoEnvelope(sequence: 1, keyframe: true)
        let delta = try makeVideoEnvelope(sequence: 2, keyframe: false)

        let firstResult = try await queue.enqueue(firstKeyframe)
        XCTAssertEqual(firstResult, .queued)
        do {
            _ = try await queue.enqueue(secondKeyframe)
            XCTFail("a keyframe must not evict another keyframe")
        } catch TransportError.mediaBackpressure {
            // Expected.
        }
        // The rejected keyframe cannot be referenced, so later delta frames
        // are skipped even after room becomes available.
        _ = await queue.dequeue()
        let deltaResult = try await queue.enqueue(delta)
        XCTAssertEqual(deltaResult, .discardedMedia)
        let emptyDequeued = await queue.dequeue()
        XCTAssertNil(emptyDequeued)
    }

    func testBoundedQueueSkipsDeltaFramesAfterProtectedMediaInvalidation() async throws {
        let queue = try BoundedFrameQueue(maxControlFrames: 1, maxMediaFrames: 3)
        let keyframe = try makeVideoEnvelope(sequence: 0, keyframe: true)
        let delta = try makeVideoEnvelope(sequence: 1, keyframe: false)
        let nextKeyframe = try makeVideoEnvelope(sequence: 2, keyframe: true)

        _ = try await queue.enqueue(keyframe)
        await queue.removeProtectedMessages()
        let deltaResult = try await queue.enqueue(delta)
        XCTAssertEqual(deltaResult, .discardedMedia)
        let keyframeResult = try await queue.enqueue(nextKeyframe)
        XCTAssertEqual(keyframeResult, .queued)
        let dequeued = await queue.dequeue()
        XCTAssertEqual(dequeued, nextKeyframe)
    }

    func testMessageStreamPreservesReliableMessagesAndUsesSafeMediaReplacement() async throws {
        let output = try MessageStream.makeBounded(
            maxControlMessages: 2,
            maxMediaMessages: 2
        )
        let input = MessagePayload.inputEvent(
            InputEventMessage(kind: .pointerMove, windowGeneration: 1, x: 1, y: 2)
        )
        let windowList = MessagePayload.windowList(WindowListMessage(windows: []))
        _ = try output.storage.yield(input)
        _ = try output.storage.yield(windowList)

        do {
            _ = try output.storage.yield(.inputEvent(
                InputEventMessage(kind: .pointerMove, windowGeneration: 1, x: 3, y: 4)
            ))
            XCTFail("reliable control messages must fail explicitly when full")
        } catch TransportError.controlBackpressure {
            // Expected.
        }

        let firstFrame = MessagePayload.videoFrame(
            VideoFrameMessage(
                generation: 1,
                captureTimestamp: 1,
                presentationTimestamp: 1,
                width: 1,
                height: 1,
                keyframe: false,
                accessUnit: Data([1])
            )
        )
        let secondFrame = MessagePayload.videoFrame(
            VideoFrameMessage(
                generation: 1,
                captureTimestamp: 2,
                presentationTimestamp: 2,
                width: 1,
                height: 1,
                keyframe: false,
                accessUnit: Data([2])
            )
        )
        let configuration = MessagePayload.videoConfig(
            VideoConfigMessage(generation: 1, decoderConfiguration: Data([3]))
        )
        let keyframe = MessagePayload.videoFrame(
            VideoFrameMessage(
                generation: 1,
                captureTimestamp: 4,
                presentationTimestamp: 4,
                width: 1,
                height: 1,
                keyframe: true,
                accessUnit: Data([4])
            )
        )
        _ = try output.storage.yield(firstFrame)
        _ = try output.storage.yield(secondFrame)
        // Required media purges the queued delta frames and starts a keyframe
        // wait; a delta frame before the keyframe is skipped.
        XCTAssertEqual(try output.storage.yield(configuration), .replacedMedia)
        XCTAssertEqual(try output.storage.yield(firstFrame), .replacedMedia)
        XCTAssertEqual(try output.storage.yield(keyframe), .queued)

        let first = try await output.storage.next()
        let second = try await output.storage.next()
        let third = try await output.storage.next()
        let fourth = try await output.storage.next()
        XCTAssertEqual([first, second], [input, windowList])
        XCTAssertEqual(third, configuration)
        XCTAssertEqual(fourth, keyframe)
        output.storage.finish()
    }

    func testMessageStreamCancellationReleasesWaitingConsumerSlot() async throws {
        let output = try MessageStream.makeBounded(
            maxControlMessages: 2,
            maxMediaMessages: 1
        )
        let waitingConsumer = Task { () throws -> MessagePayload? in
            var iterator = output.stream.makeAsyncIterator()
            return try await iterator.next()
        }
        for _ in 0 ..< 100 where !output.storage.hasWaitingConsumer() {
            await Task.yield()
        }
        XCTAssertTrue(output.storage.hasWaitingConsumer())

        waitingConsumer.cancel()
        do {
            _ = try await waitingConsumer.value
            XCTFail("a cancelled message consumer must throw cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let message = MessagePayload.inputEvent(
            InputEventMessage(kind: .pointerMove, windowGeneration: 1, x: 5, y: 6)
        )
        _ = try output.storage.yield(message)
        var iterator = output.stream.makeAsyncIterator()
        let received = try await iterator.next()
        XCTAssertEqual(received, message)
        output.storage.finish()
    }

    func testMessageStreamCancellationBeforeWaiterRegistrationDoesNotStrandSlot() async throws {
        let gate = MessageStreamRegistrationGate()
        let output = try MessageStream.makeBounded(
            maxControlMessages: 2,
            maxMediaMessages: 1,
            beforeWaiterRegistrationHook: gate.pauseBeforeFirstRegistration
        )
        let waitingConsumer = Task { () throws -> MessagePayload? in
            var iterator = output.stream.makeAsyncIterator()
            return try await iterator.next()
        }

        XCTAssertEqual(
            gate.entered.wait(timeout: .now() + 1),
            .success,
            "the test must cancel while waiter registration is paused"
        )
        waitingConsumer.cancel()
        gate.release.signal()

        do {
            _ = try await waitingConsumer.value
            XCTFail("a cancelled consumer must throw cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let message = MessagePayload.inputEvent(
            InputEventMessage(kind: .pointerMove, windowGeneration: 1, x: 7, y: 8)
        )
        _ = try output.storage.yield(message)
        let received = try await output.storage.next()
        XCTAssertEqual(received, message)
        output.storage.finish()
    }

    func testReconnectReopensIncomingMessageStreamAfterFailure() async throws {
        let localIdentity = try PeerIdentity(publicKeyRepresentation: Data("reconnect-local".utf8))
        let remoteIdentity = try PeerIdentity(publicKeyRepresentation: Data("reconnect-remote".utf8))
        let firstPair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(remoteIdentity),
            secondAuthentication: .trusted(localIdentity)
        )
        try await firstPair.first.start()
        try await firstPair.second.start()
        let session = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "reconnect-stream",
                capabilities: [.pingPong]
            ),
            transport: firstPair.first
        )
        try await session.start()
        let invalidEnvelope = try Envelope(
            channel: .control,
            messageType: .ping,
            sequence: 2,
            timestamp: 1,
            payload: try PingMessage(nonce: 1).encoded(using: .default)
        )
        _ = try await firstPair.second.send(invalidEnvelope)
        let secondInvalidEnvelope = try Envelope(
            channel: .control,
            messageType: .ping,
            sequence: 4,
            timestamp: 2,
            payload: try PingMessage(nonce: 2).encoded(using: .default)
        )
        _ = try await firstPair.second.send(secondInvalidEnvelope)
        for _ in 0 ..< 100 {
            if (await session.snapshot()).state == .failed { break }
            await Task.yield()
        }
        let failedSnapshot = await session.snapshot()
        XCTAssertEqual(failedSnapshot.state, .failed)
        guard failedSnapshot.state == .failed else { return }

        let secondPair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(remoteIdentity),
            secondAuthentication: .trusted(localIdentity)
        )
        try await secondPair.first.start()
        try await secondPair.second.start()
        let peer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "reconnect-peer",
                capabilities: [.pingPong]
            ),
            transport: secondPair.second
        )
        let peerStart = Task { () -> String? in
            do {
                try await peer.start()
                return nil
            } catch {
                return String(describing: error)
            }
        }
        do {
            try await session.reconnect(using: secondPair.first)
        } catch {
            XCTFail("session reconnect failed: \(error)")
            return
        }
        let peerStartError = await peerStart.value
        XCTAssertNil(peerStartError)
        for _ in 0 ..< 100 {
            if (await session.snapshot()).state == .capabilitiesNegotiated,
               (await peer.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            await Task.yield()
        }
        let reconnectedSessionSnapshot = await session.snapshot()
        let reconnectedPeerSnapshot = await peer.snapshot()
        XCTAssertEqual(reconnectedSessionSnapshot.state, .capabilitiesNegotiated)
        XCTAssertEqual(reconnectedPeerSnapshot.state, .capabilitiesNegotiated)
        let staleStopResult = await session.stopIfCurrent(
            reason: .shutdown,
            expectedAuthorizationGeneration: failedSnapshot.authorizationGeneration,
            expectedReconnectGeneration: failedSnapshot.reconnectGeneration
        )
        XCTAssertFalse(staleStopResult, "a stale failure must not stop the replacement session")
        let afterStaleStopSnapshot = await session.snapshot()
        XCTAssertEqual(afterStaleStopSnapshot.state, .capabilitiesNegotiated)
        let messageTask = Task { () throws -> MessagePayload? in
            var iterator = session.incomingMessages.makeAsyncIterator()
            return try await iterator.next()
        }
        let stateMessage = SessionStateMessage(
            state: .capabilitiesNegotiated,
            permission: .unknown,
            focusEligible: false
        )
        try await peer.send(.sessionState(stateMessage))
        do {
            let received = try await messageTask.value
            XCTAssertEqual(received, .sessionState(stateMessage))
        } catch {
            XCTFail("reconnected message stream failed: \(error)")
        }
        await session.stop()
        await peer.stop()
    }

    func testAuthorizationInvalidationTombstonesProtectedControlAndDropsMedia() async throws {
        let queue = try BoundedFrameQueue(maxControlFrames: 4, maxMediaFrames: 2)
        let protectedControl = try Envelope(
            message: .windowList(WindowListMessage(windows: [])),
            sequence: 0,
            timestamp: 1
        )
        let followingControl = try Envelope(
            message: .ping(PingMessage(nonce: 2)),
            sequence: 1,
            timestamp: 2
        )
        let protectedMedia = try makeVideoEnvelope(sequence: 0, keyframe: false)

        _ = try await queue.enqueue(protectedControl)
        _ = try await queue.enqueue(followingControl)
        _ = try await queue.enqueue(protectedMedia)
        await queue.removeProtectedMessages()

        let tombstone = await queue.dequeue()
        let next = await queue.dequeue()
        let media = await queue.dequeue()
        XCTAssertEqual(tombstone?.sequence, 0)
        XCTAssertEqual(tombstone?.messageType, .unknown(0x7FFE))
        XCTAssertThrowsError(try tombstone!.decodedMessage())
        XCTAssertEqual(next, followingControl)
        XCTAssertNil(media)
    }

    func testInMemoryTransportDeliversFramesOnlyAfterStarting() async throws {
        let firstIdentity = try PeerIdentity(publicKeyRepresentation: Data("first".utf8))
        let secondIdentity = try PeerIdentity(publicKeyRepresentation: Data("second".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(secondIdentity),
            secondAuthentication: .trusted(firstIdentity)
        )
        let envelope = try Envelope(
            channel: .control,
            messageType: .ping,
            sequence: 0,
            timestamp: 1
        )

        try await pair.first.start()
        try await pair.second.start()
        let receiveTask = Task { () -> Envelope? in
            var iterator = pair.second.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        _ = try await pair.first.send(envelope)
        let receivedEnvelope = await receiveTask.value
        XCTAssertEqual(receivedEnvelope, envelope)

        await pair.first.close()
        do {
            _ = try await pair.first.send(envelope)
            XCTFail("closed transport should reject sends")
        } catch TransportError.alreadyClosed {
            // Expected.
        }
    }

    func testInMemoryTransportEnforcesControlCapacityAndMediaReplacement() async throws {
        let controlPair = makeTrustedTransportPair(maxControlFrames: 1, maxMediaFrames: 2)
        try await controlPair.first.start()
        try await controlPair.second.start()
        let control = try Envelope(
            channel: .control,
            messageType: .ping,
            sequence: 0,
            timestamp: 0
        )
        _ = try await controlPair.first.send(control)
        do {
            _ = try await controlPair.first.send(control)
            XCTFail("control overflow must fail closed")
        } catch TransportError.controlBackpressure {
            // Expected.
        }
        let controlSnapshot = await controlPair.second.snapshot()
        XCTAssertEqual(controlSnapshot.state, .failed(TransportError.controlBackpressure.description))

        let mediaPair = makeTrustedTransportPair(maxControlFrames: 1, maxMediaFrames: 2)
        try await mediaPair.first.start()
        try await mediaPair.second.start()
        _ = try await mediaPair.first.send(try makeVideoEnvelope(sequence: 0, keyframe: false))
        _ = try await mediaPair.first.send(try makeVideoEnvelope(sequence: 1, keyframe: false))
        let replacement = try await mediaPair.first.send(
            try makeVideoEnvelope(sequence: 2, keyframe: false)
        )
        // The receiver drops the incoming delta frame rather than a queued
        // one, so the delivered frames remain a decodable prefix.
        XCTAssertEqual(replacement, .replacedMedia)
        let iteratorTask = Task { () async throws -> [UInt64] in
            var iterator = mediaPair.second.incoming.makeAsyncIterator()
            guard let first = try await iterator.next(),
                  let second = try await iterator.next() else {
                throw TransportError.connectionFailed("bounded stream ended early")
            }
            return [first.sequence, second.sequence]
        }
        let deliveredSequences = try await iteratorTask.value
        XCTAssertEqual(deliveredSequences, [0, 1])
    }

    func testSessionNegotiatesAndBlocksProtectedContentUntilAuthorization() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()

        let capabilities: Set<Capability> = [.pingPong, .windowSelection]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "test-host",
                capabilities: capabilities,
                mandatoryCapabilities: [.pingPong]
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "test-viewer",
                capabilities: capabilities,
                mandatoryCapabilities: [.pingPong]
            ),
            transport: pair.second
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart

        for _ in 0 ..< 100 {
            let hostSnapshot = await host.snapshot()
            let viewerSnapshot = await viewer.snapshot()
            if hostSnapshot.state == .capabilitiesNegotiated,
               viewerSnapshot.state == .capabilitiesNegotiated {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let negotiatedHostSnapshot = await host.snapshot()
        let negotiatedViewerSnapshot = await viewer.snapshot()
        XCTAssertEqual(negotiatedHostSnapshot.state, .capabilitiesNegotiated)
        XCTAssertFalse(negotiatedViewerSnapshot.authorized)

        do {
            try await host.send(.windowList(WindowListMessage(windows: [])))
            XCTFail("protected content must not be sent before authorization")
        } catch SessionError.unauthorizedMessage(.windowList) {
            // Expected.
        }

        try await host.authorize(windowGeneration: 9, capabilities: [.windowSelection])
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).authorized { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let authorizedViewerSnapshot = await viewer.snapshot()
        XCTAssertTrue(authorizedViewerSnapshot.authorized)
        XCTAssertEqual(authorizedViewerSnapshot.state, .windowSelectionAuthorized)
        let authorizedHostSnapshot = await host.snapshot()
        XCTAssertEqual(authorizedHostSnapshot.authorizedWindowGeneration, 9)
        XCTAssertEqual(authorizedHostSnapshot.authorizedCapabilities, [.windowSelection])

        try await host.send(.windowList(WindowListMessage(windows: [])))
        do {
            try await host.send(
                .windowSelection(WindowSelectionMessage(windowIdentifier: 1, windowGeneration: 8))
            )
            XCTFail("stale window generations must be rejected")
        } catch SessionError.unauthorizedMessage(.windowSelection) {
            // Expected.
        }
        do {
            try await host.send(
                .inputEvent(
                    InputEventMessage(
                        kind: .pointerMove,
                        windowGeneration: 9,
                        x: 1,
                        y: 1
                    )
                )
            )
            XCTFail("capabilities outside the authorization scope must be rejected")
        } catch SessionError.unauthorizedMessage(.inputEvent) {
            // Expected.
        }

        await pair.first.close()
        do {
            try await host.revokeAuthorization()
            XCTFail("revocation should report a failed best-effort remote notification")
        } catch {
            // The local authority must already be gone when notification fails.
        }
        let revokedHostSnapshot = await host.snapshot()
        XCTAssertFalse(revokedHostSnapshot.authorized)
        XCTAssertNil(revokedHostSnapshot.authorizedWindowGeneration)
        XCTAssertTrue(revokedHostSnapshot.authorizedCapabilities.isEmpty)
        await host.stop()
        let stoppedHostSnapshot = await host.snapshot()
        XCTAssertFalse(stoppedHostSnapshot.authorized)
    }

    func testViewerKeyframeRequestIsCapabilityGatedAndThrottled() async throws {
        let (host, viewer) = try await makeAuthorizedVideoSessions(
            capabilities: [.pingPong, .h264Video, .keyframeRequest],
            authorized: [.h264Video, .keyframeRequest]
        )
        let firstRequest = await viewer.requestKeyframe(reason: .decodeFailure)
        let throttledRequest = await viewer.requestKeyframe(reason: .decodeFailure)
        XCTAssertTrue(firstRequest)
        XCTAssertFalse(throttledRequest, "requests inside the minimum interval must be coalesced")
        let hostRequest = await host.requestKeyframe(reason: .decodeFailure)
        XCTAssertFalse(hostRequest, "only the Viewer sends keyframe requests")

        let received = try await firstKeyframeRequest(from: host)
        XCTAssertEqual(received, KeyframeRequestMessage(generation: 9, reason: .decodeFailure))
        await host.stop()
        await viewer.stop()
    }

    func testViewerKeyframeRequestRequiresAuthorizedCapability() async throws {
        let (host, viewer) = try await makeAuthorizedVideoSessions(
            capabilities: [.pingPong, .h264Video],
            authorized: [.h264Video]
        )
        let request = await viewer.requestKeyframe(reason: .mediaGap)
        XCTAssertFalse(request, "a peer that did not negotiate the capability never receives the message")
        await host.stop()
        await viewer.stop()
    }

    func testViewerRequestsKeyframeAfterLocalMediaDiscard() async throws {
        let (host, viewer) = try await makeAuthorizedVideoSessions(
            capabilities: [.pingPong, .h264Video, .keyframeRequest],
            authorized: [.h264Video, .keyframeRequest]
        )
        // Nobody consumes the Viewer's messages, so its bounded media stream
        // fills and discards the fourth frame.
        for index in 0 ..< 5 {
            try await host.send(
                .videoFrame(
                    VideoFrameMessage(
                        generation: 9,
                        captureTimestamp: UInt64(index),
                        presentationTimestamp: UInt64(index),
                        width: 1,
                        height: 1,
                        keyframe: index == 0,
                        accessUnit: Data([UInt8(index)])
                    )
                ),
                flags: index == 0 ? .keyframe : []
            )
        }
        let received = try await firstKeyframeRequest(from: host)
        XCTAssertEqual(received, KeyframeRequestMessage(generation: 9, reason: .mediaGap))
        await host.stop()
        await viewer.stop()
    }

    func testViewerSendsReceiverReportWhenAuthorized() async throws {
        let (host, viewer) = try await makeAuthorizedVideoSessions(
            capabilities: [.pingPong, .h264Video, .receiverReport],
            authorized: [.h264Video, .receiverReport]
        )
        let reader = Task { () throws -> ReceiverReportMessage? in
            for try await message in host.incomingMessages {
                if case let .receiverReport(report) = message {
                    return report
                }
            }
            return nil
        }
        // Two frames at least one report interval apart produce a report.
        for index in 0 ..< 2 {
            try await host.send(
                .videoFrame(
                    VideoFrameMessage(
                        generation: 9,
                        captureTimestamp: UInt64(index),
                        presentationTimestamp: UInt64(index),
                        width: 1,
                        height: 1,
                        keyframe: true,
                        accessUnit: Data([UInt8(index)])
                    )
                ),
                flags: .keyframe
            )
            if index == 0 {
                try await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            reader.cancel()
        }
        let report = try await reader.value
        timeout.cancel()
        XCTAssertEqual(report?.generation, 9)
        XCTAssertEqual(report?.discardedFrames, 0)
        XCTAssertGreaterThanOrEqual(report?.receivedFrames ?? 0, 1)
        await host.stop()
        await viewer.stop()
    }

    private func makeAuthorizedVideoSessions(
        capabilities: Set<Capability>,
        authorized: Set<Capability>
    ) async throws -> (host: SessionCoordinator, viewer: SessionCoordinator) {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("keyframe-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("keyframe-viewer".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "keyframe-host",
                capabilities: capabilities,
                mandatoryCapabilities: [.pingPong]
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "keyframe-viewer",
                capabilities: capabilities,
                mandatoryCapabilities: [.pingPong]
            ),
            transport: pair.second
        )
        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 200 {
            if (await host.snapshot()).state == .capabilitiesNegotiated,
               (await viewer.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await host.authorize(windowGeneration: 9, capabilities: authorized)
        for _ in 0 ..< 200 {
            if (await viewer.snapshot()).authorized { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let viewerAuthorized = await viewer.snapshot().authorized
        XCTAssertTrue(viewerAuthorized)
        return (host, viewer)
    }

    private func firstKeyframeRequest(from host: SessionCoordinator) async throws -> KeyframeRequestMessage {
        let reader = Task { () throws -> KeyframeRequestMessage? in
            for try await message in host.incomingMessages {
                if case let .keyframeRequest(request) = message {
                    return request
                }
            }
            return nil
        }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            reader.cancel()
        }
        defer { timeout.cancel() }
        guard let request = try await reader.value else {
            throw TransportError.connectionFailed("no keyframe request received")
        }
        return request
    }

    func testClipboardAcknowledgementUsesAuthenticatedCapabilityGate() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("m7-gate-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("m7-gate-viewer".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()

        let capabilities: Set<Capability> = [.pingPong, .textClipboard]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "m7-gate-host",
                capabilities: capabilities,
                mandatoryCapabilities: [.pingPong]
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "m7-gate-viewer",
                capabilities: capabilities,
                mandatoryCapabilities: [.pingPong]
            ),
            transport: pair.second
        )
        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart

        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated,
               (await viewer.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            await Task.yield()
        }
        let acknowledgement = ClipboardAcknowledgementMessage(
            generation: 1,
            origin: .viewer,
            accepted: true,
            reason: .accepted
        )
        do {
            try await viewer.send(.clipboardAcknowledgement(acknowledgement))
            XCTFail("clipboard acknowledgement must not bypass authorization")
        } catch SessionError.unauthorizedMessage(.clipboardAcknowledgement) {
            // Expected.
        }

        try await host.authorize(capabilities: [.textClipboard])
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).authorized { break }
            await Task.yield()
        }
        let authorizedViewer = await viewer.snapshot()
        XCTAssertTrue(authorizedViewer.authorized)
        try await viewer.send(.clipboardAcknowledgement(acknowledgement))

        await host.stop()
        await viewer.stop()
    }

    func testAuthorizedViewerInputReachesHostDoubleInWireOrder() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("m5-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("m5-viewer".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()

        let capabilities: Set<Capability> = [.pingPong, .mouseInput, .keyboardInput]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "m5-host",
                capabilities: capabilities
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "m5-viewer",
                capabilities: capabilities
            ),
            transport: pair.second
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart

        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated,
               (await viewer.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await host.authorize(
            windowGeneration: 17,
            capabilities: [.mouseInput, .keyboardInput]
        )
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).authorized { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let receivedTask = Task { () throws -> [InputEventMessage] in
            var iterator = host.incomingMessages.makeAsyncIterator()
            var messages: [InputEventMessage] = []
            while let message = try await iterator.next() {
                if case let .inputEvent(input) = message {
                    messages.append(input)
                    if messages.count == 2 { return messages }
                }
            }
            return messages
        }

        try await viewer.send(
            .inputEvent(
                InputEventMessage(
                    kind: .pointerMove,
                    windowGeneration: 17,
                    x: 1_024,
                    y: 2_048
                )
            )
        )
        try await viewer.send(
            .inputEvent(
                InputEventMessage(
                    kind: .keyDown,
                    windowGeneration: 17,
                    keyCode: 42,
                    modifiers: 0x03
                )
            )
        )

        let received = try await receivedTask.value
        XCTAssertEqual(received.map(\.kind), [.pointerMove, .keyDown])
        XCTAssertEqual(received.map(\.windowGeneration), [17, 17])
        XCTAssertEqual(received[0].x, 1_024)
        XCTAssertEqual(received[1].keyCode, 42)
        XCTAssertEqual(received[1].modifiers, 0x03)

        await host.stop()
        await viewer.stop()
    }

    func testAuthorizationRevocationAndTeardownDropQueuedInputButPreserveCloseMessage() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("teardown-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("teardown-viewer".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()

        let capabilities: Set<Capability> = [.pingPong, .mouseInput]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "teardown-host",
                capabilities: capabilities
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "teardown-viewer",
                capabilities: capabilities
            ),
            transport: pair.second
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated,
               (await viewer.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await host.authorize(windowGeneration: 1, capabilities: [.mouseInput])
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).authorized { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        for coordinate in 1 ... 2 {
            try await viewer.send(.inputEvent(
                InputEventMessage(
                    kind: .pointerMove,
                    windowGeneration: 1,
                    x: UInt16(coordinate),
                    y: UInt16(coordinate)
                )
            ))
        }
        for _ in 0 ..< 100 {
            if host.incomingMessages.storage.counts().control >= 2 {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(host.incomingMessages.storage.counts().control, 2)
        try await host.revokeAuthorization()
        await viewer.stop()

        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .stopping { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        var iterator = host.incomingMessages.makeAsyncIterator()
        let teardownMessage = try await iterator.next()
        XCTAssertEqual(teardownMessage, .close(CloseMessage(reason: .normal)))
        await host.stop()
    }

    func testSessionFailsExplicitlyWhenReliableIncomingDeliveryIsFull() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("incoming-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("incoming-viewer".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()

        let capabilities: Set<Capability> = [.pingPong, .mouseInput]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "incoming-host",
                capabilities: capabilities
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "incoming-viewer",
                capabilities: capabilities
            ),
            transport: pair.second
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await host.authorize(windowGeneration: 1, capabilities: [.mouseInput])
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).authorized { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        for sequence in 0 ..< 65 {
            try await viewer.send(.inputEvent(
                InputEventMessage(
                    kind: .pointerMove,
                    windowGeneration: 1,
                    x: UInt16(sequence),
                    y: UInt16(sequence)
                )
            ))
        }

        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .failed { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let failedSnapshot = await host.snapshot()
        XCTAssertEqual(failedSnapshot.state, .failed)

        var iterator = host.incomingMessages.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("invalidated input must not remain deliverable after failure")
        } catch let error as SessionError {
            XCTAssertEqual(error, .incomingMessageBackpressure(.control))
        }

        await host.stop()
        await viewer.stop()
    }

    func testOptionalUnknownMessageIsSkippedWithoutFailingSession() async throws {
        let local = try PeerIdentity(publicKeyRepresentation: Data("local-unknown".utf8))
        let remote = try PeerIdentity(publicKeyRepresentation: Data("remote-unknown".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(remote),
            secondAuthentication: .trusted(local)
        )
        try await pair.first.start()
        try await pair.second.start()
        let session = SessionCoordinator(
            configuration: SessionConfiguration(role: .viewer, implementationIdentifier: "unknown-test", capabilities: []),
            transport: pair.first
        )
        try await session.start()

        let unknown = try Envelope(
            channel: .control,
            messageType: .unknown(0x7FFF),
            sequence: 0,
            timestamp: 0,
            payload: Data([0x01])
        )
        _ = try await pair.second.send(unknown)
        try await Task.sleep(nanoseconds: 2_000_000)
        let snapshot = await session.snapshot()
        XCTAssertNotEqual(snapshot.state, .failed)
    }

    func testDirectionMatrixRejectsViewerOnlyMessageFromPeer() async throws {
        let local = try PeerIdentity(publicKeyRepresentation: Data("local-direction".utf8))
        let remote = try PeerIdentity(publicKeyRepresentation: Data("remote-direction".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(remote),
            secondAuthentication: .trusted(local)
        )
        try await pair.first.start()
        try await pair.second.start()
        let session = SessionCoordinator(
            configuration: SessionConfiguration(role: .viewer, implementationIdentifier: "direction-test", capabilities: [.windowSelection]),
            transport: pair.first
        )
        try await session.start()
        _ = try await pair.second.send(try Envelope(
            message: .hello(
                HelloMessage(
                    protocolVersion: .current,
                    role: .host,
                    implementationIdentifier: "raw-host",
                    limits: .default
                )
            ),
            sequence: 0,
            timestamp: 0
        ))
        _ = try await pair.second.send(try Envelope(
            message: .capabilities(CapabilitiesMessage(capabilities: [.windowSelection])),
            sequence: 1,
            timestamp: 1
        ))
        _ = try await pair.second.send(try Envelope(
            message: .windowSelection(WindowSelectionMessage(windowIdentifier: 1, windowGeneration: 1)),
            sequence: 2,
            timestamp: 2
        ))

        for _ in 0 ..< 100 {
            if (await session.snapshot()).state == .failed { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .failed)
    }

    func testHeartbeatDoesNotStartWithoutNegotiatedPingPong() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-no-ping".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-no-ping".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()
        let configuration = SessionConfiguration(
            role: .host,
            implementationIdentifier: "no-ping-host",
            capabilities: [],
            heartbeatIntervalNanoseconds: 1_000_000,
            heartbeatTimeoutNanoseconds: 3_000_000
        )
        let host = SessionCoordinator(configuration: configuration, transport: pair.first)
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "no-ping-viewer",
                capabilities: [],
                heartbeatIntervalNanoseconds: 1_000_000,
                heartbeatTimeoutNanoseconds: 3_000_000
            ),
            transport: pair.second
        )
        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        let snapshot = await host.snapshot()
        XCTAssertEqual(snapshot.state, .capabilitiesNegotiated)
        XCTAssertNil(snapshot.lastHeartbeatAt)
        await host.stop()
        await viewer.stop()
    }

    func testNegotiatedVideoBoundsAreTheEffectivePeerMinimum() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-video-bounds".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-video-bounds".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "bounds-host",
                capabilities: [.h264Video],
                maxVideoWidth: 640,
                maxVideoHeight: 480,
                maxFrameRate: 60
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "bounds-viewer",
                capabilities: [.h264Video],
                maxVideoWidth: 320,
                maxVideoHeight: 240,
                maxFrameRate: 30
            ),
            transport: pair.second
        )
        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let negotiated = await host.snapshot()
        XCTAssertEqual(negotiated.negotiatedMaxVideoWidth, 320)
        XCTAssertEqual(negotiated.negotiatedMaxVideoHeight, 240)
        XCTAssertEqual(negotiated.negotiatedMaxFrameRate, 30)
        try await host.authorize(windowGeneration: 1, capabilities: [.h264Video])
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).authorized { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        do {
            try await host.send(.streamConfig(
                StreamConfigMessage(width: 321, height: 240, frameRate: 30, codec: .h264, generation: 1)
            ))
            XCTFail("stream dimensions above the peer minimum must be rejected")
        } catch SessionError.videoBoundsExceeded {
            // Expected.
        }
        await host.stop()
        await viewer.stop()
    }

    func testDecodedApplicationMessagesArePublishedToSessionStream() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-publish".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-publish".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()
        let host = SessionCoordinator(
            configuration: SessionConfiguration(role: .host, implementationIdentifier: "publish-host", capabilities: [.windowSelection]),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(role: .viewer, implementationIdentifier: "publish-viewer", capabilities: [.windowSelection]),
            transport: pair.second
        )
        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await host.authorize(windowGeneration: 1, capabilities: [.windowSelection])
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).authorized { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let messageTask = Task { () async throws -> MessagePayload? in
            var iterator = viewer.incomingMessages.makeAsyncIterator()
            return try await iterator.next()
        }
        try await host.send(.windowList(WindowListMessage(windows: [])))
        let published = try await messageTask.value
        XCTAssertEqual(published, .windowList(WindowListMessage(windows: [])))
        await host.stop()
        await viewer.stop()
    }

    func testHostInitiatedPairingAdoptsChallengeAndTrustsBothPeers() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-pairing".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-pairing".utf8))
        let hostTrustStore = InMemoryTrustStore()
        let viewerTrustStore = InMemoryTrustStore()
        let hostPairing = PairingCoordinator(localIdentity: hostIdentity, trustStore: hostTrustStore)
        let viewerPairing = PairingCoordinator(localIdentity: viewerIdentity, trustStore: viewerTrustStore)
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .pairingRequired(viewerIdentity),
            secondAuthentication: .pairingRequired(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()

        let capabilities: Set<Capability> = [.pingPong]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "pairing-host",
                deviceName: "Intel-Test-Host",
                capabilities: capabilities
            ),
            transport: pair.first,
            pairingCoordinator: hostPairing
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "pairing-viewer",
                deviceName: "Apple-Silicon-Test-Viewer",
                capabilities: capabilities
            ),
            transport: pair.second,
            pairingCoordinator: viewerPairing
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart

        var viewerChallenge: PairingChallenge?
        for _ in 0 ..< 100 {
            viewerChallenge = await viewerPairing.pendingChallenge()
            if viewerChallenge?.isVerificationReady == true { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let challenge = try XCTUnwrap(viewerChallenge)
        var hostChallenge: PairingChallenge?
        for _ in 0 ..< 100 {
            hostChallenge = await hostPairing.pendingChallenge()
            if hostChallenge?.isVerificationReady == true { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let hostChallengeValue = try XCTUnwrap(hostChallenge)
        try await viewer.confirmPairing(confirmationCode: challenge.confirmationCode, accepted: true)

        for _ in 0 ..< 100 {
            if await hostPairing.consentState()?.remoteConsent == true { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let viewerPendingTrust = try await viewerPairing.trustDecision(for: hostIdentity)
        XCTAssertEqual(viewerPendingTrust, .pairingRequired)
        try await host.confirmPairing(confirmationCode: hostChallengeValue.confirmationCode, accepted: true)

        for _ in 0 ..< 100 {
            let hostState = await host.snapshot()
            let viewerState = await viewer.snapshot()
            if hostState.state == .capabilitiesNegotiated,
               viewerState.state == .capabilitiesNegotiated {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let hostSnapshot = await host.snapshot()
        let viewerSnapshot = await viewer.snapshot()
        let hostTrustDecision = try await hostPairing.trustDecision(for: viewerIdentity)
        let viewerTrustDecision = try await viewerPairing.trustDecision(for: hostIdentity)
        XCTAssertEqual(hostSnapshot.state, .capabilitiesNegotiated)
        XCTAssertEqual(viewerSnapshot.state, .capabilitiesNegotiated)
        XCTAssertEqual(hostSnapshot.peerDeviceName, "Apple-Silicon-Test-Viewer")
        XCTAssertEqual(viewerSnapshot.peerDeviceName, "Intel-Test-Host")
        XCTAssertEqual(hostTrustDecision, .trusted)
        XCTAssertEqual(viewerTrustDecision, .trusted)
        let hostTrustedPeers = try await hostTrustStore.allTrustedPeers()
        let viewerTrustedPeers = try await viewerTrustStore.allTrustedPeers()
        XCTAssertEqual(hostTrustedPeers.first?.displayName, "Apple-Silicon-Test-Viewer")
        XCTAssertEqual(viewerTrustedPeers.first?.displayName, "Intel-Test-Host")
    }

    func testPairingBootstrapReusesMatchingTrustWithoutShowingPairingUI() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-reuse".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-reuse".utf8))
        let hostTrustStore = InMemoryTrustStore()
        let viewerTrustStore = InMemoryTrustStore()
        try await hostTrustStore.save(TrustedPeer(identity: viewerIdentity, displayName: "Viewer"))
        try await viewerTrustStore.save(TrustedPeer(identity: hostIdentity, displayName: "Host"))

        let hostPairing = PairingCoordinator(localIdentity: hostIdentity, trustStore: hostTrustStore)
        let viewerPairing = PairingCoordinator(localIdentity: viewerIdentity, trustStore: viewerTrustStore)
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .pairingRequired(viewerIdentity),
            secondAuthentication: .pairingRequired(hostIdentity)
        )
        let capabilities: Set<Capability> = [.pingPong]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(role: .host, implementationIdentifier: "reuse-host", capabilities: capabilities),
            transport: pair.first,
            pairingCoordinator: hostPairing
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(role: .viewer, implementationIdentifier: "reuse-viewer", capabilities: capabilities),
            transport: pair.second,
            pairingCoordinator: viewerPairing
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart

        for _ in 0 ..< 100 {
            let hostState = await host.snapshot().state
            let viewerState = await viewer.snapshot().state
            if hostState == .capabilitiesNegotiated,
               viewerState == .capabilitiesNegotiated {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let hostSnapshot = await host.snapshot()
        let viewerSnapshot = await viewer.snapshot()
        let hostChallenge = await hostPairing.pendingChallenge()
        let viewerChallenge = await viewerPairing.pendingChallenge()
        XCTAssertEqual(hostSnapshot.state, .capabilitiesNegotiated)
        XCTAssertEqual(viewerSnapshot.state, .capabilitiesNegotiated)
        XCTAssertNil(hostChallenge)
        XCTAssertNil(viewerChallenge)
    }

    func testPairingBootstrapRecoversWhenOnlyHostHasTrustRecord() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-asymmetric".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-asymmetric".utf8))
        let hostTrustStore = InMemoryTrustStore()
        let viewerTrustStore = InMemoryTrustStore()
        try await hostTrustStore.save(TrustedPeer(identity: viewerIdentity, displayName: "Viewer"))

        let hostPairing = PairingCoordinator(localIdentity: hostIdentity, trustStore: hostTrustStore)
        let viewerPairing = PairingCoordinator(localIdentity: viewerIdentity, trustStore: viewerTrustStore)
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .pairingRequired(viewerIdentity),
            secondAuthentication: .pairingRequired(hostIdentity)
        )
        let capabilities: Set<Capability> = [.pingPong]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(role: .host, implementationIdentifier: "asymmetric-host", capabilities: capabilities),
            transport: pair.first,
            pairingCoordinator: hostPairing
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(role: .viewer, implementationIdentifier: "asymmetric-viewer", capabilities: capabilities),
            transport: pair.second,
            pairingCoordinator: viewerPairing
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart

        var viewerChallenge: PairingChallenge?
        for _ in 0 ..< 100 {
            viewerChallenge = await viewerPairing.pendingChallenge()
            if viewerChallenge?.isVerificationReady == true { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let challenge = try XCTUnwrap(viewerChallenge)
        try await viewer.confirmPairing(
            confirmationCode: challenge.confirmationCode,
            accepted: true
        )

        for _ in 0 ..< 100 {
            let hostState = await host.snapshot().state
            let viewerState = await viewer.snapshot().state
            if hostState == .capabilitiesNegotiated,
               viewerState == .capabilitiesNegotiated {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let hostSnapshot = await host.snapshot()
        let viewerSnapshot = await viewer.snapshot()
        let hostTrustDecision = try await hostPairing.trustDecision(for: viewerIdentity)
        let viewerTrustDecision = try await viewerPairing.trustDecision(for: hostIdentity)
        XCTAssertEqual(hostSnapshot.state, .capabilitiesNegotiated)
        XCTAssertEqual(viewerSnapshot.state, .capabilitiesNegotiated)
        XCTAssertEqual(hostTrustDecision, .trusted)
        XCTAssertEqual(viewerTrustDecision, .trusted)
    }

    func testReconnectClearsAuthorizationAndRequiresFreshHandshake() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-reconnect".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-reconnect".utf8))
        let firstPair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await firstPair.first.start()
        try await firstPair.second.start()
        let capabilities: Set<Capability> = [.pingPong]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(role: .host, implementationIdentifier: "host", capabilities: capabilities),
            transport: firstPair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(role: .viewer, implementationIdentifier: "viewer", capabilities: capabilities),
            transport: firstPair.second
        )
        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await host.authorize(capabilities: [.pingPong])
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).authorized { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let authorizedBeforeReconnect = await viewer.snapshot()
        XCTAssertTrue(authorizedBeforeReconnect.authorized)

        let secondPair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await secondPair.first.start()
        try await secondPair.second.start()
        async let hostReconnect: Void = host.reconnect(using: secondPair.first)
        async let viewerReconnect: Void = viewer.reconnect(using: secondPair.second)
        try await hostReconnect
        try await viewerReconnect
        for _ in 0 ..< 100 {
            let hostState = await host.snapshot()
            let viewerState = await viewer.snapshot()
            if hostState.state == .capabilitiesNegotiated,
               viewerState.state == .capabilitiesNegotiated {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let reconnectedHostSnapshot = await host.snapshot()
        let reconnectedViewerSnapshot = await viewer.snapshot()
        XCTAssertFalse(reconnectedHostSnapshot.authorized)
        XCTAssertFalse(reconnectedViewerSnapshot.authorized)
        XCTAssertEqual(reconnectedHostSnapshot.reconnectGeneration, 1)
        XCTAssertEqual(reconnectedViewerSnapshot.reconnectGeneration, 1)
    }

    func testStaleAuthorizationCannotAuthorizeAReconnectedSession() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-auth-race".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-auth-race".utf8))
        let firstPair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await firstPair.first.start()
        try await firstPair.second.start()

        let blockedViewerTransport = BlockingInvalidationTransport(base: firstPair.second)
        let capabilities: Set<Capability> = [.pingPong, .windowSelection]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "auth-race-host",
                capabilities: capabilities
            ),
            transport: firstPair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "auth-race-viewer",
                capabilities: capabilities
            ),
            transport: blockedViewerTransport
        )
        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated,
               (await viewer.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            await Task.yield()
        }

        let authorizeTask = Task { () -> String? in
            do {
                try await host.authorize(
                    windowGeneration: 11,
                    capabilities: [.windowSelection]
                )
                return nil
            } catch {
                return String(describing: error)
            }
        }
        XCTAssertEqual(
            blockedViewerTransport.waitForInvalidation(timeout: 1),
            .success,
            "the Viewer must be paused inside the authorization invalidation await"
        )

        let secondPair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await secondPair.first.start()
        try await secondPair.second.start()
        let reconnectedHost = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "auth-race-new-host",
                capabilities: capabilities
            ),
            transport: secondPair.first
        )
        let reconnectedHostStart = Task { () -> String? in
            do {
                try await reconnectedHost.start()
                return nil
            } catch {
                return String(describing: error)
            }
        }
        let reconnectTask = Task { () -> String? in
            do {
                await blockedViewerTransport.releaseInvalidation()
                try await viewer.reconnect(using: secondPair.second)
                return nil
            } catch {
                return String(describing: error)
            }
        }

        let authorizationError = await authorizeTask.value
        let reconnectError = await reconnectTask.value
        let reconnectedHostError = await reconnectedHostStart.value
        XCTAssertNil(authorizationError)
        XCTAssertNil(reconnectError)
        XCTAssertNil(reconnectedHostError)
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).state == .capabilitiesNegotiated,
               (await reconnectedHost.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            await Task.yield()
        }

        let snapshot = await viewer.snapshot()
        XCTAssertEqual(snapshot.state, .capabilitiesNegotiated)
        XCTAssertFalse(snapshot.authorized)
        XCTAssertNil(snapshot.authorizedWindowGeneration)
        XCTAssertTrue(snapshot.authorizedCapabilities.isEmpty)

        await reconnectedHost.stop()
        await viewer.stop()
        await host.stop()
    }

    func testStaleInputAdmissionCannotEnterSameWindowReauthorization() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-input-admission".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-input-admission".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()

        let capabilities: Set<Capability> = [.pingPong, .mouseInput]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "input-admission-host",
                capabilities: capabilities
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "input-admission-viewer",
                capabilities: capabilities
            ),
            transport: pair.second
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated,
               (await viewer.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            await Task.yield()
        }

        try await host.authorize(windowGeneration: 23, capabilities: [.mouseInput])
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).authorized { break }
            await Task.yield()
        }
        let input = InputEventMessage(
            kind: .pointerMove,
            windowGeneration: 23,
            x: 12,
            y: 34
        )
        let oldAdmission = try await viewer.makeInputAdmission(for: input)
        let oldAuthorizationGeneration = (await viewer.snapshot()).authorizationGeneration

        // Reauthorize the same selected window. A window-generation-only
        // check would accept oldAdmission after this transition.
        try await host.authorize(windowGeneration: 23, capabilities: [.mouseInput])
        for _ in 0 ..< 100 {
            let snapshot = await viewer.snapshot()
            if snapshot.authorizationGeneration > oldAuthorizationGeneration { break }
            await Task.yield()
        }
        let reauthorizedGeneration = (await viewer.snapshot()).authorizationGeneration
        XCTAssertGreaterThan(
            reauthorizedGeneration,
            oldAuthorizationGeneration
        )

        do {
            try await viewer.sendInput(input, using: oldAdmission)
            XCTFail("an input admission from the previous authorization epoch must be rejected")
        } catch SessionError.authorizationChanged {
            // Expected: the old record cannot enter the reauthorized session.
        }
        XCTAssertEqual(host.incomingMessages.storage.counts().control, 0)

        let freshAdmission = try await viewer.makeInputAdmission(for: input)
        try await viewer.sendInput(input, using: freshAdmission)
        for _ in 0 ..< 100 {
            if host.incomingMessages.storage.counts().control == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(host.incomingMessages.storage.counts().control, 1)

        await host.stop()
        await viewer.stop()
    }

    func testIncomingInputAdmissionIsFencedAgainstAuthorizationRevocation() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-incoming-fence".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-incoming-fence".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()

        let capabilities: Set<Capability> = [.pingPong, .mouseInput]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "incoming-fence-host",
                capabilities: capabilities
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "incoming-fence-viewer",
                capabilities: capabilities
            ),
            transport: pair.second
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated,
               (await viewer.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            await Task.yield()
        }
        try await host.authorize(windowGeneration: 5, capabilities: [.mouseInput])
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).authorized { break }
            await Task.yield()
        }

        let input = InputEventMessage(
            kind: .pointerMove,
            windowGeneration: 5,
            x: 100,
            y: 200
        )
        let operationEntered = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)
        let admissionTask = Task { () throws -> Bool in
            try await host.withIncomingInputAdmission(for: input) {
                operationEntered.signal()
                releaseOperation.wait()
                return true
            }
        }
        XCTAssertEqual(
            operationEntered.wait(timeout: .now() + 1),
            .success,
            "the admission operation must run synchronously on the session actor"
        )

        let revokeRequested = DispatchSemaphore(value: 0)
        let revokeTask = Task { () -> Bool in
            revokeRequested.signal()
            do {
                try await host.revokeAuthorization()
                return true
            } catch {
                return false
            }
        }
        XCTAssertEqual(
            revokeRequested.wait(timeout: .now() + 1),
            .success,
            "the revoke request must be submitted while admission is held"
        )
        releaseOperation.signal()
        let admissionSucceeded = try await admissionTask.value
        XCTAssertTrue(admissionSucceeded)
        let revokeSucceeded = await revokeTask.value
        XCTAssertTrue(revokeSucceeded)

        do {
            _ = try await host.withIncomingInputAdmission(for: input) {
                XCTFail("revoked authorization must not reach the injection operation")
                return false
            }
            XCTFail("revoked authorization must reject incoming input")
        } catch SessionError.unauthorizedMessage(.inputEvent) {
            // Expected: the local authorization epoch is already invalid.
        }

        await host.stop()
        await viewer.stop()
    }

    func testStaleRevokeFailureCannotFailAReauthorizedSession() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-revoke-race".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-revoke-race".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()

        let failingHostTransport = BlockingRevocationTransport(base: pair.first)
        let capabilities: Set<Capability> = [.pingPong, .mouseInput]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "revoke-race-host",
                capabilities: capabilities
            ),
            transport: failingHostTransport
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "revoke-race-viewer",
                capabilities: capabilities
            ),
            transport: pair.second
        )
        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated,
               (await viewer.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            await Task.yield()
        }
        try await host.authorize(windowGeneration: 41, capabilities: [.mouseInput])
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).authorized { break }
            await Task.yield()
        }

        failingHostTransport.armNextRevocationFailure()
        let revokeTask = Task { () -> Bool in
            do {
                try await host.revokeAuthorization()
                return false
            } catch {
                return true
            }
        }
        XCTAssertEqual(
            failingHostTransport.waitForRevocationStart(timeout: 1),
            .success,
            "the test must hold the revoke notification before reauthorization"
        )

        // revokeAuthorization has already invalidated the old epoch. This
        // call captures the new epoch while the stale revoke send is blocked;
        // the subsequent stale fail must not close it.
        let reauthorizeTask = Task { () -> Bool in
            do {
                try await host.authorize(windowGeneration: 41, capabilities: [.mouseInput])
                return true
            } catch {
                return false
            }
        }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        await failingHostTransport.releaseRevocation()

        let revokeFailed = await revokeTask.value
        let reauthorized = await reauthorizeTask.value
        XCTAssertTrue(revokeFailed)
        XCTAssertTrue(reauthorized)
        let snapshot = await host.snapshot()
        XCTAssertEqual(snapshot.state, .windowSelectionAuthorized)
        XCTAssertTrue(snapshot.authorized)
        XCTAssertEqual(snapshot.authorizedWindowGeneration, 41)

        await host.stop()
        await viewer.stop()
    }

    func testStaleHeartbeatFailureCannotFailAReconnectedSession() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-failure-race".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-failure-race".utf8))
        let firstPair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await firstPair.first.start()
        try await firstPair.second.start()

        let secondPair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await secondPair.first.start()
        try await secondPair.second.start()

        let capabilities: Set<Capability> = [.pingPong]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "failure-race-host",
                capabilities: capabilities,
                heartbeatIntervalNanoseconds: 1_000_000_000
            ),
            transport: firstPair.first
        )
        let failingViewerTransport = HeartbeatFailureTransport(base: firstPair.second)
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "failure-race-viewer",
                capabilities: capabilities,
                heartbeatIntervalNanoseconds: 1_000_000,
                heartbeatTimeoutNanoseconds: 1_000_000_000
            ),
            transport: failingViewerTransport
        )
        let reconnectedHost = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "failure-race-new-host",
                capabilities: capabilities,
                heartbeatIntervalNanoseconds: 1_000_000_000
            ),
            transport: secondPair.first
        )

        let reconnectRequested = AsyncTestSignal()
        failingViewerTransport.setFailureStartHandler {
            Task { await reconnectRequested.signal() }
        }
        let reconnectTask = Task { () -> String? in
            await reconnectRequested.wait()
            do {
                try await viewer.reconnect(using: secondPair.second)
                return nil
            } catch {
                return String(describing: error)
            }
        }
        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        let reconnectedHostStart = Task { () -> String? in
            do {
                try await reconnectedHost.start()
                return nil
            } catch {
                return String(describing: error)
            }
        }
        try await hostStart
        try await viewerStart
        for _ in 0 ..< 100 {
            if (await host.snapshot()).state == .capabilitiesNegotiated,
               (await viewer.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(
            failingViewerTransport.waitForFailureStart(timeout: 1),
            .success,
            "the heartbeat send must be held while reconnect queues"
        )
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        await failingViewerTransport.releaseFailure()

        let reconnectError = await reconnectTask.value
        let reconnectedHostError = await reconnectedHostStart.value
        XCTAssertNil(reconnectError)
        XCTAssertNil(reconnectedHostError)
        for _ in 0 ..< 100 {
            if (await viewer.snapshot()).state == .capabilitiesNegotiated,
               (await reconnectedHost.snapshot()).state == .capabilitiesNegotiated {
                break
            }
            await Task.yield()
        }

        let snapshot = await viewer.snapshot()
        XCTAssertEqual(snapshot.state, .capabilitiesNegotiated)
        XCTAssertFalse(snapshot.authorized)
        await reconnectedHost.stop()
        await viewer.stop()
        await host.stop()
    }

    func testReplaySequenceFailsSessionClosed() async throws {
        let local = try PeerIdentity(publicKeyRepresentation: Data("local-replay".utf8))
        let remote = try PeerIdentity(publicKeyRepresentation: Data("remote-replay".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(remote),
            secondAuthentication: .trusted(local)
        )
        try await pair.first.start()
        try await pair.second.start()
        let session = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "replay-test",
                capabilities: [.pingPong]
            ),
            transport: pair.first
        )
        try await session.start()

        let hello = HelloMessage(
            protocolVersion: .current,
            role: .host,
            implementationIdentifier: "raw-host",
            limits: .default
        )
        _ = try await pair.second.send(try Envelope(message: .hello(hello), sequence: 0, timestamp: 0))
        let capabilities = CapabilitiesMessage(capabilities: [.pingPong])
        _ = try await pair.second.send(try Envelope(message: .capabilities(capabilities), sequence: 1, timestamp: 1))
        _ = try await pair.second.send(try Envelope(message: .ping(PingMessage(nonce: 1)), sequence: 1, timestamp: 2))

        for _ in 0 ..< 100 {
            if (await session.snapshot()).state == .failed { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let replayFailureSnapshot = await session.snapshot()
        XCTAssertEqual(replayFailureSnapshot.state, .failed)
        XCTAssertFalse(replayFailureSnapshot.authorized)
    }

    func testHeartbeatTimeoutFailsClosedWhenPeerDoesNotRespond() async throws {
        let local = try PeerIdentity(publicKeyRepresentation: Data("local-heartbeat".utf8))
        let remote = try PeerIdentity(publicKeyRepresentation: Data("remote-heartbeat".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(remote),
            secondAuthentication: .trusted(local)
        )
        try await pair.first.start()
        try await pair.second.start()
        let session = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "heartbeat-test",
                capabilities: [.pingPong],
                heartbeatIntervalNanoseconds: 2_000_000,
                heartbeatTimeoutNanoseconds: 6_000_000
            ),
            transport: pair.first
        )
        try await session.start()

        let hello = HelloMessage(
            protocolVersion: .current,
            role: .host,
            implementationIdentifier: "silent-host",
            limits: .default
        )
        _ = try await pair.second.send(try Envelope(message: .hello(hello), sequence: 0, timestamp: 0))
        let capabilities = CapabilitiesMessage(capabilities: [.pingPong])
        _ = try await pair.second.send(try Envelope(message: .capabilities(capabilities), sequence: 1, timestamp: 1))

        for _ in 0 ..< 200 {
            if (await session.snapshot()).state == .failed { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let heartbeatFailureSnapshot = await session.snapshot()
        XCTAssertEqual(heartbeatFailureSnapshot.state, .failed)
        XCTAssertFalse(heartbeatFailureSnapshot.authorized)
    }

    func testHandshakeDeadlineFailsClosedWhenPeerDoesNotAdvance() async throws {
        let local = try PeerIdentity(publicKeyRepresentation: Data("local-handshake".utf8))
        let remote = try PeerIdentity(publicKeyRepresentation: Data("remote-handshake".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(remote),
            secondAuthentication: .trusted(local)
        )
        try await pair.first.start()
        try await pair.second.start()
        let session = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "handshake-timeout-test",
                capabilities: [.pingPong],
                handshakeTimeoutNanoseconds: 10_000_000
            ),
            transport: pair.first
        )
        try await session.start()

        for _ in 0 ..< 200 {
            if (await session.snapshot()).state == .failed { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertFalse(snapshot.authorized)
        XCTAssertNil(snapshot.authorizedWindowGeneration)
        XCTAssertTrue(snapshot.authorizedCapabilities.isEmpty)
    }

    func testPairingConsentCanOutlastGenericHandshakeDeadline() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-pairing-timeout".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-pairing-timeout".utf8))
        let hostPairing = PairingCoordinator(
            localIdentity: hostIdentity,
            trustStore: InMemoryTrustStore()
        )
        let viewerPairing = PairingCoordinator(
            localIdentity: viewerIdentity,
            trustStore: InMemoryTrustStore()
        )
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .pairingRequired(viewerIdentity),
            secondAuthentication: .pairingRequired(hostIdentity)
        )
        try await pair.first.start()
        try await pair.second.start()

        let capabilities: Set<Capability> = [.pingPong]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "pairing-timeout-host",
                capabilities: capabilities,
                handshakeTimeoutNanoseconds: 10_000_000
            ),
            transport: pair.first,
            pairingCoordinator: hostPairing
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "pairing-timeout-viewer",
                capabilities: capabilities,
                handshakeTimeoutNanoseconds: 10_000_000
            ),
            transport: pair.second,
            pairingCoordinator: viewerPairing
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        try await Task.sleep(nanoseconds: 50_000_000)

        let hostState = await host.snapshot().state
        let viewerState = await viewer.snapshot().state
        XCTAssertEqual(hostState, .pairingRequired)
        XCTAssertEqual(viewerState, .pairingRequired)

        await host.stop()
        await viewer.stop()
    }

    func testPairingDeadlineFailsClosedWhenConsentNeverCompletes() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-pairing-deadline".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("viewer-pairing-deadline".utf8))
        let hostPairing = PairingCoordinator(
            localIdentity: hostIdentity,
            trustStore: InMemoryTrustStore()
        )
        let viewerPairing = PairingCoordinator(
            localIdentity: viewerIdentity,
            trustStore: InMemoryTrustStore()
        )
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .pairingRequired(viewerIdentity),
            secondAuthentication: .pairingRequired(hostIdentity)
        )
        // Expiry is driven by the manual deadlines below, never by the
        // scheduler, so the Host deadline cannot close the shared transport
        // while the Viewer is still sending Hello from start().
        let hostDeadline = ManualPairingDeadline()
        let viewerDeadline = ManualPairingDeadline()
        let pairingTimeoutNanoseconds: UInt64 = 60_000_000_000
        let capabilities: Set<Capability> = [.pingPong]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "pairing-deadline-host",
                capabilities: capabilities,
                handshakeTimeoutNanoseconds: 60_000_000_000,
                pairingTimeoutNanoseconds: pairingTimeoutNanoseconds
            ),
            transport: pair.first,
            pairingCoordinator: hostPairing,
            pairingDeadlineSleep: { try await hostDeadline.sleep(nanoseconds: $0) }
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "pairing-deadline-viewer",
                capabilities: capabilities,
                handshakeTimeoutNanoseconds: 60_000_000_000,
                pairingTimeoutNanoseconds: pairingTimeoutNanoseconds
            ),
            transport: pair.second,
            pairingCoordinator: viewerPairing,
            pairingDeadlineSleep: { try await viewerDeadline.sleep(nanoseconds: $0) }
        )

        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart

        // Both sides must arm a deadline bounded by the challenge expiry
        // before anyone consents.
        let armTimeoutNanoseconds: UInt64 = 5_000_000_000
        guard let hostRequested = await hostDeadline.waitUntilArmed(
            timeoutNanoseconds: armTimeoutNanoseconds
        ) else {
            XCTFail("Host pairing deadline was not armed")
            return
        }
        guard let viewerRequested = await viewerDeadline.waitUntilArmed(
            timeoutNanoseconds: armTimeoutNanoseconds
        ) else {
            XCTFail("Viewer pairing deadline was not armed")
            return
        }
        XCTAssertLessThanOrEqual(hostRequested, pairingTimeoutNanoseconds)
        XCTAssertLessThanOrEqual(viewerRequested, pairingTimeoutNanoseconds)
        let hostPending = await host.snapshot()
        let viewerPending = await viewer.snapshot()
        XCTAssertEqual(hostPending.state, .pairingRequired)
        XCTAssertEqual(viewerPending.state, .pairingRequired)
        XCTAssertFalse(hostPending.authorized)
        XCTAssertFalse(viewerPending.authorized)

        // Consent never completes: the Host challenge expires first and must
        // fail closed with the pairing failure itself.
        await hostDeadline.expire()
        await waitForFailedState(host)
        let hostSnapshot = await host.snapshot()
        let hostFailure = await host.failureReason()
        XCTAssertEqual(hostSnapshot.state, .failed)
        XCTAssertFalse(hostSnapshot.authorized)
        XCTAssertEqual(hostFailure, .pairingFailed)

        // The Viewer fails closed either from its own expired challenge or
        // from the Host tearing down the transport, whichever it observes
        // first; neither path may leave it pending or authorized.
        await viewerDeadline.expire()
        await waitForFailedState(viewer)
        let viewerSnapshot = await viewer.snapshot()
        let viewerFailure = await viewer.failureReason()
        XCTAssertEqual(viewerSnapshot.state, .failed)
        XCTAssertFalse(viewerSnapshot.authorized)
        XCTAssertTrue(isPairingTimeoutFailure(viewerFailure))
    }

    /// Waits for an explicit terminal state. The wall-clock bound only stops a
    /// broken build from hanging; correctness never depends on it.
    private func waitForFailedState(
        _ coordinator: SessionCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let bound = Date().addingTimeInterval(30)
        while await coordinator.snapshot().state != .failed {
            guard Date() < bound else {
                XCTFail("session never reached .failed", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    private func isPairingTimeoutFailure(_ error: SessionError?) -> Bool {
        guard let error else { return false }
        switch error {
        case .pairingFailed, .transportFailure:
            return true
        default:
            return false
        }
    }

    func testDuplicateHelloFailsClosed() async throws {
        let local = try PeerIdentity(publicKeyRepresentation: Data("local-duplicate".utf8))
        let remote = try PeerIdentity(publicKeyRepresentation: Data("remote-duplicate".utf8))
        let pair = InMemoryTransport.makePair(
            firstAuthentication: .trusted(remote),
            secondAuthentication: .trusted(local)
        )
        try await pair.first.start()
        try await pair.second.start()
        let session = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "duplicate-hello-test",
                capabilities: [.pingPong]
            ),
            transport: pair.first
        )
        try await session.start()

        let hello = HelloMessage(
            protocolVersion: .current,
            role: .host,
            implementationIdentifier: "raw-host",
            limits: .default
        )
        _ = try await pair.second.send(try Envelope(message: .hello(hello), sequence: 0, timestamp: 0))
        _ = try await pair.second.send(try Envelope(message: .hello(hello), sequence: 1, timestamp: 1))

        for _ in 0 ..< 100 {
            if (await session.snapshot()).state == .failed { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let duplicateHelloSnapshot = await session.snapshot()
        XCTAssertEqual(duplicateHelloSnapshot.state, .failed)
        XCTAssertFalse(duplicateHelloSnapshot.authorized)
    }

    func testTLSAuthenticationRequiresPresentedIdentityAndRejectsMismatch() throws {
        let trustedIdentity = try PeerIdentity(publicKeyRepresentation: Data("tls-trusted".utf8))
        let changedIdentity = try PeerIdentity(publicKeyRepresentation: Data("tls-changed".utf8))
        let trustedOptions = TLSOptions(
            mode: .trusted(TrustedPeer(identity: trustedIdentity))
        )

        XCTAssertTrue(trustedOptions.peerAuthenticationRequired)
        XCTAssertEqual(trustedOptions.initialAuthentication, .pending)
        XCTAssertEqual(trustedOptions.resolvedAuthentication(), .pending)
        XCTAssertEqual(trustedOptions.authentication(for: trustedIdentity), .trusted(trustedIdentity))
        XCTAssertEqual(trustedOptions.authentication(for: changedIdentity), .rejected)
        XCTAssertEqual(
            trustedOptions.connectionScoped().resolvedAuthentication(),
            .pending
        )

        let bootstrapOptions = TLSOptions(
            mode: .pairingBootstrap(expectedPeer: trustedIdentity)
        )
        XCTAssertEqual(bootstrapOptions.authentication(for: trustedIdentity), .pairingRequired(trustedIdentity))
        XCTAssertEqual(bootstrapOptions.authentication(for: changedIdentity), .rejected)
    }

    func testClipboardSyncIsDisabledByDefaultAndRequiresOptIn() {
        var viewer = ClipboardSyncCoordinator(localRole: .viewer)
        XCTAssertFalse(viewer.status.localEnabled)
        XCTAssertFalse(viewer.status.isEnabledForSession)
        XCTAssertEqual(viewer.localTextChanged("secret"), .disabled)
        XCTAssertNil(viewer.status.pendingOutgoing)
    }

    func testClipboardOptInSurvivesAuthorizationEpochChangeButReconnectResetsIt() {
        var host = ClipboardSyncCoordinator(localRole: .host)
        var viewer = ClipboardSyncCoordinator(localRole: .viewer)

        let hostEnable = try! XCTUnwrap(host.setEnabled(true))
        let viewerEnable = try! XCTUnwrap(viewer.setEnabled(true))
        guard case let .acknowledgement(hostAck) = viewer.receiveOffer(hostEnable),
              case let .acknowledgement(viewerAck) = host.receiveOffer(viewerEnable) else {
            XCTFail("both per-session opt-ins must be acknowledged")
            return
        }
        XCTAssertEqual(host.receiveAcknowledgement(hostAck), .statusUpdated)
        XCTAssertEqual(viewer.receiveAcknowledgement(viewerAck), .statusUpdated)
        XCTAssertTrue(host.status.isEnabledForSession)
        XCTAssertTrue(viewer.status.isEnabledForSession)

        guard case .offer = viewer.localTextChanged("discard at window switch") else {
            XCTFail("an enabled session must admit a text offer")
            return
        }
        let viewerReenable = try! XCTUnwrap(
            viewer.resetForAuthorizationEpoch(preservingLocalOptIn: true)
        )
        host.reset()
        let hostReenable = try! XCTUnwrap(host.setEnabled(true))

        XCTAssertTrue(viewer.status.localEnabled)
        XCTAssertFalse(viewer.status.remoteEnabled)
        XCTAssertNil(viewer.status.pendingOutgoing)
        XCTAssertTrue(host.status.localEnabled)
        XCTAssertFalse(host.status.remoteEnabled)

        guard case let .acknowledgement(hostReenableAck) = viewer.receiveOffer(hostReenable),
              case let .acknowledgement(viewerReenableAck) = host.receiveOffer(viewerReenable) else {
            XCTFail("both peers must renegotiate opt-in in the new authorization epoch")
            return
        }
        XCTAssertEqual(host.receiveAcknowledgement(hostReenableAck), .statusUpdated)
        XCTAssertEqual(viewer.receiveAcknowledgement(viewerReenableAck), .statusUpdated)
        XCTAssertTrue(host.status.isEnabledForSession)
        XCTAssertTrue(viewer.status.isEnabledForSession)

        viewer.reset()
        XCTAssertFalse(viewer.status.localEnabled)
        XCTAssertFalse(viewer.status.remoteEnabled)
        XCTAssertNil(viewer.resetForAuthorizationEpoch(preservingLocalOptIn: true))
    }

    func testClipboardSyncAcknowledgesTextAndSuppressesEcho() {
        var host = ClipboardSyncCoordinator(localRole: .host)
        var viewer = ClipboardSyncCoordinator(localRole: .viewer)

        let hostEnable = try! XCTUnwrap(host.setEnabled(true))
        let viewerEnable = try! XCTUnwrap(viewer.setEnabled(true))
        guard case let .acknowledgement(hostEnableAck) = viewer.receiveOffer(hostEnable),
              case let .acknowledgement(viewerEnableAck) = host.receiveOffer(viewerEnable) else {
            XCTFail("enablement offers must be acknowledged")
            return
        }
        XCTAssertTrue(hostEnableAck.accepted)
        XCTAssertTrue(viewerEnableAck.accepted)
        XCTAssertEqual(host.receiveAcknowledgement(hostEnableAck), .statusUpdated)
        XCTAssertEqual(viewer.receiveAcknowledgement(viewerEnableAck), .statusUpdated)
        XCTAssertTrue(host.status.isEnabledForSession)
        XCTAssertTrue(viewer.status.isEnabledForSession)

        guard case let .offer(viewerOffer) = viewer.localTextChanged("你好") else {
            XCTFail("an opted-in local text change must create an offer")
            return
        }
        guard case let .acknowledgement(offerAck) = host.receiveOffer(viewerOffer) else {
            XCTFail("text offers must be acknowledged")
            return
        }
        XCTAssertTrue(offerAck.accepted)
        guard case let .sendText(textMessage) = viewer.receiveAcknowledgement(offerAck) else {
            XCTFail("an accepted offer must release its text message")
            return
        }
        guard case let .apply(text, transfer) = host.receiveText(textMessage) else {
            XCTFail("matching text must be applied")
            return
        }
        XCTAssertEqual(text, "你好")
        XCTAssertEqual(transfer.origin, .viewer)
        XCTAssertEqual(transfer.generation, viewerOffer.generation)
        var echoProbe = host
        XCTAssertEqual(echoProbe.localTextChanged("你好"), .suppressedEcho)
        host.consumeEchoSuppression()
        guard case .offer = host.localTextChanged("你好") else {
            XCTFail("a later user copy of the same text must not be suppressed")
            return
        }
        XCTAssertNil(host.status.pendingIncoming)
    }

    func testClipboardSyncQueuesNewestChangeUntilTheCurrentOfferCompletes() {
        var host = ClipboardSyncCoordinator(localRole: .host)
        var viewer = ClipboardSyncCoordinator(localRole: .viewer)

        let hostEnable = try! XCTUnwrap(host.setEnabled(true))
        let viewerEnable = try! XCTUnwrap(viewer.setEnabled(true))
        guard case let .acknowledgement(hostEnableAck) = viewer.receiveOffer(hostEnable),
              case let .acknowledgement(viewerEnableAck) = host.receiveOffer(viewerEnable) else {
            XCTFail("enablement offers must be acknowledged")
            return
        }
        _ = host.receiveAcknowledgement(hostEnableAck)
        _ = viewer.receiveAcknowledgement(viewerEnableAck)

        guard case let .offer(firstOffer) = viewer.localTextChanged("one") else {
            XCTFail("the first text change must create an offer")
            return
        }
        XCTAssertEqual(viewer.localTextChanged("two"), .queued)

        guard case let .acknowledgement(firstAck) = host.receiveOffer(firstOffer),
              case let .sendTextAndOffer(firstText, secondOffer) = viewer.receiveAcknowledgement(firstAck) else {
            XCTFail("the first acknowledgement must release the first text and queue the next offer")
            return
        }
        XCTAssertEqual(String(data: firstText.text, encoding: .utf8), "one")
        XCTAssertEqual(secondOffer.textByteCount, 3)

        guard case .apply = host.receiveText(firstText),
              case let .acknowledgement(secondAck) = host.receiveOffer(secondOffer),
              case let .sendText(secondText) = viewer.receiveAcknowledgement(secondAck) else {
            XCTFail("the queued offer must complete after the first text is delivered")
            return
        }
        XCTAssertEqual(String(data: secondText.text, encoding: .utf8), "two")
    }

    func testClipboardSyncRecoversQueuedOfferAfterObsoleteClipboardEpoch() {
        var host = ClipboardSyncCoordinator(localRole: .host)
        var viewer = ClipboardSyncCoordinator(localRole: .viewer)

        guard let hostEnable = host.setEnabled(true),
              let viewerEnable = viewer.setEnabled(true),
              case let .acknowledgement(hostEnableAck) = viewer.receiveOffer(hostEnable),
              case let .acknowledgement(viewerEnableAck) = host.receiveOffer(viewerEnable) else {
            XCTFail("both clipboard opt-ins must be acknowledged")
            return
        }
        _ = host.receiveAcknowledgement(hostEnableAck)
        _ = viewer.receiveAcknowledgement(viewerEnableAck)

        guard case let .offer(firstOffer) = viewer.localTextChanged("one"),
              case .queued = viewer.localTextChanged("two"),
              case let .acknowledgement(firstAck) = host.receiveOffer(firstOffer),
              case let .sendTextAndOffer(firstText, secondOffer) = viewer.receiveAcknowledgement(firstAck) else {
            XCTFail("the first offer must release its text and install a queued offer")
            return
        }
        XCTAssertEqual(String(data: firstText.text, encoding: .utf8), "one")
        XCTAssertEqual(viewer.localTextChanged("three"), .queued)

        let staleTransferID = ClipboardTransferID(
            generation: firstOffer.generation,
            origin: firstOffer.origin
        )
        XCTAssertNil(viewer.recoverPendingOutgoingOffer(matching: staleTransferID))
        XCTAssertEqual(viewer.status.pendingOutgoing?.generation, secondOffer.generation)
        XCTAssertEqual(viewer.retryPendingOutgoingOffer(after: staleTransferID), secondOffer)

        guard let pendingTransfer = viewer.status.pendingOutgoing,
              let recoveredOffer = viewer.recoverPendingOutgoingOffer(matching: pendingTransfer) else {
            XCTFail("a queued edit must be promoted after the old offer is fenced")
            return
        }
        XCTAssertEqual(recoveredOffer.textByteCount, 5)
        guard case let .acknowledgement(recoveredAck) = host.receiveOffer(recoveredOffer),
              case let .sendText(recoveredText) = viewer.receiveAcknowledgement(recoveredAck) else {
            XCTFail("the recovered offer must complete normally")
            return
        }
        XCTAssertEqual(String(data: recoveredText.text, encoding: .utf8), "three")
    }

    func testClipboardSyncUsesDeterministicConflictPolicyAndSizeLimit() {
        let limits = ProtocolLimits(maxClipboardTextBytes: 4)
        var host = ClipboardSyncCoordinator(localRole: .host, limits: limits)
        var viewer = ClipboardSyncCoordinator(localRole: .viewer, limits: limits)
        _ = host.setEnabled(true)
        _ = viewer.setEnabled(true)
        let hostEnableAck = host.receiveOffer(
            ClipboardOfferMessage(
                generation: 1,
                origin: .viewer,
                textByteCount: 0,
                enabled: true,
                hasText: false
            )
        )
        let viewerEnableAck = viewer.receiveOffer(
            ClipboardOfferMessage(
                generation: 1,
                origin: .host,
                textByteCount: 0,
                enabled: true,
                hasText: false
            )
        )
        if case let .acknowledgement(ack) = hostEnableAck {
            _ = viewer.receiveAcknowledgement(ack)
        }
        if case let .acknowledgement(ack) = viewerEnableAck {
            _ = host.receiveAcknowledgement(ack)
        }

        guard case let .offer(viewerOffer) = viewer.localTextChanged("one") else {
            XCTFail("viewer offer missing")
            return
        }
        guard case let .offer(hostOffer) = host.localTextChanged("two") else {
            XCTFail("host offer missing")
            return
        }
        guard case let .acknowledgement(conflictAck) = host.receiveOffer(viewerOffer) else {
            XCTFail("conflicting offer must be acknowledged")
            return
        }
        XCTAssertFalse(conflictAck.accepted)
        XCTAssertEqual(conflictAck.reason, .conflict)
        XCTAssertEqual(viewer.receiveAcknowledgement(conflictAck), .rejected(.conflict))
        XCTAssertEqual(hostOffer.origin, .host)
        XCTAssertEqual(host.localTextChanged("12345"), .tooLarge)
    }

    func testClipboardSyncUsesFieldLimitForLocalAdmission() {
        let limits = ProtocolLimits(maxClipboardTextBytes: 64, maxFieldLength: 32)
        var viewer = ClipboardSyncCoordinator(localRole: .viewer, limits: limits)
        _ = viewer.setEnabled(true)

        let remoteEnable = ClipboardOfferMessage(
            generation: 1,
            origin: .host,
            textByteCount: 0,
            enabled: true,
            hasText: false
        )
        guard case .acknowledgement = viewer.receiveOffer(remoteEnable) else {
            XCTFail("the remote opt-in must be acknowledged")
            return
        }

        XCTAssertEqual(
            viewer.localTextChanged(String(repeating: "x", count: 33)),
            .tooLarge
        )
        XCTAssertNil(viewer.status.pendingOutgoing)
    }

    func testClipboardSyncCancelsIncomingTextForOversizedAndNonTextLocalChanges() {
        let limits = ProtocolLimits(maxClipboardTextBytes: 4)
        var viewer = ClipboardSyncCoordinator(localRole: .viewer, limits: limits)
        _ = viewer.setEnabled(true)

        let firstOffer = ClipboardOfferMessage(
            generation: 1,
            origin: .host,
            textByteCount: 4,
            enabled: true
        )
        guard case let .acknowledgement(firstAcknowledgement) = viewer.receiveOffer(firstOffer) else {
            XCTFail("the first incoming offer must be acknowledged")
            return
        }
        XCTAssertTrue(firstAcknowledgement.accepted)
        XCTAssertNotNil(viewer.status.pendingIncoming)

        XCTAssertEqual(viewer.localTextChanged("12345"), .tooLarge)
        XCTAssertNil(viewer.status.pendingIncoming)
        XCTAssertEqual(
            viewer.receiveText(ClipboardTextMessage(generation: 1, text: Data("test".utf8))),
            .ignored
        )

        let secondOffer = ClipboardOfferMessage(
            generation: 2,
            origin: .host,
            textByteCount: 4,
            enabled: true
        )
        guard case .acknowledgement = viewer.receiveOffer(secondOffer) else {
            XCTFail("the second incoming offer must be acknowledged")
            return
        }
        XCTAssertNotNil(viewer.status.pendingIncoming)

        viewer.localPasteboardChangedWithoutText()
        XCTAssertNil(viewer.status.pendingIncoming)
        XCTAssertEqual(
            viewer.receiveText(ClipboardTextMessage(generation: 2, text: Data("next".utf8))),
            .ignored
        )
    }

    func testClipboardSyncSendsCancellationAfterAcceptedOfferIsLocallyDiscarded() {
        var host = ClipboardSyncCoordinator(localRole: .host)
        var viewer = ClipboardSyncCoordinator(localRole: .viewer)

        guard let hostEnable = host.setEnabled(true),
              let viewerEnable = viewer.setEnabled(true),
              case let .acknowledgement(hostEnableAck) = viewer.receiveOffer(hostEnable),
              case let .acknowledgement(viewerEnableAck) = host.receiveOffer(viewerEnable) else {
            XCTFail("both clipboard opt-ins must be acknowledged")
            return
        }
        XCTAssertEqual(host.receiveAcknowledgement(hostEnableAck), .statusUpdated)
        XCTAssertEqual(viewer.receiveAcknowledgement(viewerEnableAck), .statusUpdated)

        guard case let .offer(staleOffer) = viewer.localTextChanged("stale") else {
            XCTFail("the first local change must create an offer")
            return
        }
        guard case let .acknowledgement(staleAck) = host.receiveOffer(staleOffer) else {
            XCTFail("the peer must acknowledge the first offer")
            return
        }
        XCTAssertNotNil(host.status.pendingIncoming)

        // The sender has not processed the ACK yet. Its native pasteboard is
        // changed to a non-text value, so the accepted peer offer must be
        // explicitly superseded instead of leaving the peer blocked forever.
        viewer.localPasteboardChangedWithoutText()
        guard let cancellation = viewer.takePendingCancellation() else {
            XCTFail("discarding an outgoing text must create a cancellation offer")
            return
        }
        XCTAssertFalse(cancellation.hasText)
        XCTAssertEqual(viewer.receiveAcknowledgement(staleAck), .ignored)

        guard case let .acknowledgement(cancellationAck) = host.receiveOffer(cancellation) else {
            XCTFail("the peer must acknowledge the cancellation offer")
            return
        }
        XCTAssertTrue(cancellationAck.accepted)
        XCTAssertNil(host.status.pendingIncoming)
        XCTAssertEqual(viewer.receiveAcknowledgement(cancellationAck), .statusUpdated)

        XCTAssertEqual(
            host.receiveText(
                ClipboardTextMessage(
                    generation: staleOffer.generation,
                    text: Data("stale".utf8)
                )
            ),
            .ignored
        )
        guard case let .offer(freshOffer) = viewer.localTextChanged("fresh") else {
            XCTFail("a post-cancellation local change must create a fresh offer")
            return
        }
        guard case let .acknowledgement(freshAck) = host.receiveOffer(freshOffer) else {
            XCTFail("the fresh offer must not be rejected as a conflict")
            return
        }
        XCTAssertTrue(freshAck.accepted)
    }

    func testClipboardSyncResetClearsTransientStateAndDisablesSync() {
        var viewer = ClipboardSyncCoordinator(localRole: .viewer)
        _ = viewer.setEnabled(true)
        _ = viewer.receiveOffer(
            ClipboardOfferMessage(
                generation: 1,
                origin: .host,
                textByteCount: 3,
                enabled: true
            )
        )
        XCTAssertNotNil(viewer.status.pendingIncoming)

        viewer.reset()

        XCTAssertEqual(
            viewer.status,
            ClipboardSyncStatus(
                localEnabled: false,
                remoteEnabled: false,
                pendingOutgoing: nil,
                pendingIncoming: nil
            )
        )
        XCTAssertEqual(viewer.localTextChanged("after disconnect"), .disabled)
    }

    func testClipboardSyncRejectsStaleStatusOffers() {
        var viewer = ClipboardSyncCoordinator(localRole: .viewer)
        _ = viewer.setEnabled(true)

        let newest = viewer.receiveOffer(
            ClipboardOfferMessage(
                generation: 2,
                origin: .host,
                textByteCount: 0,
                enabled: true,
                hasText: false
            )
        )
        guard case let .acknowledgement(newestAcknowledgement) = newest else {
            XCTFail("new status offer must be acknowledged")
            return
        }
        XCTAssertTrue(newestAcknowledgement.accepted)
        XCTAssertTrue(viewer.status.remoteEnabled)

        let stale = viewer.receiveOffer(
            ClipboardOfferMessage(
                generation: 1,
                origin: .host,
                textByteCount: 0,
                enabled: false,
                hasText: false
            )
        )
        guard case let .acknowledgement(staleAcknowledgement) = stale else {
            XCTFail("stale status offer must be acknowledged")
            return
        }
        XCTAssertFalse(staleAcknowledgement.accepted)
        XCTAssertEqual(staleAcknowledgement.reason, .stale)
        XCTAssertTrue(viewer.status.remoteEnabled)
    }

    func testClipboardSyncClearsRemoteEnablementAfterDisableAcknowledgement() {
        var host = ClipboardSyncCoordinator(localRole: .host)
        var viewer = ClipboardSyncCoordinator(localRole: .viewer)
        _ = viewer.setEnabled(true)

        guard let enableOffer = host.setEnabled(true),
              case let .acknowledgement(enableAcknowledgement) = viewer.receiveOffer(enableOffer) else {
            XCTFail("enable offer must be acknowledged")
            return
        }
        XCTAssertEqual(host.receiveAcknowledgement(enableAcknowledgement), .statusUpdated)
        XCTAssertTrue(host.status.isEnabledForSession)

        guard case .offer = viewer.localTextChanged("stale") else {
            XCTFail("the first local change must create an offer")
            return
        }
        XCTAssertEqual(viewer.localTextChanged("newer"), .queued)

        guard let disableOffer = host.setEnabled(false),
              case let .acknowledgement(disableAcknowledgement) = viewer.receiveOffer(disableOffer) else {
            XCTFail("disable offer must be acknowledged")
            return
        }
        XCTAssertEqual(host.receiveAcknowledgement(disableAcknowledgement), .statusUpdated)
        XCTAssertFalse(host.status.remoteEnabled)
        XCTAssertFalse(host.status.isEnabledForSession)

        guard let reenableOffer = host.setEnabled(true),
              case let .acknowledgement(reenableAcknowledgement) = viewer.receiveOffer(reenableOffer) else {
            XCTFail("re-enable offer must be acknowledged")
            return
        }
        XCTAssertEqual(host.receiveAcknowledgement(reenableAcknowledgement), .statusUpdated)
        guard case let .offer(freshOffer) = viewer.localTextChanged("fresh") else {
            XCTFail("a fresh post-disable change must create an offer")
            return
        }
        guard case let .acknowledgement(freshAcknowledgement) = host.receiveOffer(freshOffer) else {
            XCTFail("the fresh offer must be acknowledged")
            return
        }
        guard case let .sendText(freshText) = viewer.receiveAcknowledgement(freshAcknowledgement) else {
            XCTFail("a disabled peer must not release stale queued text")
            return
        }
        XCTAssertEqual(String(data: freshText.text, encoding: .utf8), "fresh")
    }

    func testClipboardSyncDoesNotLetDelayedDisableAcknowledgementOverwriteNewerPeerOptIn() {
        var host = ClipboardSyncCoordinator(localRole: .host)
        _ = host.setEnabled(true)
        guard case .acknowledgement = host.receiveOffer(
            ClipboardOfferMessage(
                generation: 1,
                origin: .viewer,
                textByteCount: 0,
                enabled: true,
                hasText: false
            )
        ),
              let hostDisable = host.setEnabled(false) else {
            XCTFail("the host must have a pending disable status")
            return
        }
        guard case .acknowledgement = host.receiveOffer(
            ClipboardOfferMessage(
                generation: 2,
                origin: .viewer,
                textByteCount: 0,
                enabled: true,
                hasText: false
            )
        ) else {
            XCTFail("the newer peer opt-in must be acknowledged")
            return
        }

        XCTAssertEqual(
            host.receiveAcknowledgement(
                ClipboardAcknowledgementMessage(
                    generation: hostDisable.generation,
                    origin: .host,
                    accepted: true,
                    reason: .accepted
                )
            ),
            .statusUpdated
        )
        XCTAssertTrue(host.status.remoteEnabled)
    }

    func testSessionUXProjectionSeparatesReadyAndDegradedIndicators() throws {
        let identity = try PeerIdentity(publicKeyRepresentation: Data("m7-ux".utf8))
        let session = SessionSnapshot(
            state: .windowSelectionAuthorized,
            peerIdentity: identity,
            negotiatedCapabilities: [.textClipboard, .mouseInput],
            authorized: true,
            authorizedWindowGeneration: 9,
            authorizedCapabilities: [.textClipboard, .mouseInput],
            reconnectGeneration: 1,
            lastHeartbeatAt: nil
        )
        let clipboard = ClipboardSyncStatus(
            localEnabled: true,
            remoteEnabled: true,
            pendingOutgoing: nil,
            pendingIncoming: nil
        )

        let ready = SessionUXProjection.make(
            session: session,
            permission: .granted,
            streamReady: true,
            inputReady: true,
            clipboard: clipboard
        )
        XCTAssertEqual(ready.primary, .streaming)
        XCTAssertTrue(ready.indicators.contains(.authenticated))
        XCTAssertTrue(ready.indicators.contains(.paired))
        XCTAssertTrue(ready.indicators.contains(.authorized))
        XCTAssertTrue(ready.indicators.contains(.streaming))
        XCTAssertTrue(ready.indicators.contains(.inputReady))
        XCTAssertTrue(ready.indicators.contains(.clipboardEnabled))

        let degraded = SessionUXProjection.make(
            session: session,
            permission: .revoked,
            streamReady: true,
            inputReady: true,
            clipboard: clipboard
        )
        XCTAssertTrue(degraded.indicators.contains(.degraded))
        XCTAssertFalse(degraded.indicators.contains(.inputReady))
        XCTAssertFalse(degraded.indicators.contains(.clipboardEnabled))
    }

    func testSessionUXProjectionDoesNotAuthenticatePairingRequiredState() {
        let session = SessionSnapshot(
            state: .pairingRequired,
            peerIdentity: nil,
            negotiatedCapabilities: [],
            authorized: false,
            authorizedWindowGeneration: nil,
            authorizedCapabilities: [],
            reconnectGeneration: 0,
            lastHeartbeatAt: nil
        )
        let snapshot = SessionUXProjection.make(
            session: session,
            permission: .unknown,
            streamReady: false,
            inputReady: false,
            clipboard: ClipboardSyncStatus(
                localEnabled: false,
                remoteEnabled: false,
                pendingOutgoing: nil,
                pendingIncoming: nil
            )
        )

        XCTAssertEqual(snapshot.primary, .pairingRequired)
        XCTAssertFalse(snapshot.indicators.contains(.authenticated))
        XCTAssertFalse(snapshot.indicators.contains(.paired))
    }

    func testSessionCapabilityProjectionExposesPartialInputCapabilitiesAndMatchingWindow() throws {
        let identity = try PeerIdentity(publicKeyRepresentation: Data("m10-capabilities".utf8))
        let base = SessionSnapshot(
            state: .windowSelectionAuthorized,
            peerIdentity: identity,
            negotiatedCapabilities: [.mouseInput, .keyboardInput, .textClipboard],
            authorized: true,
            authorizedWindowGeneration: 4,
            authorizedCapabilities: [.mouseInput],
            reconnectGeneration: 0,
            lastHeartbeatAt: nil
        )

        XCTAssertTrue(
            SessionCapabilityProjection.inputReady(
                for: base,
                selectedWindowGeneration: 4,
                selectedStreamGeneration: 4
            )
        )
        XCTAssertEqual(
            SessionCapabilityProjection.inputAvailability(
                for: base,
                selectedWindowGeneration: 4,
                selectedStreamGeneration: 4
            ),
            SessionInputAvailability(mouseInputEnabled: true, keyboardInputEnabled: false)
        )
        XCTAssertFalse(
            SessionCapabilityProjection.inputReady(
                for: base,
                selectedWindowGeneration: 3,
                selectedStreamGeneration: 4
            )
        )
        XCTAssertEqual(
            SessionCapabilityProjection.inputAvailability(
                for: base,
                selectedWindowGeneration: 3,
                selectedStreamGeneration: 4
            ),
            .none
        )
        XCTAssertFalse(SessionCapabilityProjection.clipboardAvailable(for: base))

        let fullyAuthorized = SessionSnapshot(
            state: base.state,
            peerIdentity: base.peerIdentity,
            negotiatedCapabilities: base.negotiatedCapabilities,
            authorized: base.authorized,
            authorizedWindowGeneration: base.authorizedWindowGeneration,
            authorizedCapabilities: [.mouseInput, .keyboardInput, .textClipboard],
            reconnectGeneration: base.reconnectGeneration,
            lastHeartbeatAt: base.lastHeartbeatAt
        )
        XCTAssertTrue(
            SessionCapabilityProjection.inputReady(
                for: fullyAuthorized,
                selectedWindowGeneration: 4,
                selectedStreamGeneration: 4
            )
        )
        XCTAssertTrue(SessionCapabilityProjection.clipboardAvailable(for: fullyAuthorized))

        let unauthorized = SessionSnapshot(
            state: base.state,
            peerIdentity: base.peerIdentity,
            negotiatedCapabilities: base.negotiatedCapabilities,
            authorized: false,
            authorizedWindowGeneration: nil,
            authorizedCapabilities: fullyAuthorized.authorizedCapabilities,
            reconnectGeneration: base.reconnectGeneration,
            lastHeartbeatAt: base.lastHeartbeatAt
        )
        XCTAssertFalse(SessionCapabilityProjection.clipboardAvailable(for: unauthorized))
    }

    private func makeVideoEnvelope(sequence: UInt64, keyframe: Bool) throws -> Envelope {
        try Envelope(
            message: .videoFrame(
                VideoFrameMessage(
                    generation: 9,
                    captureTimestamp: sequence,
                    presentationTimestamp: sequence,
                    width: 1,
                    height: 1,
                    keyframe: keyframe,
                    accessUnit: Data([UInt8(sequence & 0xFF)])
                )
            ),
            flags: keyframe ? .keyframe : [],
            sequence: sequence,
            timestamp: sequence
        )
    }

    private func makeTrustedTransportPair(
        maxControlFrames: Int,
        maxMediaFrames: Int
    ) -> (first: InMemoryTransport, second: InMemoryTransport) {
        let firstIdentity = try! PeerIdentity(publicKeyRepresentation: Data("first-test".utf8))
        let secondIdentity = try! PeerIdentity(publicKeyRepresentation: Data("second-test".utf8))
        return InMemoryTransport.makePair(
            firstAuthentication: .trusted(secondIdentity),
            secondAuthentication: .trusted(firstIdentity),
            maxControlFrames: maxControlFrames,
            maxMediaFrames: maxMediaFrames
        )
    }
}

private final class BlockingRevocationTransport: SessionTransport, @unchecked Sendable {
    let incoming: EnvelopeStream

    private let base: InMemoryTransport
    private let revocationStarted = DispatchSemaphore(value: 0)
    private let releaseRevocationSignal = AsyncTestSignal()
    private let lock = NSLock()
    private var shouldFailNextRevocation = false

    init(base: InMemoryTransport) {
        self.base = base
        self.incoming = base.incoming
    }

    func armNextRevocationFailure() {
        lock.withLock {
            shouldFailNextRevocation = true
        }
    }

    func start() async throws {
        try await base.start()
    }

    func send(_ envelope: Envelope) async throws -> TransportSendResult {
        let shouldFail = lock.withLock {
            guard shouldFailNextRevocation,
                  envelope.messageType == .sessionAuthorize,
                  let message = try? envelope.decodedMessage(),
                  case let .sessionAuthorize(authorization) = message,
                  !authorization.authorized else {
                return false
            }
            shouldFailNextRevocation = false
            return true
        }
        if shouldFail {
            revocationStarted.signal()
            await releaseRevocationSignal.wait()
            throw TransportError.connectionFailed("injected authorization revoke failure")
        }
        return try await base.send(envelope)
    }

    func invalidateProtectedMessages() async {
        await base.invalidateProtectedMessages()
    }

    func close() async {
        await base.close()
    }

    func authentication() async -> PeerAuthenticationState {
        await base.authentication()
    }

    func snapshot() async -> TransportSnapshot {
        await base.snapshot()
    }

    func waitForRevocationStart(timeout: TimeInterval) -> DispatchTimeoutResult {
        revocationStarted.wait(timeout: .now() + timeout)
    }

    func releaseRevocation() async {
        await releaseRevocationSignal.signal()
    }
}

private final class HeartbeatFailureTransport: SessionTransport, @unchecked Sendable {
    let incoming: EnvelopeStream

    private let base: InMemoryTransport
    private let failureStarted = DispatchSemaphore(value: 0)
    private let releaseFailureSignal = AsyncTestSignal()
    private let lock = NSLock()
    private var shouldFailNextPing = true
    private var failureStartHandler: (@Sendable () -> Void)?

    init(base: InMemoryTransport) {
        self.base = base
        self.incoming = base.incoming
    }

    func setFailureStartHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            failureStartHandler = handler
        }
    }

    func start() async throws {
        try await base.start()
    }

    func send(_ envelope: Envelope) async throws -> TransportSendResult {
        let shouldFail = lock.withLock {
            guard shouldFailNextPing, envelope.messageType == .ping else { return false }
            shouldFailNextPing = false
            return true
        }
        if shouldFail {
            let handler = lock.withLock { failureStartHandler }
            handler?()
            failureStarted.signal()
            await releaseFailureSignal.wait()
            throw TransportError.connectionFailed("injected heartbeat failure")
        }
        return try await base.send(envelope)
    }

    func invalidateProtectedMessages() async {
        await base.invalidateProtectedMessages()
    }

    func close() async {
        await base.close()
    }

    func authentication() async -> PeerAuthenticationState {
        await base.authentication()
    }

    func snapshot() async -> TransportSnapshot {
        await base.snapshot()
    }

    func waitForFailureStart(timeout: TimeInterval) -> DispatchTimeoutResult {
        failureStarted.wait(timeout: .now() + timeout)
    }

    func releaseFailure() async {
        await releaseFailureSignal.signal()
    }
}

private final class BlockingInvalidationTransport: SessionTransport, @unchecked Sendable {
    let incoming: EnvelopeStream

    private let base: InMemoryTransport
    private let entered = DispatchSemaphore(value: 0)
    private let release = AsyncTestSignal()
    private let lock = NSLock()
    private var didBlock = false

    init(base: InMemoryTransport) {
        self.base = base
        self.incoming = base.incoming
    }

    func start() async throws {
        try await base.start()
    }

    func send(_ envelope: Envelope) async throws -> TransportSendResult {
        try await base.send(envelope)
    }

    func invalidateProtectedMessages() async {
        let shouldBlock = lock.withLock {
            guard !didBlock else { return false }
            didBlock = true
            return true
        }
        if shouldBlock {
            entered.signal()
            await release.wait()
        }
        await base.invalidateProtectedMessages()
    }

    func close() async {
        await base.close()
    }

    func authentication() async -> PeerAuthenticationState {
        await base.authentication()
    }

    func snapshot() async -> TransportSnapshot {
        await base.snapshot()
    }

    func waitForInvalidation(timeout: TimeInterval) -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + timeout)
    }

    func releaseInvalidation() async {
        await release.signal()
    }
}

private actor AsyncTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class MessageStreamRegistrationGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var didPause = false

    func pauseBeforeFirstRegistration() {
        let shouldPause: Bool
        lock.lock()
        shouldPause = !didPause
        didPause = true
        lock.unlock()
        guard shouldPause else { return }

        entered.signal()
        release.wait()
    }
}

/// Pairing-challenge expiry controlled by the test instead of wall-clock time.
/// A session arms it through the injected deadline sleep; `expire()` resumes
/// every armed sleeper, and cancelling the sleeping task throws exactly like
/// `Task.sleep`, so a superseded deadline still cannot tear down a session.
private actor ManualPairingDeadline {
    private var nextID: UInt64 = 0
    private var sleepers: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var requestedNanoseconds: [UInt64] = []

    func sleep(nanoseconds: UInt64) async throws {
        nextID &+= 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                arm(id: id, nanoseconds: nanoseconds, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func arm(
        id: UInt64,
        nanoseconds: UInt64,
        continuation: CheckedContinuation<Void, Error>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        sleepers[id] = continuation
        requestedNanoseconds.append(nanoseconds)
    }

    /// Waits a bounded time for a session to arm its pairing deadline.
    /// Expiry correctness remains manual; this timeout only fails the test
    /// instead of leaving a checked continuation suspended forever.
    func waitUntilArmed(timeoutNanoseconds: UInt64) async -> UInt64? {
        let deadline = Date().addingTimeInterval(
            Double(timeoutNanoseconds) / 1_000_000_000
        )
        while Date() < deadline {
            if let first = requestedNanoseconds.first {
                return first
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return requestedNanoseconds.first
    }

    func expire() {
        let pending = sleepers
        sleepers.removeAll()
        for continuation in pending.values {
            continuation.resume()
        }
    }

    private func cancel(_ id: UInt64) {
        sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

final class LatencyBudgetTests: XCTestCase {
    func testStageCollectorSkipsWarmupBoundsSamplesAndIgnoresNegativeIntervals() {
        var collector = BoundedStageLatencyCollector(warmupSampleCount: 2, maximumSamples: 3)
        collector.append(startNanoseconds: 0, endNanoseconds: 999)
        collector.append(startNanoseconds: 0, endNanoseconds: 999)
        collector.append(startNanoseconds: 10, endNanoseconds: 5)
        for interval: UInt64 in [10, 20, 30, 40] {
            collector.append(startNanoseconds: 100, endNanoseconds: 100 + interval)
        }
        XCTAssertEqual(collector.retainedSampleCount, 3)
        let summary = collector.summary()
        XCTAssertEqual(summary?.minimumNanoseconds, 10)
        XCTAssertEqual(summary?.maximumNanoseconds, 30)
        collector.reset()
        XCTAssertNil(collector.summary())
    }

    func testV1BudgetSumsToEndToEndTargetAndEvaluatesP95() throws {
        XCTAssertEqual(LatencyBudget.v1.endToEndNanoseconds, 50_000_000)
        let fast = try XCTUnwrap(PercentileSummary(samples: [5_000_000, 8_000_000]))
        let slow = try XCTUnwrap(PercentileSummary(samples: [5_000_000, 30_000_000]))
        let budget = LatencyBudget.v1.hostCaptureToSendNanoseconds
        XCTAssertEqual(LatencyBudget.isWithinBudget(fast, budget: budget), true)
        XCTAssertEqual(LatencyBudget.isWithinBudget(slow, budget: budget), false)
        XCTAssertNil(LatencyBudget.isWithinBudget(nil, budget: budget))
    }
}

final class ReceiverCongestionMonitorTests: XCTestCase {
    func testQueuingDelayIsMeasuredAboveTheMinimumOffset() {
        var monitor = ReceiverCongestionMonitor()
        // The Viewer clock is 1 s ahead of the Host clock. Frames first
        // arrive with 5 ms transit, then with 45 ms (40 ms of queuing).
        let offset: UInt64 = 1_000_000_000
        monitor.recordFrame(senderTimestamp: 0, receivedAt: offset + 5_000_000)
        monitor.recordFrame(senderTimestamp: 100_000_000, receivedAt: offset + 145_000_000)
        monitor.recordFrame(senderTimestamp: 200_000_000, receivedAt: offset + 245_000_000)
        XCTAssertNil(
            monitor.takeReport(generation: 3, at: offset + 300_000_000),
            "no report before the interval elapses"
        )
        monitor.recordDiscarded(2, at: offset + 400_000_000)
        let report = monitor.takeReport(generation: 3, at: offset + 600_000_000)
        XCTAssertEqual(report?.generation, 3)
        XCTAssertEqual(report?.receivedFrames, 3)
        XCTAssertEqual(report?.discardedFrames, 2)
        // (0 + 40 + 40) / 3 ms ≈ 26.666 ms.
        XCTAssertEqual(report?.queuingDelayMicroseconds, 26_666)
        XCTAssertNil(
            monitor.takeReport(generation: 3, at: offset + 1_200_000_000),
            "no report without new activity"
        )
    }

    func testNegativeClockOffsetIsHandled() {
        var monitor = ReceiverCongestionMonitor()
        // The Viewer clock is behind the Host clock.
        monitor.recordFrame(senderTimestamp: 10_000_000_000, receivedAt: 1_000_000)
        monitor.recordFrame(senderTimestamp: 10_100_000_000, receivedAt: 111_000_000)
        let report = monitor.takeReport(generation: 1, at: 700_000_000)
        XCTAssertEqual(report?.queuingDelayMicroseconds, 5_000, "(0 + 10 ms) / 2")
    }
}
