import Foundation
import RemoteProtocol
import SecurityCore
@testable import TransportCore
import XCTest

final class TransportCoreTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(TransportCoreModule.name, "TransportCore")
    }

    func testBoundedQueuesPrioritizeControlAndDropOnlyDiscardableMedia() async throws {
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
        let keyframe = try makeVideoEnvelope(sequence: 3, keyframe: true)
        let videoConfig = try Envelope(
            message: .videoConfig(
                VideoConfigMessage(generation: 9, decoderConfiguration: Data([0x01]))
            ),
            sequence: 4,
            timestamp: 4
        )

        let firstResult = try await queue.enqueue(mediaOne)
        let secondResult = try await queue.enqueue(mediaTwo)
        let droppedResult = try await queue.enqueue(mediaThree)
        let controlResult = try await queue.enqueue(control)
        XCTAssertEqual(firstResult, .queued)
        XCTAssertEqual(secondResult, .queued)
        XCTAssertEqual(droppedResult, .replacedOldestMedia)
        XCTAssertEqual(controlResult, .queued)

        do {
            _ = try await queue.enqueue(keyframe)
            XCTFail("keyframes must not be dropped when media capacity is full")
        } catch TransportError.mediaBackpressure {
            // Expected.
        }
        do {
            _ = try await queue.enqueue(videoConfig)
            XCTFail("video configuration must not be dropped when media capacity is full")
        } catch TransportError.mediaBackpressure {
            // Expected.
        }

        let firstDequeued = await queue.dequeue()
        let secondDequeued = await queue.dequeue()
        let thirdDequeued = await queue.dequeue()
        let emptyDequeued = await queue.dequeue()
        XCTAssertEqual(firstDequeued, control)
        XCTAssertEqual(secondDequeued, mediaTwo)
        XCTAssertEqual(thirdDequeued, mediaThree)
        XCTAssertNil(emptyDequeued)
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
        XCTAssertEqual(try output.storage.yield(configuration), .replacedMedia)
        XCTAssertEqual(try output.storage.yield(keyframe), .replacedMedia)

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
        XCTAssertEqual(deliveredSequences, [1, 2])
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
            configuration: SessionConfiguration(role: .host, implementationIdentifier: "pairing-host", capabilities: capabilities),
            transport: pair.first,
            pairingCoordinator: hostPairing
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(role: .viewer, implementationIdentifier: "pairing-viewer", capabilities: capabilities),
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
            if viewerChallenge != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let challenge = try XCTUnwrap(viewerChallenge)
        var hostChallenge: PairingChallenge?
        for _ in 0 ..< 100 {
            hostChallenge = await hostPairing.pendingChallenge()
            if hostChallenge != nil { break }
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
