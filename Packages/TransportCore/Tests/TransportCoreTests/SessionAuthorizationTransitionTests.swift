import Foundation
import RemoteProtocol
import SecurityCore
@testable import TransportCore
import XCTest

final class SessionAuthorizationTransitionTests: XCTestCase {
    func testAuthorizeReturnsExactWrittenAuthorizationEpoch() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("receipt-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("receipt-viewer".utf8))
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
                implementationIdentifier: "receipt-host",
                capabilities: capabilities
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "receipt-viewer",
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

            let before = await host.snapshot()
            let receipt = try await host.authorize(
                windowGeneration: 37,
                capabilities: [.mouseInput]
            )
            let after = await host.snapshot()

            XCTAssertEqual(receipt.previousAuthorizationGeneration, before.authorizationGeneration)
            XCTAssertEqual(receipt.authorizationGeneration, after.authorizationGeneration)
            XCTAssertEqual(receipt.authorizationGeneration, before.authorizationGeneration &+ 1)
            XCTAssertEqual(receipt.reconnectGeneration, after.reconnectGeneration)
            XCTAssertEqual(receipt.receiveGeneration, after.receiveGeneration)
            XCTAssertEqual(after.authorizedWindowGeneration, 37)
            XCTAssertEqual(after.authorizedCapabilities, [.mouseInput])
        } catch {
            await host.stop()
            await viewer.stop()
            throw error
        }

        await host.stop()
        await viewer.stop()
    }

    func testConcurrentAuthorizeCallsReturnConsecutiveSerializedReceipts() async throws {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("concurrent-receipt-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("concurrent-receipt-viewer".utf8))
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
                implementationIdentifier: "concurrent-receipt-host",
                capabilities: capabilities
            ),
            transport: pair.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "concurrent-receipt-viewer",
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

            let before = await host.snapshot()
            async let first = host.authorize(windowGeneration: 51, capabilities: [.mouseInput])
            async let second = host.authorize(windowGeneration: 52, capabilities: [.mouseInput])
            let (firstReceipt, secondReceipt) = try await (first, second)
            let after = await host.snapshot()
            let ordered = [firstReceipt, secondReceipt].sorted {
                $0.authorizationGeneration < $1.authorizationGeneration
            }

            XCTAssertEqual(ordered.count, 2)
            XCTAssertEqual(ordered[0].previousAuthorizationGeneration, before.authorizationGeneration)
            XCTAssertEqual(ordered[0].authorizationGeneration, before.authorizationGeneration &+ 1)
            XCTAssertEqual(ordered[1].previousAuthorizationGeneration, ordered[0].authorizationGeneration)
            XCTAssertEqual(ordered[1].authorizationGeneration, ordered[0].authorizationGeneration &+ 1)
            XCTAssertEqual(after.authorizationGeneration, ordered[1].authorizationGeneration)
            XCTAssertEqual(ordered.map(\.reconnectGeneration), [before.reconnectGeneration, before.reconnectGeneration])
            XCTAssertEqual(ordered.map(\.receiveGeneration), [before.receiveGeneration, before.receiveGeneration])
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
        satisfying predicate: (SessionSnapshot) -> Bool
    ) async throws -> SessionSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let snapshot = await session.snapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SessionAuthorizationTransitionTestError.timedOut
    }
}

private enum SessionAuthorizationTransitionTestError: Error {
    case timedOut
}
