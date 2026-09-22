import AppKit
import CodecCore
import Foundation
import InputCore
import MetalKit
import RemoteProtocol
import SecurityCore
import TransportCore

private enum ViewerPairingPromptOutcome: Sendable {
    case confirmation(String)
    case declined
    case sessionEnded
}

/// Minimal production Viewer composition. The UI is intentionally small, but
/// the data path is real: Bonjour -> authenticated SessionCoordinator -> H264
/// decoder -> Metal, with the same content rectangle used for input mapping.
@MainActor
final class ViewerRuntime: NSObject, NSApplicationDelegate, NSWindowDelegate {
    struct Configuration: Sendable {
        let hostName: String?
        let peerCertificateURL: URL?
        let identityLabel: String

        static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Configuration {
            let peerCertificateURL = environment["MACREMOTEAPP_PEER_CERT"]
                .flatMap { path in path.isEmpty ? nil : URL(fileURLWithPath: path) }
            return Configuration(
                hostName: environment["MACREMOTEAPP_HOST_NAME"],
                peerCertificateURL: peerCertificateURL,
                identityLabel: environment["MACREMOTEAPP_LOCAL_IDENTITY_LABEL"] ?? KeychainIdentityProvider.defaultLabel
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
        .textClipboard
    ]

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
    private var inputSendTail: Task<Void, Never>?
    private var session: SessionCoordinator?
    private var messageLoop: ViewerSessionMessageLoop?
    private var inputTransport: ViewerInputTransport?
    private var contentView: ViewerContentView?
    private var renderer: MetalVideoRenderer?
    private var window: NSWindow?
    private var localIdentity: ProvisionedIdentity?
    private var selectedGeneration: UInt64?
    private var selectedWindowIdentifier: UInt64?
    private var streamGenerationGate = StreamGenerationGate()
    private var streamDimensions: CGSize = .zero
    private var windowSelectionInFlight = false
    private var presentedFrameCount = 0
    private var latestPresentationSample: (captureTimestamp: UInt64, presentedTimestamp: UInt64)?
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
                    self.setStatus("Waiting for Local Network access (\(code))…")
                case .ready:
                    ViewerStartupOnboarding.markLocalNetworkReady()
                    if self.session == nil {
                        self.setStatus("Select a MacRemoteApp Host…")
                    }
                case let .failed(code):
                    self.setStatus("Local Network discovery failed (\(code)); enable MacRemoteApp Viewer in System Settings")
                case .cancelled:
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

    private func makeWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let content = ViewerContentView(frame: frame)
        content.onInputEvent = { [weak self] record in
            self?.enqueueInput(record)
        }
        content.onHostSelection = { [weak self] index in
            self?.selectHost(at: index)
        }
        content.onWindowSelection = { [weak self] windowIdentifier, generation in
            self?.selectWindow(windowIdentifier, generation: generation)
        }
        content.onPairingRetry = { [weak self] in
            self?.retryPairing()
        }
        content.onClipboardToggle = { [weak self] in
            self?.toggleClipboard()
        }
        content.onInputRejected = { [weak self] error in
            self?.setStatus(error.description)
        }
        contentView = content

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacRemoteApp Viewer"
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content.surface)

        renderer = MetalVideoRenderer(view: content.videoView)
        renderer?.onFramePresented = { [weak self] captureTimestamp, presentedTimestamp in
            self?.recordPresentation(captureTimestamp: captureTimestamp, presentedTimestamp: presentedTimestamp)
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
        contentView?.setHostSelectionEnabled(false)
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

    private func connect(to service: DiscoveredService) async -> ConnectResult {
        guard session == nil, !isShuttingDown else { return .retryableFailure }
        contentView?.setPairingRetryVisible(false)
        do {
            let localIdentity = try await loadLocalIdentity()
            let authenticationMode: TLSAuthenticationMode
            if let peerCertificateURL = configuration.peerCertificateURL {
                let peerIdentity = try PublicCertificateIdentity.load(from: peerCertificateURL)
                authenticationMode = .trusted(
                    TrustedPeer(identity: peerIdentity, displayName: "MacRemoteApp Host")
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
                trustStore: KeychainTrustStore()
            )
            let session = SessionCoordinator(
                configuration: SessionConfiguration(
                    role: .viewer,
                    implementationIdentifier: "MacRemoteApp-Viewer-M10",
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
            sessionMonitorTask = Task { @MainActor [weak self] in
                await self?.monitorSession(session)
            }
            setStatus("Connected; waiting for a selected window")
            contentView?.setPairingRetryVisible(false)
            await refreshInputSurface()
            return .connected
        } catch let error as SessionError {
            if error == .pairingDenied {
                setStatus("Pairing was denied; click Retry pairing to try again")
                contentView?.setPairingRetryVisible(true)
            } else {
                setStatus("Connection unavailable; check trusted identities and Local Network permission")
                contentView?.setPairingRetryVisible(false)
            }
            await resetSession()
            return error == .pairingDenied ? .pairingDenied : .retryableFailure
        } catch {
            setStatus("Connection unavailable; check trusted identities and Local Network permission")
            contentView?.setPairingRetryVisible(false)
            await resetSession()
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
        guard let service = lastDiscoveredService else {
            setStatus("Connection lost; rediscover the Host to reconnect")
            return
        }

        setStatus("Connection lost; reconnecting…")
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
                switch await self.connect(to: service) {
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
                            if let enteredCode = await ViewerPairingPrompt.requestConfirmation(
                                confirmationCode: challenge.confirmationCode,
                                parentWindow: parentWindow,
                                expiresAt: challenge.expiresAt
                            ) {
                                return .confirmation(enteredCode)
                            }
                            return .declined
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
                    case let .confirmation(enteredCode):
                        try await session.confirmPairing(
                            confirmationCode: enteredCode,
                            accepted: true,
                            displayName: "MacRemoteApp Host"
                        )
                    case .declined:
                        try await session.confirmPairing(
                            confirmationCode: "",
                            accepted: false,
                            displayName: "MacRemoteApp Host"
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
            let eligibleWindows = windowList.windows.filter(\.eligible)
            contentView?.setWindowOptions(
                eligibleWindows,
                generation: generation,
                selectedIdentifier: selectedWindowIdentifier
            )
            if eligibleWindows.isEmpty {
                setStatus("Host has no eligible windows")
            } else if selectedWindowIdentifier != nil {
                setStatus("Window selected; starting video")
            } else {
                setStatus("Select a Host window to start video")
            }
            await refreshInputSurface()

        case let .streamConfig(config):
            guard config.codec == .h264 else {
                setStatus("Unsupported video codec")
                return
            }
            selectedGeneration = config.generation
            streamGenerationGate.advance(to: config.generation)
            streamDimensions = CGSize(width: CGFloat(config.width), height: CGFloat(config.height))
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
                try decoder.decode(encoded) { [weak self] result in
                    Task { @MainActor [weak self] in
                        self?.present(result)
                    }
                }
            } catch {
                // A non-keyframe before decoder configuration is expected to
                // be dropped; the bounded media path waits for the next keyframe.
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

    private func selectWindow(_ windowIdentifier: UInt64, generation: UInt64) {
        guard !windowSelectionInFlight, let session else { return }
        guard selectedWindowIdentifier != windowIdentifier else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await session.snapshot()
            guard snapshot.authorizedWindowGeneration == generation else {
                setStatus("Window list expired; waiting for Host")
                return
            }
            guard windowOptionsContain(windowIdentifier) else {
                setStatus("Window is no longer available")
                return
            }
            windowSelectionInFlight = true
            selectedGeneration = nil
            streamGenerationGate.revoke()
            decoder.reset()
            streamDimensions = .zero
            contentView?.updateStream(size: .zero, readiness: .awaitingAuthorization)
            contentView?.setWindowSelectionEnabled(false)
            await refreshInputSurface()
            do {
                try await session.send(
                    .windowSelection(
                        WindowSelectionMessage(
                            windowIdentifier: windowIdentifier,
                            windowGeneration: generation
                        )
                    )
                )
                selectedWindowIdentifier = windowIdentifier
                contentView?.setSelectedWindowIdentifier(windowIdentifier)
                setStatus("Window selected; starting video")
                await refreshInputSurface()
            } catch {
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
        guard case let .success(frame) = result,
              frame.generation == selectedGeneration else { return }
        renderer?.submit(
            pixelBuffer: frame.pixelBuffer,
            captureTimestamp: frame.captureTimestamp
        )
        contentView?.markFramePresented()
    }

    private func recordPresentation(captureTimestamp: UInt64, presentedTimestamp: UInt64) {
        presentedFrameCount += 1
        latestPresentationSample = (captureTimestamp, presentedTimestamp)
        // The renderer callback is the authoritative display boundary. Keep
        // the raw pair in the in-process M8 collector boundary; conversion to
        // one-way latency is only valid after the authenticated clock-sync
        // estimate is available, so this path does not emit misleading values.
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
            contentView?.updateStream(size: streamDimensions, readiness: .awaitingAuthentication)
            contentView?.updateClipboard(status: nil, available: false)
            return
        }
        let snapshot = await session.snapshot()
        let readiness: InputReadiness
        let inputCapabilities: ViewerInputCapabilities
        if snapshot.state == .connecting || snapshot.state == .reconnecting {
            readiness = .awaitingAuthentication
            inputCapabilities = .none
        } else if snapshot.authorizedWindowGeneration == nil || selectedGeneration == nil {
            readiness = .awaitingAuthorization
            inputCapabilities = .none
        } else if let generation = selectedGeneration,
                  SessionCapabilityProjection.inputAvailability(
                      for: snapshot,
                      selectedWindowGeneration: snapshot.authorizedWindowGeneration,
                      selectedStreamGeneration: generation
                  ).anyInputEnabled {
            let availability = SessionCapabilityProjection.inputAvailability(
                for: snapshot,
                selectedWindowGeneration: snapshot.authorizedWindowGeneration,
                selectedStreamGeneration: generation
            )
            readiness = .ready(windowGeneration: generation)
            inputCapabilities = ViewerInputCapabilities(
                mouseInputEnabled: availability.mouseInputEnabled,
                keyboardInputEnabled: availability.keyboardInputEnabled
            )
        } else {
            readiness = .awaitingAuthorization
            inputCapabilities = .none
        }
        contentView?.updateStream(
            size: streamDimensions,
            readiness: readiness,
            capabilities: inputCapabilities
        )
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
        contentView?.setPairingRetryVisible(false)
        scheduleReconnect(immediate: true)
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
        windowSelectionInFlight = false
        presentedFrameCount = 0
        latestPresentationSample = nil
        streamGenerationGate.revoke()
        decoder.reset()
        streamDimensions = .zero
        contentView?.clearWindowOptions()
        contentView?.updateStream(size: .zero, readiness: .awaitingAuthentication)
        contentView?.updateClipboard(status: nil, available: false)
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
    var onWindowSelection: (@MainActor (UInt64, UInt64) -> Void)?
    var onPairingRetry: (@MainActor () -> Void)?
    var onClipboardToggle: (@MainActor () -> Void)?
    var status: String = "Starting…" {
        didSet { statusLabel.stringValue = status }
    }

    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let hostPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let connectHostButton = NSButton(title: "Connect", target: nil, action: nil)
    private let windowPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let selectWindowButton = NSButton(title: "Select", target: nil, action: nil)
    private let clipboardButton = NSButton(title: "Text clipboard unavailable", target: nil, action: nil)
    private let retryPairingButton = NSButton(title: "Retry pairing", target: nil, action: nil)
    private var windowOptions: [WindowDescriptor] = []
    private var windowSelectionGeneration: UInt64?
    private var hostOptionIdentifiers: [String] = []
    private var hostSelectionEnabled = true
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
        hostPicker.controlSize = .small
        hostPicker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hostPicker.addItem(withTitle: "Choose MacRemoteApp Host")
        hostPicker.isEnabled = false
        connectHostButton.target = self
        connectHostButton.action = #selector(connectHost(_:))
        connectHostButton.controlSize = .small
        connectHostButton.isEnabled = false
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
        addSubview(statusLabel)
        addSubview(hostPicker)
        addSubview(connectHostButton)
        addSubview(windowPicker)
        addSubview(selectWindowButton)
        addSubview(clipboardButton)
        addSubview(retryPairingButton)
        surface.onInputEvent = onInputEvent
        surface.onInputRejected = onInputRejected
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
        needsLayout = true
    }

    func updateClipboard(status: ClipboardSyncStatus?, available: Bool) {
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
            hostPicker.indexOfSelectedItem < hostOptionIdentifiers.count
            ? hostOptionIdentifiers[hostPicker.indexOfSelectedItem]
            : nil
        hostOptionIdentifiers = services.map(\.identifier)
        hostPicker.removeAllItems()
        if services.isEmpty {
            hostPicker.addItem(withTitle: "No MacRemoteApp Host found")
            hostPicker.isEnabled = false
            connectHostButton.isEnabled = false
            return
        }
        for service in services {
            let name = service.name.isEmpty ? "Unnamed Host" : service.name
            hostPicker.addItem(withTitle: name)
        }
        if let previousIdentifier,
           let index = hostOptionIdentifiers.firstIndex(of: previousIdentifier) {
            hostPicker.selectItem(at: index)
        } else {
            hostPicker.selectItem(at: 0)
        }
        hostPicker.isEnabled = hostSelectionEnabled
        connectHostButton.isEnabled = hostSelectionEnabled
    }

    func setHostSelectionEnabled(_ enabled: Bool) {
        hostSelectionEnabled = enabled
        hostPicker.isEnabled = enabled && !hostOptionIdentifiers.isEmpty
        connectHostButton.isEnabled = enabled && !hostOptionIdentifiers.isEmpty
    }

    func setWindowOptions(
        _ windows: [WindowDescriptor],
        generation: UInt64,
        selectedIdentifier: UInt64? = nil
    ) {
        windowOptions = windows
        windowSelectionGeneration = generation
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

    override func layout() {
        super.layout()
        videoView.frame = bounds
        surface.frame = bounds
        let retryWidth: CGFloat = retryPairingButton.isHidden ? 0 : 108
        statusLabel.frame = NSRect(
            x: 12,
            y: 8,
            width: max(1, bounds.width - 24 - retryWidth),
            height: 20
        )
        retryPairingButton.frame = NSRect(
            x: max(12, bounds.width - 116),
            y: 6,
            width: 104,
            height: 24
        )
        let hostControlY: CGFloat = 34
        hostPicker.frame = NSRect(
            x: 12,
            y: hostControlY,
            width: min(420, max(220, bounds.width - 220)),
            height: 24
        )
        connectHostButton.frame = NSRect(
            x: hostPicker.frame.maxX + 8,
            y: hostControlY,
            width: 76,
            height: 24
        )
        let controlY = max(34, bounds.height - 36)
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
        let contentRect = VideoContentLayout.aspectFitRect(
            contentWidth: streamSize.width,
            contentHeight: streamSize.height,
            in: bounds
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
              let generation = windowSelectionGeneration else { return }
        onWindowSelection?(windowOptions[windowPicker.indexOfSelectedItem].identifier, generation)
    }

    @objc private func connectHost(_ sender: NSButton) {
        _ = sender
        guard hostPicker.indexOfSelectedItem >= 0,
              hostPicker.indexOfSelectedItem < hostOptionIdentifiers.count else { return }
        onHostSelection?(hostPicker.indexOfSelectedItem)
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
