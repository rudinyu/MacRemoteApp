import AppKit
import CodecCore
import Foundation
import InputCore
import MetalKit
import RemoteProtocol
import SecurityCore
import TransportCore

/// Minimal production Viewer composition. The UI is intentionally small, but
/// the data path is real: Bonjour -> authenticated SessionCoordinator -> H264
/// decoder -> Metal, with the same content rectangle used for input mapping.
@MainActor
final class ViewerRuntime: NSObject, NSApplicationDelegate, NSWindowDelegate {
    struct Configuration: Sendable {
        let hostName: String?
        let peerCertificateURL: URL
        let identityLabel: String

        static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Configuration {
            guard let peerCertificatePath = environment["MACREMOTEAPP_PEER_CERT"],
                  !peerCertificatePath.isEmpty else {
                throw ViewerRuntimeError.configuration("set MACREMOTEAPP_PEER_CERT to the trusted Host's public certificate")
            }
            return Configuration(
                hostName: environment["MACREMOTEAPP_HOST_NAME"],
                peerCertificateURL: URL(fileURLWithPath: peerCertificatePath),
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
    private let discovery = NetworkBonjourDiscovery()
    private let decoder = H264Decoder()
    private var discoveryTask: Task<Void, Never>?
    private var inputSendTail: Task<Void, Never>?
    private var session: SessionCoordinator?
    private var messageLoop: ViewerSessionMessageLoop?
    private var inputTransport: ViewerInputTransport?
    private var contentView: ViewerContentView?
    private var renderer: MetalVideoRenderer?
    private var window: NSWindow?
    private var selectedGeneration: UInt64?
    private var streamGenerationGate = StreamGenerationGate()
    private var streamDimensions: CGSize = .zero
    private var didSendSelectionForGeneration: UInt64?

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
        discovery.start()
        let updates = discovery.updates
        discoveryTask = Task { [weak self] in
            var iterator = updates.makeAsyncIterator()
            while !Task.isCancelled, let services = await iterator.next() {
                guard let self,
                      let service = services.first(where: { service in
                          guard let hostName = self.configuration.hostName else { return true }
                          return service.name == hostName
                      }) else {
                    continue
                }
                await self.connect(to: service)
                return
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        Task { @MainActor [weak self] in
            await self?.disconnect()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
        content.onWindowSelection = { [weak self] windowIdentifier, generation in
            self?.selectWindow(windowIdentifier, generation: generation)
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
        content.updateStream(size: .zero, readiness: .awaitingAuthentication)
    }

    private func connect(to service: DiscoveredService) async {
        guard session == nil else { return }
        do {
            let localIdentity = try await loadLocalIdentity()
            let peerIdentity = try PublicCertificateIdentity.load(from: configuration.peerCertificateURL)
            let tlsOptions = TLSOptions(
                mode: .trusted(TrustedPeer(identity: peerIdentity, displayName: "MacRemoteApp Host")),
                localIdentity: localIdentity.secIdentity
            )
            let transport = try NetworkFramedTransport(
                endpoint: service.endpoint,
                tlsOptions: tlsOptions
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
                transport: transport
            )
            self.session = session
            self.inputTransport = ViewerInputTransport(session: session)
            let loop = ViewerSessionMessageLoop(session: session) { [weak self] message in
                await self?.handle(message)
            }
            messageLoop = loop
            loop.start()
            contentView?.updateStream(size: .zero, readiness: .awaitingAuthentication)
            try await session.start()
            setStatus("Connected; waiting for a selected window")
            await refreshInputSurface()
        } catch {
            setStatus("Connection unavailable; check trusted identities and Local Network permission")
            await disconnect()
        }
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

    private func handle(_ message: MessagePayload) async {
        switch message {
        case let .windowList(windowList):
            guard let session,
                  let generation = (await session.snapshot()).authorizedWindowGeneration else {
                await refreshInputSurface()
                return
            }
            let eligibleWindows = windowList.windows.filter(\.eligible)
            contentView?.setWindowOptions(eligibleWindows, generation: generation)
            if eligibleWindows.isEmpty {
                setStatus("Host has no eligible windows")
            } else if didSendSelectionForGeneration == generation {
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
            await disconnect()

        default:
            await refreshInputSurface()
        }
    }

    private func selectWindow(_ windowIdentifier: UInt64, generation: UInt64) {
        guard didSendSelectionForGeneration != generation,
              let session else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await session.snapshot()
            guard snapshot.authorizedWindowGeneration == generation else {
                setStatus("Window list expired; waiting for Host")
                return
            }
            do {
                try await session.send(
                    .windowSelection(
                        WindowSelectionMessage(
                            windowIdentifier: windowIdentifier,
                            windowGeneration: generation
                        )
                    )
                )
                didSendSelectionForGeneration = generation
                selectedGeneration = generation
                contentView?.setWindowSelectionEnabled(false)
                setStatus("Window selected; starting video")
                await refreshInputSurface()
            } catch {
                setStatus("Window selection was rejected")
            }
        }
    }

    private func present(_ result: Result<DecodedH264Frame, CodecError>) {
        guard case let .success(frame) = result,
              frame.generation == selectedGeneration else { return }
        renderer?.submit(
            pixelBuffer: frame.pixelBuffer,
            presentationTimestamp: frame.presentationTimestamp
        )
        contentView?.markFramePresented()
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
            return
        }
        let snapshot = await session.snapshot()
        let readiness: InputReadiness
        if snapshot.state == .connecting || snapshot.state == .reconnecting {
            readiness = .awaitingAuthentication
        } else if snapshot.authorizedWindowGeneration == nil || selectedGeneration == nil {
            readiness = .awaitingAuthorization
        } else if let generation = selectedGeneration,
                  snapshot.authorizedWindowGeneration == generation,
                  snapshot.authorizedCapabilities.contains(.mouseInput) ||
                    snapshot.authorizedCapabilities.contains(.keyboardInput) {
            readiness = .ready(windowGeneration: generation)
        } else {
            readiness = .awaitingAuthorization
        }
        contentView?.updateStream(size: streamDimensions, readiness: readiness)
    }

    private func setStatus(_ message: String) {
        contentView?.status = message
    }

    private func disconnect() async {
        discoveryTask?.cancel()
        discoveryTask = nil
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
        didSendSelectionForGeneration = nil
        streamGenerationGate.revoke()
        decoder.reset()
        streamDimensions = .zero
        contentView?.clearWindowOptions()
        contentView?.updateStream(size: .zero, readiness: .awaitingAuthentication)
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
    var onWindowSelection: (@MainActor (UInt64, UInt64) -> Void)?
    var status: String = "Starting…" {
        didSet { statusLabel.stringValue = status }
    }

    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let windowPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let selectWindowButton = NSButton(title: "Select", target: nil, action: nil)
    private var windowOptions: [WindowDescriptor] = []
    private var windowSelectionGeneration: UInt64?
    private var streamSize: CGSize = .zero
    private var readiness: InputReadiness = .awaitingAuthentication

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
        windowPicker.controlSize = .small
        windowPicker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        windowPicker.addItem(withTitle: "Choose Host window")
        windowPicker.isEnabled = false
        selectWindowButton.target = self
        selectWindowButton.action = #selector(selectWindow(_:))
        selectWindowButton.controlSize = .small
        selectWindowButton.isEnabled = false
        addSubview(videoView)
        addSubview(surface)
        addSubview(statusLabel)
        addSubview(windowPicker)
        addSubview(selectWindowButton)
        surface.onInputEvent = onInputEvent
        surface.onInputRejected = onInputRejected
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateStream(size: CGSize, readiness: InputReadiness) {
        streamSize = size
        self.readiness = readiness
        needsLayout = true
    }

    func setWindowOptions(_ windows: [WindowDescriptor], generation: UInt64) {
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
        windowPicker.isEnabled = true
        selectWindowButton.isEnabled = true
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
        statusLabel.frame = NSRect(x: 12, y: 8, width: max(1, bounds.width - 24), height: 20)
        windowPicker.frame = NSRect(
            x: 12,
            y: max(34, bounds.height - 36),
            width: min(520, max(180, bounds.width - 92)),
            height: 24
        )
        selectWindowButton.frame = NSRect(
            x: windowPicker.frame.maxX + 8,
            y: windowPicker.frame.minY,
            width: 64,
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
            readiness: readiness
        )
    }

    @objc private func selectWindow(_ sender: NSButton) {
        _ = sender
        guard windowPicker.indexOfSelectedItem >= 0,
              windowPicker.indexOfSelectedItem < windowOptions.count,
              let generation = windowSelectionGeneration else { return }
        onWindowSelection?(windowOptions[windowPicker.indexOfSelectedItem].identifier, generation)
    }
}
