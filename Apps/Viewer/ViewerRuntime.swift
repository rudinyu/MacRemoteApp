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

enum ViewerProcessControlReadiness {
    static func blocker(
        hostPermissionGranted: Bool,
        focusEligible: Bool,
        processTargetEligible: Bool?,
        controlGeneration: UInt64? = 1
    ) -> InputReadiness? {
        guard hostPermissionGranted else { return .hostPermissionUnavailable }
        guard controlGeneration != nil else { return .hostStateUnavailable }
        guard focusEligible else { return .hostFocusUnavailable }
        guard processTargetEligible == true else { return .hostProcessTargetUnavailable }
        return nil
    }
}

/// What pressing Select does for the window currently chosen in the picker.
enum ViewerWindowSelectionAction: Equatable {
    /// Nothing to send: a selection is already in flight or not yet confirmed.
    case ignore
    /// The window is already streaming. Re-send the explicit selection so the
    /// Host can try to bring that same app forward, keeping the stream intact.
    case restoreForeground
    /// A different window: replace the selection and restart the stream.
    case replaceSelection

    static func resolve(
        requestedWindowIdentifier: UInt64,
        selectedWindowIdentifier: UInt64?,
        streamGeneration: UInt64?,
        selectionPending: Bool,
        selectionInFlight: Bool
    ) -> Self {
        guard !selectionInFlight else { return .ignore }
        guard requestedWindowIdentifier == selectedWindowIdentifier else {
            return .replaceSelection
        }
        // The Host answers a same-window selection only with a foreground
        // restore attempt, never with a new stream configuration, so it is
        // meaningful only after the current stream has started.
        guard streamGeneration != nil, !selectionPending else { return .ignore }
        return .restoreForeground
    }
}

enum ViewerInputStatusPresentation {
    static let hostFocusUnavailableStatus =
        "Connected — the selected app is not active on the Host. Press Select to ask the Host to bring it forward; if that fails, click or reactivate MacRemoteApp Host locally"
    static let restoreForegroundRequestedStatus =
        "Asking the Host to bring the selected app forward"
    static func readyStatus(focusEligible: Bool) -> String {
        if focusEligible {
            return "Connected — input ready"
        }
        return hostFocusUnavailableStatus
    }

    static func readyInputSummary() -> String {
        "Ready"
    }
}

enum ViewerVideoRecoveryStatusPolicy {
    static let receivingStatus = "Receiving video"
    static let recoveringStatus = "Restoring video — waiting for Host capture"
    static let recoveryDelaySeconds: TimeInterval = 1.5

    static func shouldShowRecovering(
        currentStatus: String,
        hasSelectedWindow: Bool,
        hasSelectedGeneration: Bool,
        lastVideoActivity: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard currentStatus == receivingStatus,
              hasSelectedWindow,
              hasSelectedGeneration,
              let lastVideoActivity,
              lastVideoActivity.isFinite,
              now.isFinite,
              now >= lastVideoActivity else {
            return false
        }
        return now - lastVideoActivity >= recoveryDelaySeconds
    }

    static func shouldRestoreReceiving(currentStatus: String) -> Bool {
        currentStatus == recoveringStatus
    }
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
        case superseded
    }

    private struct AuthorizationFingerprint: Equatable {
        let sessionID: UUID
        let generation: UInt64
        let authorized: Bool
        let windowGeneration: UInt64?
        let capabilities: Set<Capability>
    }

    static let capabilities: Set<Capability> = [
        .pingPong,
        .windowSelection,
        .h264Video,
        .mouseInput,
        .keyboardInput,
        .inputSourceSync,
        .textClipboard,
        .keyframeRequest,
        .receiverReport,
        .backgroundControl
    ]

    private var hostControlState: ControlAuthorizationState?
    private var hostProcessTargetEligible: Bool?
    private var hostControlGeneration: UInt64?

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
    private var reconnectTaskID: UUID?
    private var connectionAttemptID: UUID?
    private var authorizationSnapshotGate = ViewerAuthorizationSnapshotGate()
    private var discoveredServices: [DiscoveredService] = []
    private var lastDiscoveredService: DiscoveredService?
    private var selectedServiceIdentifier: String?
    private var pairingRetryRequired = false
    private var session: SessionCoordinator?
    private var sessionLifetimeID: UUID?
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
    private lazy var inputSendQueue = ViewerInputSendQueue { [weak self] scope, category in
        self?.handleInputQueueFailure(scope, category: category)
    }
    private var activeInputSendScope: ViewerInputSendScope?
    private let presentationLifetime = ViewerPresentationLifetime()
    private var authorizationFingerprint: AuthorizationFingerprint?
    private var selectedGeneration: UInt64?
    private var selectedWindowIdentifier: UInt64?
    private var pendingWindowSelection: (identifier: UInt64, catalogGeneration: UInt64)?
    private var streamGenerationGate = StreamGenerationGate()
    private var streamDimensions: CGSize = .zero
    private var windowSelectionInFlight = false
    /// A same-window foreground restore was requested and its outcome is not
    /// known yet. Further Select presses are ignored until fresh eligible Host
    /// status arrives or the fallback timeout expires.
    private var foregroundRestorePending = false
    private var presentedFrameCount = 0
    private var presentedFrameTimes: [TimeInterval] = []
    private var lastPresentedFrameTime: TimeInterval?
    private var lastPresentedFrameUptime: TimeInterval?
    private var videoStreamExpectedSince: TimeInterval?
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
    private let inputSourceProvider = SystemInputSourceProvider()
    private var inputSourceObserver: SystemInputSourceObserver?
    private var inputSourceSyncGate = ViewerInputSourceSyncGate()
    private var inputSourceRetryGate = ViewerInputSourceRetryGate()
    private var inputSourceSyncTimeoutTask: Task<Void, Never>?
    private var inputSourceFollowViewer = true
    private var inputSourceSyncCapabilityAvailable = false
    private var remoteSurfaceFocused = false
    private var inputSourceSyncStatus = "Waiting for remote keyboard"
#if DEBUG
    private var debugVideoWindow = M10ViewerVideoWindowAccumulator()
    private var debugEligibleWindowCount: UInt64 = 0
#endif

    private static let inputSourceSyncTimeoutNanoseconds: UInt64 = 3_000_000_000

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = self
        makeWindow()
#if DEBUG
        let openDebugLog: (() -> Void)? = { [weak self] in self?.openDebugLog() }
#else
        let openDebugLog: (() -> Void)? = nil
#endif
        let menu = ApplicationMenu(
            applicationName: "MacRemoteApp Viewer",
            metadata: viewerApplicationMetadata,
            onSettings: { [weak self] in self?.showSettings() },
            onShowWindow: { [weak self] in self?.showViewerWindow() },
            onOpenDebugLog: openDebugLog
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
                guard self.session == nil,
                      self.connectionAttemptID == nil,
                      self.reconnectTask == nil else { continue }
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
                        .init("input", "Remote input"),
                        .init("inputSource", "Input-source sync"), .init("message", "Details")
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
            controller.addAction("followInputSource", title: "Follow Viewer input source", checkbox: true) { [weak self] in
                self?.toggleInputSourceFollowing()
            }
            controller.addAction("retryInputSource", title: "Retry input-source sync") { [weak self] in
                self?.retryInputSourceSynchronization()
            }
            controller.addNote("Input-source following matches enabled English or Chinese TIS sources. Both Macs need the same enabled Chinese method; some third-party IME internal modes require manual matching.")
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
        settingsView.setValue(inputSourceSyncStatus, for: "inputSource")
        settingsView.setAction("followInputSource", enabled: true, checked: inputSourceFollowViewer)
        settingsView.setAction("retryInputSource", enabled: contentView.inputSourceRetryAvailable)
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
        content.onDisconnect = { [weak self] in
            self?.disconnectFromHost()
        }
        content.onForgetPairings = { [weak self] in
            self?.forgetSavedPairings()
        }
        content.onClipboardToggle = { [weak self] in
            self?.toggleClipboard()
        }
        content.onRetryInputSource = { [weak self] in
            self?.retryInputSourceSynchronization()
        }
        content.onRemoteFocusChange = { [weak self] focused in
            self?.remoteSurfaceFocusChanged(focused)
        }
        content.onJISEisuKey = { [weak self] in
            self?.handleJISEisuKey() ?? false
        }
        content.onJISKanaKey = { [weak self] in
            self?.handleJISKanaKey() ?? false
        }
        content.onInputRejected = { [weak self] error in
            self?.setStatus(error.description)
        }
        contentView = content
        content.onSettingsChange = { [weak self] in self?.refreshSettings() }
        inputSourceObserver = SystemInputSourceObserver { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.observedInputSourceChange()
            }
        }

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
            renderer.reset(lifetimeToken: presentationLifetime.token)
            renderer.onFramePresented = { [weak self] lifetimeToken, generation, captureTimestamp, presentedTimestamp, presentationUptime in
                guard let self,
                      let sourceSession = self.session,
                      let sourceSessionID = self.sessionLifetimeID,
                      self.presentationLifetime.accepts(lifetimeToken),
                      self.selectedGeneration == generation,
                      self.streamGenerationGate.accepts(generation) else { return }
                Task { @MainActor [weak self] in
                    let snapshot = await sourceSession.snapshot()
                    guard let self,
                          self.session === sourceSession,
                          self.sessionLifetimeID == sourceSessionID else { return }
                    guard self.synchronizeAuthorization(for: sourceSession, snapshot: snapshot) else { return }
                    guard snapshot.authorized,
                          snapshot.authorizedCapabilities.contains(.h264Video),
                          snapshot.authorizedWindowGeneration == generation,
                          self.presentationLifetime.accepts(lifetimeToken),
                          self.selectedGeneration == generation,
                          self.streamGenerationGate.accepts(generation) else { return }
                    self.recordPresentation(
                        captureTimestamp: captureTimestamp,
                        presentedTimestamp: presentedTimestamp,
                        presentationUptime: presentationUptime
                    )
                    self.contentView?.markFramePresented()
                }
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
              connectionAttemptID == nil,
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
            case .superseded:
                break
            }
        }
    }

    private func connect(
        to service: DiscoveredService,
        reconnectID: UUID? = nil
    ) async -> ConnectResult {
        guard session == nil,
              connectionAttemptID == nil,
              reconnectID == nil || reconnectTaskID == reconnectID,
              !isShuttingDown else { return .superseded }
        let attemptID = UUID()
        connectionAttemptID = attemptID
#if DEBUG
        let diagnosticUptime = DispatchTime.now().uptimeNanoseconds
        flushDebugVideoWindowForTransition(atUptimeNanoseconds: diagnosticUptime)
        M10ViewerDiagnosticRecorder.shared.recordConnectionStarted(
            atUptimeNanoseconds: diagnosticUptime
        )
#endif
        defer {
            if connectionAttemptID == attemptID {
                connectionAttemptID = nil
            }
        }

        contentView?.setConnectionState(reconnectID != nil ? .reconnecting : .connecting)
        contentView?.setPeerName(service.name)
        contentView?.setPairingRetryVisible(false)
        var attemptSession: SessionCoordinator?
        var retryCleanupOwnership: ViewerRetryCleanupOwnership?
        do {
            let localIdentity = try await loadLocalIdentity()
            guard ownsConnectionAttempt(attemptID), !Task.isCancelled, !isShuttingDown else {
                return .superseded
            }
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
            let candidateSession = SessionCoordinator(
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
            guard ownsConnectionAttempt(attemptID), !Task.isCancelled, !isShuttingDown else {
                await candidateSession.stop(reason: .normal)
                return .superseded
            }
            attemptSession = candidateSession
            self.session = candidateSession
#if DEBUG
            recordDebugSessionState(await candidateSession.snapshot())
#endif
            let candidateSessionID = UUID()
            sessionLifetimeID = candidateSessionID
            if let reconnectID {
                retryCleanupOwnership = ViewerRetryCleanupOwnership(
                    sessionID: candidateSessionID,
                    attemptID: attemptID,
                    reconnectID: reconnectID
                )
            }
            authorizationFingerprint = nil
            updateInputSendScope(nil)
            advancePresentationLifetime(resetDecoder: true)
            self.inputTransport = ViewerInputTransport(session: candidateSession)
            let loop = ViewerSessionMessageLoop(session: candidateSession) { [weak self] message in
                await self?.handle(message, from: candidateSession)
            }
            loop.onClipboardStatusChange = { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.refreshInputSurface(for: candidateSession)
                }
            }
            messageLoop = loop
            loop.start()
            contentView?.updateStream(size: .zero, readiness: .awaitingAuthentication)
            try await candidateSession.start()
            guard ownsConnectionAttempt(attemptID), self.session === candidateSession,
                  !Task.isCancelled, !isShuttingDown else { return .superseded }
            try await waitForPairing(
                candidateSession,
                pairingCoordinator: pairingCoordinator,
                attemptID: attemptID
            )
            guard ownsConnectionAttempt(attemptID), self.session === candidateSession,
                  !Task.isCancelled, !isShuttingDown else { return .superseded }
            let sessionSnapshot = await candidateSession.snapshot()
            guard ownsConnectionAttempt(attemptID), self.session === candidateSession,
                  !Task.isCancelled, !isShuttingDown else { return .superseded }
            contentView?.setPeerName(sessionSnapshot.peerDeviceName ?? service.name)
            sessionMonitorTask = Task { @MainActor [weak self] in
                await self?.monitorSession(candidateSession)
            }
            contentView?.setConnectionState(.connected)
            setStatus("Connected; waiting for a selected window")
            contentView?.setPairingRetryVisible(false)
#if DEBUG
            M10ViewerDiagnosticRecorder.shared.recordConnectionOutcome(.connected)
#endif
            await refreshInputSurface(for: candidateSession)
            guard self.session === candidateSession else { return .superseded }
            return .connected
        } catch let error as SessionError {
            guard ownsConnectionAttempt(attemptID) else {
                if let attemptSession { await attemptSession.stop(reason: .normal) }
                return .superseded
            }
#if DEBUG
            recordDebugSessionFailure(error)
#endif
            if error == .pairingDenied {
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.recordConnectionOutcome(.pairingDenied)
#endif
                pairingRetryRequired = true
                setStatus("Pairing was denied; click Retry pairing to try again")
                contentView?.setPairingRetryVisible(true)
            } else {
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.recordConnectionOutcome(.sessionFailure)
#endif
                setStatus("Connection unavailable; check trusted identities and Local Network permission")
                contentView?.setPairingRetryVisible(false)
            }
            if let attemptSession {
                await resetSession(
                    expectedSession: attemptSession,
                    retryCleanupOwnership: error == .pairingDenied ? nil : retryCleanupOwnership
                )
            }
            return error == .pairingDenied ? .pairingDenied : .retryableFailure
        } catch {
            guard ownsConnectionAttempt(attemptID) else {
                if let attemptSession { await attemptSession.stop(reason: .normal) }
                return .superseded
            }
#if DEBUG
            M10ViewerDiagnosticRecorder.shared.recordConnectionOutcome(.connectionFailure)
#endif
            setStatus("Connection unavailable; check trusted identities and Local Network permission")
            contentView?.setPairingRetryVisible(false)
            if let attemptSession {
                await resetSession(
                    expectedSession: attemptSession,
                    retryCleanupOwnership: retryCleanupOwnership
                )
            }
            return .retryableFailure
        }
    }

    private func ownsConnectionAttempt(_ attemptID: UUID) -> Bool {
        connectionAttemptID == attemptID
    }

#if DEBUG
    private func recordDebugSessionFailure(_ error: SessionError?) {
        guard let error else { return }
        M10ViewerDiagnosticRecorder.shared.record(.sessionFailure(error.failureCategory))
        if let terminationClass = error.transportTerminationClass {
            M10ViewerDiagnosticRecorder.shared.record(.transportTermination(terminationClass))
        }
    }

    private func recordDebugSessionState(_ snapshot: SessionSnapshot) {
        let state: M10ViewerSessionState
        switch snapshot.state {
        case .discovered: state = .discovered
        case .connecting: state = .connecting
        case .authenticated: state = .authenticated
        case .pairingRequired: state = .pairingRequired
        case .trusted: state = .trusted
        case .capabilitiesNegotiated: state = .capabilitiesNegotiated
        case .windowSelectionAuthorized: state = .windowSelectionAuthorized
        case .streaming: state = .streaming
        case .stopping: state = .stopping
        case .reconnecting: state = .reconnecting
        case .failed: state = .failed
        }
        M10ViewerDiagnosticRecorder.shared.recordSessionState(
            M10ViewerSessionDiagnosticSnapshot(
                state: state,
                authorized: snapshot.authorized,
                windowAuthorized: snapshot.authorizedWindowGeneration != nil,
                videoCapability: snapshot.authorizedCapabilities.contains(.h264Video),
                mouseCapability: snapshot.authorizedCapabilities.contains(.mouseInput),
                keyboardCapability: snapshot.authorizedCapabilities.contains(.keyboardInput),
                windowSelectionCapability: snapshot.authorizedCapabilities.contains(.windowSelection),
                clipboardCapability: snapshot.authorizedCapabilities.contains(.textClipboard),
                backgroundControlCapability: snapshot.authorizedCapabilities.contains(.backgroundControl)
            )
        )
    }

    private func recordDebugInputReadiness(
        _ readiness: InputReadiness,
        keyboardAvailable: Bool
    ) {
        let diagnosticReadiness: M10ViewerInputReadiness
        let reason: M10ViewerInputReason
        switch readiness {
        case .awaitingAuthentication:
            diagnosticReadiness = .awaitingAuthentication
            reason = .awaitingAuthentication
        case .awaitingAuthorization:
            diagnosticReadiness = .awaitingAuthorization
            reason = selectedWindowIdentifier == nil ? .windowNotSelected : .authorizationRequired
        case .surfaceUnavailable:
            diagnosticReadiness = .surfaceUnavailable
            reason = .surfaceUnavailable
        case .hostPermissionUnavailable:
            diagnosticReadiness = .hostPermissionUnavailable
            reason = .hostPermission
        case .hostFocusUnavailable:
            diagnosticReadiness = .hostFocusUnavailable
            reason = .hostFocus
        case .hostStateUnavailable:
            diagnosticReadiness = .hostStateUnavailable
            reason = .hostInputState
        case .hostControlNegotiating:
            diagnosticReadiness = .hostControlNegotiating
            reason = .controlSetupPending
        case .hostControlUnavailable:
            diagnosticReadiness = .hostControlUnavailable
            switch hostControlState {
            case .requiresConsent: reason = .controlConsentRequired
            case .paused: reason = .controlPaused
            case .revoked: reason = .controlRevoked
            case .persistenceFailure: reason = .controlPersistenceFailure
            case .unsupported: reason = .controlUnsupported
            case .active, .negotiating, .none: reason = .capabilityUnavailable
            }
        case .hostProcessTargetUnavailable:
            diagnosticReadiness = .hostProcessTargetUnavailable
            reason = .unsafeProcessTarget
        case .ready:
            diagnosticReadiness = .ready
            reason = keyboardAvailable ? .ready : .keyboardCapabilityUnavailable
        }
        M10ViewerDiagnosticRecorder.shared.recordInputReadiness(
            diagnosticReadiness,
            reason: reason,
            keyboardAvailable: keyboardAvailable
        )
    }

    private func beginDebugVideoWindow(at uptime: TimeInterval) {
        let nanoseconds = UInt64(max(0, uptime) * 1_000_000_000)
        flushDebugVideoWindowForTransition(atUptimeNanoseconds: nanoseconds)
        debugVideoWindow.begin(at: nanoseconds)
    }

    private func flushDebugVideoWindowIfDue(at uptime: TimeInterval) {
        guard let summary = debugVideoWindow.takeSummaryIfDue(
            at: UInt64(max(0, uptime) * 1_000_000_000)
        ) else { return }
        M10ViewerDiagnosticRecorder.shared.recordVideoWindowSummary(summary)
    }

    private func flushDebugVideoWindowForTransition(atUptimeNanoseconds nanoseconds: UInt64) {
        guard let summary = debugVideoWindow.takePendingSummary(at: nanoseconds) else { return }
        M10ViewerDiagnosticRecorder.shared.recordVideoWindowSummary(summary)
    }

    private func openDebugLog() {
        let url = M10ViewerDiagnosticFileLog.logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
#endif

    private func monitorSession(_ observedSession: SessionCoordinator) async {
        var previous = await observedSession.snapshot()
#if DEBUG
        recordDebugSessionState(previous)
#endif
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            guard session === observedSession else { return }
            let current = await observedSession.snapshot()
            guard session === observedSession else { return }
#if DEBUG
            recordDebugSessionState(current)
#endif
            let clockSyncEstimate = await observedSession.clockSyncEstimate()
            guard session === observedSession else { return }
            guard synchronizeAuthorization(for: observedSession, snapshot: current) else { continue }
            refreshPresentedFPS(now: ProcessInfo.processInfo.systemUptime)
            latestClockSyncEstimate = clockSyncEstimate
            contentView?.setConnectionLatency(latestClockSyncEstimate)
            latestPerformanceSnapshot = performanceCollector.snapshot(
                clockSync: latestClockSyncEstimate
            )
            logStageBudgetIfDue()
#if DEBUG
            flushDebugVideoWindowIfDue(at: ProcessInfo.processInfo.systemUptime)
            M10ViewerDiagnosticRecorder.shared.flushInputWindowIfDue()
#endif
            if current.authorizationGeneration != previous.authorizationGeneration ||
                current.authorized != previous.authorized ||
                current.authorizedWindowGeneration != previous.authorizedWindowGeneration ||
                current.authorizedCapabilities != previous.authorizedCapabilities {
                await refreshInputSurface(for: observedSession)
            }
            guard session === observedSession else { return }
            guard synchronizeAuthorization(for: observedSession, snapshot: current) else { continue }
            previous = current
            guard current.state == .failed else { continue }

            // This task owns the failure transition, so resetSession must not
            // cancel and join this task recursively.
            sessionMonitorTask = nil
#if DEBUG
            recordDebugSessionFailure(await observedSession.failureReason())
#endif
            await resetSession(expectedSession: observedSession, cancelMonitor: false)
            scheduleReconnect()
            return
        }
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard reconnectTask == nil,
              connectionAttemptID == nil,
              session == nil,
              !isShuttingDown else { return }
        guard !pairingRetryRequired else { return }
        guard let service = lastDiscoveredService else {
            setStatus("Connection lost; rediscover the Host to reconnect")
            return
        }

        setStatus("Connection lost; reconnecting…")
        contentView?.setConnectionState(.reconnecting)
        contentView?.setHostSelectionEnabled(false)
        let reconnectID = UUID()
        reconnectTaskID = reconnectID
        reconnectTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.reconnectTaskID == reconnectID {
                    self.reconnectTask = nil
                    self.reconnectTaskID = nil
                }
            }
            let delays: [UInt64] = immediate ? [0, 1, 2, 3, 4] : [1, 2, 3, 4, 5]
            for delay in delays {
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    } catch {
                        return
                    }
                }
                guard let self,
                      self.reconnectTaskID == reconnectID,
                      !self.isShuttingDown,
                      self.session == nil,
                      self.connectionAttemptID == nil else { return }
                switch await self.connect(to: service, reconnectID: reconnectID) {
                case .connected:
                    return
                case .pairingDenied:
                    return
                case .retryableFailure:
                    continue
                case .superseded:
                    return
                }
            }
            guard let self,
                  self.reconnectTaskID == reconnectID,
                  !self.isShuttingDown,
                  self.session == nil,
                  self.connectionAttemptID == nil else { return }
            self.contentView?.setConnectionState(.disconnected)
            self.contentView?.setHostSelectionEnabled(true)
            self.setStatus("Host unavailable; start the Viewer to retry")
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectTaskID = nil
    }

    private func waitForPairing(
        _ session: SessionCoordinator,
        pairingCoordinator: PairingCoordinator,
        attemptID: UUID
    ) async throws {
        var promptedChallengeID: UInt64?
        while !Task.isCancelled {
            let snapshot = await session.snapshot()
            guard ownsConnectionAttempt(attemptID), self.session === session,
                  !isShuttingDown else { throw CancellationError() }
#if DEBUG
            recordDebugSessionState(snapshot)
#endif
            switch snapshot.state {
            case .trusted, .capabilitiesNegotiated, .windowSelectionAuthorized, .streaming:
                return
            case .pairingRequired:
                setStatus("Confirm pairing on both Macs")
                if let challenge = await pairingCoordinator.pendingChallenge(),
                   challenge.isVerificationReady,
                   promptedChallengeID != challenge.challengeID {
                    guard ownsConnectionAttempt(attemptID), self.session === session,
                          !isShuttingDown else { throw CancellationError() }
                    let consent = await pairingCoordinator.consentState()
                    guard ownsConnectionAttempt(attemptID), self.session === session,
                          !isShuttingDown else { throw CancellationError() }
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
                    guard !Task.isCancelled,
                          ownsConnectionAttempt(attemptID), self.session === session,
                          !isShuttingDown else { throw CancellationError() }
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

    private func handle(_ message: MessagePayload, from sourceSession: SessionCoordinator) async {
        guard session === sourceSession else { return }
        switch message {
        case let .windowList(windowList):
#if DEBUG
            let receivedEligibleCount = UInt64(windowList.windows.filter(\.eligible).count)
            debugEligibleWindowCount = receivedEligibleCount
            M10ViewerDiagnosticRecorder.shared.recordWindowCatalog(
                eligibleCount: receivedEligibleCount,
                selected: selectedWindowIdentifier != nil && pendingWindowSelection == nil
            )
#endif
            let snapshot = await sourceSession.snapshot()
            guard session === sourceSession else { return }
            guard synchronizeAuthorization(for: sourceSession, snapshot: snapshot) else { return }
            guard let generation = snapshot.authorizedWindowGeneration else {
                await refreshInputSurface(for: sourceSession)
                return
            }
            let selectionWasRejected = pendingWindowSelection.map {
                $0.catalogGeneration != windowList.catalogGeneration
            } ?? false
            if selectionWasRejected {
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.hostRejected)
#endif
                pendingWindowSelection = nil
                selectedWindowIdentifier = nil
                contentView?.setWindowSelectionEnabled(true)
            }
            let eligibleWindows = windowList.windows.filter(\.eligible)
#if DEBUG
            debugEligibleWindowCount = UInt64(eligibleWindows.count)
#endif
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
            await refreshInputSurface(for: sourceSession)
            guard session === sourceSession else { return }
            if selectionWasRejected {
                setStatus("Host window list changed — select a window again")
            }

        case let .streamConfig(config):
            let snapshot = await sourceSession.snapshot()
            guard session === sourceSession else { return }
            guard synchronizeAuthorization(for: sourceSession, snapshot: snapshot) else { return }
            guard snapshot.authorized,
                  snapshot.authorizedCapabilities.contains(.h264Video),
                  snapshot.authorizedWindowGeneration == config.generation else { return }
            guard config.codec == .h264 else {
                setStatus("Unsupported video codec")
                return
            }
            selectedGeneration = config.generation
#if DEBUG
            if pendingWindowSelection != nil {
                M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.hostAcknowledged)
                M10ViewerDiagnosticRecorder.shared.recordWindowCatalog(
                    eligibleCount: debugEligibleWindowCount,
                    selected: true
                )
            }
#endif
            pendingWindowSelection = nil
            streamGenerationGate.advance(to: config.generation)
            streamDimensions = CGSize(width: CGFloat(config.width), height: CGFloat(config.height))
            reportedVideoFailureGeneration = nil
            resetPresentedFPS()
            videoStreamExpectedSince = ProcessInfo.processInfo.systemUptime
#if DEBUG
            beginDebugVideoWindow(at: ProcessInfo.processInfo.systemUptime)
#endif
            performanceCollector.reset()
            latestPerformanceSnapshot = nil
            receiveToPresentCollector.reset()
            pendingFrameReceiptNanoseconds.removeAll()
            advancePresentationLifetime(resetDecoder: true)
            contentView?.updateStream(size: streamDimensions, readiness: .awaitingAuthorization)
            contentView?.setWindowSelectionEnabled(true)
            await refreshInputSurface(for: sourceSession)
            guard session === sourceSession else { return }
            setStatus("Receiving video")

        case let .videoConfig(config):
            let snapshot = await sourceSession.snapshot()
            guard session === sourceSession else { return }
            guard synchronizeAuthorization(for: sourceSession, snapshot: snapshot) else { return }
            guard snapshot.authorized,
                  snapshot.authorizedCapabilities.contains(.h264Video),
                  snapshot.authorizedWindowGeneration == config.generation,
                  config.generation == selectedGeneration,
                  streamGenerationGate.accepts(config.generation) else { return }
            do {
                let decoderConfiguration = try H264DecoderConfiguration.decode(config.decoderConfiguration)
                advancePresentationLifetime(resetDecoder: true)
                try decoder.configure(configuration: decoderConfiguration, generation: config.generation)
            } catch {
                setStatus("Video decoder configuration failed")
            }

        case let .videoFrame(frame):
            let snapshot = await sourceSession.snapshot()
            guard session === sourceSession else { return }
            guard synchronizeAuthorization(for: sourceSession, snapshot: snapshot) else { return }
            guard snapshot.authorized,
                  snapshot.authorizedCapabilities.contains(.h264Video),
                  snapshot.authorizedWindowGeneration == frame.generation,
                  frame.generation == selectedGeneration,
                  streamGenerationGate.accepts(frame.generation) else { return }
#if DEBUG
            debugVideoWindow.recordReceived()
#endif
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
                let decodeSessionID = sessionLifetimeID
                let decodeAuthorizationGeneration = snapshot.authorizationGeneration
                let decodeLifetimeToken = presentationLifetime.token
                try decoder.decode(encoded) { [weak self] result in
                    Task { @MainActor [weak self] in
                        let decodedSnapshot = await sourceSession.snapshot()
                        guard let self,
                              self.session === sourceSession,
                              self.sessionLifetimeID == decodeSessionID else { return }
                        guard self.synchronizeAuthorization(for: sourceSession, snapshot: decodedSnapshot) else { return }
                        guard decodedSnapshot.authorized,
                              decodedSnapshot.authorizedCapabilities.contains(.h264Video),
                              decodedSnapshot.authorizationGeneration == decodeAuthorizationGeneration,
                              decodedSnapshot.authorizedWindowGeneration == decodeGeneration,
                              self.presentationLifetime.accepts(decodeLifetimeToken),
                              self.selectedGeneration == decodeGeneration,
                              self.streamGenerationGate.accepts(decodeGeneration) else {
                            return
                        }
                        self.present(
                            result,
                            from: sourceSession,
                            lifetimeToken: decodeLifetimeToken
                        )
                    }
                }
            } catch let error as CodecError {
                // A non-keyframe before decoder configuration is expected to
                // be dropped; ask for the next keyframe instead of waiting for
                // the periodic one.
                if error == .missingDecoderConfiguration {
#if DEBUG
                    debugVideoWindow.recordDecodeFailure()
#endif
                    requestRecoveryKeyframe()
                } else if error != .cancelled {
                    reportVideoDecodeFailure(error)
                }
            } catch {
#if DEBUG
                debugVideoWindow.recordDecodeFailure()
#endif
                setStatus("Video frame could not be decoded")
            }

        case let .sessionState(message):
            if message.state == .failed || message.state == .stopping {
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.record(.peerTerminal(
                    message.state == .failed ? .sessionFailed : .sessionStopping
                ))
#endif
            }
            let snapshot = await sourceSession.snapshot()
            guard session === sourceSession else { return }
            guard synchronizeAuthorization(for: sourceSession, snapshot: snapshot) else { return }
            if let controlState = message.controlState {
                hostControlState = controlState
                if snapshot.negotiatedCapabilities.contains(.backgroundControl) {
                    hostControlGeneration = message.controlGeneration
                }
            }
            let processTargetStatusIsCurrent = message.windowGeneration == snapshot.authorizedWindowGeneration &&
                (message.windowGeneration == nil || snapshot.authorized)
            if processTargetStatusIsCurrent, let processTargetEligible = message.processTargetEligible {
                hostProcessTargetEligible = processTargetEligible
            }
            if message.state == .failed || message.state == .stopping {
                hostInputPermission = .unknown
                hostInputFocusEligible = false
                hostInputStatusGeneration = nil
                hostControlState = nil
                hostProcessTargetEligible = nil
                hostControlGeneration = nil
            } else if message.controlState == nil || message.processTargetEligible != nil {
                if let generation = message.windowGeneration,
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
            } else if message.controlState != nil,
                      message.processTargetEligible == nil {
                // Control-only updates must not erase the independent Host
                // permission/focus snapshot for this window generation.
                // Keep the prior status; `controlState` is still refreshed.
            }
            await refreshInputSurface(for: sourceSession)
            guard session === sourceSession else { return }
            if hostInputPermission == .missing || hostInputPermission == .revoked {
                setStatus("Connected — enable PostEvent permission for MacRemoteApp Host")
            } else if hostInputPermission == .unknown {
                setStatus("Connected — waiting for Host input status")
            } else if !snapshot.negotiatedCapabilities.contains(.backgroundControl),
                      !hostInputFocusEligible {
                setStatus(ViewerInputStatusPresentation.hostFocusUnavailableStatus)
            }

        case let .inputSourceAcknowledgement(acknowledgement):
            await handleInputSourceAcknowledgement(acknowledgement, from: sourceSession)

        case .close:
#if DEBUG
            M10ViewerDiagnosticRecorder.shared.record(.peerTerminal(.close))
#endif
            // The callback is running inside ViewerSessionMessageLoop. Defer
            // teardown until the callback returns so stop() never waits on
            // the message-loop task itself. A peer close is recoverable; only
            // application termination uses disconnect(), which stops Bonjour.
            Task { @MainActor [weak self] in
                guard let self, self.session === sourceSession else { return }
                await self.resetSession(expectedSession: sourceSession)
                self.scheduleReconnect()
            }

        default:
            await refreshInputSurface(for: sourceSession)
        }
    }

    private func selectWindow(
        _ windowIdentifier: UInt64,
        generation: UInt64,
        catalogGeneration: UInt64
    ) {
        guard let session else { return }
        switch ViewerWindowSelectionAction.resolve(
            requestedWindowIdentifier: windowIdentifier,
            selectedWindowIdentifier: selectedWindowIdentifier,
            streamGeneration: selectedGeneration,
            selectionPending: pendingWindowSelection != nil,
            selectionInFlight: windowSelectionInFlight || foregroundRestorePending
        ) {
        case .ignore:
            return
        case .restoreForeground:
            requestForegroundRestore(
                windowIdentifier,
                generation: generation,
                catalogGeneration: catalogGeneration,
                session: session
            )
            return
        case .replaceSelection:
            break
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await session.snapshot()
            guard self.session === session else { return }
            guard synchronizeAuthorization(for: session, snapshot: snapshot) else { return }
            guard snapshot.authorizedWindowGeneration == generation else {
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.rejectedLocally)
#endif
                setStatus("Window list expired; waiting for Host")
                return
            }
            guard contentView?.windowSelectionCatalogGeneration == catalogGeneration else {
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.rejectedLocally)
#endif
                setStatus("Window catalog expired; waiting for Host")
                return
            }
            guard windowOptionsContain(windowIdentifier) else {
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.rejectedLocally)
#endif
                setStatus("Window is no longer available")
                return
            }
            windowSelectionInFlight = true
#if DEBUG
            M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.requested)
#endif
            resetPresentedFPS()
            selectedGeneration = nil
            streamGenerationGate.revoke()
            updateInputSendScope(nil)
            advancePresentationLifetime(resetDecoder: true)
            streamDimensions = .zero
            hostInputPermission = .unknown
            hostInputFocusEligible = false
            hostInputStatusGeneration = nil
            contentView?.updateStream(size: .zero, readiness: .awaitingAuthorization)
            contentView?.setWindowSelectionEnabled(false)
            await refreshInputSurface(for: session)
            guard self.session === session else { return }
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
                guard self.session === session else { return }
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.sent)
#endif
                selectedWindowIdentifier = windowIdentifier
                contentView?.setSelectedWindowIdentifier(windowIdentifier)
                pendingWindowSelection = (windowIdentifier, catalogGeneration)
                setStatus("Window selected; starting video")
                await refreshInputSurface(for: session)
                guard self.session === session else { return }
            } catch {
                guard self.session === session else { return }
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.sendFailed)
#endif
                pendingWindowSelection = nil
                selectedWindowIdentifier = nil
                contentView?.setWindowSelectionEnabled(true)
                setStatus("Window selection was rejected")
            }
            if self.session === session {
                windowSelectionInFlight = false
            }
        }
    }

    /// Re-sends the explicit selection for the window that is already
    /// streaming. Host policy allows a cooperative foreground request only for
    /// an explicit Viewer selection; this gives the operator that action after
    /// focus was lost. The stream, decoder, and input scope stay as they are,
    /// and input readiness changes only when the Host reports fresh status.
    private func requestForegroundRestore(
        _ windowIdentifier: UInt64,
        generation: UInt64,
        catalogGeneration: UInt64,
        session: SessionCoordinator
    ) {
        windowSelectionInFlight = true
        foregroundRestorePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var awaitingHostStatus = false
            defer {
                if self.session === session {
                    windowSelectionInFlight = false
                    if !awaitingHostStatus {
                        foregroundRestorePending = false
                    }
                }
            }
            let snapshot = await session.snapshot()
            guard self.session === session else { return }
            guard synchronizeAuthorization(for: session, snapshot: snapshot) else { return }
            guard snapshot.authorizedWindowGeneration == generation,
                  contentView?.windowSelectionCatalogGeneration == catalogGeneration,
                  windowOptionsContain(windowIdentifier),
                  selectedWindowIdentifier == windowIdentifier else {
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.rejectedLocally)
#endif
                setStatus("Window list expired; waiting for Host")
                return
            }
#if DEBUG
            M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.requested)
#endif
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
                guard self.session === session else { return }
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.sent)
#endif
                if !hostInputFocusEligible {
                    awaitingHostStatus = true
                    setStatus(ViewerInputStatusPresentation.restoreForegroundRequestedStatus)
                    scheduleForegroundRestoreFallback(for: session, generation: generation)
                }
            } catch {
                guard self.session === session else { return }
#if DEBUG
                M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.sendFailed)
#endif
                setStatus("Could not reach the Host to bring the app forward")
            }
        }
    }

    /// The Host sends nothing when a cooperative foreground request is
    /// refused. Restore the actionable focus guidance if no ready status for
    /// the same window generation has arrived after the Host's bounded attempt.
    private func scheduleForegroundRestoreFallback(
        for session: SessionCoordinator,
        generation: UInt64
    ) {
        Task { @MainActor [weak self] in
            // Poll so a successful restore re-enables Select promptly; the
            // Host's bounded attempt finishes well inside the timeout.
            let deadline = DispatchTime.now().uptimeNanoseconds &+ 6_000_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.session === session else { return }
                if hostInputFocusEligible {
                    foregroundRestorePending = false
                    return
                }
            }
            guard let self, self.session === session else { return }
            foregroundRestorePending = false
            guard hostInputStatusGeneration == generation || hostInputStatusGeneration == nil,
                  !hostInputFocusEligible else { return }
            let snapshot = await session.snapshot()
            guard self.session === session,
                  snapshot.authorizedWindowGeneration == generation,
                  !hostInputFocusEligible else { return }
            setStatus(ViewerInputStatusPresentation.hostFocusUnavailableStatus)
        }
    }

    private func windowOptionsContain(_ identifier: UInt64) -> Bool {
        contentView?.containsWindow(identifier) == true
    }

    private func present(
        _ result: Result<DecodedH264Frame, CodecError>,
        from sourceSession: SessionCoordinator,
        lifetimeToken: UUID
    ) {
        guard session === sourceSession,
              presentationLifetime.accepts(lifetimeToken) else { return }
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
            streamGeneration: frame.generation,
            lifetimeToken: lifetimeToken
        ) else {
            setStatus("Video decoded, but the Metal view is unavailable")
            return
        }
    }

    private func reportVideoDecodeFailure(_ error: CodecError) {
#if DEBUG
        debugVideoWindow.recordDecodeFailure()
#endif
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
#if DEBUG
        debugVideoWindow.recordPresented()
#endif
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
        lastPresentedFrameUptime = max(lastPresentedFrameUptime ?? uptime, uptime)
        if ViewerVideoRecoveryStatusPolicy.shouldRestoreReceiving(
            currentStatus: contentView?.status ?? ""
        ) {
            setStatus(ViewerVideoRecoveryStatusPolicy.receivingStatus)
        }
        presentedFPSIsIdle = false
        presentedFrameTimes.append(uptime)
        presentedFrameTimes.sort()
        lastPresentedFrameTime = max(lastPresentedFrameTime ?? uptime, uptime)
        refreshPresentedFPS(now: lastPresentedFrameTime ?? uptime)
    }

    private func refreshPresentedFPS(now: TimeInterval) {
        let lastVideoActivity = lastPresentedFrameUptime ?? videoStreamExpectedSince
        if ViewerVideoRecoveryStatusPolicy.shouldShowRecovering(
            currentStatus: contentView?.status ?? "",
            hasSelectedWindow: selectedWindowIdentifier != nil,
            hasSelectedGeneration: selectedGeneration != nil,
            lastVideoActivity: lastVideoActivity,
            now: now
        ) {
            setStatus(ViewerVideoRecoveryStatusPolicy.recoveringStatus)
        }
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
        lastPresentedFrameUptime = nil
        videoStreamExpectedSince = nil
        presentedFPSIsIdle = false
        contentView?.updatePresentedFPS("FPS: —")
    }

    private func enqueueInput(_ record: InputEventRecord) {
        guard let scope = activeInputSendScope,
              record.windowGeneration == scope.windowGeneration,
              let transport = inputTransport else { return }

        if record.kind == .keyDown || record.kind == .keyUp {
            prepareInputSourceStateBeforeKey(in: scope)
            switch inputSourceSyncGate.routeKeyboard(record, in: scope) {
            case .send:
                enqueueInputRecord(
                    record,
                    in: scope,
                    transport: transport,
                    keyboardDeliveryToken: inputSourceSyncGate.keyboardDeliveryToken
                )
            case .buffered, .discarded:
                break
            case .overflow:
                setInputSourceSyncStatus(
                    "Input-source sync queue is full — enable the same Chinese input method on Host, then retry",
                    retryAvailable: true
                )
            }
            return
        }
        enqueueInputRecord(record, in: scope, transport: transport)
    }

    private func enqueueInputRecord(
        _ record: InputEventRecord,
        in scope: ViewerInputSendScope,
        transport: ViewerInputTransport,
        keyboardDeliveryToken: UUID? = nil
    ) {
        _ = inputSendQueue.enqueue(record, in: scope) { [weak self] event, authorizationGeneration in
            guard let self else { return .discarded }
            if let keyboardDeliveryToken,
               !self.inputSourceSyncGate.allowsQueuedKeyboardSend(
                   event,
                   in: scope,
                   deliveryToken: keyboardDeliveryToken
               ) {
                return .discarded
            }
            try await transport.send(
                event,
                expectedAuthorizationGeneration: authorizationGeneration,
                controlGeneration: scope.controlGeneration
            )
            if keyboardDeliveryToken != nil {
                self.inputSourceSyncGate.noteDelivered(event, in: scope)
            }
            return .sent
        }
    }

    private func prepareInputSourceStateBeforeKey(in scope: ViewerInputSendScope) {
        guard inputSourceFollowViewer,
              inputSourceSyncCapabilityAvailable,
              remoteSurfaceFocused else {
            if inputSourceSyncGate.scope != scope || inputSourceSyncGate.state == .inactive {
                inputSourceSyncGate.useManualSelection(in: scope)
            }
            return
        }
        guard let source = inputSourceProvider.currentInputSource() else {
            inputSourceSyncGate.useManualSelection(in: scope)
            setInputSourceSyncStatus(
                "Unsupported Viewer input source — match sources manually",
                retryAvailable: false
            )
            return
        }
        if inputSourceSyncGate.needsSynchronization(to: source, in: scope) {
            beginInputSourceSynchronization(to: source, in: scope)
        }
    }

    private func enqueueInputSourceSelection(
        _ request: ViewerInputSourceSyncRequest,
        in scope: ViewerInputSendScope,
        transport: ViewerInputTransport
    ) {
        _ = inputSendQueue.enqueueStatefulOperation(
            in: scope,
            mayEndHeldInputState: true
        ) { [weak self] queuedScope in
            guard let self else { return [] }
            var deliveredTransitions: [InputStateTransition] = []

            // This operation is behind every previously admitted input event.
            // Releases are derived from the transport-confirmed held-key set,
            // not from locally queued keyDowns that never reached the Host.
            let heldKeys = self.inputSourceSyncGate.takeRemoteKeysForOrderedRelease(in: queuedScope)
            let releases = self.contentView?.surface.makeOrderedKeyReleases(for: heldKeys) ?? []
            for release in releases {
                try await transport.send(
                    release,
                    expectedAuthorizationGeneration: queuedScope.authorizationGeneration
                )
                self.inputSourceSyncGate.noteDelivered(release, in: queuedScope)
                if let keyCode = release.keyCode {
                    deliveredTransitions.append(.ended(.key(keyCode)))
                }
            }

            guard self.inputSourceSyncGate.isCurrent(request) else { return deliveredTransitions }
            do {
                try await transport.sendInputSourceSelection(request) { [weak self] in
                    guard let self,
                          self.activeInputSendScope == queuedScope,
                          self.remoteSurfaceFocused,
                          self.inputSourceFollowViewer,
                          self.inputSourceSyncCapabilityAvailable,
                          self.inputSourceSyncGate.isCurrent(request),
                          self.inputSourceProvider.currentInputSource() == request.source else {
                        return false
                    }
                    return true
                }
            } catch ViewerInputTransportError.inputSourceRequestNotAdmitted {
                // Focus/source/request changed while waiting for the session's
                // outbound mutex. The current lifecycle callback will either
                // start a fresh request or leave keyboard input in manual mode.
            }
            return deliveredTransitions
        }
    }

    private func beginInputSourceSynchronization(
        to source: InputSourceDescriptor,
        in scope: ViewerInputSendScope
    ) {
        guard let transport = inputTransport,
              let request = inputSourceSyncGate.beginSynchronization(in: scope, source: source) else {
            setInputSourceSyncStatus(
                "Input-source sync unavailable — match sources manually",
                retryAvailable: true
            )
            return
        }
        inputSourceSyncTimeoutTask?.cancel()
        setInputSourceSyncStatus("Waiting for Host input-source change…", retryAvailable: false)
        enqueueInputSourceSelection(request, in: scope, transport: transport)
        inputSourceSyncTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.inputSourceSyncTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.inputSourceSyncGate.timeout(scope: scope, requestID: request.requestID) else {
                return
            }
            self.setInputSourceSyncStatus(
                "Input source sync timed out — enable the same Chinese input method on Host, then retry",
                retryAvailable: true
            )
        }
    }

    private func handleInputSourceAcknowledgement(
        _ acknowledgement: InputSourceAcknowledgementMessage,
        from sourceSession: SessionCoordinator
    ) async {
        guard session === sourceSession else { return }
        let snapshot = await sourceSession.snapshot()
        guard session === sourceSession,
              synchronizeAuthorization(for: sourceSession, snapshot: snapshot) else { return }
        guard let scope = activeInputSendScope,
              scope.sessionID == sessionLifetimeID,
              snapshot.authorized,
              scope.authorizationGeneration == snapshot.authorizationGeneration,
              snapshot.authorizedWindowGeneration == scope.windowGeneration,
              scope.windowGeneration == acknowledgement.windowGeneration else {
            await refreshInputSurface(for: sourceSession)
            return
        }
        let disposition = inputSourceSyncGate.acknowledge(
            scope: scope,
            requestID: acknowledgement.requestID,
            applied: acknowledgement.status == .applied
        )
        switch disposition {
        case .stale:
            return
        case .failed:
            inputSourceSyncTimeoutTask?.cancel()
            switch acknowledgement.status {
            case .unavailable:
                setInputSourceSyncStatus(
                    "Source unavailable on Host — enable the same Chinese input method, then retry",
                    retryAvailable: true
                )
            case .denied:
                setInputSourceSyncStatus(
                    "Host could not safely change its input source — return to the remote view, then retry",
                    retryAvailable: true
                )
            case .failed, .applied:
                setInputSourceSyncStatus(
                    "Host could not change its input source — enable the same Chinese input method, then retry",
                    retryAvailable: true
                )
            }
        case let .applied(bufferedEvents):
            inputSourceSyncTimeoutTask?.cancel()
            guard remoteSurfaceFocused,
                  inputSourceFollowViewer,
                  inputSourceProvider.currentInputSource() == inputSourceSyncGate.synchronizedSource else {
                if let current = inputSourceProvider.currentInputSource(),
                   let scope = activeInputSendScope {
                    beginInputSourceSynchronization(to: current, in: scope)
                } else {
                    setInputSourceSyncStatus(
                        "Unsupported Viewer input source — match sources manually",
                        retryAvailable: false
                    )
                }
                return
            }
            setInputSourceSyncStatus("Synchronized", retryAvailable: false)
            guard let transport = inputTransport else { return }
            for event in bufferedEvents {
                guard inputSourceSyncGate.routeKeyboard(event, in: scope) == .send else { continue }
                enqueueInputRecord(
                    event,
                    in: scope,
                    transport: transport,
                    keyboardDeliveryToken: inputSourceSyncGate.keyboardDeliveryToken
                )
            }
        }
    }

    private func setInputSourceSyncStatus(_ status: String, retryAvailable: Bool) {
        inputSourceSyncStatus = status
        contentView?.setInputSourceSyncStatus(status, retryAvailable: retryAvailable)
        refreshSettings()
    }

    private func observedInputSourceChange() {
        guard remoteSurfaceFocused,
              inputSourceFollowViewer,
              inputSourceSyncCapabilityAvailable,
              let scope = activeInputSendScope else { return }
        guard let source = inputSourceProvider.currentInputSource() else {
            inputSourceSyncGate.useManualSelection(in: scope)
            setInputSourceSyncStatus(
                "Unsupported Viewer input source — match sources manually",
                retryAvailable: false
            )
            return
        }
        if inputSourceSyncGate.state == .manualSelection ||
            inputSourceSyncGate.needsSynchronization(to: source, in: scope) {
            beginInputSourceSynchronization(to: source, in: scope)
        }
    }

    private func remoteSurfaceFocusChanged(_ focused: Bool) {
        let wasFocused = remoteSurfaceFocused
        remoteSurfaceFocused = focused
        guard focused else {
            inputSourceSyncTimeoutTask?.cancel()
            inputSourceSyncGate.setInactive()
            setInputSourceSyncStatus("Remote view is inactive — return to sync", retryAvailable: false)
            return
        }
        guard let scope = activeInputSendScope else { return }
        if inputSourceRetryGate.consumeOnRemoteFocus() {
            retryInputSourceNow(in: scope)
        } else if !wasFocused {
            synchronizeViewerInputSource(in: scope, force: true)
        }
    }

    private func synchronizeViewerInputSource(in scope: ViewerInputSendScope, force: Bool) {
        guard remoteSurfaceFocused else { return }
        guard inputSourceFollowViewer else {
            inputSourceSyncGate.useManualSelection(in: scope)
            setInputSourceSyncStatus("Follow Viewer input source is off — match sources manually", retryAvailable: false)
            return
        }
        guard inputSourceSyncCapabilityAvailable else {
            inputSourceSyncGate.useManualSelection(in: scope)
            setInputSourceSyncStatus("Host does not support input-source sync — match sources manually", retryAvailable: false)
            return
        }
        guard let source = inputSourceProvider.currentInputSource() else {
            inputSourceSyncGate.useManualSelection(in: scope)
            setInputSourceSyncStatus("Unsupported Viewer input source — match sources manually", retryAvailable: false)
            return
        }
        if force || inputSourceSyncGate.needsSynchronization(to: source, in: scope) {
            beginInputSourceSynchronization(to: source, in: scope)
        }
    }

    private func retryInputSourceSynchronization() {
        guard let scope = activeInputSendScope,
              inputSourceFollowViewer,
              inputSourceSyncCapabilityAvailable else {
            setInputSourceSyncStatus("Return to the remote view with input-source following enabled to retry", retryAvailable: true)
            return
        }
        guard inputSourceRetryGate.request(remoteSurfaceFocused: remoteSurfaceFocused) else {
            showViewerWindow()
            if window?.firstResponder === contentView?.surface {
                remoteSurfaceFocusChanged(true)
            }
            return
        }
        retryInputSourceNow(in: scope)
    }

    private func retryInputSourceNow(in scope: ViewerInputSendScope) {
        guard inputSourceProvider.currentInputSource() != nil else {
            setInputSourceSyncStatus("Unsupported Viewer input source — match sources manually", retryAvailable: false)
            return
        }
        synchronizeViewerInputSource(in: scope, force: true)
    }

    private func toggleInputSourceFollowing() {
        inputSourceFollowViewer.toggle()
        guard let scope = activeInputSendScope else {
            setInputSourceSyncStatus(
                inputSourceFollowViewer ? "Waiting for remote keyboard" : "Follow Viewer input source is off — match sources manually",
                retryAvailable: false
            )
            return
        }
        if inputSourceFollowViewer {
            synchronizeViewerInputSource(in: scope, force: true)
        } else {
            inputSourceSyncTimeoutTask?.cancel()
            inputSourceRetryGate.cancel()
            inputSourceSyncGate.useManualSelection(in: scope)
            setInputSourceSyncStatus("Follow Viewer input source is off — match sources manually", retryAvailable: false)
        }
    }

    private func handleJISEisuKey() -> Bool {
        guard inputSourceFollowViewer,
              inputSourceSyncCapabilityAvailable,
              remoteSurfaceFocused,
              let scope = activeInputSendScope else { return false }
        let current = inputSourceProvider.currentInputSource()
        let enabledEnglish = inputSourceProvider.enabledInputSources()
            .filter { $0.kind == .english }
            .sorted { $0.identifier < $1.identifier }
        let target: InputSourceDescriptor?
        if current?.kind == .english {
            target = current
        } else if enabledEnglish.count == 1 {
            target = enabledEnglish[0]
        } else {
            target = nil
        }
        guard let target else {
            inputSourceSyncGate.useManualSelection(in: scope, source: current)
            setInputSourceSyncStatus("JIS Eisu needs one enabled English source — match sources manually", retryAvailable: false)
            return true
        }
        let outcome = inputSourceProvider.selectInputSource(target)
        guard outcome == .applied || inputSourceProvider.currentInputSource() == target else {
            inputSourceSyncGate.useManualSelection(in: scope, source: current)
            setInputSourceSyncStatus("JIS Eisu source change is unsupported — match sources manually", retryAvailable: false)
            return true
        }
        observedInputSourceChange()
        return true
    }

    private func handleJISKanaKey() -> Bool {
        guard inputSourceFollowViewer,
              inputSourceSyncCapabilityAvailable,
              remoteSurfaceFocused,
              let scope = activeInputSendScope else { return false }
        inputSourceSyncGate.useManualSelection(
            in: scope,
            source: inputSourceProvider.currentInputSource()
        )
        setInputSourceSyncStatus(
            "JIS Kana's Japanese/internal mode is unsupported — choose the same input source manually",
            retryAvailable: false
        )
        return true
    }

    private func updateInputSourceSyncAvailability(
        for snapshot: SessionSnapshot,
        readiness: InputReadiness,
        keyboardInputEnabled: Bool
    ) {
        inputSourceSyncCapabilityAvailable = keyboardInputEnabled &&
            snapshot.authorizedCapabilities.contains(.inputSourceSync)
        guard readiness.isReady,
              keyboardInputEnabled,
              let scope = activeInputSendScope else {
            inputSourceSyncGate.setInactive()
            setInputSourceSyncStatus("Remote keyboard is unavailable", retryAvailable: false)
            return
        }
        guard remoteSurfaceFocused else {
            inputSourceSyncGate.setInactive()
            setInputSourceSyncStatus("Remote view is inactive — return to sync", retryAvailable: false)
            return
        }
        if snapshot.negotiatedCapabilities.contains(.backgroundControl),
           !hostInputFocusEligible,
           hostProcessTargetEligible == true {
            inputSourceSyncCapabilityAvailable = false
            inputSourceSyncGate.useManualSelection(in: scope)
            setInputSourceSyncStatus(
                "Host app is in background — match input sources manually",
                retryAvailable: false
            )
            return
        }
        guard inputSourceFollowViewer else {
            inputSourceSyncGate.useManualSelection(in: scope)
            setInputSourceSyncStatus("Follow Viewer input source is off — match sources manually", retryAvailable: false)
            return
        }
        guard inputSourceSyncCapabilityAvailable else {
            inputSourceSyncGate.useManualSelection(in: scope)
            setInputSourceSyncStatus("Host does not support input-source sync — match sources manually", retryAvailable: false)
            return
        }
        guard let source = inputSourceProvider.currentInputSource() else {
            inputSourceSyncGate.useManualSelection(in: scope)
            setInputSourceSyncStatus("Unsupported Viewer input source — match sources manually", retryAvailable: false)
            return
        }
        if inputSourceSyncGate.needsSynchronization(to: source, in: scope) {
            beginInputSourceSynchronization(to: source, in: scope)
        } else if inputSourceSyncGate.state == .synchronized {
            setInputSourceSyncStatus("Synchronized", retryAvailable: false)
        }
    }

    private func refreshInputSurface(for observedSession: SessionCoordinator? = nil) async {
        guard let session = observedSession ?? self.session else {
            updateInputSendScope(nil)
            inputSourceSyncCapabilityAvailable = false
            setInputSourceSyncStatus("Not connected", retryAvailable: false)
            let readiness = InputReadiness.awaitingAuthentication
            contentView?.updateStream(size: streamDimensions, readiness: readiness)
            contentView?.updateClipboard(status: nil, available: false)
#if DEBUG
            recordDebugInputReadiness(readiness, keyboardAvailable: false)
#endif
            return
        }
        let snapshot = await session.snapshot()
        guard self.session === session else { return }
        guard synchronizeAuthorization(for: session, snapshot: snapshot) else { return }
        var readiness: InputReadiness = .awaitingAuthorization
        var inputCapabilities = ViewerInputCapabilities.none
        if snapshot.state == .connecting || snapshot.state == .reconnecting {
            readiness = .awaitingAuthentication
        } else if !snapshot.authorized ||
                    snapshot.authorizedWindowGeneration == nil ||
                    selectedGeneration == nil {
            readiness = .awaitingAuthorization
        } else if let generation = selectedGeneration {
            let availability = SessionCapabilityProjection.inputAvailability(
                for: snapshot,
                selectedWindowGeneration: snapshot.authorizedWindowGeneration,
                selectedStreamGeneration: generation
            )
            let processControlNegotiated = snapshot.negotiatedCapabilities.contains(.backgroundControl)
            if processControlNegotiated,
               hostControlState == .negotiating {
                readiness = .hostControlNegotiating
            } else if processControlNegotiated && hostControlState != .active {
                readiness = .hostControlUnavailable
            } else if hostInputStatusGeneration != snapshot.authorizedWindowGeneration {
                readiness = .hostStateUnavailable
            } else if processControlNegotiated,
                      let blocker = ViewerProcessControlReadiness.blocker(
                          hostPermissionGranted: hostInputPermission == .granted,
                          focusEligible: hostInputFocusEligible,
                          processTargetEligible: hostProcessTargetEligible,
                          controlGeneration: hostControlGeneration
                      ) {
                readiness = blocker
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
        if case let .ready(windowGeneration) = readiness,
           let sessionLifetimeID {
            updateInputSendScope(
                ViewerInputSendScope(
                    sessionID: sessionLifetimeID,
                    authorizationGeneration: snapshot.authorizationGeneration,
                    windowGeneration: windowGeneration,
                    controlGeneration: snapshot.negotiatedCapabilities.contains(.backgroundControl)
                        ? hostControlGeneration
                        : nil
                )
            )
        } else {
            updateInputSendScope(nil)
        }
#if DEBUG
        recordDebugInputReadiness(
            readiness,
            keyboardAvailable: inputCapabilities.keyboardInputEnabled
        )
#endif
        contentView?.updateStream(
            size: streamDimensions,
            readiness: readiness,
            capabilities: inputCapabilities
        )
        updateInputSourceSyncAvailability(
            for: snapshot,
            readiness: readiness,
            keyboardInputEnabled: inputCapabilities.keyboardInputEnabled
        )
        switch readiness {
        case .ready:
            setStatus(
                ViewerInputStatusPresentation.readyStatus(
                    focusEligible: hostInputFocusEligible
                )
            )
        case .hostPermissionUnavailable:
            setStatus("Connected — enable PostEvent permission for MacRemoteApp Host")
        case .hostFocusUnavailable:
            setStatus(ViewerInputStatusPresentation.hostFocusUnavailableStatus)
        case .hostStateUnavailable:
            setStatus("Connected — waiting for Host input status")
        case .hostControlNegotiating:
            setStatus("Connected — Host is setting up Viewer control")
        case .hostControlUnavailable:
            switch hostControlState {
            case .requiresConsent: setStatus("Connected — approve Viewer control on the Host")
            case .paused: setStatus("Connected — Viewer control is paused on the Host")
            case .revoked: setStatus("Connected — Viewer control was revoked on the Host")
            case .persistenceFailure: setStatus("Connected — Host control is blocked by a Keychain error")
            case .unsupported: setStatus("Connected — Host does not support process-level control")
            case .active, .negotiating, .none: setStatus("Connected — Host control is unavailable")
            }
        case .hostProcessTargetUnavailable:
            setStatus("Connected — Host target is not currently safe for process control")
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

    private func synchronizeAuthorization(
        for session: SessionCoordinator,
        snapshot: SessionSnapshot
    ) -> Bool {
        guard self.session === session,
              let sessionLifetimeID,
              authorizationSnapshotGate.admit(
                sessionID: sessionLifetimeID,
                authorizationGeneration: snapshot.authorizationGeneration
              ) else { return false }
        let next = AuthorizationFingerprint(
            sessionID: sessionLifetimeID,
            generation: snapshot.authorizationGeneration,
            authorized: snapshot.authorized,
            windowGeneration: snapshot.authorizedWindowGeneration,
            capabilities: snapshot.authorizedCapabilities
        )
        guard authorizationFingerprint != next else { return true }
        authorizationFingerprint = next
        updateInputSendScope(nil)
        advancePresentationLifetime(resetDecoder: true)
        return true
    }

    private func updateInputSendScope(_ scope: ViewerInputSendScope?) {
        guard activeInputSendScope != scope else { return }
        inputSourceSyncTimeoutTask?.cancel()
        inputSourceRetryGate.cancel()
        inputSourceSyncGate.invalidateScope()
        activeInputSendScope = scope
        inputSendQueue.updateScope(scope)
        if scope == nil {
            inputSourceSyncCapabilityAvailable = false
        }
    }

    private func advancePresentationLifetime(resetDecoder: Bool) {
        let token = presentationLifetime.advance()
        renderer?.reset(lifetimeToken: token)
        if resetDecoder {
            decoder.reset()
        }
        pendingFrameReceiptNanoseconds.removeAll(keepingCapacity: true)
    }

    private func handleInputQueueFailure(
        _ scope: ViewerInputSendScope,
        category: ViewerInputFailureCategory
    ) {
#if DEBUG
        M10ViewerDiagnosticRecorder.shared.recordViewerInputFailureCategory(category)
#endif
        if activeInputSendScope == scope {
            activeInputSendScope = nil
        }
        guard sessionLifetimeID == scope.sessionID,
              let observedSession = session else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.session === observedSession,
                  self.sessionLifetimeID == scope.sessionID else { return }
            let snapshot = await observedSession.snapshot()
            guard self.session === observedSession,
                  self.sessionLifetimeID == scope.sessionID else { return }
            guard self.synchronizeAuthorization(for: observedSession, snapshot: snapshot) else { return }
            guard snapshot.authorizationGeneration == scope.authorizationGeneration,
                  snapshot.authorized,
                  snapshot.authorizedWindowGeneration == scope.windowGeneration else {
                await self.refreshInputSurface(for: observedSession)
                return
            }
            guard category.disposition.requiresSessionReset else {
                // The queue already invalidated its old scope. Recompute the
                // current readiness and install a fresh scope only if the
                // authenticated session still authorizes input.
                await self.refreshInputSurface(for: observedSession)
                return
            }
            await self.resetSession(expectedSession: observedSession)
            self.scheduleReconnect()
        }
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
        guard !isShuttingDown,
              session == nil,
              connectionAttemptID == nil,
              reconnectTask == nil else { return }
        guard lastDiscoveredService != nil else {
            setStatus("No Host is currently discovered")
            return
        }
        pairingRetryRequired = false
        contentView?.setPairingRetryVisible(false)
        scheduleReconnect(immediate: true)
    }

    /// Operator-requested disconnect. Clears the selected Host first so the
    /// discovery stream does not reconnect on its own, cancels any connection
    /// attempt or reconnect loop, and closes the session normally so the Host
    /// releases held input and stops capture. Saved pairings are kept.
    private func disconnectFromHost() {
        guard !isShuttingDown,
              session != nil || connectionAttemptID != nil || reconnectTask != nil else { return }
        selectedServiceIdentifier = nil
        lastDiscoveredService = nil
        pairingRetryRequired = false
        contentView?.setPairingRetryVisible(false)
        connectionAttemptID = nil
        cancelReconnect()
        updateInputSendScope(nil)
        advancePresentationLifetime(resetDecoder: true)
        contentView?.setConnectionState(.disconnected)
        setStatus("Disconnecting…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await resetSession()
            contentView?.setConnectionState(.disconnected)
            contentView?.setHostSelectionEnabled(true)
            setStatus("Disconnected — choose a Host and press Connect")
        }
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
        connectionAttemptID = nil
        cancelReconnect()
        updateInputSendScope(nil)
        advancePresentationLifetime(resetDecoder: true)
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
        connectionAttemptID = nil
        cancelReconnect()
        discovery.cancel()
        await resetSession()
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
    }

    private func resetSession(
        expectedSession: SessionCoordinator? = nil,
        cancelMonitor: Bool = true,
        retryCleanupOwnership: ViewerRetryCleanupOwnership? = nil
    ) async {
        if let expectedSession, session !== expectedSession { return }
        guard let cleanupPresentation = ViewerSessionCleanupPresentation.resolve(
            retryOwnership: retryCleanupOwnership,
            sessionID: sessionLifetimeID,
            attemptID: connectionAttemptID,
            reconnectID: reconnectTaskID
        ) else { return }
        if retryCleanupOwnership != nil {
            guard !isShuttingDown, !pairingRetryRequired else { return }
        }
#if DEBUG
        flushDebugVideoWindowForTransition(
            atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
#endif
        if cancelMonitor {
            sessionMonitorTask?.cancel()
            sessionMonitorTask = nil
        }
        connectionAttemptID = nil
        let previousSession = session
        let previousMessageLoop = messageLoop
        session = nil
        sessionLifetimeID = nil
        messageLoop = nil
        inputTransport = nil
        authorizationFingerprint = nil
        updateInputSendScope(nil)
        selectedGeneration = nil
#if DEBUG
        if selectedWindowIdentifier != nil {
            M10ViewerDiagnosticRecorder.shared.recordWindowSelection(.cleared)
        }
#endif
        selectedWindowIdentifier = nil
        pendingWindowSelection = nil
        windowSelectionInFlight = false
        foregroundRestorePending = false
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
        hostControlState = nil
        hostProcessTargetEligible = nil
        hostControlGeneration = nil
        streamGenerationGate.revoke()
        advancePresentationLifetime(resetDecoder: true)
        streamDimensions = .zero
        contentView?.clearWindowOptions()
        contentView?.updateStream(size: .zero, readiness: .awaitingAuthentication)
        contentView?.setPeerName(nil)
        contentView?.setConnectionLatency(nil)
        contentView?.updateClipboard(status: nil, available: false)
        // Set the cleanup UI before suspension; never restore it after old
        // teardown, which may outlive a replacement session or manual attempt.
        contentView?.setConnectionState(cleanupPresentation == .reconnecting ? .reconnecting : .disconnected)
        contentView?.setHostSelectionEnabled(cleanupPresentation.hostSelectionEnabled)

        if let previousMessageLoop {
            await previousMessageLoop.stop()
        }
        if let previousSession {
            await previousSession.stop(reason: .normal)
        }
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

enum ViewerConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting

    var buttonTitle: String {
        switch self {
        case .disconnected: return "Connect"
        // While connected or trying to connect, the same button ends the
        // session (or the attempt) and stops automatic reconnection.
        case .connecting, .connected, .reconnecting: return "Disconnect"
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
    var onDisconnect: (@MainActor () -> Void)?
    var onForgetPairings: (@MainActor () -> Void)?
    var onClipboardToggle: (@MainActor () -> Void)?
    var onRetryInputSource: (@MainActor () -> Void)?
    var onRemoteFocusChange: (@MainActor (Bool) -> Void)? {
        didSet { surface.onRemoteFocusChange = onRemoteFocusChange }
    }
    var onJISEisuKey: (@MainActor () -> Bool)? {
        didSet { surface.onJISEisuKey = onJISEisuKey }
    }
    var onJISKanaKey: (@MainActor () -> Bool)? {
        didSet { surface.onJISKanaKey = onJISKanaKey }
    }
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
         "inputSource": inputSourceSyncStatus, "message": status, "clipboard": clipboardSummary]
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
    private let retryInputSourceButton = NSButton(title: "Retry source sync", target: nil, action: nil)
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
    private var inputSourceSyncStatus = "Waiting for remote keyboard"
    private(set) var inputSourceRetryAvailable = false

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
        retryInputSourceButton.target = self
        retryInputSourceButton.action = #selector(retryInputSource(_:))
        retryInputSourceButton.controlSize = .small
        retryInputSourceButton.isHidden = true
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
        addSubview(retryInputSourceButton)
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

    func setInputSourceSyncStatus(_ status: String, retryAvailable: Bool) {
        inputSourceSyncStatus = status
        inputSourceRetryAvailable = retryAvailable
        retryInputSourceButton.isHidden = !retryAvailable
        retryInputSourceButton.isEnabled = retryAvailable
        updateConnectionDetails()
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
        let compactSourceStatus: String
        switch inputSourceSyncStatus {
        case "Synchronized": compactSourceStatus = "synced"
        case "Waiting for Host input-source change…": compactSourceStatus = "waiting"
        case "Follow Viewer input source is off — match sources manually": compactSourceStatus = "manual"
        case "Host does not support input-source sync — match sources manually": compactSourceStatus = "manual"
        case "Unsupported Viewer input source — match sources manually": compactSourceStatus = "manual"
        case "Remote view is inactive — return to sync": compactSourceStatus = "paused"
        case "Input source sync timed out — enable the same Chinese input method on Host, then retry": compactSourceStatus = "retry"
        default: compactSourceStatus = inputSourceSyncStatus
        }
        inputStatusLabel.stringValue = "Input: \(compactInputStatus(readiness)) · Source: \(compactSourceStatus)"
        inputStatusLabel.toolTip = "Input: \(compactInputStatus(readiness)). Input-source sync: \(inputSourceSyncStatus)."
        inputStatusLabel.textColor = readiness.isReady && inputSourceSyncStatus == "Synchronized"
            ? .systemGreen
            : readiness.isReady ? .secondaryLabelColor : .systemOrange
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
        case .hostControlNegotiating:
            return "Host setting up control"
        case .hostControlUnavailable:
            return "Host control unavailable"
        case .hostProcessTargetUnavailable:
            return "Host target unavailable"
        case .ready:
            return ViewerInputStatusPresentation.readyInputSummary()
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
        connectHostButton.isEnabled = connectionState != .disconnected ||
            (hostSelectionEnabled && hasHostSelection)
    }

    private func updateHostControls() {
        let isDisconnected = connectionState == .disconnected
        hostPicker.isEnabled = isDisconnected && hostSelectionEnabled && !hostOptionIdentifiers.isEmpty
        connectHostButton.title = connectionState.buttonTitle
        connectHostButton.isEnabled = !isDisconnected || (
            hostSelectionEnabled &&
                hostPicker.indexOfSelectedItem > 0 &&
                hostPicker.indexOfSelectedItem - 1 < hostOptionIdentifiers.count
        )
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
        let sourceRetryWidth: CGFloat = 112
        let pairingInset = retryPairingButton.isHidden ? 0 : retryWidth + 8
        let sourceInset = retryInputSourceButton.isHidden ? 0 : sourceRetryWidth + 8
        let retryInset = pairingInset + sourceInset
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
        let sourceRetryX = contentRight - retryWidth - 8 - sourceRetryWidth
        retryInputSourceButton.frame = NSRect(
            x: retryPairingButton.isHidden ? contentRight - sourceRetryWidth : sourceRetryX,
            y: panelFrame.minY + 7,
            width: sourceRetryWidth,
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
        guard connectionState == .disconnected else {
            onDisconnect?()
            return
        }
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

    @objc private func retryInputSource(_ sender: NSButton) {
        _ = sender
        onRetryInputSource?()
    }

    @objc private func toggleClipboard(_ sender: NSButton) {
        _ = sender
        onClipboardToggle?()
    }
}
