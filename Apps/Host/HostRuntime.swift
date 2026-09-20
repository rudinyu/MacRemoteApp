import AppKit
import CaptureCore
import CodecCore
import Foundation
import InputCore
import RemoteProtocol
import SecurityCore
import TransportCore

private enum HostPairingPromptOutcome: Sendable {
    case consent(Bool)
    case sessionEnded
}

/// The production Host composition for the V1 vertical slice.
///
/// The shared packages remain responsible for capture, encoding, transport,
/// authorization, and input policy. This actor only owns their lifecycle and
/// the selected-window state that ties them together. There is intentionally
/// one active Viewer and one selected window per Host session.
actor HostRuntime {
    struct Configuration: Sendable {
        let serviceName: String
        let peerCertificateURL: URL?
        let identityLabel: String

        static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Configuration {
            let peerCertificateURL = environment["MACREMOTEAPP_PEER_CERT"]
                .flatMap { path in path.isEmpty ? nil : URL(fileURLWithPath: path) }
            return Configuration(
                serviceName: environment["MACREMOTEAPP_SERVICE_NAME"] ?? "MacRemoteApp-Host",
                peerCertificateURL: peerCertificateURL,
                identityLabel: environment["MACREMOTEAPP_LOCAL_IDENTITY_LABEL"] ?? KeychainIdentityProvider.defaultLabel
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

    private let configuration: Configuration
    private let windowProvider: ScreenRecordingWindowProvider
    private let captureSession: WindowCaptureSession
    private let stateStore = HostInputStateStore()

    private var listener: NetworkBonjourListener?
    private var localIdentity: ProvisionedIdentity?
    private var activeSession: SessionCoordinator?
    private var inputRuntime: HostInputSessionRuntime?
    private var sessionMonitor: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var encoder: H264Encoder?
    private var selectedWindow: CaptureWindow?
    private var advertisedWindowGeneration: UInt64 = 1
    private var videoConfigSentGeneration: UInt64?

    init(
        configuration: Configuration,
        windowProvider: ScreenRecordingWindowProvider = ScreenRecordingWindowProvider(),
        captureSession: WindowCaptureSession? = nil
    ) {
        self.configuration = configuration
        self.windowProvider = windowProvider
        self.captureSession = captureSession ?? WindowCaptureSession(windowProvider: windowProvider)
    }

    func run() async throws {
        let permission = await captureSession.permissionState()
        guard permission == .authorized else {
            throw HostRuntimeError.permission("Screen Recording permission is not authorized")
        }

        let localIdentity = try await loadLocalIdentity()
        self.localIdentity = localIdentity
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
        listener.onConnection = { [weak self] transport in
            Task { [weak self] in
                await self?.accept(transport)
            }
        }
        self.listener = listener
        listener.start()
        print("MacRemoteApp Host listening for one paired Viewer")

        do {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch is CancellationError {
            // Run the same teardown path as an orderly stop so input cleanup
            // and capture shutdown are completed before the process exits.
        }
        await stop()
    }

    func stop() async {
        sessionMonitor?.cancel()
        sessionMonitor = nil
        await stopVideoPipeline()
        await inputRuntime?.stop()
        inputRuntime = nil
        if let activeSession {
            await activeSession.stop(reason: .normal)
        }
        activeSession = nil
        selectedWindow = nil
        stateStore.clearSelection()
        listener?.cancel()
        listener = nil
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
        return try await KeychainIdentityProvider(label: configuration.identityLabel).load()
    }

    private func accept(_ transport: NetworkFramedTransport) async {
        guard activeSession == nil, let localIdentity else {
            await transport.close()
            return
        }

        let pairingCoordinator = PairingCoordinator(
            localIdentity: localIdentity.peerIdentity,
            trustStore: KeychainTrustStore()
        )

        let session = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "MacRemoteApp-Host-M10",
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
            try await session.send(.windowList(.init(windows: windows.map(Self.descriptor))))
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
        while !Task.isCancelled {
            let snapshot = await session.snapshot()
            switch snapshot.state {
            case .trusted, .capabilitiesNegotiated, .windowSelectionAuthorized,
                 .streaming:
                return
            case .pairingRequired:
                if let challenge = await pairingCoordinator.pendingChallenge(),
                   promptedChallengeID != challenge.challengeID {
                    let consent = await pairingCoordinator.consentState()
                    guard consent?.localConsent != true else {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }
                    promptedChallengeID = challenge.challengeID
                    let outcome = await withTaskGroup(of: HostPairingPromptOutcome.self) { group in
                        group.addTask {
                            let accepted = await HostPairingPrompt.requestConsent(
                                confirmationCode: challenge.confirmationCode,
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
                        accepted: accepted,
                        displayName: "MacRemoteApp Viewer"
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
        while !Task.isCancelled {
            let snapshot = await session.snapshot()
            stateStore.update(session: snapshot)
            if snapshot.state == .failed || snapshot.state == .stopping {
                await teardown(session: session)
                return
            }
            if selectedWindow != nil {
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
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func handle(_ message: MessagePayload, for session: SessionCoordinator) async {
        guard activeSession === session else { return }
        switch message {
        case let .windowSelection(selection):
            guard selection.windowGeneration == advertisedWindowGeneration,
                  selectedWindow == nil else {
                scheduleTeardown(session: session)
                return
            }
            do {
                let windows = try await captureSession.discoverWindows()
                guard let window = windows.first(where: {
                    $0.identifier == selection.windowIdentifier && $0.eligible
                }) else {
                    scheduleTeardown(session: session)
                    return
                }
                try await activateSelection(window, generation: selection.windowGeneration, session: session)
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
        guard captureSnapshot.generation == generation,
              case .capturing = captureSnapshot.state,
              let selected = captureSnapshot.selectedWindow else {
            throw HostRuntimeError.staleWindowGeneration
        }
        selectedWindow = selected
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

        try await session.authorize(windowGeneration: generation, capabilities: Self.capabilities)
        stateStore.update(session: await session.snapshot())

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
        do {
            if videoConfigSentGeneration != generation,
               let decoderConfiguration = frame.decoderConfiguration {
                try await session.send(
                    .videoConfig(
                        VideoConfigMessage(
                            generation: generation,
                            decoderConfiguration: decoderConfiguration.encoded()
                        )
                    )
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
                flags: frame.keyframe ? [.keyframe] : []
            )
        } catch {
            await stopVideoPipelineIfCurrent(session)
        }
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
    }

    private func teardown(session: SessionCoordinator) async {
        guard activeSession === session else { return }
        sessionMonitor?.cancel()
        sessionMonitor = nil
        await stopVideoPipeline()
        await inputRuntime?.stop()
        inputRuntime = nil
        await session.stop(reason: .normal)
        activeSession = nil
        selectedWindow = nil
        stateStore.clearSelection()
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
}

enum HostRuntimeError: Error, CustomStringConvertible, Sendable {
    case configuration(String)
    case permission(String)
    case sessionEnded
    case sessionTimedOut
    case pairingTimedOut
    case staleWindowGeneration

    var description: String {
        switch self {
        case let .configuration(message), let .permission(message): return message
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
