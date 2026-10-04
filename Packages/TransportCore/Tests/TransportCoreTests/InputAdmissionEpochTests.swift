import Foundation
import RemoteProtocol
import SecurityCore
@testable import TransportCore
import XCTest

final class InputAdmissionEpochTests: XCTestCase {
    func testMakeInputAdmissionRejectsStaleExpectedEpochForSameWindow() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("epoch-guard-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("epoch-guard-viewer".utf8))
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
                implementationIdentifier: "epoch-guard-host",
                capabilities: capabilities
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "epoch-guard-viewer",
                capabilities: capabilities
            ),
            transport: pair.second
        )

        do {
            async let hostStart: Void = host.start()
            async let viewerStart: Void = viewer.start()
            try await hostStart
            try await viewerStart

            _ = try await waitForSnapshot(of: host) { $0.state == .capabilitiesNegotiated }
            _ = try await waitForSnapshot(of: viewer) { $0.state == .capabilitiesNegotiated }

            let windowGeneration: UInt64 = 23
            try await host.authorize(windowGeneration: windowGeneration, capabilities: [.mouseInput])
            let firstAuthorization = try await waitForSnapshot(of: viewer) {
                $0.authorized && $0.authorizedWindowGeneration == windowGeneration
            }

            let staleInput = InputEventMessage(
                kind: .pointerMove,
                windowGeneration: windowGeneration,
                x: 12,
                y: 34
            )
            let freshInput = InputEventMessage(
                kind: .pointerMove,
                windowGeneration: windowGeneration,
                x: 56,
                y: 78
            )

            // Reauthorize the same window to advance the authorization epoch
            // without changing the window-generation fence.
            try await host.authorize(windowGeneration: windowGeneration, capabilities: [.mouseInput])
            let currentAuthorization = try await waitForSnapshot(of: viewer) {
                $0.authorizationGeneration > firstAuthorization.authorizationGeneration &&
                    $0.authorized &&
                    $0.authorizedWindowGeneration == windowGeneration
            }

            var staleAdmission: SessionInputAdmissionToken?
            do {
                staleAdmission = try await viewer.makeInputAdmission(
                    for: staleInput,
                    expectedAuthorizationGeneration: firstAuthorization.authorizationGeneration
                )
            } catch SessionError.authorizationChanged {
                // Expected: a matching window generation cannot revive a
                // record queued in an earlier authorization epoch.
            }
            XCTAssertNil(staleAdmission, "a stale queued event must not receive a current-epoch token")

            // If the guard regresses, exercise the dangerous path too: that
            // token would let the stale event pass the final session fence.
            if let staleAdmission {
                try await viewer.sendInput(staleInput, using: staleAdmission)
            }

            let freshAdmission = try await viewer.makeInputAdmission(
                for: freshInput,
                expectedAuthorizationGeneration: currentAuthorization.authorizationGeneration
            )
            try await viewer.sendInput(freshInput, using: freshAdmission)

            let deliveredInput = try await nextInputEvent(
                from: host.incomingMessages,
                timeout: .seconds(3)
            )
            XCTAssertEqual(
                deliveredInput,
                freshInput,
                "the fresh event must arrive unchanged and no stale event may precede it"
            )
        } catch {
            await host.stop()
            await viewer.stop()
            throw error
        }

        await host.stop()
        await viewer.stop()
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
            guard clock.now < deadline else { throw InputAdmissionEpochTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func nextInputEvent(
        from stream: MessageStream,
        timeout: Duration
    ) async throws -> InputEventMessage {
        try await withThrowingTaskGroup(of: InputEventMessage.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                while let payload = try await iterator.next() {
                    if case let .inputEvent(input) = payload { return input }
                }
                throw InputAdmissionEpochTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw InputAdmissionEpochTestError.timedOut
            }
            defer { group.cancelAll() }
            guard let input = try await group.next() else {
                throw InputAdmissionEpochTestError.streamEnded
            }
            return input
        }
    }
}

private enum InputAdmissionEpochTestError: Error {
    case timedOut
    case streamEnded
}
