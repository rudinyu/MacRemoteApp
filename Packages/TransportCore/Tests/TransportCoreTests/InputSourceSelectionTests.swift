import Foundation
import RemoteProtocol
import SecurityCore
@testable import TransportCore
import XCTest

final class InputSourceSelectionTests: XCTestCase {
    func testSourceMessagesAreTombstonedOrPurgedByEveryProtectedQueue() async throws {
        let messages = sourceMessages()
        let envelopes = try messages.enumerated().map { index, message in
            try Envelope(message: message, sequence: UInt64(index + 1), timestamp: UInt64(index + 10))
        }

        let boundedQueue = try BoundedFrameQueue(maxControlFrames: 4, maxMediaFrames: 1)
        for envelope in envelopes { _ = try await boundedQueue.enqueue(envelope) }
        await boundedQueue.removeProtectedMessages()
        for index in 0 ..< 2 {
            let dequeuedEnvelope = await boundedQueue.dequeue()
            let tombstone = try XCTUnwrap(dequeuedEnvelope)
            XCTAssertEqual(tombstone.messageType, .unknown(0x7FFE))
            XCTAssertEqual(tombstone.sequence, envelopes[index].sequence)
            XCTAssertThrowsError(try tombstone.decodedMessage())
        }
        let remainingEnvelope = await boundedQueue.dequeue()
        XCTAssertEqual(remainingEnvelope, envelopes[2])

        let envelopeStream = try EnvelopeStream.makeBounded(maxControlFrames: 4, maxMediaFrames: 1)
        for envelope in envelopes { _ = try envelopeStream.storage.yield(envelope) }
        envelopeStream.storage.removeProtectedMessages()
        for index in 0 ..< 2 {
            let dequeuedEnvelope = try await envelopeStream.storage.next()
            let tombstone = try XCTUnwrap(dequeuedEnvelope)
            XCTAssertEqual(tombstone.messageType, .unknown(0x7FFE))
            XCTAssertEqual(tombstone.sequence, envelopes[index].sequence)
            XCTAssertThrowsError(try tombstone.decodedMessage())
        }
        let remainingStreamEnvelope = try await envelopeStream.storage.next()
        XCTAssertEqual(remainingStreamEnvelope, envelopes[2])

        let protectedMessages = try MessageStream.makeBounded(maxControlMessages: 4, maxMediaMessages: 1)
        for message in messages { _ = try protectedMessages.storage.yield(message) }
        protectedMessages.storage.removeProtectedMessages()
        XCTAssertEqual(protectedMessages.storage.counts().control, 1)
        let remainingProtectedMessage = try await protectedMessages.storage.next()
        XCTAssertEqual(remainingProtectedMessage, messages[2])

        let pendingInputs = try MessageStream.makeBounded(maxControlMessages: 5, maxMediaMessages: 1)
        for message in messages.dropLast() { _ = try pendingInputs.storage.yield(message) }
        _ = try pendingInputs.storage.yield(
            .inputEvent(InputEventMessage(kind: .keyDown, windowGeneration: 7, keyCode: 12, modifiers: 0))
        )
        _ = try pendingInputs.storage.yield(messages[2])
        pendingInputs.storage.removePendingInputMessages()
        XCTAssertEqual(pendingInputs.storage.counts().control, 1)
        let remainingPendingMessage = try await pendingInputs.storage.next()
        XCTAssertEqual(remainingPendingMessage, messages[2])
    }

    func testIncomingSelectionAdmissionRejectsDequeuedOldEpochAndFencesAcknowledgement() async throws {
        let sessions = try await makeSessions(
            hostCapabilities: [.pingPong, .keyboardInput, .inputSourceSync],
            viewerCapabilities: [.pingPong, .keyboardInput, .inputSourceSync]
        )
        do {
            let windowGeneration: UInt64 = 17
            try await sessions.host.authorize(
                windowGeneration: windowGeneration,
                capabilities: [.keyboardInput, .inputSourceSync]
            )
            let firstViewerSnapshot = try await waitForSnapshot(of: sessions.viewer) {
                $0.authorized && $0.authorizedWindowGeneration == windowGeneration
            }

            let oldSelection = sourceSelection(windowGeneration: windowGeneration, requestID: 1)
            let hostMessageStream = sessions.host.incomingMessages
            let receivedTask = Task {
                try await awaitInputSourceSelection(on: hostMessageStream, timeout: .seconds(3))
            }
            try await sessions.viewer.send(
                .inputSourceSelection(oldSelection),
                expectedAuthorizationGeneration: firstViewerSnapshot.authorizationGeneration
            )
            let dequeuedSelection = try await receivedTask.value
            XCTAssertTrue(dequeuedSelection == oldSelection)

            try await sessions.host.authorize(
                windowGeneration: windowGeneration,
                capabilities: [.keyboardInput, .inputSourceSync]
            )
            let secondViewerSnapshot = try await waitForSnapshot(of: sessions.viewer) {
                $0.authorizationGeneration > firstViewerSnapshot.authorizationGeneration &&
                    $0.authorized && $0.authorizedWindowGeneration == windowGeneration
            }

            let calls = AdmissionCallRecorder()
            do {
                _ = try await sessions.host.withIncomingInputSourceSelectionAdmission(for: dequeuedSelection) {
                    calls.record(dequeuedSelection.requestID)
                    return InputSourceSelectionStatus.applied
                }
                XCTFail("a selection delivered under the old authorization epoch must not run")
            } catch let error as SessionError {
                XCTAssertEqual(error, .authorizationChanged)
            }
            XCTAssertTrue(calls.requestIDs().isEmpty)

            let freshSelection = sourceSelection(windowGeneration: windowGeneration, requestID: 2)
            let fresh = try await receiveAndAdmit(
                freshSelection,
                viewer: sessions.viewer,
                host: sessions.host,
                expectedAuthorizationGeneration: secondViewerSnapshot.authorizationGeneration,
                calls: calls
            )
            XCTAssertEqual(fresh.value, .applied)
            XCTAssertEqual(fresh.requestID, freshSelection.requestID)
            let hostSnapshotAfterAdmission = await sessions.host.snapshot()
            XCTAssertEqual(fresh.authorizationGeneration, hostSnapshotAfterAdmission.authorizationGeneration)

            let acknowledgement = InputSourceAcknowledgementMessage(
                windowGeneration: fresh.windowGeneration,
                requestID: fresh.requestID,
                status: fresh.value
            )
            try await sessions.host.send(
                .inputSourceAcknowledgement(acknowledgement),
                expectedAuthorizationGeneration: fresh.authorizationGeneration
            )
            let receivedAcknowledgement = try await nextSourceAcknowledgement(
                from: sessions.viewer.incomingMessages,
                timeout: .seconds(3)
            )
            XCTAssertTrue(receivedAcknowledgement == acknowledgement)

            let duplicate = sourceSelection(windowGeneration: windowGeneration, requestID: 2)
            _ = try await sendAndReceiveSelection(
                duplicate,
                viewer: sessions.viewer,
                host: sessions.host,
                expectedAuthorizationGeneration: secondViewerSnapshot.authorizationGeneration
            )
            do {
                _ = try await sessions.host.withIncomingInputSourceSelectionAdmission(for: duplicate) {
                    calls.record(duplicate.requestID)
                    return InputSourceSelectionStatus.applied
                }
                XCTFail("a duplicate request ID must not run")
            } catch let error as SessionError {
                XCTAssertEqual(error, .replayDetected)
            }
            XCTAssertEqual(calls.requestIDs(), [2])

            try await sessions.host.authorize(
                windowGeneration: windowGeneration,
                capabilities: [.keyboardInput, .inputSourceSync]
            )
            let thirdViewerSnapshot = try await waitForSnapshot(of: sessions.viewer) {
                $0.authorizationGeneration > secondViewerSnapshot.authorizationGeneration &&
                    $0.authorized && $0.authorizedWindowGeneration == windowGeneration
            }
            _ = try await sendAndReceiveSelection(
                duplicate,
                viewer: sessions.viewer,
                host: sessions.host,
                expectedAuthorizationGeneration: thirdViewerSnapshot.authorizationGeneration
            )
            do {
                _ = try await sessions.host.withIncomingInputSourceSelectionAdmission(for: duplicate) {
                    calls.record(duplicate.requestID)
                    return InputSourceSelectionStatus.applied
                }
                XCTFail("same-session reauthorization must not reset the request-ID fence")
            } catch let error as SessionError {
                XCTAssertEqual(error, .replayDetected)
            }
            XCTAssertEqual(calls.requestIDs(), [2])

            do {
                try await sessions.host.send(
                    .inputSourceAcknowledgement(acknowledgement),
                    expectedAuthorizationGeneration: fresh.authorizationGeneration
                )
                XCTFail("an acknowledgement from the previous epoch must not enter the new epoch")
            } catch let error as SessionError {
                XCTAssertEqual(error, .authorizationChanged)
            }

            let nextEpochSelection = sourceSelection(windowGeneration: windowGeneration, requestID: 3)
            let nextEpochAdmission = try await receiveAndAdmit(
                nextEpochSelection,
                viewer: sessions.viewer,
                host: sessions.host,
                expectedAuthorizationGeneration: thirdViewerSnapshot.authorizationGeneration,
                calls: calls
            )
            XCTAssertEqual(nextEpochAdmission.authorizationGeneration, thirdViewerSnapshot.authorizationGeneration)

            try await sessions.host.authorize(
                windowGeneration: windowGeneration + 1,
                capabilities: [.keyboardInput, .inputSourceSync]
            )
            let fourthViewerSnapshot = try await waitForSnapshot(of: sessions.viewer) {
                $0.authorizationGeneration > thirdViewerSnapshot.authorizationGeneration &&
                    $0.authorizedWindowGeneration == windowGeneration + 1
            }
            let replacementSelection = sourceSelection(windowGeneration: windowGeneration + 1, requestID: 4)
            let replacementAdmission = try await receiveAndAdmit(
                replacementSelection,
                viewer: sessions.viewer,
                host: sessions.host,
                expectedAuthorizationGeneration: fourthViewerSnapshot.authorizationGeneration,
                calls: calls
            )
            XCTAssertEqual(replacementAdmission.windowGeneration, windowGeneration + 1)
            XCTAssertEqual(calls.requestIDs(), [2, 3, 4])
        } catch {
            await sessions.host.stop()
            await sessions.viewer.stop()
            throw error
        }
        await sessions.host.stop()
        await sessions.viewer.stop()
    }

    func testViewerComposedTextRequiresTextInputCapability() async throws {
        let text = InputEventMessage(kind: .text, windowGeneration: 31, text: "你好")

        let older = try await makeSessions(
            hostCapabilities: [.pingPong, .keyboardInput],
            viewerCapabilities: [.pingPong, .keyboardInput, .textInput]
        )
        do {
            try await older.host.authorize(windowGeneration: 31, capabilities: [.keyboardInput])
            let snapshot = try await waitForSnapshot(of: older.viewer) {
                $0.authorized && $0.authorizedWindowGeneration == 31
            }
            XCTAssertFalse(snapshot.negotiatedCapabilities.contains(.textInput))
            do {
                _ = try await older.viewer.makeInputAdmission(
                    for: text,
                    expectedAuthorizationGeneration: snapshot.authorizationGeneration
                )
                XCTFail("text must not be sent to a Host without the textInput capability")
            } catch {
                // Expected: not negotiated.
            }
        } catch {
            await older.host.stop()
            await older.viewer.stop()
            throw error
        }
        await older.host.stop()
        await older.viewer.stop()

        let current = try await makeSessions(
            hostCapabilities: [.pingPong, .keyboardInput, .textInput],
            viewerCapabilities: [.pingPong, .keyboardInput, .textInput]
        )
        do {
            try await current.host.authorize(windowGeneration: 31, capabilities: [.keyboardInput, .textInput])
            let snapshot = try await waitForSnapshot(of: current.viewer) {
                $0.authorized && $0.authorizedWindowGeneration == 31
            }
            let admission = try await current.viewer.makeInputAdmission(
                for: text,
                expectedAuthorizationGeneration: snapshot.authorizationGeneration
            )
            try await current.viewer.sendInput(text, using: admission)
            let received = try await nextInputEvent(from: current.host.incomingMessages, timeout: .seconds(3))
            XCTAssertEqual(received.kind, .text)
            XCTAssertEqual(received.text, "你好")
        } catch {
            await current.host.stop()
            await current.viewer.stop()
            throw error
        }
        await current.host.stop()
        await current.viewer.stop()
    }

    func testInputSourceSyncCapabilityIsOptionalForOlderPeers() async throws {
        let sessions = try await makeSessions(
            hostCapabilities: [.pingPong, .keyboardInput],
            viewerCapabilities: [.pingPong, .keyboardInput, .inputSourceSync]
        )
        do {
            try await sessions.host.authorize(windowGeneration: 21, capabilities: [.keyboardInput])
            let viewerSnapshot = try await waitForSnapshot(of: sessions.viewer) {
                $0.authorized && $0.authorizedWindowGeneration == 21
            }
            XCTAssertFalse(viewerSnapshot.negotiatedCapabilities.contains(.inputSourceSync))

            do {
                try await sessions.viewer.send(
                    .inputSourceSelection(sourceSelection(windowGeneration: 21, requestID: 1)),
                    expectedAuthorizationGeneration: viewerSnapshot.authorizationGeneration
                )
                XCTFail("source synchronization must remain disabled when the peer lacks the capability")
            } catch let error as SessionError {
                XCTAssertEqual(error, .unauthorizedMessage(.inputSourceSelection))
            }

            let keyboard = InputEventMessage(
                kind: .keyDown,
                windowGeneration: 21,
                keyCode: 12,
                modifiers: 0
            )
            let admission = try await sessions.viewer.makeInputAdmission(
                for: keyboard,
                expectedAuthorizationGeneration: viewerSnapshot.authorizationGeneration
            )
            try await sessions.viewer.sendInput(keyboard, using: admission)
            let receivedKeyboard = try await nextInputEvent(
                from: sessions.host.incomingMessages,
                timeout: .seconds(3)
            )
            XCTAssertTrue(receivedKeyboard == keyboard)

            do {
                try await sessions.host.send(
                    .inputSourceSelection(sourceSelection(windowGeneration: 21, requestID: 2))
                )
                XCTFail("a Host must not send Viewer-to-Host source selections")
            } catch let error as SessionError {
                XCTAssertEqual(error, .unauthorizedMessage(.inputSourceSelection))
            }
        } catch {
            await sessions.host.stop()
            await sessions.viewer.stop()
            throw error
        }
        await sessions.host.stop()
        await sessions.viewer.stop()
    }

    func testDiscardPendingInputMessagesInvalidatesDirectlyDeliveredSelectionLease() async throws {
        let sessions = try await makeSessions(
            hostCapabilities: [.pingPong, .keyboardInput, .inputSourceSync],
            viewerCapabilities: [.pingPong, .keyboardInput, .inputSourceSync]
        )
        do {
            let windowGeneration: UInt64 = 29
            try await sessions.host.authorize(
                windowGeneration: windowGeneration,
                capabilities: [.keyboardInput, .inputSourceSync]
            )
            let viewerSnapshot = try await waitForSnapshot(of: sessions.viewer) {
                $0.authorized && $0.authorizedWindowGeneration == windowGeneration
            }

            let staleSelection = sourceSelection(windowGeneration: windowGeneration, requestID: 1)
            let hostMessageStream = sessions.host.incomingMessages
            let receivedTask = Task {
                try await awaitInputSourceSelection(on: hostMessageStream, timeout: .seconds(3))
            }
            try await waitForWaitingConsumer(on: sessions.host.incomingMessages)
            try await sessions.viewer.send(
                .inputSourceSelection(staleSelection),
                expectedAuthorizationGeneration: viewerSnapshot.authorizationGeneration
            )
            let dequeuedSelection = try await receivedTask.value
            XCTAssertEqual(dequeuedSelection, staleSelection)

            await sessions.host.discardPendingInputMessages()
            let calls = AdmissionCallRecorder()
            do {
                _ = try await sessions.host.withIncomingInputSourceSelectionAdmission(for: dequeuedSelection) {
                    calls.record(dequeuedSelection.requestID)
                    return InputSourceSelectionStatus.applied
                }
                XCTFail("a directly delivered selection invalidated by discard must not run")
            } catch let error as SessionError {
                XCTAssertEqual(error, .authorizationChanged)
            }
            XCTAssertTrue(calls.requestIDs().isEmpty)

            let currentSelection = sourceSelection(windowGeneration: windowGeneration, requestID: 2)
            let currentAdmission = try await receiveAndAdmit(
                currentSelection,
                viewer: sessions.viewer,
                host: sessions.host,
                expectedAuthorizationGeneration: viewerSnapshot.authorizationGeneration,
                calls: calls
            )
            XCTAssertEqual(currentAdmission.requestID, 2)

            let replay = sourceSelection(windowGeneration: windowGeneration, requestID: 1)
            _ = try await sendAndReceiveSelection(
                replay,
                viewer: sessions.viewer,
                host: sessions.host,
                expectedAuthorizationGeneration: viewerSnapshot.authorizationGeneration
            )
            do {
                _ = try await sessions.host.withIncomingInputSourceSelectionAdmission(for: replay) {
                    calls.record(replay.requestID)
                    return InputSourceSelectionStatus.applied
                }
                XCTFail("discarding a pending selection must not reset the session request-ID fence")
            } catch let error as SessionError {
                XCTAssertEqual(error, .replayDetected)
            }
            XCTAssertEqual(calls.requestIDs(), [2])
        } catch {
            await sessions.host.stop()
            await sessions.viewer.stop()
            throw error
        }
        await sessions.host.stop()
        await sessions.viewer.stop()
    }

    private func sourceMessages() -> [MessagePayload] {
        [
            .inputSourceSelection(sourceSelection(windowGeneration: 7, requestID: 1)),
            .inputSourceAcknowledgement(
                InputSourceAcknowledgementMessage(windowGeneration: 7, requestID: 1, status: .applied)
            ),
            .ping(PingMessage(nonce: 31))
        ]
    }

    private func sourceSelection(windowGeneration: UInt64, requestID: UInt64) -> InputSourceSelectionMessage {
        InputSourceSelectionMessage(
            windowGeneration: windowGeneration,
            requestID: requestID,
            kind: .chinese,
            sourceIdentifier: "source-id"
        )
    }

    private func receiveAndAdmit(
        _ selection: InputSourceSelectionMessage,
        viewer: SessionCoordinator,
        host: SessionCoordinator,
        expectedAuthorizationGeneration: UInt64,
        calls: AdmissionCallRecorder
    ) async throws -> InputSourceSelectionAdmissionResult<InputSourceSelectionStatus> {
        _ = try await sendAndReceiveSelection(
            selection,
            viewer: viewer,
            host: host,
            expectedAuthorizationGeneration: expectedAuthorizationGeneration
        )
        return try await host.withIncomingInputSourceSelectionAdmission(for: selection) {
            calls.record(selection.requestID)
            return .applied
        }
    }

    private func sendAndReceiveSelection(
        _ selection: InputSourceSelectionMessage,
        viewer: SessionCoordinator,
        host: SessionCoordinator,
        expectedAuthorizationGeneration: UInt64
    ) async throws -> InputSourceSelectionMessage {
        try await viewer.send(
            .inputSourceSelection(selection),
            expectedAuthorizationGeneration: expectedAuthorizationGeneration
        )
        return try await nextSourceSelection(from: host.incomingMessages, timeout: .seconds(3))
    }

    private func makeSessions(
        hostCapabilities: Set<Capability>,
        viewerCapabilities: Set<Capability>
    ) async throws -> (host: SessionCoordinator, viewer: SessionCoordinator) {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("input-source-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("input-source-viewer".utf8))
        let transports = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "input-source-host",
                capabilities: hostCapabilities
            ),
            transport: transports.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "input-source-viewer",
                capabilities: viewerCapabilities
            ),
            transport: transports.second
        )

        do {
            async let startHost: Void = host.start()
            async let startViewer: Void = viewer.start()
            try await startHost
            try await startViewer
            _ = try await waitForSnapshot(of: host) { $0.state == .capabilitiesNegotiated }
            _ = try await waitForSnapshot(of: viewer) { $0.state == .capabilitiesNegotiated }
            return (host, viewer)
        } catch {
            await host.stop()
            await viewer.stop()
            throw error
        }
    }

    private func waitForSnapshot(
        of session: SessionCoordinator,
        timeout: Duration = .seconds(5),
        satisfying predicate: (SessionSnapshot) -> Bool
    ) async throws -> SessionSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let snapshot = await session.snapshot()
            if predicate(snapshot) { return snapshot }
            guard clock.now < deadline else { throw InputSourceSelectionTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForWaitingConsumer(
        on stream: MessageStream,
        timeout: Duration = .seconds(3)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !stream.storage.hasWaitingConsumer() {
            guard clock.now < deadline else { throw InputSourceSelectionTestError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func nextSourceSelection(
        from stream: MessageStream,
        timeout: Duration
    ) async throws -> InputSourceSelectionMessage {
        try await nextMessage(from: stream, timeout: timeout) {
            guard case let .inputSourceSelection(selection) = $0 else { return nil }
            return selection
        }
    }

    private func nextSourceAcknowledgement(
        from stream: MessageStream,
        timeout: Duration
    ) async throws -> InputSourceAcknowledgementMessage {
        try await nextMessage(from: stream, timeout: timeout) {
            guard case let .inputSourceAcknowledgement(acknowledgement) = $0 else { return nil }
            return acknowledgement
        }
    }

    private func nextInputEvent(
        from stream: MessageStream,
        timeout: Duration
    ) async throws -> InputEventMessage {
        try await nextMessage(from: stream, timeout: timeout) {
            guard case let .inputEvent(input) = $0 else { return nil }
            return input
        }
    }

    private func nextMessage<Value: Sendable>(
        from stream: MessageStream,
        timeout: Duration,
        matching extract: @escaping @Sendable (MessagePayload) -> Value?
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                while let message = try await iterator.next() {
                    if let value = extract(message) { return value }
                }
                throw InputSourceSelectionTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw InputSourceSelectionTestError.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw InputSourceSelectionTestError.streamEnded
            }
            return value
        }
    }
}

private final class AdmissionCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []

    func record(_ requestID: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(requestID)
    }

    func requestIDs() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private enum InputSourceSelectionTestError: Error {
    case timedOut
    case streamEnded
}

private func awaitInputSourceSelection(
    on stream: MessageStream,
    timeout: Duration
) async throws -> InputSourceSelectionMessage {
    try await withThrowingTaskGroup(of: InputSourceSelectionMessage.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            while let message = try await iterator.next() {
                if case let .inputSourceSelection(selection) = message {
                    return selection
                }
            }
            throw InputSourceSelectionTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw InputSourceSelectionTestError.timedOut
        }
        defer { group.cancelAll() }
        guard let selection = try await group.next() else {
            throw InputSourceSelectionTestError.streamEnded
        }
        return selection
    }
}
