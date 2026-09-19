import Foundation
import InputCore
import RemoteProtocol
import SecurityCore
import TransportCore

enum M2PhysicalHostSmoke {
    private struct Configuration {
        let identityURL: URL
        let peerCertificateURL: URL
        let password: String
        let serviceName: String
        let timeoutSeconds: UInt64
        let postAuthorizationGraceSeconds: UInt64

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
            let postAuthorizationGraceSeconds = UInt64(
                environment["MACREMOTEAPP_M2_POST_AUTH_SECONDS"] ?? "15"
            ) ?? 15
            return Configuration(
                identityURL: URL(fileURLWithPath: identityPath),
                peerCertificateURL: URL(fileURLWithPath: peerCertificatePath),
                password: password,
                serviceName: environment["MACREMOTEAPP_SERVICE_NAME"] ?? "MacRemoteApp-Host",
                timeoutSeconds: max(1, min(timeoutSeconds, 300)),
                postAuthorizationGraceSeconds: max(1, min(postAuthorizationGraceSeconds, 60))
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
        let trustedPeer = TrustedPeer(identity: peerIdentity, displayName: "MacRemoteApp Viewer")
        let tlsOptions = TLSOptions(
            mode: .trusted(trustedPeer),
            localIdentity: localIdentity.secIdentity
        )
        let listener = try NetworkBonjourListener(
            serviceName: configuration.serviceName,
            tlsOptions: tlsOptions,
            authentication: .pending
        )
        let result = AsyncThrowingStream<SessionSnapshot, Error>.makeStream()

        listener.onConnection = { transport in
            Task {
                do {
                    let session = SessionCoordinator(
                        configuration: SessionConfiguration(
                            role: .host,
                            implementationIdentifier: "MacRemoteApp-M2-PhysicalHost",
                            capabilities: [.pingPong],
                            mandatoryCapabilities: [.pingPong]
                        ),
                        transport: transport
                    )
                    let contextProvider = CoreGraphicsAccessibilityContextProvider(
                        sessionStateProvider: {
                            HostInputSessionState(
                                authorized: false,
                                authorizedWindowGeneration: nil,
                                mouseInputEnabled: false,
                                keyboardInputEnabled: false
                            )
                        },
                        selectionProvider: { nil }
                    )
                    let inputRuntime = await HostApp.startInputSession(
                        session,
                        contextProvider: contextProvider,
                        injectionAdapter: CoreGraphicsAccessibilityInputAdapter(
                            contextProvider: contextProvider
                        ),
                        onNonInputMessage: { _ in
                            // The M2 diagnostic has no product message/UI
                            // dispatcher. Host production composition passes
                            // its central dispatcher here; the loop still
                            // remains the sole consumer of this stream.
                        }
                    )
                    do {
                        try await session.start()
                        _ = try await waitForSession(
                            session,
                            authorized: false,
                            timeoutSeconds: configuration.timeoutSeconds
                        )
                        try await session.authorize(capabilities: [.pingPong])
                        let snapshot = try await waitForSession(
                            session,
                            authorized: true,
                            timeoutSeconds: configuration.timeoutSeconds
                        )
                        // Give Network.framework time to deliver the queued
                        // authorization envelope before the diagnostic tears
                        // down its intentionally short-lived session. The
                        // protocol has no application-level authorization ACK;
                        // the Viewer process is the authoritative PASS witness.
                        try? await Task.sleep(
                            nanoseconds: configuration.postAuthorizationGraceSeconds * 1_000_000_000
                        )
                        await session.stop()
                        await inputRuntime.stop()
                        result.continuation.yield(snapshot)
                        result.continuation.finish()
                        print(
                            "M2 physical host authorized peer \(shortIdentity(snapshot.peerIdentity)) " +
                                "capabilities=pingPong"
                        )
                    } catch {
                        await inputRuntime.stop()
                        throw error
                    }
                } catch {
                    result.continuation.finish(throwing: error)
                    await transport.close()
                }
            }
        }

        listener.start()
        print(
            "M2 physical host listening as \(configuration.serviceName) " +
                "on _macremote._tcp; waiting for a trusted Viewer"
        )
        defer { listener.cancel() }

        let snapshot = try await waitForResult(
            result.stream,
            // The connection workflow can spend one full timeout waiting for
            // capability negotiation and another full timeout waiting for the
            // authorized snapshot before the grace period begins.
            timeoutSeconds: configuration.timeoutSeconds * 2 +
                configuration.postAuthorizationGraceSeconds + 5
        )
        guard snapshot.authorized,
              snapshot.authorizedCapabilities == [.pingPong] else {
            throw SmokeError("session completed without pingPong authorization")
        }
        print("M2 physical smoke PASS (Host authorized Viewer)")
    }

    private static func waitForResult(
        _ stream: AsyncThrowingStream<SessionSnapshot, Error>,
        timeoutSeconds: UInt64
    ) async throws -> SessionSnapshot {
        try await withThrowingTaskGroup(of: SessionSnapshot.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let snapshot = try await iterator.next() else {
                    throw SmokeError("the Host listener ended before a session completed")
                }
                return snapshot
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw SmokeError("timed out waiting for a Viewer connection")
            }
            defer { group.cancelAll() }
            guard let snapshot = try await group.next() else {
                throw SmokeError("the Host smoke wait ended without a result")
            }
            return snapshot
        }
    }

    private static func waitForSession(
        _ session: SessionCoordinator,
        authorized: Bool,
        timeoutSeconds: UInt64
    ) async throws -> SessionSnapshot {
        let attempts = max(1, timeoutSeconds * 10)
        for _ in 0..<attempts {
            let snapshot = await session.snapshot()
            if snapshot.state == .failed {
                throw SmokeError("session entered the failed state")
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
