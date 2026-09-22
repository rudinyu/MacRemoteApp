@preconcurrency import Network
import Foundation
import Security
import SecurityCore
import TransportCore
import XCTest

final class M2LanSmokeTests: XCTestCase {
    func testM2LoopbackTLSAndSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACREMOTEAPP_RUN_M2_LAN_SMOKE"] == "1" else {
            throw XCTSkip("set MACREMOTEAPP_RUN_M2_LAN_SMOKE=1 to run the real Network.framework smoke test")
        }
        guard let hostPath = environment["MACREMOTEAPP_HOST_P12"],
              let viewerPath = environment["MACREMOTEAPP_VIEWER_P12"],
              let password = environment["MACREMOTEAPP_P12_PASSWORD"] else {
            throw XCTSkip("the LAN smoke test requires two PKCS#12 identity paths and a password")
        }

        let provider = KeychainIdentityProvider(label: nil)
        let hostIdentity = try await provider.importPKCS12(
            at: URL(fileURLWithPath: hostPath),
            password: password
        )
        let viewerIdentity = try await provider.importPKCS12(
            at: URL(fileURLWithPath: viewerPath),
            password: password
        )

        try await runLoopback(hostIdentity: hostIdentity, viewerIdentity: viewerIdentity)
    }

    func testM2LoopbackTLSAndSessionWithGeneratedIdentities() async throws {
        guard ProcessInfo.processInfo.environment["MACREMOTEAPP_RUN_M2_LOCAL_IDENTITY_SMOKE"] == "1" else {
            throw XCTSkip("set MACREMOTEAPP_RUN_M2_LOCAL_IDENTITY_SMOKE=1 to run the generated-identity smoke test")
        }

        let suffix = UUID().uuidString
        let temporaryKeychain = try TemporaryKeychain()
        let hostProvider = KeychainIdentityProvider(
            label: "MacRemoteApp Local Host Test",
            applicationTag: "com.rudinyu.MacRemoteApp.test.host.\(suffix)",
            keychain: KeychainReference(temporaryKeychain.reference)
        )
        let viewerProvider = KeychainIdentityProvider(
            label: "MacRemoteApp Local Viewer Test",
            applicationTag: "com.rudinyu.MacRemoteApp.test.viewer.\(suffix)",
            keychain: KeychainReference(temporaryKeychain.reference)
        )
        let hostIdentity = try await hostProvider.loadOrCreate()
        let viewerIdentity = try await viewerProvider.loadOrCreate()
        XCTAssertNotEqual(hostIdentity.peerIdentity, viewerIdentity.peerIdentity)

        do {
            try await runLoopback(hostIdentity: hostIdentity, viewerIdentity: viewerIdentity)
            try await hostProvider.removeGeneratedIdentity()
            try await viewerProvider.removeGeneratedIdentity()
        } catch {
            try? await hostProvider.removeGeneratedIdentity()
            try? await viewerProvider.removeGeneratedIdentity()
            throw error
        }
    }

    private func runLoopback(
        hostIdentity: ProvisionedIdentity,
        viewerIdentity: ProvisionedIdentity
    ) async throws {

        let hostTLS = TLSOptions(
            mode: .trusted(TrustedPeer(identity: viewerIdentity.peerIdentity)),
            localIdentity: hostIdentity.secIdentity
        )
        let viewerTLS = TLSOptions(
            mode: .trusted(TrustedPeer(identity: hostIdentity.peerIdentity)),
            localIdentity: viewerIdentity.secIdentity
        )

        let listener = try NWListener(using: hostTLS.makeParameters())
        let listenerQueue = DispatchQueue(label: "MacRemoteApp.M2LoopbackListener")
        let readyStream = AsyncThrowingStream<NWEndpoint.Port, Error>.makeStream()
        let acceptedStream = AsyncThrowingStream<NetworkFramedTransport, Error>.makeStream()
        let readyContinuation = readyStream.continuation
        let acceptedContinuation = acceptedStream.continuation

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port {
                    readyContinuation.yield(port)
                    readyContinuation.finish()
                } else {
                    readyContinuation.finish(throwing: TransportError.connectionFailed("listener has no port"))
                }
            case let .failed(error):
                readyContinuation.finish(throwing: error)
                acceptedContinuation.finish(throwing: error)
            case .cancelled:
                readyContinuation.finish()
                acceptedContinuation.finish()
            default:
                break
            }
        }
        listener.newConnectionHandler = { connection in
            do {
                let transport = try NetworkFramedTransport(
                    connection: connection,
                    tlsOptions: hostTLS.connectionScoped(),
                    authentication: .pending
                )
                Task {
                    do {
                        try await transport.start()
                        acceptedContinuation.yield(transport)
                    } catch {
                        acceptedContinuation.finish(throwing: error)
                    }
                }
            } catch {
                connection.cancel()
                acceptedContinuation.finish(throwing: error)
            }
        }
        listener.start(queue: listenerQueue)

        var readyIterator = readyStream.stream.makeAsyncIterator()
        guard let port = try await readyIterator.next() else {
            throw TransportError.connectionFailed("listener did not become ready")
        }

        let clientConnection = NWConnection(
            host: "127.0.0.1",
            port: port,
            using: viewerTLS.makeParameters()
        )
        let clientTransport = try NetworkFramedTransport(
            connection: clientConnection,
            tlsOptions: viewerTLS.connectionScoped(),
            authentication: .pending
        )
        try await clientTransport.start()

        var acceptedIterator = acceptedStream.stream.makeAsyncIterator()
        guard let serverTransport = try await acceptedIterator.next() else {
            throw TransportError.connectionFailed("listener accepted no transport")
        }

        let clientAuthentication = await clientTransport.authentication()
        let serverAuthentication = await serverTransport.authentication()
        XCTAssertEqual(clientAuthentication, .trusted(hostIdentity.peerIdentity))
        XCTAssertEqual(serverAuthentication, .trusted(viewerIdentity.peerIdentity))

        let hostSession = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "m2-loopback-host",
                capabilities: [.pingPong]
            ),
            transport: serverTransport
        )
        let viewerSession = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "m2-loopback-viewer",
                capabilities: [.pingPong]
            ),
            transport: clientTransport
        )

        async let hostStart: Void = hostSession.start()
        async let viewerStart: Void = viewerSession.start()
        try await hostStart
        try await viewerStart

        for _ in 0 ..< 500 {
            let hostState = await hostSession.snapshot().state
            let viewerState = await viewerSession.snapshot().state
            if hostState == .capabilitiesNegotiated,
               viewerState == .capabilitiesNegotiated {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let hostSnapshot = await hostSession.snapshot()
        let viewerSnapshot = await viewerSession.snapshot()
        XCTAssertEqual(hostSnapshot.state, .capabilitiesNegotiated)
        XCTAssertEqual(viewerSnapshot.state, .capabilitiesNegotiated)

        await hostSession.stop()
        await viewerSession.stop()
        await serverTransport.close()
        await clientTransport.close()
        listener.cancel()
    }

}

private final class TemporaryKeychain {
    let reference: SecKeychain
    private let previousSearchList: [SecKeychain]
    private let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteApp-M2-Test-\(UUID().uuidString).keychain")
        let password = Data(UUID().uuidString.utf8)
        var created: SecKeychain?
        let status = url.path.withCString { path in
            password.withUnsafeBytes { bytes in
                SecKeychainCreate(
                    path,
                    UInt32(password.count),
                    bytes.baseAddress,
                    false,
                    nil,
                    &created
                )
            }
        }
        guard status == errSecSuccess, let created else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        reference = created

        var existingSearchList: CFArray?
        let copyStatus = SecKeychainCopySearchList(&existingSearchList)
        guard copyStatus == errSecSuccess else {
            _ = SecKeychainDelete(created)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(copyStatus))
        }
        previousSearchList = existingSearchList as? [SecKeychain] ?? []
        let newSearchList = ([created] + previousSearchList) as CFArray
        let setStatus = SecKeychainSetSearchList(newSearchList)
        guard setStatus == errSecSuccess else {
            _ = SecKeychainDelete(created)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(setStatus))
        }
    }

    deinit {
        _ = SecKeychainSetSearchList(previousSearchList as CFArray)
        _ = SecKeychainDelete(reference)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
