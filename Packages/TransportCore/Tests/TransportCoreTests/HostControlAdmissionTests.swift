import Foundation
import RemoteProtocol
import SecurityCore
@testable import TransportCore
import XCTest

final class HostControlAdmissionTests: XCTestCase {
    func testPauseResumeDropsOldInputAndSourceEpochWhileVideoAuthorizationRemainsLive() async throws {
        let sessions = try await makeSessions()
        defer {
            Task {
                await sessions.host.stop()
                await sessions.viewer.stop()
            }
        }

        await sessions.host.setLocalInputAdmission(true, revision: 1)
        let authorizedCapabilities: Set<Capability> = [
            .mouseInput,
            .keyboardInput,
            .inputSourceSync,
            .backgroundControl,
            .h264Video
        ]
        try await sessions.host.authorize(windowGeneration: 7, capabilities: authorizedCapabilities)
        let viewerSnapshot = try await waitForSnapshot(of: sessions.viewer) { $0.authorized }
        let hostSnapshot = await sessions.host.snapshot()
        XCTAssertEqual(hostSnapshot.authorizedCapabilities, authorizedCapabilities)

        // Simulate an event buffered before Host decode: it arrives after the
        // Host has paused and resumed, carrying the old local-control epoch.
        await sessions.host.setLocalInputAdmission(false, revision: 2)
        await sessions.host.setLocalInputAdmission(true, revision: 3)
        try await sessions.viewer.send(
            .inputEvent(
                InputEventMessage(
                    kind: .pointerMove,
                    windowGeneration: 7,
                    x: 100,
                    y: 200,
                    controlGeneration: 1
                )
            ),
            expectedAuthorizationGeneration: viewerSnapshot.authorizationGeneration
        )
        try await sessions.viewer.send(
            .inputSourceSelection(
                InputSourceSelectionMessage(
                    windowGeneration: 7,
                    requestID: 1,
                    kind: .english,
                    sourceIdentifier: "com.apple.keylayout.US",
                    controlGeneration: 1
                )
            ),
            expectedAuthorizationGeneration: viewerSnapshot.authorizationGeneration
        )

        // A paused P6 gate is local to input. Authorized media still travels.
        await sessions.host.setLocalInputAdmission(false, revision: 4)
        let frameTask = Task {
            try await Self.withTimeout(.seconds(3)) {
                var iterator = sessions.viewer.incomingMessages.makeAsyncIterator()
                while let message = try await iterator.next() {
                    if case let .videoFrame(frame) = message { return frame }
                }
                throw HostControlAdmissionTestError.streamEnded
            }
        }
        try await sessions.host.send(
            .videoFrame(
                VideoFrameMessage(
                    generation: 7,
                    captureTimestamp: 100,
                    presentationTimestamp: 101,
                    width: 16,
                    height: 16,
                    keyframe: true,
                    accessUnit: Data([0x00, 0x00, 0x00, 0x01, 0x65])
                )
            ),
            expectedAuthorizationGeneration: hostSnapshot.authorizationGeneration
        )
        let frame = try await frameTask.value
        XCTAssertEqual(frame.generation, 7)

        // Resume with a new epoch. The old-generation input above must not be
        // in the app stream; a fresh token is admitted without reconnecting.
        await sessions.host.setLocalInputAdmission(true, revision: 5)
        let inputTask = Task {
            try await Self.withTimeout(.seconds(3)) {
                var iterator = sessions.host.incomingMessages.makeAsyncIterator()
                while let message = try await iterator.next() {
                    if case let .inputEvent(input) = message { return input }
                }
                throw HostControlAdmissionTestError.streamEnded
            }
        }
        try await sessions.viewer.send(
            .inputEvent(
                InputEventMessage(
                    kind: .pointerMove,
                    windowGeneration: 7,
                    x: 300,
                    y: 400,
                    controlGeneration: 5
                )
            ),
            expectedAuthorizationGeneration: viewerSnapshot.authorizationGeneration
        )
        let freshInput = try await inputTask.value
        XCTAssertEqual(freshInput.controlGeneration, 5)
        let finalHostSnapshot = await sessions.host.snapshot()
        let finalViewerSnapshot = await sessions.viewer.snapshot()
        XCTAssertEqual(finalHostSnapshot.state, .windowSelectionAuthorized)
        XCTAssertEqual(finalViewerSnapshot.authorizedCapabilities, authorizedCapabilities)
    }

    private func makeSessions() async throws -> (host: SessionCoordinator, viewer: SessionCoordinator) {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("p6-admission-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("p6-admission-viewer".utf8))
        let transports = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        let capabilities: Set<Capability> = [
            .pingPong,
            .mouseInput,
            .keyboardInput,
            .inputSourceSync,
            .backgroundControl,
            .h264Video
        ]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "p6-admission-host",
                capabilities: capabilities
            ),
            transport: transports.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "p6-admission-viewer",
                capabilities: capabilities
            ),
            transport: transports.second
        )
        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        _ = try await waitForSnapshot(of: host) { $0.state == .capabilitiesNegotiated }
        _ = try await waitForSnapshot(of: viewer) { $0.state == .capabilitiesNegotiated }
        return (host, viewer)
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
            guard clock.now < deadline else { throw HostControlAdmissionTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func withTimeout<Value: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw HostControlAdmissionTestError.timedOut
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

private enum HostControlAdmissionTestError: Error {
    case timedOut
    case streamEnded
}
