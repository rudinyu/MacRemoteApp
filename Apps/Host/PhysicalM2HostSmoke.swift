#if DEBUG
import Foundation
import InputCore
import RemoteProtocol
import SecurityCore
import TransportCore

enum M2PhysicalHostSmoke {
    private enum ClipboardOperatorEvent: Sendable {
        case input(String?)
        case status(ClipboardSyncStatus)
        case session(SessionSnapshot)
        case normalClose
    }

    private enum ClipboardWalkthroughCompletion: Equatable, Sendable {
        case operatorRequested
        case peerNormalClose
    }

    private actor ClipboardNormalCloseObserver {
        private var observed = false

        func record(_ reason: CloseReason) {
            if reason == .normal {
                observed = true
            }
        }

        func wasObserved() -> Bool {
            observed
        }
    }

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

    static func run(clipboardOptIn: Bool = false) async throws {
        let configuration = try Configuration.load()
        let capabilities: Set<Capability> = clipboardOptIn
            ? [.pingPong, .textClipboard]
            : [.pingPong]
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
                let normalCloseObserver = ClipboardNormalCloseObserver()
                do {
                    let session = SessionCoordinator(
                        configuration: SessionConfiguration(
                            role: .host,
                            implementationIdentifier: clipboardOptIn
                                ? "MacRemoteApp-M7-PhysicalHost"
                                : "MacRemoteApp-M2-PhysicalHost",
                            capabilities: capabilities,
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
                        onNonInputMessage: { message in
                            // The M2 diagnostic has no product message/UI
                            // dispatcher. Host production composition passes
                            // its central dispatcher here; the loop still
                            // remains the sole consumer of this stream.
                            if case let .close(close) = message {
                                await normalCloseObserver.record(close.reason)
                            }
                        }
                    )
                    do {
                        try await session.start()
                        _ = try await waitForSession(
                            session,
                            authorized: false,
                            timeoutSeconds: configuration.timeoutSeconds
                        )
                        try await session.authorize(capabilities: capabilities)
                        let snapshot = try await waitForSession(
                            session,
                            authorized: true,
                            timeoutSeconds: configuration.timeoutSeconds
                        )
                        if clipboardOptIn {
                            print(
                                "M7 physical host clipboard opt-in enabled by explicit " +
                                    "--m7-physical-host command"
                            )
                            try await inputRuntime.setClipboardEnabled(true)
                            let clipboardStatus = try await waitForClipboard(
                                inputRuntime,
                                timeoutSeconds: configuration.timeoutSeconds
                            )
                            let ux = SessionUXProjection.make(
                                session: snapshot,
                                permission: .unknown,
                                streamReady: false,
                                inputReady: false,
                                clipboard: clipboardStatus
                            )
                            guard ux.clipboardEnabled else {
                                throw SmokeError(
                                    "authorized clipboard opt-in did not reach the ready state"
                                )
                            }
                            print(
                                "M7 physical host UI state: authorized, " +
                                    "clipboard=enabled"
                            )
                            let completion = try await waitForClipboardOperatorStop(
                                inputRuntime,
                                session: session,
                                normalCloseObserver: normalCloseObserver
                            )
                            let sessionIsLive = isLiveClipboardSession(await session.snapshot())
                            let normalCloseObserved = await normalCloseObserver.wasObserved()
                            guard completion == .peerNormalClose ||
                                sessionIsLive ||
                                normalCloseObserved else {
                                throw SmokeError("session ended during the M7 clipboard walkthrough")
                            }
                        }
                        if !clipboardOptIn {
                            // Give Network.framework time to deliver the queued
                            // authorization envelope before the diagnostic tears
                            // down its intentionally short-lived session. The
                            // protocol has no application-level authorization ACK;
                            // the Viewer process is the authoritative PASS witness.
                            try? await Task.sleep(
                                nanoseconds: configuration.postAuthorizationGraceSeconds * 1_000_000_000
                            )
                        }
                        await session.stop()
                        await inputRuntime.stop()
                        result.continuation.yield(snapshot)
                        result.continuation.finish()
                        print(
                            "M\(clipboardOptIn ? 7 : 2) physical host authorized peer " +
                                "\(shortIdentity(snapshot.peerIdentity)) " +
                                "capabilities=\(clipboardOptIn ? "pingPong,textClipboard" : "pingPong")"
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
            "M\(clipboardOptIn ? 7 : 2) physical host listening as \(configuration.serviceName) " +
                "on _macremote._tcp; waiting for a trusted Viewer"
        )
        defer { listener.cancel() }

        let snapshot: SessionSnapshot
        if clipboardOptIn {
            var iterator = result.stream.makeAsyncIterator()
            guard let interactiveSnapshot = try await iterator.next() else {
                throw SmokeError("the Host listener ended before a session completed")
            }
            snapshot = interactiveSnapshot
        } else {
            snapshot = try await waitForResult(
                result.stream,
                // The connection workflow can spend one full timeout waiting
                // for capability negotiation and another full timeout waiting
                // for the authorized snapshot before the grace period begins.
                timeoutSeconds: configuration.timeoutSeconds * 2 +
                    configuration.postAuthorizationGraceSeconds + 5
            )
        }
        guard snapshot.authorized,
              snapshot.authorizedCapabilities == capabilities else {
            throw SmokeError("session completed without the requested authorization")
        }
        print("M\(clipboardOptIn ? 7 : 2) physical smoke PASS (Host authorized Viewer)")
    }

    private static func waitForClipboard(
        _ runtime: HostInputSessionRuntime,
        timeoutSeconds: UInt64
    ) async throws -> ClipboardSyncStatus {
        let attempts = max(1, timeoutSeconds * 10)
        for _ in 0..<attempts {
            if let status = await runtime.clipboardStatus(), status.isEnabledForSession {
                return status
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SmokeError("timed out waiting for both clipboard opt-ins")
    }

    private static func waitForClipboardOperatorStop(
        _ runtime: HostInputSessionRuntime,
        session: SessionCoordinator,
        normalCloseObserver: ClipboardNormalCloseObserver
    ) async throws -> ClipboardWalkthroughCompletion {
        print(
            "M7 physical host clipboard ready; copy text now. " +
                "Type disable to opt out, or press Return to stop."
        )
        let (events, continuation) = AsyncStream<ClipboardOperatorEvent>.makeStream()
        let initialStatus = await runtime.clipboardStatus()
        let initialSession = await session.snapshot()
        guard isLiveClipboardSession(initialSession) else {
            continuation.finish()
            print(
                "M7 physical host UI state: session=disconnected, " +
                    "clipboard=disabled; walkthrough failed"
            )
            throw SmokeError("session ended before the M7 clipboard walkthrough started")
        }
        let inputTask = Task.detached(priority: nil) {
            while !Task.isCancelled {
                let command = readLine()
                continuation.yield(.input(command))
                guard command != nil else { return }
            }
        }
        let statusTask = Task { [runtime, session, initialStatus, initialSession] in
            var previous = initialStatus
            var previousSessionIsLive = isLiveClipboardSession(initialSession)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                if let current = await runtime.clipboardStatus(), current != previous {
                    previous = current
                    continuation.yield(.status(current))
                }
                let currentSession = await session.snapshot()
                let currentSessionIsLive = isLiveClipboardSession(currentSession)
                if !currentSessionIsLive || currentSessionIsLive != previousSessionIsLive {
                    if !currentSessionIsLive {
                        if await normalCloseObserver.wasObserved() {
                            continuation.yield(.normalClose)
                            return
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if await normalCloseObserver.wasObserved() {
                            continuation.yield(.normalClose)
                            return
                        }
                    }
                    previousSessionIsLive = currentSessionIsLive
                    continuation.yield(.session(currentSession))
                }
            }
        }
        defer {
            inputTask.cancel()
            statusTask.cancel()
            continuation.finish()
        }

        for await event in events {
            switch event {
            case let .status(status):
                print(
                    "M7 physical host UI state: authorized, " +
                        "clipboard=\(status.isEnabledForSession ? "enabled" : "disabled")"
                )
            case let .session(snapshot):
                guard isLiveClipboardSession(snapshot) else {
                    print(
                        "M7 physical host UI state: session=disconnected, " +
                            "clipboard=disabled; walkthrough failed"
                    )
                    throw SmokeError("session ended during the M7 clipboard walkthrough")
                }
            case .normalClose:
                return .peerNormalClose
            case let .input(command):
                guard let command else { return .operatorRequested }
                let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard normalized == "disable" || normalized == "off" else {
                    return .operatorRequested
                }
                try await runtime.setClipboardEnabled(false)
                print("M7 physical host UI state: authorized, clipboard=disabled")
                print("M7 physical host clipboard remains connected; press Return to stop.")
            }
        }
        return .operatorRequested
    }

    private static func isLiveClipboardSession(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.authorized &&
            snapshot.authorizedCapabilities.contains(.textClipboard) &&
            snapshot.state != .reconnecting &&
            snapshot.state != .stopping &&
            snapshot.state != .failed
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
#endif
