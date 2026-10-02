import AppKit
import AppSupport
import CodecCore
import Foundation
import InputCore
import MetalKit
import RemoteProtocol
import SecurityCore
import TransportCore

private enum ViewerPairingPromptOutcome: Sendable {
    case consent(accepted: Bool)
    case sessionEnded
}

private let viewerApplicationMetadata = ApplicationMetadata(bundle: .main)
private let viewerProtocolVersion = "\(ProtocolVersion.current.major).\(ProtocolVersion.current.minor)"

/// Minimal production Viewer composition. The UI is intentionally small, but
/// the data path is real: Bonjour -> authenticated SessionCoordinator -> H264
/// decoder -> Metal, with the same content rectangle used for input mapping.
@MainActor
final class ViewerRuntime: NSObject, NSApplicationDelegate, NSWindowDelegate {
    struct Configuration: Sendable {
        static let defaultIdentityLabel = "MacRemoteApp.viewer"
        static let defaultTrustStoreService = "com.rudinyu.MacRemoteApp.Viewer.trust"

        let hostName: String?
        let peerCertificateURL: URL?
        let identityLabel: String

        static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Configuration {
            let peerCertificateURL = environment["MACREMOTEAPP_PEER_CERT"]
                .flatMap { path in path.isEmpty ? nil : URL(fileURLWithPath: path) }
            let identityLabel = environment["MACREMOTEAPP_LOCAL_IDENTITY_LABEL"]
                .map { "\($0).viewer" } ?? defaultIdentityLabel
            return Configuration(
                hostName: environment["MACREMOTEAPP_HOST_NAME"],
                peerCertificateURL: peerCertificateURL,
                identityLabel: identityLabel
            )
        }
    }

    private enum ConnectResult {
        case connected
        case retryableFailure
        case pairingDenied
    }

    private static let capabilities: Set<Capability> = [
        .pingPong,
        .windowSelection,
        .h264Video,
        .mouseInput,
        .keyboardInput,
        .textClipboard,
        .keyframeRequest,
        .receiverReport
    ]

    private static var localDeviceName: String {
        let shortName = ProcessInfo.processInfo.hostName
            .split(separator: ".", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        guard !shortName.isEmpty,
              shortName.utf8.count <= HelloMessage.maximumDeviceNameUTF8Bytes,
              shortName.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return "MacRemoteApp Viewer"
        }
        return shortName
    }

    private let configuration: Configuration
    private let discovery = NetworkBonjourDiscovery()
    private let decoder = H264Decoder()
    private var identityEnrollmentTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var discoveryStateTask: Task<Void, Never>?
    private var sessionMonitorTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var discoveredServices: [DiscoveredService] = []
    private var lastDiscoveredService: DiscoveredService?
    private var selectedServiceIdentifier: String?
    private var pairingRetryRequired = false
    private var inputSendTail: Task<Void, Never>?
    private var session: SessionCoordinator?
    private var messageLoop: ViewerSessionMessageLoop?
    private var inputTransport: ViewerInputTransport?
    private var contentView: ViewerContentView?
    private var renderer: MetalVideoRenderer?
    private var window: NSWindow?
    private var applicationMenu: ApplicationMenu?
    private var settingsView: SettingsView?
    private var isShowingSettings = false
    private var discoveryStatus = "Not started" {
        didSet { refreshSettings() }
    }
    private var localIdentity: ProvisionedIdentity?
    private var selectedGeneration: UInt64?
    private var selectedWindowIdentifier: UInt64?
    private var pendingWindowSelection: (identifier: UInt64, catalogGeneration: UInt64)?
    private var streamGenerationGate = StreamGenerationGate()
    private var streamDimensions: CGSize = .zero
    private var windowSelectionInFlight = false
    private var presentedFrameCount = 0
    private var presentedFrameTimes: [TimeInterval] = []
    private var lastPresentedFrameTime: TimeInterval?
    private var presentedFPSIsIdle = false
    private var reportedVideoFailureGeneration: UInt64?
    private var performanceCollector = BoundedPresentationSampleCollector()
    private var latestPerformanceSnapshot: PresentationSampleSnapshot?
    /// M8 stage budget evidence: Viewer receipt to drawable presentation.
    /// Receipt times are keyed by the frame's capture timestamp and bounded.
    private var pendingFrameReceiptNanoseconds: [UInt64: UInt64] = [:]
    private static let maximumPendingFrameReceipts = 16
    private var receiveToPresentCollector = BoundedStageLatencyCollector()
    private var stageLogTick = 0
    private static let stageLogTickInterval = 100
    private var latestClockSyncEstimate: ClockSyncEstimate?
    private var hostInputPermission: PermissionState = .unknown
    private var hostInputFocusEligible = false
    private var hostInputStatusGeneration: UInt64?
    private var isShuttingDown = false

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = self
        makeWindow()
        let menu = ApplicationMenu(
            applicationName: "MacRemoteApp Viewer",
            metadata: viewerApplicationMetadata,
            onSettings: { [weak self] in self?.showSettings() },
            onShowWindow: { [weak self] in self?.showViewerWindow() }
        )
        applicationMenu = menu
        menu.install()
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        identityEnrollmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                localIdentity = try await loadLocalIdentity()
                guard ViewerStartupOnboarding.prepareLocalNetwork() else {
                    setStatus("Local Network setup is required before Host discovery")
                    return
                }
                setStatus("Searching for a MacRemoteApp Host…")
                startDiscovery()
            } catch {
                macRemoteAppStartupLogger.error(
                    "MacRemoteApp Viewer local identity setup failed (code: \(viewerStartupErrorCode(error), privacy: .public))"
                )
                setStatus("Local identity setup failed; check Keychain access and relaunch")
            }
            identityEnrollmentTask = nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        identityEnrollmentTask?.cancel()
        Task { @MainActor [weak self] in
            await self?.disconnect()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func startDiscovery() {
        guard discoveryTask == nil, discoveryStateTask == nil, !isShuttingDown else { return }
        discoveryStatus = "Starting Bonjour discovery"
        let updates = discovery.updates
        let stateUpdates = discovery.stateUpdates
        discoveryStateTask = Task { @MainActor [weak self] in
            var iterator = stateUpdates.makeAsyncIterator()
            while !Task.isCancelled, let state = await iterator.next() {
                guard let self, !self.isShuttingDown else { return }
                switch state {
                case .setup:
                    break
                case let .waiting(code):
                    self.discoveryStatus = "Waiting for Local Network (\(code))"
                    self.setStatus("Waiting for Local Network access (\(code))…")
                case .ready:
                    self.discoveryStatus = "Bonjour browser ready"
                    ViewerStartupOnboarding.markLocalNetworkReady()
                    if self.session == nil {
                        self.setStatus("Select a MacRemoteApp Host…")
                    }
                case let .failed(code):
                    self.discoveryStatus = "Discovery failed (\(code))"
                    self.setStatus("Local Network discovery failed (\(code)); enable MacRemoteApp Viewer in System Settings")
                case .cancelled:
                    self.discoveryStatus = "Stopped"
                    return
                }
            }
        }
        discovery.start()
        discoveryTask = Task { @MainActor [weak self] in
            var iterator = updates.makeAsyncIterator()
            while !Task.isCancelled, let services = await iterator.next() {
                guard let self, !self.isShuttingDown else {
                    continue
                }
                let matchingServices = services.filter { service in
                    guard let hostName = self.configuration.hostName else { return true }
                    return service.name == hostName
                }
                self.discoveredServices = matchingServices
                self.contentView?.setHostOptions(matchingServices)

                guard let selectedServiceIdentifier = self.selectedServiceIdentifier else {
                    self.lastDiscoveredService = nil
                    if matchingServices.isEmpty {
                        self.setStatus("No MacRemoteApp Host found")
                    } else {
                        self.setStatus("Select a MacRemoteApp Host to connect")
                    }
                    continue
                }
                guard let service = matchingServices.first(where: {
                    $0.identifier == selectedServiceIdentifier
                }) else {
                    self.lastDiscoveredService = nil
                    self.setStatus("Selected Host is unavailable; choose another Host")
                    continue
                }
                self.lastDiscoveredService = service
                guard self.session == nil, self.reconnectTask == nil else { continue }
                guard !self.pairingRetryRequired else { continue }
                // A previously selected Host may reappear after a network
                // interruption. Initial connection is always explicit; only a
                // previously selected Host is eligible for reconnect.
                self.scheduleReconnect(immediate: true)
            }
            // State updates own the actionable failure text. Do not overwrite
            // a policy-denied or DNS-specific reason merely because the
            // results stream finished after Network.framework failed.
        }
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        NSApplication.shared.terminate(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isShowingSettings else { return true }
        showViewerWindow()
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if window?.isMiniaturized == true { window?.deminiaturize(nil) }
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    private func showViewerWindow() {
        isShowingSettings = false
        window?.contentView = contentView
        window?.title = "MacRemoteApp Viewer — Version \(viewerApplicationMetadata.displayVersionDetails)"
        if let contentView { window?.makeFirstResponder(contentView.surface) }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        if settingsView == nil {
            let controller = SettingsView(
                title: "Viewer Settings",
                subtitle: "Current connection details and controls for this Viewer.",
                metadata: viewerApplicationMetadata,
                sections: [
                    .init("Connection", fields: [
                        .init("connection", "Status"), .init("host", "Host"),
                        .init("transport", "Transport", "LAN / TLS"),
                        .init("discovery", "Local discovery"), .init("latency", "Round-trip time"),
                        .init("input", "Remote input"), .init("message", "Details")
                    ]),
                    .init("Session settings", fields: [
                        .init("filter", "Host filter", configuration.hostName ?? "All LAN Hosts"),
                        .init("pairing", "Trust", configuration.peerCertificateURL == nil ? "Pairing saved in Keychain" : "Pinned certificate override"),
                        .init("reconnect", "Reconnect", "Automatic for the selected Host"),
                        .init("clipboard", "Text clipboard")
                    ])
                ]
            )
            controller.addAction("back", title: "← Back to Remote View", atTop: true) { [weak self] in
                self?.showViewerWindow()
            }
            controller.addAction("clipboard", title: "Share text clipboard for this session", checkbox: true) { [weak self] in
                self?.toggleClipboard()
            }
            controller.addNote("Clipboard sharing requires consent on both Macs and resets when the session ends. Local discovery reflects browser activity; macOS manages the permission.")
            controller.addAction("network", title: "Local Network Settings…") {
                ViewerStartupOnboarding.openLocalNetworkSettings()
            }
            controller.addAction("forget", title: "Forget saved pairings…") { [weak self] in
                self?.forgetSavedPairings()
            }
            settingsView = controller
        }
        refreshSettings()
        isShowingSettings = true
        window?.contentView = settingsView
        window?.title = "Viewer Settings — Version \(viewerApplicationMetadata.displayVersionDetails)"
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func refreshSettings() {
        guard let settingsView, let contentView else { return }
        for (key, value) in contentView.settingsValues {
            settingsView.setValue(value, for: key)
        }
        settingsView.setValue(discoveryStatus, for: "discovery")
        settingsView.setAction("clipboard", enabled: contentView.clipboardAvailable, checked: contentView.clipboardEnabled)
    }

    private func makeWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let content = ViewerContentView(frame: frame)
        content.onInputEvent = { [weak self] record in
            self?.enqueueInput(record)
        }
        content.onHostSelection = { [weak self] index in
            self?.selectHost(at: index)
        }
        content.onWindowSelection = { [weak self] windowIdentifier, generation, catalogGeneration in
            self?.selectWindow(
                windowIdentifier,
                generation: generation,
                catalogGeneration: catalogGeneration
            )
        }
        content.onPairingRetry = { [weak self] in
            self?.retryPairing()
        }
        content.onForgetPairings = { [weak self] in
            self?.forgetSavedPairings()
        }
        content.onClipboardToggle = { [weak self] in
            self?.toggleClipboard()
        }
        content.onInputRejected = { [weak self] error in
            self?.setStatus(error.description)
        }
        contentView = content
        content.onSettingsChange = { [weak self] in self?.refreshSettings() }

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacRemoteApp Viewer — Version \(viewerApplicationMetadata.displayVersionDetails)"
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 560)
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content.surface)

        if let renderer = MetalVideoRenderer(view: content.videoView) {
            self.renderer = renderer
            renderer.onFramePresented = { [weak self] generation, captureTimestamp, presentedTimestamp, presentationUptime in
                guard let self,
                      self.selectedGeneration == generation,
                      self.streamGenerationGate.accepts(generation) else { return }
                self.recordPresentation(
                    captureTimestamp: captureTimestamp,
                    presentedTimestamp: presentedTimestamp,
                    presentationUptime: presentationUptime
                )
                self.contentView?.markFramePresented()
            }
        } else {
            macRemoteAppStartupLogger.error(
                "MacRemoteApp Viewer could not create a Metal device or command queue"
            )
        }
        content.updateStream(size: .zero, readiness: .awaitingAuthentication)
    }

    private func selectHost(at index: Int) {
        guard index >= 0,
              index < discoveredServices.count,
              session == nil,
              reconnectTask == nil else { return }
        let service = discoveredServices[index]
        selectedServiceIdentifier = service.identifier
        lastDiscoveredService = service
        // Choosing a Host is an explicit operator action and is therefore
        // allowed to retry a previously denied pairing challenge.
        pairingRetryRequired = false
        contentView?.setHostSelectionEnabled(false)
        contentView?.setConnectionState(.connecting)
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await connect(to: service) {
            case .connected:
                break
            case .pairingDenied:
                break
            case .retryableFailure:
                scheduleReconnect()
            }
        }
    }

    private func connect(
        to service: DiscoveredService,
        reconnecting: Bool = false
    ) async -> ConnectResult {
        guard session == nil, !isShuttingDown else { return .retryableFailure }
        contentView?.setConnectionState(reconnecting ? .reconnecting : .connecting)
        contentView?.setPeerName(service.name)
        contentView?.setPairingRetryVisible(false)
        do {
            let localIdentity = try await loadLocalIdentity()
            let authenticationMode: TLSAuthenticationMode
            if let peerCertificateURL = configuration.peerCertificateURL {
                let peerIdentity = try PublicCertificateIdentity.load(from: peerCertificateURL)
                authenticationMode = .trusted(
                    TrustedPeer(identity: peerIdentity, displayName: service.name)
                )
            } else {
                authenticationMode = .pairingBootstrap(expectedPeer: nil)
            }
            let tlsOptions = TLSOptions(
                mode: authenticationMode,
                localIdentity: localIdentity.secIdentity
            )
            let transport = try NetworkFramedTransport(
                endpoint: service.endpoint,
                tlsOptions: tlsOptions
            )
            let pairingCoordinator = PairingCoordinator(
                localIdentity: localIdentity.peerIdentity,
                trustStore: KeychainTrustStore(service: Configuration.defaultTrustStoreService)
            )
            let session = SessionCoordinator(
                configuration: SessionConfiguration(
                    role: .viewer,
                    implementationIdentifier: "MacRemoteApp-Viewer-M10",
                    deviceName: Self.localDeviceName,
                    capabilities: Self.capabilities,
                    mandatoryCapabilities: [.pingPong],
                    maxVideoWidth: 1920,
                    maxVideoHeight: 1080,
                    maxFrameRate: 60
                ),
                transport: transport,
                pairingCoordinator: pairingCoordinator
            )
            self.session = session
            self.inputTransport = ViewerInputTransport(session: session)
            let loop = ViewerSessionMessageLoop(session: session) { [weak self] message in
                await self?.handle(message)
            }
            loop.onClipboardStatusChange = { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.refreshInputSurface()
                }
            }
            messageLoop = loop
            loop.start()
            contentView?.updateStream(size: .zero, readiness: .awaitingAuthentication)
            try await session.start()
            try await waitForPairing(session, pairingCoordinator: pairingCoordinator)
            let sessionSnapshot = await session.snapshot()
            contentView?.setPeerName(sessionSnapshot.peerDeviceName ?? service.name)
            sessionMonitorTask = Task { @MainActor [weak self] in
                await self?.monitorSession(session)
            }
            contentView?.setConnectionState(.connected)
            setStatus("Connected; waiting for a selected window")
            contentView?.setPairingRetryVisible(false)
            await refreshInputSurface()
            return .connected
        } catch let error as SessionError {
            if error == .pairingDenied {
                pairingRetryRequired = true
                setStatus("Pairing was denied; click Retry pairing to try again")
                contentView?.setPairingRetryVisible(true)
            } else {
                setStatus("Connection unavailable; check trusted identities and Local Network permission")
                contentView?.setPairingRetryVisible(false)
            }
            await resetSession()
            if reconnecting, error != .pairingDenied {
                contentView?.setConnectionState(.reconnecting)
                contentView?.setHostSelectionEnabled(false)
            }
            return error == .pairingDenied ? .pairingDenied : .retryableFailure
        } catch {
            setStatus("Connection unavailable; check trusted identities and Local Network permission")
            contentView?.setPairingRetryVisible(false)
            await resetSession()
            if reconnecting {
                contentView?.setConnectionState(.reconnecting)
                contentView?.setHostSelectionEnabled(false)
            }
            return .retryableFailure
        }
    }

    private func monitorSession(_ observedSession: SessionCoordinator) async {
        var previous = await observedSession.snapshot()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            guard session === observedSession else { return }
            let current = await observedSession.snapshot()
            refreshPresentedFPS(now: ProcessInfo.processInfo.systemUptime)
            latestClockSyncEstimate = await observedSession.clockSyncEstimate()
            contentView?.setConnectionLatency(latestClockSyncEstimate)
            latestPerformanceSnapshot = performanceCollector.snapshot(
                clockSync: latestClockSyncEstimate
            )
            logStageBudgetIfDue()
            if current.authorizationGeneration != previous.authorizationGeneration ||
                current.authorized != previous.authorized ||
                current.authorizedWindowGeneration != previous.authorizedWindowGeneration ||
                current.authorizedCapabilities != previous.authorizedCapabilities {
                await refreshInputSurface()
            }
            previous = current
            guard current.state == .failed else { continue }

            // This task owns the failure transition, so resetSession must not
            // cancel and join this task recursively.
            sessionMonitorTask = nil
            await resetSession(cancelMonitor: false)
            scheduleReconnect()
            return
        }
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard reconnectTask == nil, !isShuttingDown else { return }
        guard !pairingRetryRequired else { return }
        guard let service = lastDiscoveredService else {
            setStatus("Connection lost; rediscover the Host to reconnect")
            return
        }

        setStatus("Connection lost; reconnecting…")
        contentView?.setConnectionState(.reconnecting)
        contentView?.setHostSelectionEnabled(false)
        reconnectTask = Task { @MainActor [weak self] in
            let delays: [UInt64] = immediate ? [0, 1, 2, 3, 4] : [1, 2, 3, 4, 5]
            for delay in delays {
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    } catch {
                        return
                    }
                }
                guard let self, self.session == nil else { return }
                switch await self.connect(to: service, reconnecting: true) {
                case .connected:
                    self.reconnectTask = nil
                    return
                case .pairingDenied:
                    self.reconnectTask = nil
                    return
                case .retryableFailure:
                    continue
                }
            }
            guard let self, self.session == nil else { return }
            self.reconnectTask = nil
            self.contentView?.setConnectionState(.disconnected)
            self.contentView?.setHostSelectionEnabled(true)
            self.setStatus("Host unavailable; start the Viewer to retry")
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
            case .trusted, .capabilitiesNegotiated, .windowSelectionAuthorized, .streaming:
                return
            case .pairingRequired:
                setStatus("Confirm pairing on both Macs")
                if let challenge = await pairingCoordinator.pendingChallenge(),
                   challenge.isVerificationReady,
                   promptedChallengeID != challenge.challengeID {
                    let consent = await pairingCoordinator.consentState()
                    guard consent?.localConsent != true else {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }
                    promptedChallengeID = challenge.challengeID
                    let parentWindow = window
                    let outcome = await withTaskGroup(of: ViewerPairingPromptOutcome.self) { group in
                        group.addTask {
                            let accepted = await ViewerPairingPrompt.requestConsent(
                                confirmationCode: challenge.confirmationCode,
                                peerName: (await session.snapshot()).peerDeviceName,
                                parentWindow: parentWindow,
                                expiresAt: challenge.expiresAt
                            )
                            return .consent(accepted: accepted)
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
                    switch outcome {
                    case .consent(accepted: true):
                        try await session.confirmPairing(
                            confirmationCode: challenge.confirmationCode,
                            accepted: true
                        )
                    case .consent(accepted: false):
                        try await session.confirmPairing(
                            confirmationCode: "",
                            accepted: false
                        )
                    case .sessionEnded:
                        throw await session.failureReason() ?? .pairingFailed
                    }
                }
            case .failed, .stopping:
                throw await session.failureReason() ?? .pairingFailed
            case .discovered, .authenticated, .connecting, .reconnecting:
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SessionError.handshakeTimeout
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
        if let localIdentity {
            return localIdentity
        }
        let identity = try await KeychainIdentityProvider(label: configuration.identityLabel).loadOrCreate()
        self.localIdentity = identity
        return identity
    }

    private func handle(_ message: MessagePayload) async {
        switch message {
        case let .windowList(windowList):
            guard let session,
                  let generation = (await session.snapshot()).authorizedWindowGeneration else {
                await refreshInputSurface()
                return
            }
            let selectionWasRejected = pendingWindowSelection.map {
                $0.catalogGeneration != windowList.catalogGeneration
            } ?? false
            if selectionWasRejected {
                pendingWindowSelection = nil
                selectedWindowIdentifier = nil
                contentView?.setWindowSelectionEnabled(true)
            }
            let eligibleWindows = windowList.windows.filter(\.eligible)
            contentView?.setWindowOptions(
                eligibleWindows,
                generation: generation,
                catalogGeneration: windowList.catalogGeneration,
                selectedIdentifier: selectedWindowIdentifier
            )
            if eligibleWindows.isEmpty {
                setStatus("Connected — Host has no eligible windows")
            } else if selectionWasRejected {
                setStatus("Host window list changed — select a window again")
            } else if selectedWindowIdentifier != nil {
                setStatus(selectedGeneration == nil ? "Connected — starting video" : "Receiving video")
            } else {
                setStatus("Connected — select a Host window to start video")
            }
            await refreshInputSurface()
            if selectionWasRejected {
                setStatus("Host window list changed — select a window again")
            }

        case let .streamConfig(config):
            guard config.codec == .h264 else {
                setStatus("Unsupported video codec")
                return
            }
            selectedGeneration = config.generation
            pendingWindowSelection = nil
            streamGenerationGate.advance(to: config.generation)
            streamDimensions = CGSize(width: CGFloat(config.width), height: CGFloat(config.height))
            reportedVideoFailureGeneration = nil
            resetPresentedFPS()
            performanceCollector.reset()
            latestPerformanceSnapshot = nil
            receiveToPresentCollector.reset()
            pendingFrameReceiptNanoseconds.removeAll()
            decoder.reset()
            contentView?.updateStream(size: streamDimensions, readiness: .awaitingAuthorization)
            contentView?.setWindowSelectionEnabled(true)
            await refreshInputSurface()
            setStatus("Receiving video")

        case let .videoConfig(config):
            guard config.generation == selectedGeneration else { return }
            do {
                let decoderConfiguration = try H264DecoderConfiguration.decode(config.decoderConfiguration)
                try decoder.configure(configuration: decoderConfiguration, generation: config.generation)
            } catch {
                setStatus("Video decoder configuration failed")
            }

        case let .videoFrame(frame):
            guard frame.generation == selectedGeneration,
                  streamGenerationGate.accepts(frame.generation) else { return }
            notePendingFrameReceipt(captureTimestamp: frame.captureTimestamp)
            do {
                let encoded = try EncodedH264Frame(
                    generation: frame.generation,
                    captureTimestamp: frame.captureTimestamp,
                    presentationTimestamp: frame.presentationTimestamp,
                    width: frame.width,
                    height: frame.height,
                    keyframe: frame.keyframe,
                    accessUnit: frame.accessUnit
                )
                let decodeGeneration = encoded.generation
                try decoder.decode(encoded) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.selectedGeneration == decodeGeneration,
                              self.streamGenerationGate.accepts(decodeGeneration) else {
                            return
                        }
                        self.present(result)
                    }
                }
            } catch let error as CodecError {
                // A non-keyframe before decoder configuration is expected to
                // be dropped; ask for the next keyframe instead of waiting for
                // the periodic one.
                if error == .missingDecoderConfiguration {
                    requestRecoveryKeyframe()
                } else if error != .cancelled {
                    reportVideoDecodeFailure(error)
                }
            } catch {
                setStatus("Video frame could not be decoded")
            }

        case let .sessionState(message):
            guard let session else {
                hostInputPermission = .unknown
                hostInputFocusEligible = false
                hostInputStatusGeneration = nil
                await refreshInputSurface()
                return
            }
            let snapshot = await session.snapshot()
            if message.state == .failed || message.state == .stopping {
                hostInputPermission = .unknown
                hostInputFocusEligible = false
                hostInputStatusGeneration = nil
            } else if let generation = message.windowGeneration,
                      snapshot.authorized,
                      snapshot.authorizedWindowGeneration == generation {
                hostInputPermission = message.permission
                hostInputFocusEligible = message.focusEligible
                hostInputStatusGeneration = generation
            } else {
                // A status for an old selection or an unauthorizing session
                // cannot make the current surface ready.
                hostInputPermission = .unknown
                hostInputFocusEligible = false
                hostInputStatusGeneration = nil
            }
            await refreshInputSurface()
            if hostInputPermission == .missing || hostInputPermission == .revoked {
                setStatus("Connected — enable PostEvent permission for MacRemoteApp Host")
            } else if hostInputPermission == .unknown {
                setStatus("Connected — waiting for Host input status")
            } else if !hostInputFocusEligible {
                setStatus("Connected — the selected app must be foreground on the Host")
            }

        case .close:
            // The callback is running inside ViewerSessionMessageLoop. Defer
            // teardown until the callback returns so stop() never waits on
            // the message-loop task itself. A peer close is recoverable; only
            // application termination uses disconnect(), which stops Bonjour.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.resetSession()
                self.scheduleReconnect()
            }

        default:
            await refreshInputSurface()
        }
    }

    private func selectWindow(
        _ windowIdentifier: UInt64,
        generation: UInt64,
        catalogGeneration: UInt64
    ) {
        guard !windowSelectionInFlight, let session else { return }
        guard selectedWindowIdentifier != windowIdentifier else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await session.snapshot()
            guard snapshot.authorizedWindowGeneration == generation else {
                setStatus("Window list expired; waiting for Host")
                return
            }
            guard contentView?.windowSelectionCatalogGeneration == catalogGeneration else {
                setStatus("Window catalog expired; waiting for Host")
                return
            }
            guard windowOptionsContain(windowIdentifier) else {
                setStatus("Window is no longer available")
                return
            }
            windowSelectionInFlight = true
            resetPresentedFPS()
            selectedGeneration = nil
            streamGenerationGate.revoke()
            decoder.reset()
            streamDimensions = .zero
            hostInputPermission = .unknown
            hostInputFocusEligible = false
            hostInputStatusGeneration = nil
            contentView?.updateStream(size: .zero, readiness: .awaitingAuthorization)
            contentView?.setWindowSelectionEnabled(false)
            await refreshInputSurface()
            do {
                try await session.send(
                    .windowSelection(
                        WindowSelectionMessage(
                            windowIdentifier: windowIdentifier,
                            windowGeneration: generation,
                            catalogGeneration: catalogGeneration
                        )
                    )
                )
                selectedWindowIdentifier = windowIdentifier
                contentView?.setSelectedWindowIdentifier(windowIdentifier)
                pendingWindowSelection = (windowIdentifier, catalogGeneration)
                setStatus("Window selected; starting video")
                await refreshInputSurface()
            } catch {
                pendingWindowSelection = nil
                selectedWindowIdentifier = nil
                contentView?.setWindowSelectionEnabled(true)
                setStatus("Window selection was rejected")
            }
            windowSelectionInFlight = false
        }
    }

    private func windowOptionsContain(_ identifier: UInt64) -> Bool {
        contentView?.containsWindow(identifier) == true
    }

    private func present(_ result: Result<DecodedH264Frame, CodecError>) {
        guard case let .success(frame) = result else {
            if case let .failure(error) = result,
               error != .cancelled,
               error != .missingDecoderConfiguration {
                reportVideoDecodeFailure(error)
            }
            return
        }
        guard frame.generation == selectedGeneration else { return }
        guard let renderer else {
            setStatus("Video decoded, but Metal rendering is unavailable")
            return
        }
        guard renderer.submit(
            pixelBuffer: frame.pixelBuffer,
            captureTimestamp: frame.captureTimestamp,
            streamGeneration: frame.generation
        ) else {
            setStatus("Video decoded, but the Metal view is unavailable")
            return
        }
    }

    private func reportVideoDecodeFailure(_ error: CodecError) {
        requestRecoveryKeyframe()
        guard let generation = selectedGeneration,
              reportedVideoFailureGeneration != generation else { return }
        reportedVideoFailureGeneration = generation
        macRemoteAppStartupLogger.error(
            "MacRemoteApp Viewer H.264 decode failed: \(error.description, privacy: .public)"
        )
        setStatus("Video decoding failed; check Viewer logs")
    }

    /// Best-effort and rate-limited by `SessionCoordinator`; a Host without
    /// `Capability.keyframeRequest` simply recovers at its periodic keyframe.
    private func requestRecoveryKeyframe() {
        guard let session else { return }
        Task {
            await session.requestKeyframe(reason: .decodeFailure)
        }
    }

    private func recordPresentation(
        captureTimestamp: UInt64,
        presentedTimestamp: UInt64?,
        presentationUptime: TimeInterval
    ) {
        presentedFrameCount += 1
        let receivedAt = pendingFrameReceiptNanoseconds.removeValue(forKey: captureTimestamp)
        if let presentedTimestamp, let receivedAt {
            receiveToPresentCollector.append(
                startNanoseconds: receivedAt,
                endNanoseconds: presentedTimestamp
            )
        }
        if let presentedTimestamp {
            // The renderer callback is the authoritative display boundary.
            // Raw pairs stay inside a bounded collector and are converted only
            // with the authenticated clock estimate.
            performanceCollector.append(
                captureTimestampNanoseconds: captureTimestamp,
                presentedTimestampNanoseconds: presentedTimestamp
            )
        }
        recordPresentedFrame(at: presentationUptime)
    }

    private func notePendingFrameReceipt(captureTimestamp: UInt64) {
        if pendingFrameReceiptNanoseconds.count >= Self.maximumPendingFrameReceipts,
           let oldest = pendingFrameReceiptNanoseconds.keys.min() {
            // Capture timestamps increase, so the smallest key belongs to a
            // frame that was dropped or superseded before presentation.
            pendingFrameReceiptNanoseconds.removeValue(forKey: oldest)
        }
        pendingFrameReceiptNanoseconds[captureTimestamp] = DispatchTime.now().uptimeNanoseconds
    }

    /// Logs only aggregate timing, about every ten seconds.
    private func logStageBudgetIfDue() {
        stageLogTick += 1
        guard stageLogTick % Self.stageLogTickInterval == 0 else { return }
        let budget = LatencyBudget.v1
        if let summary = receiveToPresentCollector.summary() {
            let within = LatencyBudget.isWithinBudget(
                summary,
                budget: budget.viewerReceiveToPresentNanoseconds
            ) ?? false
            macRemoteAppStartupLogger.notice(
                "M8 stage viewer-receive-to-present samples=\(summary.count, privacy: .public) p50Ns=\(summary.p50Nanoseconds, privacy: .public) p95Ns=\(summary.p95Nanoseconds, privacy: .public) budgetNs=\(budget.viewerReceiveToPresentNanoseconds, privacy: .public) withinBudget=\(within, privacy: .public)"
            )
        }
        if let summary = latestPerformanceSnapshot?.captureToDisplay {
            let within = LatencyBudget.isWithinBudget(summary, budget: budget.endToEndNanoseconds) ?? false
            macRemoteAppStartupLogger.notice(
                "M8 stage end-to-end samples=\(summary.count, privacy: .public) p50Ns=\(summary.p50Nanoseconds, privacy: .public) p95Ns=\(summary.p95Nanoseconds, privacy: .public) budgetNs=\(budget.endToEndNanoseconds, privacy: .public) withinBudget=\(within, privacy: .public)"
            )
        }
    }

    private func recordPresentedFrame(at uptime: TimeInterval) {
        guard uptime.isFinite, uptime > 0 else { return }
        presentedFPSIsIdle = false
        presentedFrameTimes.append(uptime)
        presentedFrameTimes.sort()
        lastPresentedFrameTime = max(lastPresentedFrameTime ?? uptime, uptime)
        refreshPresentedFPS(now: lastPresentedFrameTime ?? uptime)
    }

    private func refreshPresentedFPS(now: TimeInterval) {
        guard let lastPresentedFrameTime else {
            contentView?.updatePresentedFPS(presentedFPSIsIdle ? "FPS: idle" : "FPS: —")
            return
        }
        guard now - lastPresentedFrameTime <= 1 else {
            presentedFrameTimes.removeAll(keepingCapacity: true)
            self.lastPresentedFrameTime = nil
            presentedFPSIsIdle = true
            contentView?.updatePresentedFPS("FPS: idle")
            return
        }

        let cutoff = now - 1
        presentedFrameTimes.removeAll { $0 < cutoff }
        guard let first = presentedFrameTimes.first,
              let last = presentedFrameTimes.last,
              presentedFrameTimes.count > 1,
              last - first >= 0.5 else {
            contentView?.updatePresentedFPS("FPS: warming…")
            return
        }
        let framesPerSecond = Double(presentedFrameTimes.count - 1) / (last - first)
        contentView?.updatePresentedFPS("FPS: \(Int(framesPerSecond.rounded()))")
    }

    private func resetPresentedFPS() {
        presentedFrameTimes.removeAll(keepingCapacity: true)
        lastPresentedFrameTime = nil
        presentedFPSIsIdle = false
        contentView?.updatePresentedFPS("FPS: —")
    }

    private func enqueueInput(_ record: InputEventRecord) {
        let previous = inputSendTail
        inputSendTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, let inputTransport else { return }
            try? await inputTransport.send(record)
        }
    }

    private func refreshInputSurface() async {
        guard let session else {
            let readiness = InputReadiness.awaitingAuthentication
            contentView?.updateStream(size: streamDimensions, readiness: readiness)
            contentView?.updateClipboard(status: nil, available: false)
            return
        }
        let snapshot = await session.snapshot()
        var readiness: InputReadiness = .awaitingAuthorization
        var inputCapabilities = ViewerInputCapabilities.none
        if snapshot.state == .connecting || snapshot.state == .reconnecting {
            readiness = .awaitingAuthentication
        } else if snapshot.authorizedWindowGeneration == nil || selectedGeneration == nil {
            readiness = .awaitingAuthorization
        } else if let generation = selectedGeneration {
            let availability = SessionCapabilityProjection.inputAvailability(
                for: snapshot,
                selectedWindowGeneration: snapshot.authorizedWindowGeneration,
                selectedStreamGeneration: generation
            )
            if hostInputStatusGeneration != snapshot.authorizedWindowGeneration {
                readiness = .hostStateUnavailable
            } else if hostInputPermission != .granted {
                readiness = .hostPermissionUnavailable
            } else if !hostInputFocusEligible {
                readiness = .hostFocusUnavailable
            } else if !availability.anyInputEnabled {
                readiness = .awaitingAuthorization
            } else {
                readiness = .ready(windowGeneration: generation)
                inputCapabilities = ViewerInputCapabilities(
                    mouseInputEnabled: availability.mouseInputEnabled,
                    keyboardInputEnabled: availability.keyboardInputEnabled
                )
            }
        }
        contentView?.updateStream(
            size: streamDimensions,
            readiness: readiness,
            capabilities: inputCapabilities
        )
        switch readiness {
        case .ready:
            setStatus("Connected — input ready")
        case .hostPermissionUnavailable:
            setStatus("Connected — enable PostEvent permission for MacRemoteApp Host")
        case .hostFocusUnavailable:
            setStatus("Connected — the selected app must be foreground on the Host")
        case .hostStateUnavailable:
            setStatus("Connected — waiting for Host input status")
        case .awaitingAuthorization:
            if selectedWindowIdentifier == nil {
                setStatus("Connected — select a Host window to start video")
            } else if streamDimensions == .zero {
                setStatus("Connected — authorizing the selected Host window")
            }
        case .awaitingAuthentication, .surfaceUnavailable:
            break
        }
        let clipboardAvailable = SessionCapabilityProjection.clipboardAvailable(for: snapshot)
        contentView?.updateClipboard(
            status: messageLoop?.clipboardStatus,
            available: clipboardAvailable
        )
    }

    private func toggleClipboard() {
        guard let messageLoop else {
            setStatus("Text clipboard is unavailable until the session is authorized")
            return
        }
        let enabled = messageLoop.clipboardStatus.localEnabled
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await messageLoop.setClipboardEnabled(!enabled)
                await refreshInputSurface()
            } catch {
                setStatus("Text clipboard is not authorized for this session")
                await refreshInputSurface()
            }
        }
    }

    private func setStatus(_ message: String) {
        contentView?.status = message
    }

    private func retryPairing() {
        guard !isShuttingDown, session == nil, reconnectTask == nil else { return }
        guard lastDiscoveredService != nil else {
            setStatus("No Host is currently discovered")
            return
        }
        pairingRetryRequired = false
        contentView?.setPairingRetryVisible(false)
        scheduleReconnect(immediate: true)
    }

    private func forgetSavedPairings() {
        guard !isShuttingDown else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Forget all saved pairings?"
        alert.informativeText =
            "This removes saved Host trust records from this Mac and stops the active session. The Viewer identity and Local Network permission remain unchanged. The next connection must be paired again."
        alert.addButton(withTitle: "Forget Pairings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Clear the selected service before stopping the session so the
        // discovery stream cannot immediately reconnect to the Host while its
        // old trust record is being removed.
        selectedServiceIdentifier = nil
        lastDiscoveredService = nil
        pairingRetryRequired = false
        contentView?.clearHostSelection()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await resetSession()
                let trustStore = KeychainTrustStore(service: Configuration.defaultTrustStoreService)
                let count = try await trustStore.removeAllPairings()
                contentView?.setHostSelectionEnabled(true)
                setStatus(
                    count == 0
                    ? "No saved pairings"
                    : "Saved pairings cleared; choose a Host to pair again"
                )
            } catch {
                setStatus("Saved pairings could not be cleared; check Keychain access")
            }
        }
    }

    private func disconnect() async {
        isShuttingDown = true
        reconnectTask?.cancel()
        reconnectTask = nil
        discovery.cancel()
        if let discoveryStateTask {
            discoveryStateTask.cancel()
            await discoveryStateTask.value
            self.discoveryStateTask = nil
        }
        if let discoveryTask {
            discoveryTask.cancel()
            await discoveryTask.value
            self.discoveryTask = nil
        }
        await resetSession()
    }

    private func resetSession(cancelMonitor: Bool = true) async {
        if cancelMonitor {
            sessionMonitorTask?.cancel()
            sessionMonitorTask = nil
        }
        inputSendTail?.cancel()
        inputSendTail = nil
        if let messageLoop {
            await messageLoop.stop()
        }
        messageLoop = nil
        if let session {
            await session.stop(reason: .normal)
        }
        session = nil
        inputTransport = nil
        selectedGeneration = nil
        selectedWindowIdentifier = nil
        pendingWindowSelection = nil
        windowSelectionInFlight = false
        presentedFrameCount = 0
        resetPresentedFPS()
        performanceCollector.reset()
        latestPerformanceSnapshot = nil
        receiveToPresentCollector.reset()
        pendingFrameReceiptNanoseconds.removeAll()
        latestClockSyncEstimate = nil
        hostInputPermission = .unknown
        hostInputFocusEligible = false
        hostInputStatusGeneration = nil
        streamGenerationGate.revoke()
        decoder.reset()
        streamDimensions = .zero
        contentView?.clearWindowOptions()
        contentView?.updateStream(size: .zero, readiness: .awaitingAuthentication)
        contentView?.setPeerName(nil)
        contentView?.setConnectionLatency(nil)
        contentView?.updateClipboard(status: nil, available: false)
        contentView?.setConnectionState(.disconnected)
        contentView?.setHostSelectionEnabled(true)
    }
}

enum ViewerRuntimeError: Error, CustomStringConvertible, Sendable {
    case configuration(String)

    var description: String {
        switch self {
        case let .configuration(message): return message
        }
    }
}

private enum ViewerConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting

    var buttonTitle: String {
        switch self {
        case .disconnected: return "Connect"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting…"
        }
    }

    var statusTitle: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        }
    }
}

@MainActor
private final class ViewerStatusPanel: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        _ = point
        return nil
    }
}

@MainActor
private final class ViewerContentView: NSView {
    let videoView: MTKView
    let surface: ViewerInputSurface
    var onInputEvent: (@MainActor (InputEventRecord) -> Void)? {
        didSet { surface.onInputEvent = onInputEvent }
    }
    var onInputRejected: (@MainActor (InputCoreError) -> Void)? {
        didSet { surface.onInputRejected = onInputRejected }
    }
    var onHostSelection: (@MainActor (Int) -> Void)?
    var onWindowSelection: (@MainActor (UInt64, UInt64, UInt64) -> Void)?
    var onPairingRetry: (@MainActor () -> Void)?
    var onForgetPairings: (@MainActor () -> Void)?
    var onClipboardToggle: (@MainActor () -> Void)?
    var onSettingsChange: (@MainActor () -> Void)?
    var status: String = "Starting…" {
        didSet {
            statusLabel.stringValue = status
            onSettingsChange?()
        }
    }
    private(set) var clipboardAvailable = false
    private(set) var clipboardEnabled = false
    private var clipboardSummary = "Unavailable"
    var settingsValues: [String: String] {
        ["connection": connectionState.statusTitle, "host": peerName,
         "latency": connectionLatency, "input": compactInputStatus(readiness),
         "message": status, "clipboard": clipboardSummary]
    }

    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let connectionStateLabel = NSTextField(labelWithString: "Disconnected")
    private let fpsLabel = NSTextField(labelWithString: "FPS: —")
    private let connectionPanel = ViewerStatusPanel(frame: .zero)
    private let connectionStatusDot = NSView(frame: .zero)
    private let peerNameLabel = NSTextField(labelWithString: "Host: —")
    private let routeLabel = NSTextField(labelWithString: "Transport: LAN / TLS")
    private let latencyLabel = NSTextField(labelWithString: "RTT: —")
    private let inputStatusLabel = NSTextField(labelWithString: "Input: Authenticating")
    private let versionLabel = NSTextField(labelWithString: "Version: —")
    private let protocolLabel = NSTextField(labelWithString: "Protocol: —")
    private let hostPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let connectHostButton = NSButton(title: "Connect", target: nil, action: nil)
    private let forgetPairingsButton = NSButton(title: "Forget saved pairings…", target: nil, action: nil)
    private let windowPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let selectWindowButton = NSButton(title: "Select", target: nil, action: nil)
    private let clipboardButton = NSButton(title: "Text clipboard unavailable", target: nil, action: nil)
    private let retryPairingButton = NSButton(title: "Retry pairing", target: nil, action: nil)
    private var windowOptions: [WindowDescriptor] = []
    private var windowSelectionGeneration: UInt64?
    private(set) var windowSelectionCatalogGeneration: UInt64?
    private var hostOptionIdentifiers: [String] = []
    private var hostSelectionEnabled = true
    private var connectionState: ViewerConnectionState = .disconnected
    private var peerName = "—"
    private var connectionLatency = "—"
    private var streamSize: CGSize = .zero
    private var readiness: InputReadiness = .awaitingAuthentication
    private var inputCapabilities: ViewerInputCapabilities = .none

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        videoView = MTKView(frame: frameRect)
        surface = ViewerInputSurface(
            frame: frameRect,
            contentRect: InputContentRect(originX: 0, originY: 0, width: 0, height: 0),
            readiness: .awaitingAuthentication
        )
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        videoView.isPaused = true
        videoView.enableSetNeedsDisplay = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.backgroundColor = .clear
        statusLabel.isBordered = false
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 12)
        connectionStateLabel.textColor = .labelColor
        connectionStateLabel.backgroundColor = .clear
        connectionStateLabel.isBordered = false
        connectionStateLabel.alignment = .left
        connectionStateLabel.lineBreakMode = .byTruncatingTail
        connectionStateLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        fpsLabel.textColor = .secondaryLabelColor
        fpsLabel.backgroundColor = .clear
        fpsLabel.isBordered = false
        fpsLabel.alignment = .right
        connectionPanel.wantsLayer = true
        connectionPanel.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        connectionPanel.layer?.cornerRadius = 10
        connectionPanel.layer?.borderWidth = 1
        connectionPanel.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        connectionStatusDot.wantsLayer = true
        connectionStatusDot.layer?.cornerRadius = 4
        for label in [
            peerNameLabel,
            routeLabel,
            latencyLabel,
            inputStatusLabel,
            versionLabel,
            protocolLabel
        ] {
            configureDetailLabel(label)
        }
        hostPicker.controlSize = .small
        hostPicker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hostPicker.addItem(withTitle: "Choose MacRemoteApp Host")
        hostPicker.isEnabled = false
        hostPicker.target = self
        hostPicker.action = #selector(hostSelectionChanged(_:))
        connectHostButton.target = self
        connectHostButton.action = #selector(connectHost(_:))
        connectHostButton.controlSize = .small
        connectHostButton.isEnabled = false
        forgetPairingsButton.target = self
        forgetPairingsButton.action = #selector(forgetPairings(_:))
        forgetPairingsButton.controlSize = .small
        windowPicker.controlSize = .small
        windowPicker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        windowPicker.addItem(withTitle: "Choose Host window")
        windowPicker.isEnabled = false
        selectWindowButton.target = self
        selectWindowButton.action = #selector(selectWindow(_:))
        selectWindowButton.controlSize = .small
        selectWindowButton.isEnabled = false
        clipboardButton.target = self
        clipboardButton.action = #selector(toggleClipboard(_:))
        clipboardButton.controlSize = .small
        clipboardButton.isEnabled = false
        retryPairingButton.target = self
        retryPairingButton.action = #selector(retryPairing(_:))
        retryPairingButton.controlSize = .small
        retryPairingButton.isHidden = true
        addSubview(videoView)
        addSubview(surface)
        addSubview(connectionPanel)
        addSubview(connectionStateLabel)
        addSubview(statusLabel)
        addSubview(fpsLabel)
        addSubview(connectionStatusDot)
        addSubview(peerNameLabel)
        addSubview(routeLabel)
        addSubview(latencyLabel)
        addSubview(inputStatusLabel)
        addSubview(versionLabel)
        addSubview(protocolLabel)
        addSubview(hostPicker)
        addSubview(connectHostButton)
        addSubview(forgetPairingsButton)
        addSubview(windowPicker)
        addSubview(selectWindowButton)
        addSubview(clipboardButton)
        addSubview(retryPairingButton)
        surface.onInputEvent = onInputEvent
        surface.onInputRejected = onInputRejected
        updateConnectionDetails()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateStream(
        size: CGSize,
        readiness: InputReadiness,
        capabilities: ViewerInputCapabilities = .none
    ) {
        streamSize = size
        self.readiness = readiness
        inputCapabilities = capabilities
        updateConnectionDetails()
        needsLayout = true
    }

    func updateClipboard(status: ClipboardSyncStatus?, available: Bool) {
        clipboardAvailable = available
        clipboardEnabled = available && status?.localEnabled == true
        clipboardSummary = !available ? "Unavailable" : !clipboardEnabled ? "Off" : status?.remoteEnabled == true ? "Sharing text" : "Waiting for Host consent"
        defer { onSettingsChange?() }
        guard available else {
            clipboardButton.title = "Text clipboard unavailable"
            clipboardButton.isEnabled = false
            return
        }
        if let status, status.localEnabled {
            clipboardButton.title = status.remoteEnabled
                ? "Disable text clipboard"
                : "Clipboard enabled (waiting)"
        } else {
            clipboardButton.title = "Enable text clipboard"
        }
        clipboardButton.isEnabled = true
    }

    func setPairingRetryVisible(_ visible: Bool) {
        retryPairingButton.isHidden = !visible
        retryPairingButton.isEnabled = visible
        needsLayout = true
    }

    func setHostOptions(_ services: [DiscoveredService]) {
        let previousIdentifier = hostPicker.indexOfSelectedItem >= 0 &&
            hostPicker.indexOfSelectedItem > 0 &&
            hostPicker.indexOfSelectedItem - 1 < hostOptionIdentifiers.count
            ? hostOptionIdentifiers[hostPicker.indexOfSelectedItem - 1]
            : nil
        hostOptionIdentifiers = services.map(\.identifier)
        hostPicker.removeAllItems()
        if services.isEmpty {
            hostPicker.addItem(withTitle: "No MacRemoteApp Host found")
            updateHostControls()
            return
        }
        hostPicker.addItem(withTitle: "Choose MacRemoteApp Host")
        for service in services {
            let name = service.name.isEmpty ? "Unnamed Host" : service.name
            hostPicker.addItem(withTitle: name)
        }
        if let previousIdentifier,
           let index = hostOptionIdentifiers.firstIndex(of: previousIdentifier) {
            hostPicker.selectItem(at: index + 1)
        } else {
            hostPicker.selectItem(at: 0)
        }
        updateHostControls()
    }

    func setHostSelectionEnabled(_ enabled: Bool) {
        hostSelectionEnabled = enabled
        updateHostControls()
    }

    func setConnectionState(_ state: ViewerConnectionState) {
        connectionState = state
        updateHostControls()
        updateConnectionDetails()
    }

    func setPeerName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        peerName = trimmed.isEmpty ? "—" : trimmed
        updateConnectionDetails()
    }

    func setConnectionLatency(_ estimate: ClockSyncEstimate?) {
        let nextLatency: String
        if let estimate {
            let milliseconds = Double(estimate.minimumRoundTripNanoseconds) / 1_000_000
            nextLatency = String(format: "%.1f ms", milliseconds)
        } else {
            nextLatency = "—"
        }
        guard nextLatency != connectionLatency else { return }
        connectionLatency = nextLatency
        updateConnectionDetails()
    }

    private func updateConnectionDetails() {
        connectionStateLabel.stringValue = connectionState.statusTitle
        peerNameLabel.stringValue = "Host: \(peerName)"
        peerNameLabel.toolTip = peerName == "—" ? nil : peerName
        routeLabel.stringValue = connectionState == .connected
            ? "Route: LAN / TLS"
            : "Transport: LAN / TLS"
        latencyLabel.stringValue = "RTT: \(connectionLatency)"
        inputStatusLabel.stringValue = "Input: \(compactInputStatus(readiness))"
        inputStatusLabel.textColor = readiness.isReady ? .systemGreen : .secondaryLabelColor
        versionLabel.stringValue = "Version: \(viewerApplicationMetadata.displayVersionDetails)"
        protocolLabel.stringValue = "Protocol: \(viewerProtocolVersion)"

        let statusColor: NSColor
        switch connectionState {
        case .disconnected:
            statusColor = .systemGray
        case .connecting, .reconnecting:
            statusColor = .systemOrange
        case .connected:
            statusColor = .systemGreen
        }
        connectionStatusDot.layer?.backgroundColor = statusColor.cgColor
        onSettingsChange?()
    }

    private func configureDetailLabel(_ label: NSTextField) {
        label.textColor = .secondaryLabelColor
        label.backgroundColor = .clear
        label.isBordered = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
    }

    private func compactInputStatus(_ readiness: InputReadiness) -> String {
        guard connectionState != .disconnected else { return "Not connected" }
        switch readiness {
        case .awaitingAuthentication:
            return "Authenticating"
        case .awaitingAuthorization:
            return "Authorization required"
        case .surfaceUnavailable:
            return "Remote content unavailable"
        case .hostPermissionUnavailable:
            return "Host permission required"
        case .hostFocusUnavailable:
            return "Host not foreground"
        case .hostStateUnavailable:
            return "Waiting for Host"
        case .ready:
            return "Ready"
        }
    }

    func clearHostSelection() {
        hostPicker.selectItem(at: 0)
        hostSelectionEnabled = true
        updateHostControls()
    }

    @objc private func hostSelectionChanged(_ sender: NSPopUpButton) {
        _ = sender
        let selectedIndex = hostPicker.indexOfSelectedItem - 1
        let hasHostSelection = selectedIndex >= 0 && selectedIndex < hostOptionIdentifiers.count
        connectHostButton.isEnabled = connectionState == .disconnected &&
            hostSelectionEnabled && hasHostSelection
    }

    private func updateHostControls() {
        let isDisconnected = connectionState == .disconnected
        hostPicker.isEnabled = isDisconnected && hostSelectionEnabled && !hostOptionIdentifiers.isEmpty
        connectHostButton.title = connectionState.buttonTitle
        connectHostButton.isEnabled = isDisconnected &&
            hostSelectionEnabled &&
            hostPicker.indexOfSelectedItem > 0 &&
            hostPicker.indexOfSelectedItem - 1 < hostOptionIdentifiers.count
    }

    func setWindowOptions(
        _ windows: [WindowDescriptor],
        generation: UInt64,
        catalogGeneration: UInt64,
        selectedIdentifier: UInt64? = nil
    ) {
        windowOptions = windows
        windowSelectionGeneration = generation
        windowSelectionCatalogGeneration = catalogGeneration
        windowPicker.removeAllItems()
        if windows.isEmpty {
            windowPicker.addItem(withTitle: "No eligible Host windows")
            windowPicker.isEnabled = false
            selectWindowButton.isEnabled = false
            return
        }
        for window in windows {
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled window"
            let itemTitle = "\(title) — \(window.applicationIdentifier) (\(window.width)x\(window.height))"
            windowPicker.addItem(withTitle: itemTitle)
        }
        if let selectedIdentifier,
           let index = windows.firstIndex(where: { $0.identifier == selectedIdentifier }) {
            windowPicker.selectItem(at: index)
        } else {
            windowPicker.selectItem(at: 0)
        }
        windowPicker.isEnabled = true
        selectWindowButton.isEnabled = true
    }

    func setSelectedWindowIdentifier(_ identifier: UInt64) {
        guard let index = windowOptions.firstIndex(where: { $0.identifier == identifier }) else { return }
        windowPicker.selectItem(at: index)
    }

    func containsWindow(_ identifier: UInt64) -> Bool {
        windowOptions.contains { $0.identifier == identifier }
    }

    func setWindowSelectionEnabled(_ enabled: Bool) {
        windowPicker.isEnabled = enabled && !windowOptions.isEmpty
        selectWindowButton.isEnabled = enabled && !windowOptions.isEmpty
    }

    func clearWindowOptions() {
        windowOptions.removeAll(keepingCapacity: false)
        windowSelectionGeneration = nil
        windowSelectionCatalogGeneration = nil
        windowPicker.removeAllItems()
        windowPicker.addItem(withTitle: "Choose Host window")
        windowPicker.isEnabled = false
        selectWindowButton.isEnabled = false
    }

    func markFramePresented() {
        if readiness.isReady {
            statusLabel.stringValue = "Connected — input ready"
        }
    }

    func updatePresentedFPS(_ value: String) {
        fpsLabel.stringValue = value
    }

    override func layout() {
        super.layout()
        let panelFrame = NSRect(
            x: 12,
            y: 8,
            width: max(1, bounds.width - 24),
            height: 112
        )
        connectionPanel.frame = panelFrame
        let contentLeft = panelFrame.minX + 14
        let contentRight = panelFrame.maxX - 14
        let fpsWidth: CGFloat = 80
        let retryWidth: CGFloat = 104
        let retryInset = retryPairingButton.isHidden ? 0 : retryWidth + 8
        let fpsX = contentRight - retryInset - fpsWidth
        let stateLabelWidth: CGFloat = 124
        connectionStateLabel.frame = NSRect(
            x: contentLeft + 22,
            y: panelFrame.minY + 9,
            width: stateLabelWidth,
            height: 20
        )
        statusLabel.frame = NSRect(
            x: connectionStateLabel.frame.maxX + 8,
            y: panelFrame.minY + 9,
            width: max(1, fpsX - 8 - connectionStateLabel.frame.maxX - 8),
            height: 20
        )
        fpsLabel.frame = NSRect(
            x: fpsX,
            y: panelFrame.minY + 9,
            width: fpsWidth,
            height: 20
        )
        connectionStatusDot.frame = NSRect(
            x: contentLeft,
            y: panelFrame.minY + 15,
            width: 8,
            height: 8
        )
        retryPairingButton.frame = NSRect(
            x: contentRight - retryWidth,
            y: panelFrame.minY + 7,
            width: retryWidth,
            height: 24
        )
        let firstRowY = panelFrame.minY + 36
        let secondRowY = panelFrame.minY + 58
        let detailWidth = max(1, contentRight - contentLeft)
        let rowGap: CGFloat = 16
        let firstRowAvailable = max(1, detailWidth - rowGap * 2)
        let hostWidth = firstRowAvailable * 0.48
        let routeWidth = firstRowAvailable * 0.30
        let latencyWidth = max(1, firstRowAvailable - hostWidth - routeWidth)
        peerNameLabel.frame = NSRect(
            x: contentLeft,
            y: firstRowY,
            width: hostWidth,
            height: 18
        )
        routeLabel.frame = NSRect(
            x: peerNameLabel.frame.maxX + rowGap,
            y: firstRowY,
            width: routeWidth,
            height: 18
        )
        latencyLabel.frame = NSRect(
            x: routeLabel.frame.maxX + rowGap,
            y: firstRowY,
            width: latencyWidth,
            height: 18
        )
        let secondRowAvailable = max(1, detailWidth - rowGap * 2)
        let inputWidth = secondRowAvailable * 0.45
        let versionWidth = secondRowAvailable * 0.37
        let protocolWidth = max(1, secondRowAvailable - inputWidth - versionWidth)
        inputStatusLabel.frame = NSRect(
            x: contentLeft,
            y: secondRowY,
            width: inputWidth,
            height: 18
        )
        versionLabel.frame = NSRect(
            x: inputStatusLabel.frame.maxX + rowGap,
            y: secondRowY,
            width: versionWidth,
            height: 18
        )
        protocolLabel.frame = NSRect(
            x: versionLabel.frame.maxX + rowGap,
            y: secondRowY,
            width: protocolWidth,
            height: 18
        )
        let hostControlY = panelFrame.minY + 82
        let connectWidth: CGFloat = 112
        let forgetWidth: CGFloat = 168
        let horizontalGap: CGFloat = 8
        let hostPickerWidth = min(
            420,
            max(180, panelFrame.width - 28 - connectWidth - forgetWidth - horizontalGap * 2)
        )
        hostPicker.frame = NSRect(
            x: contentLeft,
            y: hostControlY,
            width: hostPickerWidth,
            height: 24
        )
        connectHostButton.frame = NSRect(
            x: hostPicker.frame.maxX + horizontalGap,
            y: hostControlY,
            width: connectWidth,
            height: 24
        )
        forgetPairingsButton.frame = NSRect(
            x: connectHostButton.frame.maxX + horizontalGap,
            y: hostControlY,
            width: forgetWidth,
            height: 24
        )
        let controlY = max(panelFrame.maxY + 16, bounds.height - 36)
        let clipboardWidth: CGFloat = 176
        windowPicker.frame = NSRect(
            x: 12,
            y: controlY,
            width: min(520, max(180, bounds.width - 288)),
            height: 24
        )
        selectWindowButton.frame = NSRect(
            x: windowPicker.frame.maxX + 8,
            y: windowPicker.frame.minY,
            width: 64,
            height: 24
        )
        clipboardButton.frame = NSRect(
            x: max(selectWindowButton.frame.maxX + 8, bounds.width - clipboardWidth - 12),
            y: controlY,
            width: clipboardWidth,
            height: 24
        )
        let videoTop = panelFrame.maxY + 12
        let videoBottom = controlY - 12
        let videoFrame = NSRect(
            x: 12,
            y: videoTop,
            width: max(1, bounds.width - 24),
            height: max(1, videoBottom - videoTop)
        )
        // Keep the complete remote window visible. Previously the video was
        // fitted behind the opaque connection panel and bottom controls, so
        // those overlays hid real portions of the captured app.
        videoView.frame = videoFrame
        surface.frame = videoFrame
        let contentRect = VideoContentLayout.aspectFitRect(
            contentWidth: streamSize.width,
            contentHeight: streamSize.height,
            in: surface.bounds
        )
        surface.updateInputState(
            contentRect: InputContentRect(
                originX: contentRect.origin.x,
                originY: contentRect.origin.y,
                width: contentRect.width,
                height: contentRect.height
            ),
            readiness: readiness,
            capabilities: inputCapabilities
        )
    }

    @objc private func selectWindow(_ sender: NSButton) {
        _ = sender
        guard windowPicker.indexOfSelectedItem >= 0,
              windowPicker.indexOfSelectedItem < windowOptions.count,
              let generation = windowSelectionGeneration,
              let catalogGeneration = windowSelectionCatalogGeneration else { return }
        onWindowSelection?(
            windowOptions[windowPicker.indexOfSelectedItem].identifier,
            generation,
            catalogGeneration
        )
    }

    @objc private func connectHost(_ sender: NSButton) {
        _ = sender
        let selectedIndex = hostPicker.indexOfSelectedItem - 1
        guard selectedIndex >= 0,
              selectedIndex < hostOptionIdentifiers.count else { return }
        onHostSelection?(selectedIndex)
    }

    @objc private func forgetPairings(_ sender: NSButton) {
        _ = sender
        onForgetPairings?()
    }

    @objc private func retryPairing(_ sender: NSButton) {
        _ = sender
        onPairingRetry?()
    }

    @objc private func toggleClipboard(_ sender: NSButton) {
        _ = sender
        onClipboardToggle?()
    }
}
