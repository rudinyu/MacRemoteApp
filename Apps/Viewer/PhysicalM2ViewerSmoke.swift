#if DEBUG
import Foundation
import RemoteProtocol
import SecurityCore
import TransportCore

enum M2PhysicalViewerSmoke {
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
        print("M\(clipboardOptIn ? 7 : 2) physical viewer discovered a trusted Host via Bonjour")

        let transport = try NetworkFramedTransport(
            endpoint: service.endpoint,
            tlsOptions: tlsOptions
        )
        let session = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: clipboardOptIn
                    ? "MacRemoteApp-M7-PhysicalViewer"
                    : "MacRemoteApp-M2-PhysicalViewer",
                capabilities: capabilities,
                mandatoryCapabilities: [.pingPong]
            ),
            transport: transport
        )
        let normalCloseObserver = ClipboardNormalCloseObserver()
        let messageLoop = await ViewerApp.startSession(session) { message in
            if case let .close(close) = message {
                await normalCloseObserver.record(close.reason)
            }
        }

        do {
            try await session.start()
            _ = try await waitForSession(
                session,
                authorized: false,
                timeoutSeconds: configuration.timeoutSeconds
            )
            let snapshot = try await waitForSession(
                session,
                authorized: true,
                timeoutSeconds: configuration.timeoutSeconds
            )
            guard snapshot.authorizedCapabilities == capabilities else {
                throw SmokeError("Host authorization did not contain the requested capabilities")
            }
            if clipboardOptIn {
                print(
                    "M7 physical viewer clipboard opt-in enabled by explicit " +
                        "--m7-physical-viewer command"
                )
                try await messageLoop.setClipboardEnabled(true)
                let clipboardStatus = try await waitForClipboard(
                    messageLoop,
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
                    "M7 physical viewer UI state: authorized, " +
                        "clipboard=enabled"
                )
                let completion = try await waitForClipboardOperatorStop(
                    messageLoop,
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
            print(
                "M\(clipboardOptIn ? 7 : 2) physical viewer authorized by Host " +
                    "\(shortIdentity(snapshot.peerIdentity)) " +
                    "capabilities=\(clipboardOptIn ? "pingPong,textClipboard" : "pingPong")"
            )
            print("M\(clipboardOptIn ? 7 : 2) physical smoke PASS (Viewer received Host authorization)")
            await session.stop()
            await messageLoop.stop()
        } catch {
            await messageLoop.stop()
            await transport.close()
            throw error
        }
    }

    private static func waitForClipboard(
        _ messageLoop: ViewerSessionMessageLoop,
        timeoutSeconds: UInt64
    ) async throws -> ClipboardSyncStatus {
        let attempts = max(1, timeoutSeconds * 10)
        for _ in 0..<attempts {
            let status = await messageLoop.clipboardStatus
            if status.isEnabledForSession {
                return status
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SmokeError("timed out waiting for both clipboard opt-ins")
    }

    private static func waitForClipboardOperatorStop(
        _ messageLoop: ViewerSessionMessageLoop,
        session: SessionCoordinator,
        normalCloseObserver: ClipboardNormalCloseObserver
    ) async throws -> ClipboardWalkthroughCompletion {
        print(
            "M7 physical viewer clipboard ready; copy text now. " +
                "Type disable to opt out, or press Return to stop."
        )
        let (events, continuation) = AsyncStream<ClipboardOperatorEvent>.makeStream()
        let initialStatus = await messageLoop.clipboardStatus
        let initialSession = await session.snapshot()
        guard isLiveClipboardSession(initialSession) else {
            continuation.finish()
            print(
                "M7 physical viewer UI state: session=disconnected, " +
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
        let statusTask = Task { [messageLoop, session, initialStatus, initialSession] in
            var previous = initialStatus
            var previousSessionIsLive = isLiveClipboardSession(initialSession)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                let current = await messageLoop.clipboardStatus
                if current != previous {
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
                    "M7 physical viewer UI state: authorized, " +
                        "clipboard=\(status.isEnabledForSession ? "enabled" : "disabled")"
                )
            case let .session(snapshot):
                guard isLiveClipboardSession(snapshot) else {
                    print(
                        "M7 physical viewer UI state: session=disconnected, " +
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
                try await messageLoop.setClipboardEnabled(false)
                print("M7 physical viewer UI state: authorized, clipboard=disabled")
                print("M7 physical viewer clipboard remains connected; press Return to stop.")
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
