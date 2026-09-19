import Foundation
import RemoteProtocol
import SecurityCore
import TransportCore

enum M2PhysicalViewerSmoke {
    private struct Configuration {
        let identityURL: URL
        let peerCertificateURL: URL
        let password: String
        let hostName: String?
        let timeoutSeconds: UInt64

        static func load() throws -> Configuration {
            let environment = ProcessInfo.processInfo.environment
            guard let identityPath = environment["MACREMOTEAPP_LOCAL_IDENTITY_P12"],
                  let peerCertificatePath = environment["MACREMOTEAPP_PEER_CERT"] else {
                throw SmokeError(
                    "set MACREMOTEAPP_LOCAL_IDENTITY_P12 and MACREMOTEAPP_PEER_CERT"
                )
            }
            guard let password = environment["MACREMOTEAPP_P12_PASSWORD"],
                  !password.isEmpty else {
                throw SmokeError("set MACREMOTEAPP_P12_PASSWORD without printing it")
            }

            let timeoutSeconds = UInt64(environment["MACREMOTEAPP_M2_TIMEOUT_SECONDS"] ?? "30") ?? 30
            return Configuration(
                identityURL: URL(fileURLWithPath: identityPath),
                peerCertificateURL: URL(fileURLWithPath: peerCertificatePath),
                password: password,
                hostName: environment["MACREMOTEAPP_HOST_NAME"],
                timeoutSeconds: max(1, min(timeoutSeconds, 300))
            )
        }
    }

    private struct SmokeError: Error, CustomStringConvertible, Sendable {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    static func run() async throws {
        let configuration = try Configuration.load()
        let identityProvider = KeychainIdentityProvider()
        let localIdentity = try await identityProvider.importPKCS12(
            at: configuration.identityURL,
            password: configuration.password
        )
        let peerIdentity = try PublicCertificateIdentity.load(
            from: configuration.peerCertificateURL
        )
        let trustedPeer = TrustedPeer(identity: peerIdentity, displayName: "MacRemoteApp Host")
        let tlsOptions = TLSOptions(
            mode: .trusted(trustedPeer),
            localIdentity: localIdentity.secIdentity
        )
        let discovery = NetworkBonjourDiscovery()
        discovery.start()
        defer { discovery.cancel() }

        let service = try await discoverHost(
            from: discovery,
            hostName: configuration.hostName,
            timeoutSeconds: configuration.timeoutSeconds
        )
        // Bonjour metadata is untrusted; keep discovery diagnostics fixed and
        // printable instead of echoing a remote service name to the terminal.
        print("M2 physical viewer discovered a trusted Host via Bonjour")

        let transport = try NetworkFramedTransport(
            endpoint: service.endpoint,
            tlsOptions: tlsOptions
        )
        let session = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "MacRemoteApp-M2-PhysicalViewer",
                capabilities: [.pingPong],
                mandatoryCapabilities: [.pingPong]
            ),
            transport: transport
        )
        let failureProbe = Task<String?, Never> {
            var iterator = session.incomingMessages.makeAsyncIterator()
            do {
                while try await iterator.next() != nil {}
                return nil
            } catch {
                return String(describing: error)
            }
        }

        do {
            try await session.start()
            _ = try await waitForSession(
                session,
                authorized: false,
                timeoutSeconds: configuration.timeoutSeconds,
                failureProbe: failureProbe
            )
            let snapshot = try await waitForSession(
                session,
                authorized: true,
                timeoutSeconds: configuration.timeoutSeconds,
                failureProbe: failureProbe
            )
            guard snapshot.authorizedCapabilities == Set<Capability>([.pingPong]) else {
                throw SmokeError("Host authorization did not contain only pingPong")
            }
            print(
                "M2 physical viewer authorized by Host \(shortIdentity(snapshot.peerIdentity)) " +
                    "capabilities=pingPong"
            )
            print("M2 physical smoke PASS (Viewer received Host authorization)")
            await session.stop()
            failureProbe.cancel()
        } catch {
            failureProbe.cancel()
            await transport.close()
            throw error
        }
    }

    private static func discoverHost(
        from discovery: NetworkBonjourDiscovery,
        hostName: String?,
        timeoutSeconds: UInt64
    ) async throws -> DiscoveredService {
        try await withThrowingTaskGroup(of: DiscoveredService.self) { group in
            group.addTask {
                var iterator = discovery.updates.makeAsyncIterator()
                while let services = await iterator.next() {
                    if let service = services.first(where: { service in
                        guard let hostName else { return true }
                        return service.name == hostName
                    }) {
                        return service
                    }
                }
                throw SmokeError("Bonjour discovery ended before a Host was found")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw SmokeError("timed out waiting for a Bonjour Host")
            }
            defer { group.cancelAll() }
            guard let service = try await group.next() else {
                throw SmokeError("Bonjour wait ended without a Host")
            }
            return service
        }
    }

    private static func waitForSession(
        _ session: SessionCoordinator,
        authorized: Bool,
        timeoutSeconds: UInt64,
        failureProbe: Task<String?, Never>
    ) async throws -> SessionSnapshot {
        let attempts = max(1, timeoutSeconds * 10)
        for _ in 0..<attempts {
            let snapshot = await session.snapshot()
            if snapshot.state == .failed {
                let detail = await failureProbe.value ?? "unknown session error"
                throw SmokeError("session entered the failed state: \(detail)")
            }
            if authorized {
                if snapshot.authorized { return snapshot }
            } else if snapshot.state == .capabilitiesNegotiated ||
                        snapshot.state == .windowSelectionAuthorized {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SmokeError("timed out waiting for session authorization state")
    }

    private static func shortIdentity(_ identity: PeerIdentity?) -> String {
        guard let identity else { return "unknown" }
        return String(identity.identifier.prefix(12))
    }
}
