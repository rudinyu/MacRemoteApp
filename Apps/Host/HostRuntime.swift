import AppKit
import CaptureCore
import CodecCore
import Foundation
import InputCore
import os
import RemoteProtocol
import SecurityCore
import TransportCore

private enum HostPairingPromptOutcome: Sendable {
    case consent(Bool)
    case sessionEnded
}

enum HostRuntimeStatus: Sendable, Equatable, CustomStringConvertible {
    case starting
    case needsScreenRecording
    case needsLocalNetwork
    case listenerFailed
    case connected
    case pairing(code: String)
    case listening
    case failed
    case stopped

    var description: String {
        switch self {
        case .starting: return "Starting"
        case .needsScreenRecording: return "Screen Recording permission required"
        case .needsLocalNetwork: return "Local Network permission required"
        case .listenerFailed: return "Bonjour service unavailable"
        case .connected: return "Viewer connected"
        case .pairing: return "Pairing requested"
        case .listening: return "Listening for a paired Viewer"
        case .failed: return "Startup failed — retry setup"
        case .stopped: return "Stopped"
        }
    }
}

/// The production Host composition for the V1 vertical slice.
///
/// The shared packages remain responsible for capture, encoding, transport,
/// authorization, and input policy. This actor only owns their lifecycle and
/// the selected-window state that ties them together. There is intentionally
/// one active Viewer and one selected window per Host session.
actor HostRuntime {
    struct Configuration: Sendable {
        static let defaultIdentityLabel = "MacRemoteApp.host"
        static let defaultTrustStoreService = "com.rudinyu.MacRemoteApp.Host.trust"

        var serviceName: String
        let peerCertificateURL: URL?
        let identityLabel: String

        static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Configuration {
            let peerCertificateURL = environment["MACREMOTEAPP_PEER_CERT"]
                .flatMap { path in path.isEmpty ? nil : URL(fileURLWithPath: path) }
            let serviceName = HostPreferences.load(environment: environment)
            let identityLabel = environment["MACREMOTEAPP_LOCAL_IDENTITY_LABEL"]
                .map { "\($0).host" } ?? defaultIdentityLabel
            return Configuration(
                serviceName: serviceName,
                peerCertificateURL: peerCertificateURL,
                identityLabel: identityLabel
            )
        }
    }

    private static let capabilities: Set<Capability> = [
        .pingPong,
        .windowSelection,
        .h264Video,
        .mouseInput,
        .keyboardInput,
        .textClipboard
    ]
    private static let inputCapabilities: Set<Capability> = [
        .mouseInput,
        .keyboardInput
    ]

    private var configuration: Configuration
    private let windowProvider: ScreenRecordingWindowProvider
    private let captureSession: WindowCaptureSession
    private let stateStore = HostInputStateStore()
    let statusUpdates: AsyncStream<HostRuntimeStatus>
    private let statusContinuation: AsyncStream<HostRuntimeStatus>.Continuation

    private var listener: NetworkBonjourListener?
    private var localIdentity: ProvisionedIdentity?
    private var activeSession: SessionCoordinator?
    private var inputRuntime: HostInputSessionRuntime?
    private var sessionMonitor: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var encoder: H264Encoder?
    private var selectedWindow: CaptureWindow?
    private var selectedWindowGeneration: UInt64?
    private var advertisedWindowGeneration: UInt64 = 1
    private var advertisedWindowCatalogGeneration: UInt64 = 0
    private var advertisedWindows: [CaptureWindow] = []
    private var videoConfigSentGeneration: UInt64?
    private var videoConfigSentAuthorizationGeneration: UInt64?
    private var clipboardOptedInForSession = false
    private var clipboardConsentPromptedForSession = false
    private var clipboardConsentTask: Task<Void, Never>?
    private var retryRequested = false
    private var restartRequested = false
    private var selectionTransitionInProgress = false
    private let startupLogger = Logger(
        subsystem: "com.rudinyu.MacRemoteApp",
        category: "host-runtime"
    )

    init(
        configuration: Configuration,
        windowProvider: ScreenRecordingWindowProvider = ScreenRecordingWindowProvider(),
        captureSession: WindowCaptureSession? = nil
    ) {
        let statusStream = AsyncStream<HostRuntimeStatus>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.configuration = configuration
        self.windowProvider = windowProvider
        self.captureSession = captureSession ?? WindowCaptureSession(windowProvider: windowProvider)
        self.statusUpdates = statusStream.stream
        self.statusContinuation = statusStream.continuation
    }

    func run() async throws {
        startupLogger.info("Host runtime entered")
        publish(.starting)
        while !Task.isCancelled {
            do {
                try await startRuntime()
                publish(.listening)
                try await waitUntilCancelled()
            } catch is CancellationError {
                await stop()
                publish(.stopped)
                throw CancellationError()
            } catch let error as HostRuntimeError {
                startupLogger.error(
                    "Host runtime startup retry required (stage: \(hostRuntimeErrorCode(error), privacy: .public))"
                )
                await stop()
                publish(error.status)
                try await waitForRetry()
            } catch {
                // A resident accessory app must not disappear because a
                // transient Keychain, listener, or TCC error occurred. Keep
                // the process alive and make the recovery action explicit in
                // the status menu instead of silently retrying forever.
                startupLogger.error(
                    "Host runtime startup retry required (stage: unknown, error: \(String(describing: error), privacy: .public))"
                )
                await stop()
                publish(.failed)
                try await waitForRetry()
            }
        }
        await stop()
        publish(.stopped)
    }

    func requestRetry() {
        retryRequested = true
    }

    func updateServiceName(_ serviceName: String) throws {
        guard let validated = HostPreferences.validatedServiceName(serviceName) else {
            throw HostRuntimeError.configuration(
                "Host name must contain visible characters and be at most 63 UTF-8 bytes"
            )
        }
        configuration.serviceName = validated
        restartRequested = true
        retryRequested = true
        publish(.starting)
    }

    /// Revokes every saved peer trust record without deleting this Mac's own
    /// TLS identity. An active session is stopped before the records are
    /// removed so no already-authorized input or media path survives the
    /// operator's explicit reset.
    func forgetAllPairings() async throws -> Int {
        await stopActiveSession()
        let trustStore = KeychainTrustStore(service: Configuration.defaultTrustStoreService)
        let count = try await trustStore.removeAllPairings()
        if listener != nil {
            publish(.listening)
        }
        return count
    }

    private func publish(_ status: HostRuntimeStatus) {
        statusContinuation.yield(status)
    }

    private func waitUntilCancelled() async throws {
        while !Task.isCancelled {
            if restartRequested {
                restartRequested = false
                await stop()
                publish(.starting)
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw CancellationError()
    }

    private func waitForRetry() async throws {
        retryRequested = false
        while !Task.isCancelled {
            if retryRequested {
                retryRequested = false
                // A rename requested while startup was already waiting for
                // recovery only needs this retry; do not perform a second
                // restart after the new listener becomes ready.
                restartRequested = false
                publish(.starting)
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw CancellationError()
    }

    private func startRuntime() async throws {
        // Permission setup must not be hidden behind Keychain enrollment. A
        // broken or locked login Keychain must still allow the signed Host to
        // request Screen Recording and Local Network access visibly.
        startupLogger.info("Host startup stage: screen-recording permission")
        try await prepareScreenRecordingPermission()
        startupLogger.info("Host startup stage complete: screen-recording permission")

        startupLogger.info("Host startup stage: local-network Bonjour readiness")
        let shouldRequestLocalNetwork = await MainActor.run {
            HostStartupOnboarding.shouldRequestLocalNetwork()
        }
        if shouldRequestLocalNetwork {
            let shouldStart = await MainActor.run {
                HostStartupOnboarding.requestLocalNetwork()
            }
            guard shouldStart else {
                throw HostRuntimeError.localNetwork(
                    "Local Network setup was not completed; enable MacRemoteApp Host in System Settings > Privacy & Security > Local Network, then relaunch the Host"
                )
            }
        }

        do {
            let discovery = NetworkBonjourDiscovery()
            try await discovery.startAndWaitForReadiness()
        } catch is CancellationError {
            throw CancellationError()
        } catch let discoveryError as BonjourDiscoveryStartupError {
            startupLogger.error(
                "Host Bonjour permission probe failed (stage: \(hostBonjourErrorCode(discoveryError), privacy: .public))"
            )
            throw HostRuntimeError.localNetwork(
                "Local Network access did not become ready; enable MacRemoteApp Host in System Settings > Privacy & Security > Local Network, then relaunch the Host"
            )
        }
        await MainActor.run {
            HostStartupOnboarding.markLocalNetworkReady()
        }
        startupLogger.info("Host startup stage complete: local-network Bonjour readiness")

        startupLogger.info("Host startup stage: Keychain identity")
        let localIdentity = try await loadLocalIdentity()
        self.localIdentity = localIdentity
        startupLogger.info("Host startup stage complete: Keychain identity")

        let authenticationMode: TLSAuthenticationMode
        if let peerCertificateURL = configuration.peerCertificateURL {
            let peerIdentity = try PublicCertificateIdentity.load(from: peerCertificateURL)
            authenticationMode = .trusted(
                TrustedPeer(identity: peerIdentity, displayName: "MacRemoteApp Viewer")
            )
        } else {
            authenticationMode = .pairingBootstrap(expectedPeer: nil)
        }
        let tlsOptions = TLSOptions(
            mode: authenticationMode,
            localIdentity: localIdentity.secIdentity
        )
        let listener = try NetworkBonjourListener(
            serviceName: configuration.serviceName,
            tlsOptions: tlsOptions,
            authentication: .pending
        )
        startupLogger.info("Host startup stage: Bonjour listener")
        listener.onConnection = { [weak self] transport in
            Task { [weak self] in
                await self?.accept(transport)
            }
        }
        self.listener = listener
        do {
            try await listener.startAndWaitForReadiness()
        } catch is CancellationError {
            throw CancellationError()
        } catch let startupError as BonjourListenerStartupError {
            if case .timedOut = startupError {
                throw HostRuntimeError.localNetwork(
                    "Local Network access did not become ready; enable MacRemoteApp Host in System Settings > Privacy & Security > Local Network, then relaunch the Host"
                )
            }
            throw HostRuntimeError.listener(startupError.description)
        } catch {
            throw HostRuntimeError.listener(
                "Bonjour listener could not start. Check Local Network access and whether another service is using the configured port, then relaunch the Host"
            )
        }
        await MainActor.run {
            HostStartupOnboarding.markLocalNetworkReady()
        }
        startupLogger.info("Host startup stage complete: Bonjour listener")
        print("MacRemoteApp Host listening for one paired Viewer")

        let currentPermission = await captureSession.permissionState()
        guard currentPermission == .authorized else {
            throw HostRuntimeError.permission(
                "Screen Recording permission is not authorized; enable MacRemoteApp Host in System Settings > Privacy & Security > Screen Recording, then relaunch the app"
            )
        }

        publish(.listening)
    }

    private func prepareScreenRecordingPermission() async throws {
        guard await captureSession.permissionState() != .authorized else {
            return
        }

        let shouldRequest = await MainActor.run {
            HostStartupOnboarding.requestScreenRecording()
        }
        guard shouldRequest else {
            throw HostRuntimeError.permission(
                "Screen Recording setup was not completed; enable MacRemoteApp Host in System Settings > Privacy & Security > Screen Recording, then relaunch the Host"
            )
        }

        _ = await captureSession.requestPermission()
        // On some macOS releases the consent UI is delivered asynchronously.
        // Recheck for a bounded period before failing closed, so an Allow click
        // is not mistaken for a denial merely because the TCC database has not
        // returned the new state to this process yet.
        for _ in 0 ..< 120 {
            if await captureSession.permissionState() == .authorized {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw HostRuntimeError.permission(
            "Screen Recording permission is not authorized; enable MacRemoteApp Host in System Settings > Privacy & Security > Screen Recording, then relaunch the Host"
        )
    }

    func stop() async {
        await stopActiveSession()
        listener?.cancel()
        listener = nil
    }

    private func stopActiveSession() async {
        sessionMonitor?.cancel()
        sessionMonitor = nil
        await stopVideoPipeline()
        clipboardConsentTask?.cancel()
        clipboardConsentTask = nil
        await inputRuntime?.stop()
        inputRuntime = nil
        if let activeSession {
            await activeSession.stop(reason: .normal)
        }
        activeSession = nil
        selectedWindow = nil
        selectedWindowGeneration = nil
        advertisedWindowCatalogGeneration = 0
        advertisedWindows.removeAll(keepingCapacity: false)
        clipboardOptedInForSession = false
        clipboardConsentPromptedForSession = false
        stateStore.clearSelection()
    }

    private func loadLocalIdentity() async throws -> ProvisionedIdentity {
#if DEBUG
        if let identityPath = ProcessInfo.processInfo.environment["MACREMOTEAPP_LOCAL_IDENTITY_P12"],
           let password = ProcessInfo.processInfo.environment["MACREMOTEAPP_P12_PASSWORD"],
           !password.isEmpty {
            return try await KeychainIdentityProvider(label: nil).importPKCS12(
                at: URL(fileURLWithPath: identityPath),
                password: password
            )
        }
#endif
        return try await KeychainIdentityProvider(label: configuration.identityLabel).loadOrCreate()
    }

    private func accept(_ transport: NetworkFramedTransport) async {
        guard activeSession == nil, let localIdentity else {
            await transport.close()
            return
        }

        let pairingCoordinator = PairingCoordinator(
            localIdentity: localIdentity.peerIdentity,
            trustStore: KeychainTrustStore(service: Configuration.defaultTrustStoreService)
        )

        let session = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "MacRemoteApp-Host-M10",
                deviceName: configuration.serviceName,
                capabilities: Self.capabilities,
                mandatoryCapabilities: [.pingPong],
                maxVideoWidth: 1920,
                maxVideoHeight: 1080,
                maxFrameRate: 60
            ),
            transport: transport,
            pairingCoordinator: pairingCoordinator
        )
        activeSession = session
        publish(.connected)
        clipboardOptedInForSession = false
        clipboardConsentPromptedForSession = false
        stateStore.update(session: await session.snapshot())

        let contextProvider = CoreGraphicsAccessibilityContextProvider(
            sessionStateProvider: { [stateStore] in stateStore.sessionState() },
            selectionProvider: { [stateStore] in stateStore.selection() },
            secureInputStateProvider: CoreGraphicsAccessibilityContextProvider.detectSecureInputState
        )
        let runtime = await HostApp.startInputSession(
            session,
            contextProvider: contextProvider,
            injectionAdapter: CoreGraphicsAccessibilityInputAdapter(contextProvider: contextProvider),
            onNonInputMessage: { [weak self] message in
                await self?.handle(message, for: session)
            },
            onSessionLifecycleReset: { [stateStore] in
                let snapshot = await session.snapshot()
                stateStore.update(session: snapshot)
            },
            onInputStatusChange: { status in
                let snapshot = await session.snapshot()
                guard snapshot.state != .failed,
                      snapshot.state != .stopping,
                      snapshot.state != .reconnecting else { return }

                let permission: PermissionState
                let focusEligible: Bool
                switch status {
                case .ready:
                    permission = .granted
                    focusEligible = true
                case .permissionUnavailable:
                    // A previously authorized input path lost its local TCC
                    // access. The Viewer must remain disabled until a fresh
                    // Host status proves that permission is usable again.
                    permission = .revoked
                    focusEligible = false
                case .focusUnavailable:
                    permission = .granted
                    focusEligible = false
                case .sessionUnauthorized,
                     .selectionUnavailable,
                     .capabilityUnavailable,
                     .inputStateCleanupPending:
                    permission = .unknown
                    focusEligible = false
                }
                try? await session.send(
                    .sessionState(
                        SessionStateMessage(
                            state: snapshot.state,
                            permission: permission,
                            focusEligible: focusEligible,
                            windowGeneration: snapshot.authorizedWindowGeneration
                        )
                    ),
                    expectedAuthorizationGeneration: snapshot.authorizationGeneration
                )
            }
        )
        inputRuntime = runtime

        do {
            try await session.start()
            try await waitForPairing(session, pairingCoordinator: pairingCoordinator)
            try await waitForCapabilities(session)
            let windows = try await captureSession.discoverWindows()
            advertisedWindowGeneration = max(1, (await captureSession.snapshot().generation) &+ 1)
            stateStore.update(session: await session.snapshot())
            try await session.authorize(
                windowGeneration: advertisedWindowGeneration,
                capabilities: [.windowSelection]
            )
            stateStore.update(session: await session.snapshot())
            _ = try await publishWindowCatalog(windows, to: session, force: true)
            sessionMonitor = Task { [weak self] in
                await self?.monitor(session)
            }
        } catch {
            await teardown(session: session)
        }
    }

    private func waitForPairing(
        _ session: SessionCoordinator,
        pairingCoordinator: PairingCoordinator
    ) async throws {
        var promptedChallengeID: UInt64?
        var projectedChallengeID: UInt64?
        while !Task.isCancelled {
            let snapshot = await session.snapshot()
            switch snapshot.state {
            case .trusted, .capabilitiesNegotiated, .windowSelectionAuthorized,
                 .streaming:
                publish(.connected)
                return
            case .pairingRequired:
                if let challenge = await pairingCoordinator.pendingChallenge() {
                    // The code is not available until the Viewer contribution
                    // has been received and the Host reveal is complete.
                    guard challenge.isVerificationReady else {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }
                    if projectedChallengeID != challenge.challengeID {
                        // A Host with an existing one-sided trust record may
                        // already have local consent and therefore skip the
                        // Allow/Deny prompt. Still expose the same one-time
                        // code in the Host status menu so both operators can
                        // compare the same value before consenting.
                        publish(.pairing(code: challenge.confirmationCode))
                        projectedChallengeID = challenge.challengeID
                    }
                    let consent = await pairingCoordinator.consentState()
                    guard consent?.localConsent != true else {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }
                    guard promptedChallengeID != challenge.challengeID else {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }
                    promptedChallengeID = challenge.challengeID
                    let outcome = await withTaskGroup(of: HostPairingPromptOutcome.self) { group in
                        group.addTask {
                    let accepted = await HostPairingPrompt.requestConsent(
                        confirmationCode: challenge.confirmationCode,
                        peerName: (await session.snapshot()).peerDeviceName,
                        expiresAt: challenge.expiresAt
                            )
                            return .consent(accepted)
                        }
                        group.addTask {
                            while !Task.isCancelled {
                                let state = await session.snapshot().state
                                if state == .failed || state == .stopping {
                                    return .sessionEnded
                                }
                                do {
                                    try await Task.sleep(nanoseconds: 100_000_000)
                                } catch {
                                    return .sessionEnded
                                }
                            }
                            return .sessionEnded
                        }
                        let outcome = await group.next() ?? .sessionEnded
                        group.cancelAll()
                        return outcome
                    }
                    guard !Task.isCancelled else { throw CancellationError() }
                    guard case let .consent(accepted) = outcome else {
                        throw HostRuntimeError.sessionEnded
                    }
                    try await session.confirmPairing(
                        confirmationCode: challenge.confirmationCode,
                        accepted: accepted
                    )
                }
            case .failed, .stopping:
                throw HostRuntimeError.sessionEnded
            case .discovered, .authenticated, .connecting, .reconnecting:
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw HostRuntimeError.pairingTimedOut
    }

    private func waitForCapabilities(_ session: SessionCoordinator) async throws {
        for _ in 0 ..< 300 {
            let snapshot = await session.snapshot()
            if snapshot.state == .capabilitiesNegotiated || snapshot.state == .windowSelectionAuthorized {
                return
            }
            if snapshot.state == .failed || snapshot.state == .stopping {
                throw HostRuntimeError.sessionEnded
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw HostRuntimeError.sessionTimedOut
    }

    private func monitor(_ session: SessionCoordinator) async {
        var nextWindowListRefreshAt: UInt64 = 0
        while !Task.isCancelled {
            let snapshot = await session.snapshot()
            stateStore.update(session: snapshot)
            if snapshot.state == .failed || snapshot.state == .stopping {
                await teardown(session: session)
                return
            }
            if selectedWindow != nil, !selectionTransitionInProgress {
                await synchronizeInputAuthorization(session)
                let captureSnapshot = await captureSession.snapshot()
                switch captureSnapshot.state {
                case .capturing:
                    break
                case .idle, .starting, .stopping, .stopped, .failed:
                    // CaptureCore can stop after a window disappears or a
                    // permission is revoked while the transport remains
                    // authenticated. Tear down the protected session instead
                    // of leaving input enabled without a live video target.
                    await teardown(session: session)
                    return
                }
            }
            let canRefreshWindowCatalog = snapshot.state == .capabilitiesNegotiated ||
                snapshot.state == .windowSelectionAuthorized ||
                snapshot.state == .streaming
            if !selectionTransitionInProgress, canRefreshWindowCatalog {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= nextWindowListRefreshAt {
                    nextWindowListRefreshAt = now &+ 1_000_000_000
                    await refreshWindowListIfNeeded(session)
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Window discovery can change after a Viewer connects: the user may
    /// launch, unminimize, or bring an application to the foreground after
    /// the initial handshake. Refresh during the authorized session, including
    /// while a window is selected, and publish only when the descriptor list
    /// changes so the Viewer can switch apps without reconnecting.
    private func refreshWindowListIfNeeded(_ session: SessionCoordinator) async {
        guard activeSession === session,
              !selectionTransitionInProgress else { return }
        let windows: [CaptureWindow]
        do {
            windows = try await captureSession.discoverWindows()
        } catch {
            startupLogger.error(
                "Host window list refresh failed (error: \(String(describing: error), privacy: .public))"
            )
            return
        }
        do {
            if try await publishWindowCatalog(windows, to: session) {
                startupLogger.info(
                    "Host refreshed window list (count: \(windows.count, privacy: .public), catalog: \(self.advertisedWindowCatalogGeneration, privacy: .public))"
                )
            }
        } catch {
            startupLogger.error(
                "Host window list refresh send failed (error: \(String(describing: error), privacy: .public))"
            )
            scheduleTeardown(session: session)
        }
    }

    private func synchronizeInputAuthorization(_ session: SessionCoordinator) async {
        guard selectedWindow != nil, let selectedWindowGeneration else { return }
        let snapshot = await session.snapshot()
        guard snapshot.authorized,
              snapshot.authorizedWindowGeneration == selectedWindowGeneration else {
            return
        }

        let permission = await MainActor.run {
            CoreGraphicsAccessibilityContextProvider.currentPermissionState()
        }
        let negotiatedInput = snapshot.negotiatedCapabilities.intersection(Self.inputCapabilities)
        var desired = snapshot.authorizedCapabilities
        if permission == .authorized {
            desired.formUnion(negotiatedInput)
        } else {
            desired.subtract(Self.inputCapabilities)
        }
        if clipboardOptedInForSession,
           snapshot.negotiatedCapabilities.contains(.textClipboard) {
            desired.insert(.textClipboard)
        } else {
            desired.remove(.textClipboard)
        }
        guard desired != snapshot.authorizedCapabilities else { return }
        let shouldRestoreClipboard = clipboardOptedInForSession &&
            desired.contains(.textClipboard)

        do {
            try await session.authorize(
                windowGeneration: selectedWindowGeneration,
                capabilities: desired
            )
            // SessionCoordinator invalidates queued protected media whenever
            // the authorization epoch changes. Force the next keyframe to
            // carry VideoConfig again instead of allowing the Viewer to keep
            // a stale decoder configuration.
            videoConfigSentGeneration = nil
            videoConfigSentAuthorizationGeneration = nil
            stateStore.update(session: await session.snapshot())
            if shouldRestoreClipboard, let inputRuntime {
                do {
                    try await inputRuntime.setClipboardEnabled(true)
                } catch {
                    // A lifecycle reset can race this reauthorization. If
                    // the local clipboard bridge cannot be re-enabled, do
                    // not leave the peer with an apparently authorized but
                    // unusable clipboard capability.
                    var fallback = desired
                    fallback.remove(.textClipboard)
                    try? await session.authorize(
                        windowGeneration: selectedWindowGeneration,
                        capabilities: fallback
                    )
                    stateStore.update(session: await session.snapshot())
                }
            }
        } catch {
            videoConfigSentGeneration = nil
            videoConfigSentAuthorizationGeneration = nil
            // The session loop will handle a failed peer. Keep the local
            // admission state synchronized with the latest session snapshot.
            stateStore.update(session: await session.snapshot())
        }
    }

    private func handle(_ message: MessagePayload, for session: SessionCoordinator) async {
        guard activeSession === session else { return }
        switch message {
        case let .windowSelection(selection):
            guard selection.windowGeneration == advertisedWindowGeneration,
                  selection.catalogGeneration == advertisedWindowCatalogGeneration,
                  let advertisedWindow = advertisedWindows.first(where: {
                      $0.identifier == selection.windowIdentifier && $0.eligible
                  }) else {
                scheduleTeardown(session: session)
                return
            }
            do {
                let windows = try await captureSession.discoverWindows()
                guard let window = windows.first(where: {
                    $0.identifier == selection.windowIdentifier && $0.eligible
                }),
                selection.catalogGeneration == advertisedWindowCatalogGeneration,
                let currentAdvertisedWindow = advertisedWindows.first(where: {
                    $0.identifier == selection.windowIdentifier && $0.eligible
                }),
                currentAdvertisedWindow.hasSameOwner(as: advertisedWindow),
                window.hasSameOwner(as: currentAdvertisedWindow) else {
                    scheduleTeardown(session: session)
                    return
                }
                if selectedWindow?.hasSameOwner(as: window) == true {
                    return
                }
                guard advertisedWindowGeneration < UInt64.max else {
                    scheduleTeardown(session: session)
                    return
                }
                // The selected-window generation fences input/media, while
                // catalogGeneration above fences the exact WindowList snapshot.
                // Both are required because WindowServer can reuse a numeric
                // ID after an app exits.
                let replacementGeneration = advertisedWindowGeneration &+ 1
                advertisedWindowGeneration = replacementGeneration
                try await activateSelection(
                    window,
                    generation: replacementGeneration,
                    session: session
                )
            } catch {
                scheduleTeardown(session: session)
            }
        case .close:
            scheduleTeardown(session: session)
        default:
            break
        }
    }

    /// `handle` is called by HostInputSessionLoop's single message consumer.
    /// Defer teardown until that callback returns; otherwise `stop()` would
    /// try to join the very task that is currently awaiting this callback.
    private func scheduleTeardown(session: SessionCoordinator) {
        Task { [weak self] in
            await self?.teardown(session: session)
        }
    }

    private func activateSelection(
        _ window: CaptureWindow,
        generation: UInt64,
        session: SessionCoordinator
    ) async throws {
        selectionTransitionInProgress = true
        defer { selectionTransitionInProgress = false }
        if let inputRuntime {
            await inputRuntime.selectionWillChange()
            do {
                try await activateSelectionBody(window, generation: generation, session: session)
            } catch {
                await inputRuntime.selectionDidChange()
                throw error
            }
            await inputRuntime.selectionDidChange()
            return
        }

        try await activateSelectionBody(window, generation: generation, session: session)
    }

    private func activateSelectionBody(
        _ window: CaptureWindow,
        generation: UInt64,
        session: SessionCoordinator
    ) async throws {

        await stopVideoPipeline()
        try await captureSession.start(windowIdentifier: window.identifier)
        let captureSnapshot = await captureSession.snapshot()
        // CaptureCore owns its internal engine generation. It advances that
        // value on every restart, including a same-session window switch. The
        // wire generation remains the advertised WindowList generation and is
        // intentionally validated separately above.
        guard case .capturing = captureSnapshot.state,
              captureSnapshot.selectedWindow?.identifier == window.identifier,
              let selected = captureSnapshot.selectedWindow else {
            throw HostRuntimeError.staleWindowGeneration
        }

        let negotiatedCapabilities = (await session.snapshot()).negotiatedCapabilities
        let negotiatedInput = negotiatedCapabilities.intersection(Self.inputCapabilities)
        let permission = await MainActor.run {
            let current = CoreGraphicsAccessibilityContextProvider.currentPermissionState()
            guard !negotiatedInput.isEmpty, current != .authorized else {
                return current
            }
            // Ask only after a Viewer has negotiated input and the operator has
            // selected a Host window. The signed Host bundle owns the TCC
            // request; a view-only session never receives this prompt.
            return CoreGraphicsAccessibilityContextProvider.requestPermission()
        }
        // Authorize only the capabilities both endpoints negotiated. A Viewer
        // may intentionally omit optional input or clipboard support; that
        // must degrade to view-only/partial control instead of rejecting the
        // entire selected window.
        var authorizedCapabilities = Self.capabilities.intersection(negotiatedCapabilities)
        if permission != .authorized {
            authorizedCapabilities.subtract(Self.inputCapabilities)
        }
        if !clipboardOptedInForSession {
            authorizedCapabilities.remove(.textClipboard)
        }

        // Selecting a listed application is explicit Viewer intent to use it
        // interactively. Bring its app to the Host foreground before the
        // authorization/focus checks; InputCore still rejects every event if
        // macOS does not confirm that the selected window is foreground.
        let didForegroundSelectedApplication = await bringSelectedApplicationToForeground(selected)
        if !didForegroundSelectedApplication {
            startupLogger.error(
                "Host could not confirm the selected application became foreground; input remains fail-closed"
            )
        }

        try await session.authorize(windowGeneration: generation, capabilities: authorizedCapabilities)
        selectedWindow = selected
        selectedWindowGeneration = generation
        videoConfigSentGeneration = nil
        videoConfigSentAuthorizationGeneration = nil
        stateStore.setSelection(
            HostInputWindowSelection(
                windowIdentifier: selected.identifier,
                processIdentifier: selected.processIdentifier,
                applicationIdentifier: selected.applicationIdentifier,
                generation: generation,
                bounds: InputWindowBounds(
                    originX: selected.bounds.x,
                    originY: selected.bounds.y,
                    width: selected.bounds.width,
                    height: selected.bounds.height
                )
            )
        )
        stateStore.update(session: await session.snapshot())

        // Re-publish the eligible list after every selection authorization so
        // the Viewer learns the new selection/authorization generation before
        // it can request another replacement. The catalog generation changes
        // only when the exact advertised window ownership set changes.
        let refreshedWindows = try await captureSession.discoverWindows()
        _ = try await publishWindowCatalog(refreshedWindows, to: session, force: true)

        if clipboardOptedInForSession {
            try await inputRuntime?.setClipboardEnabled(true)
        }

        let dimensions = CaptureConfiguration.default.outputDimensions(for: selected.bounds)
        let encoder = try H264Encoder(
            configuration: H264EncoderConfiguration(
                width: dimensions.width,
                height: dimensions.height,
                frameRate: 60,
                averageBitrate: 8_000_000,
                keyframeInterval: 60,
                maxInFlightFrames: 2
            )
        )
        try encoder.start(generation: generation)
        self.encoder = encoder
        videoConfigSentGeneration = nil
        videoConfigSentAuthorizationGeneration = nil
        try await session.send(
            .streamConfig(
                StreamConfigMessage(
                    width: dimensions.width,
                    height: dimensions.height,
                    frameRate: 60,
                    codec: .h264,
                    generation: generation
                )
            )
        )

        let frames = captureSession.frames
        captureTask = Task { [weak self, weak encoder] in
            var framesSinceKeyframe = 60
            do {
                for try await frame in frames {
                    guard !Task.isCancelled, let encoder else { return }
                    let forceKeyframe = framesSinceKeyframe >= 60
                    do {
                        try encoder.encode(
                            pixelBuffer: frame.pixelBuffer,
                            captureTimestamp: frame.captureTimestamp,
                            presentationTimestamp: frame.presentationTimestamp,
                            forceKeyframe: forceKeyframe,
                            completion: { [weak self] result in
                                Task { [weak self] in
                                    await self?.sendEncoded(result, generation: generation, session: session)
                                }
                            }
                        )
                        framesSinceKeyframe = forceKeyframe ? 0 : framesSinceKeyframe + 1
                    } catch {
                        // VideoToolbox queue pressure is handled by dropping
                        // the frame; the bounded CaptureCore stream provides
                        // the next opportunity for a keyframe.
                    }
                }
            } catch {
                await self?.captureDidEnd(session)
            }
        }

        // Clipboard sync is optional. Presenting its consent sheet must never
        // hold up the selected-window video path: authorize and stream the
        // picture first, then apply clipboard permission independently.
        if negotiatedCapabilities.contains(.textClipboard) {
            scheduleClipboardConsentPrompt(for: session)
        }
    }

    private func scheduleClipboardConsentPrompt(for session: SessionCoordinator) {
        guard !clipboardConsentPromptedForSession,
              activeSession === session else { return }
        clipboardConsentPromptedForSession = true
        clipboardConsentTask = Task { [weak self] in
            let consented = await HostClipboardPrompt.requestConsent(
                expiresAt: Date().addingTimeInterval(60),
                isSessionActive: {
                    let snapshot = await session.snapshot()
                    guard snapshot.authorized else { return false }
                    switch snapshot.state {
                    case .failed, .stopping, .reconnecting:
                        return false
                    default:
                        return true
                    }
                }
            )
            await self?.completeClipboardConsent(consented, for: session)
        }
    }

    private func completeClipboardConsent(
        _ consented: Bool,
        for session: SessionCoordinator
    ) async {
        guard activeSession === session else { return }
        clipboardConsentTask = nil
        guard consented,
              (await session.snapshot()).negotiatedCapabilities.contains(.textClipboard) else {
            return
        }
        clipboardOptedInForSession = true
        // The regular authorization monitor applies the new capability as
        // soon as the current selection transition has published its generation.
        guard !selectionTransitionInProgress else { return }
        await synchronizeInputAuthorization(session)
    }

    private func sendEncoded(
        _ result: Result<EncodedH264Frame, CodecError>,
        generation: UInt64,
        session: SessionCoordinator
    ) async {
        guard activeSession === session,
              selectedWindow != nil,
              case let .success(frame) = result,
              frame.generation == generation else { return }

        let snapshot = await session.snapshot()
        guard snapshot.authorized,
              snapshot.authorizedWindowGeneration == generation else {
            return
        }
        let authorizationGeneration = snapshot.authorizationGeneration
        if videoConfigSentAuthorizationGeneration != authorizationGeneration {
            // A Host authorization transition invalidates queued protected
            // media. The first keyframe admitted in the new epoch must carry
            // a fresh decoder configuration.
            videoConfigSentGeneration = nil
            videoConfigSentAuthorizationGeneration = authorizationGeneration
        }

        do {
            if videoConfigSentGeneration != generation {
                guard let decoderConfiguration = frame.decoderConfiguration else {
                    // Wait for the next keyframe. Non-keyframes cannot repair
                    // a decoder after the previous epoch was invalidated.
                    return
                }
                try await session.send(
                    .videoConfig(
                        VideoConfigMessage(
                            generation: generation,
                            decoderConfiguration: decoderConfiguration.encoded()
                        )
                    ),
                    expectedAuthorizationGeneration: authorizationGeneration
                )
                videoConfigSentGeneration = generation
            }
            guard videoConfigSentGeneration == generation else { return }
            try await session.send(
                .videoFrame(
                    VideoFrameMessage(
                        generation: generation,
                        captureTimestamp: frame.captureTimestamp,
                        presentationTimestamp: frame.presentationTimestamp,
                        width: frame.width,
                        height: frame.height,
                        keyframe: frame.keyframe,
                        accessUnit: frame.accessUnit
                    )
                ),
                flags: frame.keyframe ? [.keyframe] : [],
                expectedAuthorizationGeneration: authorizationGeneration
            )
        } catch let error as SessionError {
            switch error {
            case .authorizationChanged, .reconnectRequired:
                // This is a normal race with authorization/reconnect. The
                // next admitted keyframe will rebuild VideoConfig for the
                // current epoch; do not freeze the capture pipeline.
                videoConfigSentGeneration = nil
                videoConfigSentAuthorizationGeneration = nil
            default:
                startupLogger.error(
                    "Host video send failed (generation: \(generation, privacy: .public), error: \(error.description, privacy: .public))"
                )
                await stopVideoPipelineIfCurrent(session)
            }
        } catch {
            startupLogger.error(
                "Host video send failed (generation: \(generation, privacy: .public), error: \(String(describing: error), privacy: .public))"
            )
            await stopVideoPipelineIfCurrent(session)
        }
    }

    @MainActor
    private func bringSelectedApplicationToForeground(_ window: CaptureWindow) async -> Bool {
        guard let application = NSRunningApplication(processIdentifier: window.processIdentifier),
              application.activationPolicy == .regular else {
            return false
        }
        _ = application.activate(options: [.activateIgnoringOtherApps])
        for _ in 0 ..< 20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == window.processIdentifier {
                return true
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == window.processIdentifier
    }

    private func stopVideoPipelineIfCurrent(_ session: SessionCoordinator) async {
        guard activeSession === session else { return }
        await stopVideoPipeline()
    }

    /// Called by the capture task itself. It must not await the task stored in
    /// `captureTask`, otherwise an end-of-stream error would wait on itself.
    private func captureDidEnd(_ session: SessionCoordinator) {
        guard activeSession === session else { return }
        captureTask = nil
        encoder?.reset()
        encoder = nil
        videoConfigSentGeneration = nil
        videoConfigSentAuthorizationGeneration = nil
    }

    private func stopVideoPipeline() async {
        captureTask?.cancel()
        await captureSession.stop()
        if let captureTask {
            await captureTask.value
        }
        captureTask = nil
        encoder?.reset()
        encoder = nil
        videoConfigSentGeneration = nil
        videoConfigSentAuthorizationGeneration = nil
    }

    private func teardown(session: SessionCoordinator) async {
        guard activeSession === session else { return }
        await stopActiveSession()
        publish(.listening)
    }

    private static func descriptor(_ window: CaptureWindow) -> WindowDescriptor {
        WindowDescriptor(
            identifier: window.identifier,
            applicationIdentifier: window.applicationIdentifier,
            title: window.title,
            width: UInt32(max(1, window.bounds.width.rounded())),
            height: UInt32(max(1, window.bounds.height.rounded())),
            eligible: window.eligible
        )
    }

    /// Publishes a catalog snapshot and returns whether a wire message was
    /// sent. The catalog generation is advanced before the await so a queued
    /// selection from the previous snapshot fails closed while the new list is
    /// in flight. A send failure tears down the session at the caller.
    @discardableResult
    private func publishWindowCatalog(
        _ windows: [CaptureWindow],
        to session: SessionCoordinator,
        force: Bool = false
    ) async throws -> Bool {
        let changed = advertisedWindowCatalogGeneration == 0 || windows != advertisedWindows
        guard changed || force else { return false }

        if changed {
            guard advertisedWindowCatalogGeneration < UInt64.max else {
                throw HostRuntimeError.staleWindowGeneration
            }
            advertisedWindowCatalogGeneration = advertisedWindowCatalogGeneration == 0
                ? 1
                : advertisedWindowCatalogGeneration &+ 1
            advertisedWindows = windows
        }

        let message = WindowListMessage(
            windows: windows.map(Self.descriptor),
            catalogGeneration: advertisedWindowCatalogGeneration
        )
        try await session.send(.windowList(message))
        return true
    }
}

private func hostRuntimeErrorCode(_ error: HostRuntimeError) -> String {
    switch error {
    case .configuration: return "configuration"
    case .permission: return "screen-recording"
    case .localNetwork: return "local-network"
    case .listener: return "listener"
    case .sessionEnded: return "session-ended"
    case .sessionTimedOut: return "session-timeout"
    case .pairingTimedOut: return "pairing-timeout"
    case .staleWindowGeneration: return "stale-window"
    }
}

private func hostBonjourErrorCode(_ error: BonjourDiscoveryStartupError) -> String {
    switch error {
    case .failed: return "failed"
    case .cancelled: return "cancelled"
    case .timedOut: return "timed-out"
    }
}

enum HostRuntimeError: Error, CustomStringConvertible, Sendable {
    case configuration(String)
    case permission(String)
    case localNetwork(String)
    case listener(String)
    case sessionEnded
    case sessionTimedOut
    case pairingTimedOut
    case staleWindowGeneration

    var status: HostRuntimeStatus {
        switch self {
        case .permission:
            return .needsScreenRecording
        case .localNetwork:
            return .needsLocalNetwork
        case .listener:
            return .listenerFailed
        case .configuration, .sessionEnded, .sessionTimedOut, .pairingTimedOut, .staleWindowGeneration:
            return .failed
        }
    }

    var description: String {
        switch self {
        case let .configuration(message), let .permission(message), let .localNetwork(message), let .listener(message): return message
        case .sessionEnded: return "Host session ended before the Viewer was ready"
        case .sessionTimedOut: return "Host session capability negotiation timed out"
        case .pairingTimedOut: return "Host pairing confirmation timed out"
        case .staleWindowGeneration: return "selected window generation changed during capture setup"
        }
    }
}

private final class HostInputStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionStateValue = HostInputSessionState(
        authorized: false,
        authorizedWindowGeneration: nil,
        mouseInputEnabled: false,
        keyboardInputEnabled: false
    )
    private var selectedWindow: HostInputWindowSelection?

    func update(session snapshot: SessionSnapshot) {
        lock.withLock {
            sessionStateValue = HostInputSessionState(
                authorized: snapshot.authorized,
                authorizedWindowGeneration: snapshot.authorizedWindowGeneration,
                mouseInputEnabled: snapshot.authorizedCapabilities.contains(.mouseInput),
                keyboardInputEnabled: snapshot.authorizedCapabilities.contains(.keyboardInput)
            )
        }
    }

    func setSelection(_ selection: HostInputWindowSelection) {
        lock.withLock { selectedWindow = selection }
    }

    func clearSelection() {
        lock.withLock { selectedWindow = nil }
    }

    func sessionState() -> HostInputSessionState {
        lock.withLock { sessionStateValue }
    }

    func selection() -> HostInputWindowSelection? {
        lock.withLock { selectedWindow }
    }
}
