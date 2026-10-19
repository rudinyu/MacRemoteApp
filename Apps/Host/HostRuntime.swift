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

enum HostRuntimeWindowSelectionAction: Equatable {
    case restoreExistingSelection
    case activateRequestedSelection

    static func resolve(currentWindowHasSameOwner: Bool) -> Self {
        currentWindowHasSameOwner
            ? .restoreExistingSelection
            : .activateRequestedSelection
    }
}

enum HostRuntimeForegroundRestorationPolicy {
    static func permits(
        activeSession: Bool,
        selectionTransitionInProgress: Bool,
        authorized: Bool,
        selectedWindowMatches: Bool,
        requestGeneration: UInt64?,
        selectedWindowGeneration: UInt64?,
        authorizedWindowGeneration: UInt64?,
        requiresHostFrontmost: Bool,
        hostIsFrontmost: Bool
    ) -> Bool {
        guard activeSession,
              !selectionTransitionInProgress,
              authorized,
              selectedWindowMatches,
              let requestGeneration,
              selectedWindowGeneration == requestGeneration,
              authorizedWindowGeneration == requestGeneration else {
            return false
        }
        return !requiresHostFrontmost || hostIsFrontmost
    }
}

enum HostRuntimeForegroundActivationPolicy {
    static func permits(
        explicitViewerSelection: Bool,
        targetApplicationAvailable: Bool,
        targetIsRegularApplication: Bool
    ) -> Bool {
        explicitViewerSelection &&
            targetApplicationAvailable &&
            targetIsRegularApplication
    }

    static func authorizedCapabilities(
        _ capabilities: Set<Capability>,
        afterForegroundConfirmation didConfirmForeground: Bool,
        inputCapabilities: Set<Capability>
    ) -> Set<Capability> {
        guard !didConfirmForeground else { return capabilities }
        var result = capabilities
        result.subtract(inputCapabilities)
        result.remove(.inputSourceSync)
        result.remove(.backgroundControl)
        return result
    }
}

/// Ordered activation requests for an explicit Viewer selection. Each step is
/// a public macOS request that may be refused; after each one the Host
/// re-checks that the exact selected window is foreground, and no step
/// authorizes input by itself.
enum HostForegroundActivationStep: String, Equatable {
    case cooperativeYield = "cooperative-yield"
    case accessibilityFrontmost = "accessibility-frontmost"
    case launchServicesActivation = "launch-services-activation"
}

enum HostForegroundActivationPlan {
    static func steps(
        cooperativeAPIAvailable: Bool,
        accessibilityTrusted: Bool,
        selectedProcessIsOnlyRunningInstance: Bool
    ) -> [HostForegroundActivationStep] {
        var steps: [HostForegroundActivationStep] = []
        if cooperativeAPIAvailable { steps.append(.cooperativeYield) }
        if accessibilityTrusted { steps.append(.accessibilityFrontmost) }
        // LaunchServices activates by bundle; with more than one running copy
        // it could pick a different process, so it is skipped then.
        if selectedProcessIsOnlyRunningInstance { steps.append(.launchServicesActivation) }
        return steps
    }
}

enum HostRuntimeCooperativeActivationPolicy {
    static func permitsYield(
        cooperativeAPIAvailable: Bool,
        hostIsFrontmost: Bool
    ) -> Bool {
        cooperativeAPIAvailable && hostIsFrontmost
    }
}

enum HostRuntimeVideoAuthorizationRecoveryPolicy {
    static func shouldRecover(
        capturedAuthorizationGeneration: UInt64,
        capturedWindowGeneration: UInt64?,
        capturedAuthorized: Bool,
        freshAuthorizationGeneration: UInt64,
        freshWindowGeneration: UInt64?,
        freshAuthorized: Bool
    ) -> Bool {
        guard capturedAuthorized else { return false }
        return capturedAuthorizationGeneration != freshAuthorizationGeneration ||
            capturedWindowGeneration != freshWindowGeneration ||
            capturedAuthorized != freshAuthorized
    }
}

enum HostRuntimeClipboardAuthorizationPolicy {
    static func permits(
        pairedPeerTrusted: Bool,
        capabilityNegotiated: Bool,
        pairingRevoked: Bool = false
    ) -> Bool {
        pairedPeerTrusted && capabilityNegotiated && !pairingRevoked
    }
}

enum HostRuntimeCaptureLivenessPolicy {
    static func keepsAuthenticatedSession(for state: CaptureSessionState) -> Bool {
        switch state {
        case .capturing, .recovering: true
        case .idle, .starting, .stopping, .stopped, .failed: false
        }
    }

    /// A fixed, log-safe category for why capture ended. Free-form platform
    /// error text is deliberately omitted.
    static func summary(for state: CaptureSessionState) -> String {
        func category(_ failure: CaptureFailure?) -> String {
            switch failure {
            case .permissionDenied: "permission-denied"
            case .windowUnavailable: "window-unavailable"
            case .captureFailed: "capture-failed"
            case .providerFailed: "provider-failed"
            case .cancelled: "cancelled"
            case nil: "none"
            }
        }
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .capturing: return "capturing"
        case .recovering: return "recovering"
        case .stopping: return "stopping"
        case let .stopped(failure): return "stopped-\(category(failure))"
        case let .failed(failure): return "failed-\(category(failure))"
        }
    }
}

enum HostRuntimeWindowCatalogPolicy {
    /// A temporary picker-catalog omission must not make the Viewer clear an
    /// already selected target. CaptureCore owns the bounded target-liveness
    /// decision; the catalog resumes publishing when that target reappears.
    static func shouldPublish(
        _ windows: [CaptureWindow],
        preserving selectedWindow: CaptureWindow?
    ) -> Bool {
        guard let selectedWindow else { return true }
        return windows.contains { $0.hasSameOwner(as: selectedWindow) }
    }
}

enum HostRuntimeCallbackTeardownScheduler {
    @discardableResult
    static func schedule(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task { await operation() }
    }
}

enum HostRuntimeStatus: Sendable, Equatable, CustomStringConvertible {
    case starting
    case needsScreenRecording
    case needsLocalNetwork
    case listenerFailed
    case connected
    /// A Viewer is authorized for one app window. `broughtToFront` records
    /// that the Host activated the app because of the Viewer's selection, so
    /// the person at the Host can see why their frontmost app changed.
    case sharing(application: String, broughtToFront: Bool)
    case recovering(application: String)
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
        case let .sharing(application, broughtToFront):
            return broughtToFront
                ? "Viewer brought \(application) to the front and is sharing it"
                : "Viewer is sharing \(application)"
        case let .recovering(application): return "Restoring video for \(application)"
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
        static let defaultControlGrantStoreService = KeychainControlGrantStore.defaultService

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
    /// Floor between Viewer-requested keyframes, independent of the Viewer's
    /// own throttle, so a misbehaving peer cannot force every frame to be
    /// a keyframe.
    private static let viewerKeyframeRequestMinimumIntervalNanoseconds: UInt64 = 250_000_000
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
    let controlStatusUpdates: AsyncStream<HostControlStatus>
    private let controlStatusContinuation: AsyncStream<HostControlStatus>.Continuation
    private let controlGrantStore: any ControlGrantStore
    private let trustStore: any TrustStore
    private let controlAuthorization: HostControlAuthorizationCoordinator
    private var controlStatusValue: HostControlStatus = .unavailable
    private var controlPeerIdentifier: String?
    private var controlPeerName: String?
    private var controlGranted = false
    private var controlWireAuthorized = false
    private var controlPaused = false
    private var controlSessionID: UUID?
    private var controlAppliedRevision: UInt64 = 0
    private var pairingResetInProgress = false

    private var listener: NetworkBonjourListener?
    private var localIdentity: ProvisionedIdentity?
    private var activeSession: SessionCoordinator?
    private var activeSessionStopInProgress = false
    private var inputRuntime: HostInputSessionRuntime?
    private var sessionMonitor: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var encodedSendTask: Task<Void, Never>?
    private var encodedFrameRelay: HostEncodedFrameRelay?
    private var encoder: H264Encoder?
    private var selectedWindow: CaptureWindow?
    private var selectedWindowGeneration: UInt64?
    private var advertisedWindowGeneration: UInt64 = 1
    private var advertisedWindowCatalogGeneration: UInt64 = 0
    private var advertisedWindows: [CaptureWindow] = []
    private var videoConfigSentGeneration: UInt64?
    private var videoConfigSentAuthorizationGeneration: UInt64?
#if DEBUG
    private var lastDebugSessionState: M10HostSessionDiagnosticSnapshot?
    private var lastDebugScreenRecordingPermission: M10HostScreenRecordingPermission?
    private var lastDebugWindowCatalog: M10HostWindowCatalogDiagnosticSnapshot?
    private var lastDebugInputReadiness: M10HostInputReadiness?
#endif
    /// Set when the media queue discarded video or the decoder configuration
    /// must be resent. The Viewer skips delta frames until the next keyframe,
    /// so the capture loop forces one.
    private var keyframeRequested = false
    private var lastViewerKeyframeRequestNanoseconds: UInt64?
    /// Lowers the encoder bitrate on congestion and restores it when the
    /// path is clear. Created per video pipeline.
    private var bitrateController: AdaptiveBitrateController?
    /// M8 stage budget evidence: capture arrival to wire-queue admission.
    private var captureToSendCollector = BoundedStageLatencyCollector()
    private static let stageLogSampleInterval = 600
    private var clipboardAuthorizedForSession = false
    private var retryRequested = false
    private var restartRequested = false
    private var selectionTransitionInProgress = false
    private var captureRecoveryStatusActive = false
    private let startupLogger = Logger(
        subsystem: "com.rudinyu.MacRemoteApp",
        category: "host-runtime"
    )

    init(
        configuration: Configuration,
        windowProvider: ScreenRecordingWindowProvider = ScreenRecordingWindowProvider(),
        captureSession: WindowCaptureSession? = nil,
        controlGrantStore: any ControlGrantStore = KeychainControlGrantStore(
            service: Configuration.defaultControlGrantStoreService
        ),
        trustStore: any TrustStore = KeychainTrustStore(
            service: Configuration.defaultTrustStoreService
        )
    ) {
        let statusStream = AsyncStream<HostRuntimeStatus>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.configuration = configuration
        self.windowProvider = windowProvider
        self.captureSession = captureSession ?? WindowCaptureSession(windowProvider: windowProvider)
        self.statusUpdates = statusStream.stream
        self.statusContinuation = statusStream.continuation
        let controlStatusStream = AsyncStream<HostControlStatus>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.controlStatusUpdates = controlStatusStream.stream
        self.controlStatusContinuation = controlStatusStream.continuation
        self.controlGrantStore = controlGrantStore
        self.trustStore = trustStore
        self.controlAuthorization = HostControlAuthorizationCoordinator(trustStore: trustStore)
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

    func controlStatus() -> HostControlStatus { controlStatusValue }

    func toggleViewerControl() async {
        guard let session = activeSession, let controlSessionID else { return }
        let updated = await controlAuthorization.togglePause(for: controlSessionID)
        guard activeSession === session, self.controlSessionID == controlSessionID else { return }
        guard updated.granted else { return }
        await applyControlAuthorization(updated, for: session)
    }

    func revokeViewerControl() async {
        guard let session = activeSession, let controlSessionID else { return }
        guard let ticket = await controlAuthorization.beginRevocation(for: controlSessionID) else { return }
        let stillCurrent = activeSession === session && self.controlSessionID == controlSessionID
        if stillCurrent, ticket.sessionID == controlSessionID {
            // Close local process targeting and transport admission before
            // persistence. A replacement session must not inherit this local
            // mutation, but the durable revoke ticket must still complete if
            // the session changes while the actor call above is suspended.
            controlPaused = true
            controlGranted = false
            controlWireAuthorized = false
            controlAppliedRevision = max(controlAppliedRevision, ticket.revision)
            clipboardAuthorizedForSession = false
            stateStore.setProcessTargetingAuthorized(false)
            publishControlStatus(.revoked)
            await setLocalControlAdmission(false, revision: ticket.revision, for: session)
            try? await inputRuntime?.setClipboardEnabled(false)
            await synchronizeInputAuthorization(session)
        }
        let result = await controlAuthorization.completeRevocation(ticket)
        if result.status == .revoked,
           activeSession != nil,
           self.controlSessionID == result.sessionID,
           result.peerIdentifier == ticket.peerIdentifier {
            // If a same-peer session replaced the revoked session while the
            // Keychain operation was suspended, fence that authenticated
            // transport too before it can remain active without pairing trust.
            await stopActiveSession()
            return
        }
        guard stillCurrent,
              ticket.sessionID == controlSessionID,
              activeSession === session,
              self.controlSessionID == controlSessionID else { return }
        await applyControlAuthorization(result, for: session)
    }

    /// Revokes every saved peer trust record without deleting this Mac's own
    /// TLS identity. An active session is stopped before the records are
    /// removed so no already-authorized input or media path survives the
    /// operator's explicit reset.
    func forgetAllPairings() async throws -> Int {
        guard !pairingResetInProgress else { return 0 }
        pairingResetInProgress = true
        defer { pairingResetInProgress = false }
        await stopActiveSession()
        // Old P6 grant records are no longer consulted. Remove them best-effort
        // while the paired Viewer trust record remains the sole authorization.
        _ = try? await controlGrantStore.removeAll()
        let count: Int
        if let keychainTrustStore = trustStore as? KeychainTrustStore {
            count = try await keychainTrustStore.removeAllPairings()
        } else {
            let peers = try await trustStore.allTrustedPeers()
            for peer in peers {
                try await trustStore.revoke(peerIdentifier: peer.identity.identifier)
            }
            count = peers.count
        }
        await controlAuthorization.clearRevocationFailuresAfterPairingReset()
        if listener != nil {
            publish(.listening)
        }
        return count
    }

    private func publish(_ status: HostRuntimeStatus) {
        statusContinuation.yield(status)
    }

    private func publishControlStatus(_ status: HostControlStatus) {
        controlStatusValue = status
        controlStatusContinuation.yield(status)
    }

    private func setControlStatus(
        _ status: HostControlStatus,
        for session: SessionCoordinator,
        controlRevision: UInt64? = nil
    ) async {
        guard activeSession === session,
              controlRevision.map({ $0 == controlAppliedRevision }) ?? true else { return }
        publishControlStatus(status)
        let snapshot = await session.snapshot()
        guard activeSession === session,
              controlRevision.map({ $0 == controlAppliedRevision }) ?? true else { return }
        let inputStatus = await inputRuntime?.status() ?? .selectionUnavailable
        guard activeSession === session,
              controlRevision.map({ $0 == controlAppliedRevision }) ?? true else { return }
        // Permission preflight is synchronous CoreGraphics I/O; keep it off
        // AppKit's main actor so the 100 ms authorization monitor cannot stall
        // the Host event loop while TCC responds.
        let localPermission = CoreGraphicsAccessibilityContextProvider.currentPermissionState()
        guard activeSession === session,
              controlRevision.map({ $0 == controlAppliedRevision }) ?? true else { return }
        let permission: PermissionState
        switch localPermission {
        case .authorized: permission = .granted
        case .missing: permission = .missing
        case .unknown: permission = .unknown
        }
        let processTargetEligible: Bool? = snapshot.negotiatedCapabilities.contains(.backgroundControl)
            ? (inputStatus == .ready)
            : nil
        let wireState: ControlAuthorizationState
        switch status {
        case .unavailable, .unsupported: wireState = .unsupported
        case .negotiating: wireState = .negotiating
        case .requiresConsent: wireState = .requiresConsent
        case .active: wireState = .active
        case .paused: wireState = .paused
        case .revoked: wireState = .revoked
        case .persistenceFailure: wireState = .persistenceFailure
        }
        let controlGeneration: UInt64?
        if snapshot.negotiatedCapabilities.contains(.backgroundControl) {
            let revision = controlRevision ?? controlAppliedRevision
            controlGeneration = revision > 0 ? revision : nil
        } else {
            controlGeneration = nil
        }
        _ = try? await session.send(
            .sessionState(
                SessionStateMessage(
                    state: snapshot.state,
                    permission: permission,
                    focusEligible: inputStatus == .ready,
                    windowGeneration: snapshot.authorizedWindowGeneration,
                    controlState: wireState,
                    processTargetEligible: processTargetEligible,
                    controlGeneration: controlGeneration
                )
            ),
            expectedAuthorizationGeneration: snapshot.authorizationGeneration
        )
    }

    private func prepareViewerControl(for session: SessionCoordinator) async {
        let snapshot = await session.snapshot()
        guard activeSession === session, let controlSessionID else { return }
        controlPeerIdentifier = snapshot.peerIdentity?.identifier
        controlPeerName = snapshot.peerDeviceName
        let initial = await controlAuthorization.beginSession(
            sessionID: controlSessionID,
            peerIdentifier: snapshot.peerIdentity?.identifier,
            peerName: snapshot.peerDeviceName,
            supportsControl: snapshot.negotiatedCapabilities.contains(.backgroundControl)
        )
        guard activeSession === session, self.controlSessionID == controlSessionID else {
            await controlAuthorization.endSession(controlSessionID)
            return
        }
        await applyControlAuthorization(initial, for: session)
        let resolved = await controlAuthorization.resolvePairingTrust(for: controlSessionID)
        guard activeSession === session, self.controlSessionID == controlSessionID else { return }
        clipboardAuthorizedForSession = HostRuntimeClipboardAuthorizationPolicy.permits(
            pairedPeerTrusted: resolved.trusted,
            capabilityNegotiated: snapshot.negotiatedCapabilities.contains(.textClipboard)
        )
        await applyControlAuthorization(resolved, for: session)
    }

    private func applyControlAuthorization(
        _ snapshot: HostControlAuthorizationSnapshot,
        for session: SessionCoordinator
    ) async {
        guard activeSession === session,
              let controlSessionID,
              snapshot.sessionID == controlSessionID,
              snapshot.revision >= controlAppliedRevision else { return }

        controlAppliedRevision = snapshot.revision
        controlPeerIdentifier = snapshot.peerIdentifier
        controlGranted = snapshot.granted
        controlWireAuthorized = snapshot.granted
        controlPaused = snapshot.paused
        let admitted = snapshot.granted && !snapshot.paused && snapshot.status == .active
        stateStore.setProcessTargetingAuthorized(admitted)
        publishControlStatus(snapshot.status)

        await setLocalControlAdmission(admitted, revision: snapshot.revision, for: session)
        guard activeSession === session,
              self.controlSessionID == controlSessionID,
              controlAppliedRevision == snapshot.revision else { return }

        if selectedWindow != nil {
            await synchronizeInputAuthorization(session)
            guard activeSession === session,
                  self.controlSessionID == controlSessionID,
                  controlAppliedRevision == snapshot.revision else { return }
        }
        await setControlStatus(snapshot.status, for: session, controlRevision: snapshot.revision)
    }

    private func setLocalControlAdmission(
        _ enabled: Bool,
        revision: UInt64? = nil,
        for session: SessionCoordinator
    ) async {
        guard activeSession === session,
              revision.map({ $0 >= controlAppliedRevision }) ?? true else { return }
        stateStore.setProcessTargetingAuthorized(enabled)
        let gateRevision = revision ?? controlAppliedRevision
        if let inputRuntime {
            await inputRuntime.setLocalInputAdmission(
                enabled,
                revision: gateRevision,
                session: session
            )
        } else {
            await session.setLocalInputAdmission(enabled, revision: gateRevision)
        }
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
        let initialPermission = await captureSession.permissionState()
        recordDebugScreenRecordingPermission(initialPermission)
        guard initialPermission != .authorized else {
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

        let requestedPermission = await captureSession.requestPermission()
        recordDebugScreenRecordingPermission(requestedPermission)
        // On some macOS releases the consent UI is delivered asynchronously.
        // Recheck for a bounded period before failing closed, so an Allow click
        // is not mistaken for a denial merely because the TCC database has not
        // returned the new state to this process yet.
        for _ in 0 ..< 120 {
            let permission = await captureSession.permissionState()
            recordDebugScreenRecordingPermission(permission)
            if permission == .authorized {
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
        guard !activeSessionStopInProgress else { return }
        activeSessionStopInProgress = true
        defer { activeSessionStopInProgress = false }
        let stoppingSession = activeSession
        let stoppingControlSessionID = controlSessionID
        // Fence status and consent tasks before yielding to another actor.
        activeSession = nil
        controlSessionID = nil
        controlAppliedRevision = 0
        controlGranted = false
        controlWireAuthorized = false
        controlPaused = false
        controlPeerIdentifier = nil
        controlPeerName = nil
        stateStore.setProcessTargetingAuthorized(false)
        if let stoppingSession {
            await stoppingSession.setLocalInputAdmission(false, revision: .max)
        }
        if let stoppingControlSessionID {
            await controlAuthorization.endSession(stoppingControlSessionID)
        }

        sessionMonitor?.cancel()
        sessionMonitor = nil
        await stopVideoPipeline()
        await inputRuntime?.stop()
        inputRuntime = nil
        if let stoppingSession {
            await stoppingSession.stop(reason: .normal)
        }
        selectedWindow = nil
        selectedWindowGeneration = nil
        captureRecoveryStatusActive = false
        advertisedWindowCatalogGeneration = 0
        advertisedWindows.removeAll(keepingCapacity: false)
        clipboardAuthorizedForSession = false
        stateStore.clearSelection()
        publishControlStatus(.unavailable)
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
        guard activeSession == nil,
              !activeSessionStopInProgress,
              !pairingResetInProgress,
              let localIdentity else {
            await transport.close()
            return
        }

        let pairingCoordinator = PairingCoordinator(
            localIdentity: localIdentity.peerIdentity,
            trustStore: trustStore
        )

        let session = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "MacRemoteApp-Host-M10",
                deviceName: configuration.serviceName,
                capabilities: Self.capabilities,
                mandatoryCapabilities: [.pingPong],
                // Advertise the CaptureCore pixel cap; SessionCoordinator
                // rejects any StreamConfig/VideoFrame above the negotiated
                // min(Host, Viewer) bound.
                maxVideoWidth: CaptureConfiguration.default.maximumWidth,
                maxVideoHeight: CaptureConfiguration.default.maximumHeight,
                maxFrameRate: 60
            ),
            transport: transport,
            pairingCoordinator: pairingCoordinator
        )
#if DEBUG
        let diagnosticConnectionSequence = M10HostDiagnosticFileLog.shared.recordConnectionStarted()
        M10HostDiagnosticFileLog.shared.bind(session, toConnectionSequence: diagnosticConnectionSequence)
#endif
        activeSession = session
        controlSessionID = UUID()
        controlAppliedRevision = 0
        publish(.connected)
        controlGranted = false
        controlWireAuthorized = false
        controlPaused = false
        controlPeerIdentifier = nil
        controlPeerName = nil
        stateStore.setProcessTargetingAuthorized(false)
        await setControlStatus(.negotiating, for: session)
        clipboardAuthorizedForSession = false
        stateStore.update(session: await session.snapshot())

        let contextProvider = CoreGraphicsAccessibilityContextProvider(
            sessionStateProvider: { [stateStore] in stateStore.sessionState() },
            selectionProvider: { [stateStore] in stateStore.selection() }
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
            onInputStatusChange: { [weak self] status in
#if DEBUG
                await self?.recordDebugInputReadiness(status)
#endif
                let snapshot = await session.snapshot()
                guard snapshot.state != .failed,
                      snapshot.state != .stopping,
                      snapshot.state != .reconnecting else { return }

                let permission: PermissionState
                let focusEligible: Bool
                let processTargetEligible: Bool?
                switch status {
                case .ready:
                    permission = .granted
                    focusEligible = true
                    processTargetEligible = snapshot.negotiatedCapabilities.contains(.backgroundControl) ? true : nil
                case .permissionUnavailable:
                    // A previously authorized input path lost its local TCC
                    // access. The Viewer must remain disabled until a fresh
                    // Host status proves that permission is usable again.
                    permission = .revoked
                    focusEligible = false
                    processTargetEligible = snapshot.negotiatedCapabilities.contains(.backgroundControl) ? false : nil
                case .focusUnavailable:
                    permission = .granted
                    focusEligible = false
                    processTargetEligible = snapshot.negotiatedCapabilities.contains(.backgroundControl) ? false : nil
                case .sessionUnauthorized,
                     .selectionUnavailable,
                     .capabilityUnavailable,
                     .inputStateCleanupPending:
                    permission = .unknown
                    focusEligible = false
                    processTargetEligible = snapshot.negotiatedCapabilities.contains(.backgroundControl) ? false : nil
                }
                _ = try? await session.send(
                    .sessionState(
                        SessionStateMessage(
                            state: snapshot.state,
                            permission: permission,
                            focusEligible: focusEligible,
                            windowGeneration: snapshot.authorizedWindowGeneration,
                            processTargetEligible: processTargetEligible
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
            await prepareViewerControl(for: session)
            let windows = try await discoverWindowsForRuntime()
            advertisedWindowGeneration = max(1, (await captureSession.snapshot().generation) &+ 1)
            stateStore.update(session: await session.snapshot())
            try await authorizeSession(
                session,
                source: .connectionEstablishment,
                windowGeneration: advertisedWindowGeneration,
                capabilities: [.windowSelection]
            )
            stateStore.update(session: await session.snapshot())
            _ = try await publishWindowCatalog(windows, to: session, force: true)
#if DEBUG
            M10HostDiagnosticFileLog.shared.record(.connectionOutcome(.connected))
#endif
            sessionMonitor = Task { [weak self] in
                await self?.monitor(session)
            }
        } catch let error as SessionError {
#if DEBUG
            M10HostDiagnosticFileLog.shared.record(
                .connectionOutcome(error == .pairingDenied ? .pairingDenied : .sessionFailure)
            )
            recordDebugSessionFailure(error)
#endif
            await setLocalControlAdmission(false, for: session)
            await setControlStatus(.unavailable, for: session)
            await teardown(session: session)
        } catch {
#if DEBUG
            M10HostDiagnosticFileLog.shared.record(.connectionOutcome(.connectionFailure))
#endif
            await setLocalControlAdmission(false, for: session)
            await setControlStatus(.unavailable, for: session)
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
            recordDebugSessionState(snapshot)
#if DEBUG
            M10HostVideoDiagnostics.shared.flushIfDue()
#endif
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
            recordDebugSessionState(snapshot)
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
            recordDebugSessionState(snapshot)
            stateStore.update(session: snapshot)
            if snapshot.state == .failed || snapshot.state == .stopping {
#if DEBUG
                if snapshot.state == .failed {
                    recordDebugSessionFailure(await session.failureReason())
                }
#endif
                await teardown(session: session)
                return
            }
            if selectedWindow != nil, !selectionTransitionInProgress {
                await synchronizeInputAuthorization(session)
                let captureSnapshot = await captureSession.snapshot()
                guard HostRuntimeCaptureLivenessPolicy.keepsAuthenticatedSession(
                    for: captureSnapshot.state
                ) else {
                    // Confirmed target loss or permission failure closes the
                    // protected session. A short discovery gap and bounded
                    // stream restart keep the authenticated session alive.
                    startupLogger.error(
                        "Host ended the session because capture stopped (state: \(HostRuntimeCaptureLivenessPolicy.summary(for: captureSnapshot.state), privacy: .public))"
                    )
                    await teardown(session: session)
                    return
                }
                switch captureSnapshot.state {
                case .capturing:
                    if captureRecoveryStatusActive, let selectedWindow {
                        captureRecoveryStatusActive = false
                        publish(.sharing(
                            application: Self.statusApplicationName(for: selectedWindow),
                            broughtToFront: false
                        ))
                    }
                    break
                case .recovering:
                    if !captureRecoveryStatusActive, let selectedWindow {
                        captureRecoveryStatusActive = true
                        publish(.recovering(
                            application: Self.statusApplicationName(for: selectedWindow)
                        ))
                    }
                    break
                case .idle, .starting, .stopping, .stopped, .failed:
                    break
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
            windows = try await discoverWindowsForRuntime()
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

    /// A catalog can change between the Viewer rendering its picker and the
    /// Host receiving the selection. That is a normal UI race, not a reason to
    /// end an authenticated session. Advance the catalog epoch even if the
    /// descriptors are unchanged so the Viewer can discard its pending choice
    /// and retry against the refreshed snapshot.
    private func republishWindowCatalogAfterRejectedSelection(
        _ session: SessionCoordinator,
        discoveredWindows: [CaptureWindow]? = nil
    ) async {
        guard activeSession === session else { return }
        let windows: [CaptureWindow]
        if let discoveredWindows {
            windows = discoveredWindows
        } else {
            windows = (try? await discoverWindowsForRuntime()) ?? advertisedWindows
        }
        guard activeSession === session else { return }

        if windows == advertisedWindows {
            guard advertisedWindowCatalogGeneration < UInt64.max else {
                scheduleTeardown(session: session)
                return
            }
            advertisedWindowCatalogGeneration &+= 1
        }
        do {
            _ = try await publishWindowCatalog(windows, to: session, force: true)
        } catch {
            startupLogger.error(
                "Host window catalog recovery failed (error: \(String(describing: error), privacy: .public))"
            )
            scheduleTeardown(session: session)
        }
    }

    /// Capture/encoder startup for one app may fail even though the LAN
    /// session is healthy. Release the old input target, return to the current
    /// authorized selection epoch, and let the Viewer choose a window again.
    private func recoverFromSelectionFailure(
        _ session: SessionCoordinator,
        fallbackWindowGeneration: UInt64
    ) async {
        guard activeSession === session else { return }
        selectionTransitionInProgress = true
        defer { selectionTransitionInProgress = false }
        selectedWindow = nil
        selectedWindowGeneration = nil
        captureRecoveryStatusActive = false
        stateStore.clearSelection()
        await stopVideoPipeline()

        let snapshot = await session.snapshot()
        guard snapshot.authorized,
              snapshot.state != .failed,
              snapshot.state != .stopping else {
            scheduleTeardown(session: session)
            return
        }
        advertisedWindowGeneration = snapshot.authorizedWindowGeneration ?? fallbackWindowGeneration
        stateStore.update(session: snapshot)

        if clipboardAuthorizedForSession,
           snapshot.authorizedCapabilities.contains(.textClipboard),
           let inputRuntime {
            try? await inputRuntime.setClipboardEnabled(true)
        }
        await republishWindowCatalogAfterRejectedSelection(session)
    }

    /// Records the exact authorization epoch returned by TransportCore for
    /// successful attempts. Failed attempts retain source and requested
    /// metadata without inventing a generation transition.
    private func authorizeWithInputFence(
        _ session: SessionCoordinator,
        windowGeneration: UInt64?,
        capabilities: Set<Capability>
    ) async throws -> SessionAuthorizationTransition {
        // Capture the runtime before the first suspension. If HostRuntime is
        // re-entered while authorization waits for its receipt, this call must
        // release the same input loop whose admissions it closed.
        let inputRuntime = self.inputRuntime
        guard let inputRuntime else {
            // The initial connection cannot have admitted Host input before
            // its input runtime is created.
            return try await session.authorize(
                windowGeneration: windowGeneration,
                capabilities: capabilities
            )
        }
        return try await inputRuntime.withAuthorizationFence(session: session) {
            try await session.authorize(
                windowGeneration: windowGeneration,
                capabilities: capabilities
            )
        }
    }

    private func authorizeSession(
        _ session: SessionCoordinator,
        source: M10HostAuthorizationSource,
        windowGeneration: UInt64?,
        capabilities: Set<Capability>
    ) async throws {
        do {
#if DEBUG
            let transition = try await authorizeWithInputFence(
                session,
                windowGeneration: windowGeneration,
                capabilities: capabilities
            )
            recordAuthorizationAttempt(
                session,
                source: source,
                succeeded: true,
                transition: transition,
                requestedWindowGeneration: windowGeneration,
                requestedCapabilities: capabilities
            )
#else
            _ = try await authorizeWithInputFence(
                session,
                windowGeneration: windowGeneration,
                capabilities: capabilities
            )
#endif
        } catch {
#if DEBUG
            recordAuthorizationAttempt(
                session,
                source: source,
                succeeded: false,
                transition: nil,
                requestedWindowGeneration: windowGeneration,
                requestedCapabilities: capabilities
            )
#endif
            throw error
        }
    }

#if DEBUG
    private func recordAuthorizationAttempt(
        _ session: SessionCoordinator,
        source: M10HostAuthorizationSource,
        succeeded: Bool,
        transition: SessionAuthorizationTransition?,
        requestedWindowGeneration: UInt64?,
        requestedCapabilities: Set<Capability>
    ) {
        M10HostDiagnosticFileLog.shared.record(
            .authorizationAttempt(
                source: source,
                succeeded: succeeded,
                transition: transition.map { M10HostAuthorizationDiagnosticTransition($0) },
                requestedWindowGeneration: requestedWindowGeneration,
                requestedCapabilities: M10HostCapabilityDiagnosticFlags(requestedCapabilities)
            ),
            connectionSequenceOverride: M10HostDiagnosticFileLog.shared.connectionSequence(for: session) ?? 0
        )
    }
#endif

    private func synchronizeInputAuthorization(_ session: SessionCoordinator) async {
        guard activeSession === session,
              let controlSessionID,
              selectedWindow != nil,
              let selectedWindowGeneration else { return }
        let expectedControlRevision = controlAppliedRevision
        let processControlGranted = controlWireAuthorized
        let snapshot = await session.snapshot()
        guard activeSession === session,
              self.controlSessionID == controlSessionID,
              controlAppliedRevision == expectedControlRevision,
              snapshot.authorized,
              snapshot.authorizedWindowGeneration == selectedWindowGeneration else {
            return
        }

        let permission = CoreGraphicsAccessibilityContextProvider.currentPermissionState()
        guard activeSession === session,
              self.controlSessionID == controlSessionID,
              controlAppliedRevision == expectedControlRevision else { return }
        let negotiatedInput = snapshot.negotiatedCapabilities.intersection(Self.inputCapabilities)
        let processControlNegotiated = snapshot.negotiatedCapabilities.contains(.backgroundControl)
        var desired = snapshot.authorizedCapabilities
        let wasAuthorizedForProcessControl = snapshot.authorizedCapabilities.contains(.backgroundControl)
        if permission == .authorized &&
            (!processControlNegotiated || processControlGranted || wasAuthorizedForProcessControl) {
            desired.formUnion(negotiatedInput)
        } else {
            desired.subtract(Self.inputCapabilities)
        }
        if permission == .authorized,
           desired.contains(.keyboardInput),
           snapshot.negotiatedCapabilities.contains(.inputSourceSync) {
            desired.insert(.inputSourceSync)
        } else {
            desired.remove(.inputSourceSync)
        }
        if processControlNegotiated && permission == .authorized &&
            (processControlGranted || wasAuthorizedForProcessControl) {
            desired.insert(.backgroundControl)
        } else {
            desired.remove(.backgroundControl)
        }
        if clipboardAuthorizedForSession,
           snapshot.negotiatedCapabilities.contains(.textClipboard) {
            desired.insert(.textClipboard)
        } else {
            desired.remove(.textClipboard)
        }
        guard desired != snapshot.authorizedCapabilities else { return }
        let shouldRestoreClipboard = clipboardAuthorizedForSession &&
            desired.contains(.textClipboard)

        do {
            try await authorizeSession(
                session,
                source: .inputAuthorization,
                windowGeneration: selectedWindowGeneration,
                capabilities: desired
            )
            guard activeSession === session,
                  self.controlSessionID == controlSessionID,
                  controlAppliedRevision == expectedControlRevision else { return }
            // SessionCoordinator invalidates queued protected media whenever
            // the authorization epoch changes. Force the next keyframe to
            // carry VideoConfig again instead of allowing the Viewer to keep
            // a stale decoder configuration.
            videoConfigSentGeneration = nil
            videoConfigSentAuthorizationGeneration = nil
            let updated = await session.snapshot()
            guard activeSession === session,
                  self.controlSessionID == controlSessionID,
                  controlAppliedRevision == expectedControlRevision else { return }
            stateStore.update(session: updated)
            if shouldRestoreClipboard, let inputRuntime {
                do {
                    try await inputRuntime.setClipboardEnabled(true)
                    guard activeSession === session,
                          self.controlSessionID == controlSessionID,
                          controlAppliedRevision == expectedControlRevision else { return }
                } catch {
                    // Text clipboard is optional. A local bridge failure
                    // disables only this capability for the current session;
                    // it must not affect the selected video or LAN session.
                    clipboardAuthorizedForSession = false
                    try? await inputRuntime.setClipboardEnabled(false)
                    var fallback = desired
                    fallback.remove(.textClipboard)
                    try? await authorizeSession(
                        session,
                        source: .clipboardFallback,
                        windowGeneration: selectedWindowGeneration,
                        capabilities: fallback
                    )
                    guard activeSession === session,
                          self.controlSessionID == controlSessionID,
                          controlAppliedRevision == expectedControlRevision else { return }
                    let fallbackSnapshot = await session.snapshot()
                    guard activeSession === session,
                          self.controlSessionID == controlSessionID,
                          controlAppliedRevision == expectedControlRevision else { return }
                    stateStore.update(session: fallbackSnapshot)
                }
            }
        } catch {
            guard activeSession === session,
                  self.controlSessionID == controlSessionID,
                  controlAppliedRevision == expectedControlRevision else { return }
            videoConfigSentGeneration = nil
            videoConfigSentAuthorizationGeneration = nil
            // The session loop will handle a failed peer. Keep the local
            // admission state synchronized with the latest session snapshot.
            let failedSnapshot = await session.snapshot()
            guard activeSession === session,
                  self.controlSessionID == controlSessionID,
                  controlAppliedRevision == expectedControlRevision else { return }
            stateStore.update(session: failedSnapshot)
        }
    }

    private func handle(_ message: MessagePayload, for session: SessionCoordinator) async {
        guard activeSession === session else { return }
        switch message {
        case let .windowSelection(selection):
#if DEBUG
            M10HostDiagnosticFileLog.shared.record(.windowSelection(.requested))
#endif
            guard selection.windowGeneration == advertisedWindowGeneration,
                  selection.catalogGeneration == advertisedWindowCatalogGeneration,
                  let advertisedWindow = advertisedWindows.first(where: {
                      $0.identifier == selection.windowIdentifier && $0.eligible
                  }) else {
#if DEBUG
                M10HostDiagnosticFileLog.shared.record(.windowSelection(.rejected))
#endif
                await republishWindowCatalogAfterRejectedSelection(session)
                return
            }
            do {
                let windows = try await discoverWindowsForRuntime()
                guard activeSession === session else { return }
                guard let window = windows.first(where: {
                    $0.identifier == selection.windowIdentifier && $0.eligible
                }),
                selection.catalogGeneration == advertisedWindowCatalogGeneration,
                let currentAdvertisedWindow = advertisedWindows.first(where: {
                    $0.identifier == selection.windowIdentifier && $0.eligible
                }),
                currentAdvertisedWindow.hasSameOwner(as: advertisedWindow),
                window.hasSameOwner(as: currentAdvertisedWindow) else {
#if DEBUG
                    M10HostDiagnosticFileLog.shared.record(.windowSelection(.rejected))
#endif
                    await republishWindowCatalogAfterRejectedSelection(session, discoveredWindows: windows)
                    return
                }
                switch HostRuntimeWindowSelectionAction.resolve(
                    currentWindowHasSameOwner: selectedWindow?.hasSameOwner(as: window) == true
                ) {
                case .restoreExistingSelection:
                    guard let selectedWindowGeneration else { return }
                    _ = await restoreSelectedApplicationToForeground(
                        window,
                        for: session,
                        requestGeneration: selectedWindowGeneration,
                        requiresHostFrontmost: false
                    )
                    return
                case .activateRequestedSelection:
                    break
                }
                let previousWindowGeneration = advertisedWindowGeneration
                guard previousWindowGeneration < UInt64.max else {
                    scheduleTeardown(session: session)
                    return
                }
                // The selected-window generation fences input/media, while
                // catalogGeneration above fences the exact WindowList snapshot.
                // Both are required because WindowServer can reuse a numeric
                // ID after an app exits.
                let replacementGeneration = previousWindowGeneration &+ 1
                advertisedWindowGeneration = replacementGeneration
                do {
                    try await activateSelection(
                        window,
                        generation: replacementGeneration,
                        session: session
                    )
#if DEBUG
                    M10HostDiagnosticFileLog.shared.record(.windowSelection(.accepted))
#endif
                } catch {
#if DEBUG
                    M10HostDiagnosticFileLog.shared.record(.windowSelection(.rejected))
#endif
                    startupLogger.error(
                        "Host could not start the selected window; keeping the session available for retry (error: \(String(describing: error), privacy: .public))"
                    )
                    await recoverFromSelectionFailure(
                        session,
                        fallbackWindowGeneration: previousWindowGeneration
                    )
                }
            } catch {
                guard activeSession === session else { return }
#if DEBUG
                M10HostDiagnosticFileLog.shared.record(.windowSelection(.rejected))
#endif
                startupLogger.error(
                    "Host could not refresh windows during selection; keeping the session available (error: \(String(describing: error), privacy: .public))"
                )
                await republishWindowCatalogAfterRejectedSelection(session)
            }
        case let .keyframeRequest(request):
            // SessionCoordinator already checked the authorized capability
            // and window generation; also ignore a request for a stream the
            // encoder is no longer producing.
            guard request.generation == selectedWindowGeneration, encoder != nil else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if let last = lastViewerKeyframeRequestNanoseconds,
               now &- last < Self.viewerKeyframeRequestMinimumIntervalNanoseconds {
                return
            }
            if request.reason == .mediaGap {
                applyBitrate(bitrateController?.recordCongestion(atNanoseconds: now), reason: "viewer-media-gap")
            }
            lastViewerKeyframeRequestNanoseconds = now
            requestKeyframe()
        case let .receiverReport(report):
            // Authorization and window generation were checked by
            // SessionCoordinator; ignore a report for a stopped pipeline.
            guard report.generation == selectedWindowGeneration, encoder != nil else { return }
            applyBitrate(
                bitrateController?.recordReport(
                    queuingDelayMicroseconds: report.queuingDelayMicroseconds,
                    discardedFrames: report.discardedFrames,
                    atNanoseconds: DispatchTime.now().uptimeNanoseconds
                ),
                reason: "viewer-report"
            )
        case let .sessionState(message):
            if message.state == .failed || message.state == .stopping {
#if DEBUG
                M10HostDiagnosticFileLog.shared.record(.peerTerminal(
                    message.state == .failed ? .sessionFailed : .sessionStopping
                ))
#endif
            }
        case .close:
#if DEBUG
            M10HostDiagnosticFileLog.shared.record(.peerTerminal(.close))
#endif
            scheduleTeardown(session: session)
        default:
            break
        }
    }

    /// `handle` is called by HostInputSessionLoop's single message consumer.
    /// Defer teardown until that callback returns; otherwise `stop()` would
    /// try to join the very task that is currently awaiting this callback.
    private func scheduleTeardown(session: SessionCoordinator) {
        HostRuntimeCallbackTeardownScheduler.schedule { [weak self] in
            await self?.teardown(session: session)
        }
    }

    private func restoreSelectedApplicationToForeground(
        _ window: CaptureWindow,
        for session: SessionCoordinator,
        requestGeneration: UInt64,
        requiresHostFrontmost: Bool
    ) async -> Bool {
        let snapshot = await session.snapshot()
        let hostIsFrontmost: Bool
        if requiresHostFrontmost {
            hostIsFrontmost = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.processIdentifier ==
                    ProcessInfo.processInfo.processIdentifier
            }
        } else {
            hostIsFrontmost = false
        }
        guard HostRuntimeForegroundRestorationPolicy.permits(
            activeSession: activeSession === session,
            selectionTransitionInProgress: selectionTransitionInProgress,
            authorized: snapshot.authorized,
            selectedWindowMatches: selectedWindow?.hasSameOwner(as: window) == true,
            requestGeneration: requestGeneration,
            selectedWindowGeneration: selectedWindowGeneration,
            authorizedWindowGeneration: snapshot.authorizedWindowGeneration,
            requiresHostFrontmost: requiresHostFrontmost,
            hostIsFrontmost: hostIsFrontmost
        ) else {
            return false
        }

        let didRestore = await bringSelectedApplicationToForeground(
            window,
            explicitViewerSelection: true
        )
        let currentSnapshot = await session.snapshot()
        guard HostRuntimeForegroundRestorationPolicy.permits(
            activeSession: activeSession === session,
            selectionTransitionInProgress: selectionTransitionInProgress,
            authorized: currentSnapshot.authorized,
            selectedWindowMatches: selectedWindow?.hasSameOwner(as: window) == true,
            requestGeneration: requestGeneration,
            selectedWindowGeneration: selectedWindowGeneration,
            authorizedWindowGeneration: currentSnapshot.authorizedWindowGeneration,
            requiresHostFrontmost: false,
            hostIsFrontmost: true
        ) else {
            return false
        }
        return didRestore
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
#if DEBUG
        M10HostVideoDiagnostics.shared.beginWindow()
#endif
        captureRecoveryStatusActive = false
        try await captureSession.start(window: window)
        let captureSnapshot = await captureSession.snapshot()
        // CaptureCore owns its internal engine generation. It advances that
        // value on every restart, including a same-session window switch. The
        // wire generation remains the advertised WindowList generation and is
        // intentionally validated separately above.
        guard case .capturing = captureSnapshot.state,
              captureSnapshot.selectedWindow?.hasSameOwner(as: window) == true,
              let selected = captureSnapshot.selectedWindow,
              let dimensions = captureSnapshot.outputDimensions else {
            throw HostRuntimeError.staleWindowGeneration
        }

        let negotiatedCapabilities = (await session.snapshot()).negotiatedCapabilities
        let negotiatedInput = negotiatedCapabilities.intersection(Self.inputCapabilities)
        let processControlNegotiated = negotiatedCapabilities.contains(.backgroundControl)
        let currentPermission = CoreGraphicsAccessibilityContextProvider.currentPermissionState()
        let permission: HostInputPermissionState
        if !negotiatedInput.isEmpty, currentPermission != .authorized {
            // Ask only after a Viewer has negotiated input and the operator has
            // selected a Host window. The signed Host bundle owns the TCC
            // request; a view-only session never receives this prompt.
            permission = await MainActor.run {
                CoreGraphicsAccessibilityContextProvider.requestPermission()
            }
        } else {
            permission = currentPermission
        }
        // Authorize only the capabilities both endpoints negotiated. A Viewer
        // may intentionally omit optional input or clipboard support; that
        // must degrade to view-only/partial control instead of rejecting the
        // entire selected window.
        var authorizedCapabilities = Self.capabilities.intersection(negotiatedCapabilities)
        if permission != .authorized || (processControlNegotiated && !controlWireAuthorized) {
            authorizedCapabilities.subtract(Self.inputCapabilities)
            authorizedCapabilities.remove(.inputSourceSync)
            authorizedCapabilities.remove(.backgroundControl)
        } else if !authorizedCapabilities.contains(.keyboardInput) {
            authorizedCapabilities.remove(.inputSourceSync)
        }
        if !clipboardAuthorizedForSession {
            authorizedCapabilities.remove(.textClipboard)
        }

        // P6 is a pairing and control-generation extension; it does not
        // enable inactive-process event delivery. Every explicit selection
        // must foreground the selected regular app before input can be
        // authorized, regardless of capability negotiation.
        let didForegroundSelectedApplication = await bringSelectedApplicationToForeground(selected)
        if !didForegroundSelectedApplication {
            startupLogger.error(
                "Host could not confirm the selected application became foreground; input remains fail-closed"
            )
        }
        authorizedCapabilities = HostRuntimeForegroundActivationPolicy.authorizedCapabilities(
            authorizedCapabilities,
            afterForegroundConfirmation: didForegroundSelectedApplication,
            inputCapabilities: Self.inputCapabilities
        )

        try await authorizeSession(
            session,
            source: .windowSelection,
            windowGeneration: generation,
            capabilities: authorizedCapabilities
        )
        selectedWindow = selected
        selectedWindowGeneration = generation
        publish(
            .sharing(
                application: Self.statusApplicationName(for: selected),
                broughtToFront: didForegroundSelectedApplication
            )
        )
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

        if clipboardAuthorizedForSession,
           authorizedCapabilities.contains(.textClipboard) {
            do {
                try await inputRuntime?.setClipboardEnabled(true)
            } catch {
                // Text clipboard is optional. A bridge failure must not turn
                // an accepted window selection into a video/session failure.
                clipboardAuthorizedForSession = false
                try? await inputRuntime?.setClipboardEnabled(false)
                authorizedCapabilities.remove(.textClipboard)
                try await authorizeSession(
                    session,
                    source: .clipboardFallback,
                    windowGeneration: generation,
                    capabilities: authorizedCapabilities
                )
                stateStore.update(session: await session.snapshot())
                startupLogger.error(
                    "Host clipboard bridge is unavailable; continuing without text clipboard"
                )
            }
        }

        // `dimensions` is the pixel size the capture engine was configured
        // with for this generation (backing scale applied, fit to the cap).
        let encoder = try H264Encoder(
            configuration: H264EncoderConfiguration(
                width: dimensions.width,
                height: dimensions.height,
                frameRate: 60,
                averageBitrate: H264EncoderConfiguration.defaultAverageBitrate,
                keyframeInterval: 60,
                maxInFlightFrames: 2
            )
        )
        try encoder.start(generation: generation)
        self.encoder = encoder
        videoConfigSentGeneration = nil
        videoConfigSentAuthorizationGeneration = nil
        keyframeRequested = false
        captureToSendCollector.reset()
        bitrateController = AdaptiveBitrateController(
            configuration: .standard(maximumBitrate: H264EncoderConfiguration.defaultAverageBitrate)
        )
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

        // Announce that the selection succeeded before sending a refreshed
        // catalog. The Viewer can then distinguish a genuine stream start
        // from a catalog refresh rejecting an out-of-date picker selection.
        let refreshedWindows = try await discoverWindowsForRuntime()
        _ = try await publishWindowCatalog(refreshedWindows, to: session, force: true)

        let frames = captureSession.frames
        let relay = HostEncodedFrameRelay()
        encodedFrameRelay = relay
        encodedSendTask = Task { [weak self] in
            var continuity = HostEncodedFrameContinuity()
            for await relayFrame in relay.frames {
                guard !Task.isCancelled else { return }
                let decision = continuity.consume(
                    relayFrame,
                    droppedFrameObserved: relay.takeDroppedFrame()
                )
                if !decision.shouldSend {
#if DEBUG
                    M10HostVideoDiagnostics.shared.recordDropped()
#endif
                }
                if decision.requestKeyframe {
                    await self?.requestKeyframe()
                }
                guard decision.shouldSend else { continue }
                await self?.sendEncoded(
                    relayFrame.result,
                    generation: generation,
                    session: session
                )
            }
        }
        captureTask = Task { [weak self, weak encoder] in
            defer { relay.finish() }
            var framesSinceKeyframe = 60
            do {
                for try await frame in frames {
                    guard !Task.isCancelled, let encoder else { return }
#if DEBUG
                    M10HostVideoDiagnostics.shared.recordCaptured()
#endif
                    let requested = await self?.consumeKeyframeRequest() ?? false
                    let forceKeyframe = requested || framesSinceKeyframe >= 60
                    do {
                        try encoder.encode(
                            pixelBuffer: frame.pixelBuffer,
                            captureTimestamp: frame.captureTimestamp,
                            presentationTimestamp: frame.presentationTimestamp,
                            forceKeyframe: forceKeyframe,
                            completion: { result in
#if DEBUG
                                switch result {
                                case .success:
                                    M10HostVideoDiagnostics.shared.recordEncoded()
                                case .failure:
                                    M10HostVideoDiagnostics.shared.recordEncodeFailure()
                                }
#endif
                                relay.submit(result)
                            }
                        )
                        framesSinceKeyframe = forceKeyframe ? 0 : framesSinceKeyframe + 1
                    } catch {
#if DEBUG
                        M10HostVideoDiagnostics.shared.recordEncodeFailure()
                        M10HostVideoDiagnostics.shared.recordDropped()
#endif
                        // VideoToolbox queue pressure is handled by dropping
                        // the frame; the bounded CaptureCore stream provides
                        // the next opportunity for a keyframe.
                        if forceKeyframe {
                            framesSinceKeyframe = 60
                        }
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
                    // a decoder after the previous epoch was invalidated, so
                    // ask for one instead of waiting for the periodic keyframe.
                    keyframeRequested = true
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
            let result = try await session.send(
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
            if result == .replacedMedia {
#if DEBUG
                M10HostVideoDiagnostics.shared.recordDropped()
#endif
                keyframeRequested = true
                // The Host send queue is full: the path cannot carry the
                // current bitrate.
                applyBitrate(
                    bitrateController?.recordCongestion(atNanoseconds: DispatchTime.now().uptimeNanoseconds),
                    reason: "host-queue-discard"
                )
            } else {
#if DEBUG
                M10HostVideoDiagnostics.shared.recordSendQueued()
#endif
            }
            captureToSendCollector.append(
                startNanoseconds: frame.captureTimestamp,
                endNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            logCaptureToSendStageIfDue()
        } catch let error as SessionError {
            switch error {
            case .authorizationChanged:
                // This is a normal race with authorization/reconnect. The
                // next admitted keyframe will rebuild VideoConfig for the
                // current epoch; do not freeze the capture pipeline.
                let observedSnapshot = await session.snapshot()
                guard activeSession === session else { return }
                resetVideoConfigurationForAuthorizationTransition()
#if DEBUG
                recordVideoAuthorizationDenial(
                    session: session,
                    reason: M10HostVideoAuthorizationReason.forSessionError(error) ?? .other,
                    recovered: true,
                    captured: snapshot,
                    observed: observedSnapshot
                )
#endif
            case .reconnectRequired:
                // A stale receive/reconnect lease is distinct from a changed
                // authorization epoch, though both keep the current recovery
                // behavior and request a fresh keyframe.
                let observedSnapshot = await session.snapshot()
                guard activeSession === session else { return }
                resetVideoConfigurationForAuthorizationTransition()
#if DEBUG
                recordVideoAuthorizationDenial(
                    session: session,
                    reason: M10HostVideoAuthorizationReason.forSessionError(error) ?? .other,
                    recovered: true,
                    captured: snapshot,
                    observed: observedSnapshot
                )
#endif
            case let .unauthorizedMessage(messageType)
                where messageType == .videoConfig || messageType == .videoFrame:
                let freshSnapshot = await session.snapshot()
                guard activeSession === session else { return }
                guard HostRuntimeVideoAuthorizationRecoveryPolicy.shouldRecover(
                    capturedAuthorizationGeneration: snapshot.authorizationGeneration,
                    capturedWindowGeneration: snapshot.authorizedWindowGeneration,
                    capturedAuthorized: snapshot.authorized,
                    freshAuthorizationGeneration: freshSnapshot.authorizationGeneration,
                    freshWindowGeneration: freshSnapshot.authorizedWindowGeneration,
                    freshAuthorized: freshSnapshot.authorized
                ) else {
#if DEBUG
                    let reason = videoAuthorizationDenialReason(
                        captured: snapshot,
                        current: freshSnapshot,
                        expectedWindowGeneration: generation
                    )
                    recordVideoAuthorizationDenial(
                        session: session,
                        reason: reason,
                        recovered: false,
                        captured: snapshot,
                        observed: freshSnapshot
                    )
#endif
                    startupLogger.error("Host video send stopped after authorization denial")
                    await stopVideoPipelineIfCurrent(session)
                    return
                }
                resetVideoConfigurationForAuthorizationTransition()
#if DEBUG
                let reason = videoAuthorizationDenialReason(
                    captured: snapshot,
                    current: freshSnapshot,
                    expectedWindowGeneration: generation
                )
                recordVideoAuthorizationDenial(
                    session: session,
                    reason: reason,
                    recovered: true,
                    captured: snapshot,
                    observed: freshSnapshot
                )
#endif
                let messageTypeName = messageType == .videoConfig ? "video_config" : "video_frame"
                startupLogger.notice(
                    "Host video authorization changed; pipeline recovery requested type=\(messageTypeName, privacy: .public)"
                )
            default:
#if DEBUG
                M10HostVideoDiagnostics.shared.recordSendFailure()
#endif
                startupLogger.error("Host video send stopped after a fixed session error")
                await stopVideoPipelineIfCurrent(session)
            }
        } catch {
#if DEBUG
            M10HostVideoDiagnostics.shared.recordSendFailure()
#endif
            startupLogger.error("Host video send stopped after a fixed send failure")
            await stopVideoPipelineIfCurrent(session)
        }
    }

    private func resetVideoConfigurationForAuthorizationTransition() {
        videoConfigSentGeneration = nil
        videoConfigSentAuthorizationGeneration = nil
        requestKeyframe()
    }

#if DEBUG
    private func videoAuthorizationDenialReason(
        captured: SessionSnapshot,
        current: SessionSnapshot,
        expectedWindowGeneration: UInt64
    ) -> M10HostVideoAuthorizationReason {
        guard current.authorized else { return .sessionUnauthorized }
        guard current.authorizedCapabilities.contains(.h264Video) else { return .missingCapability }
        guard current.authorizedWindowGeneration == expectedWindowGeneration else {
            return .windowGenerationMismatch
        }
        guard captured.receiveGeneration == current.receiveGeneration,
              captured.reconnectGeneration == current.reconnectGeneration else {
            return .reconnectRequired
        }
        guard captured.authorizationGeneration == current.authorizationGeneration else {
            return .authorizationChanged
        }
        return .other
    }

    private func recordVideoAuthorizationDenial(
        session: SessionCoordinator,
        reason: M10HostVideoAuthorizationReason,
        recovered: Bool,
        captured: SessionSnapshot,
        observed: SessionSnapshot
    ) {
        M10HostDiagnosticFileLog.shared.record(
            .videoAuthorizationDenied(
                reason: reason,
                recovered: recovered,
                capturedAuthorizationGeneration: captured.authorizationGeneration,
                observedAuthorizationGeneration: observed.authorizationGeneration,
                capturedReconnectGeneration: captured.reconnectGeneration,
                observedReconnectGeneration: observed.reconnectGeneration,
                capturedReceiveGeneration: captured.receiveGeneration,
                observedReceiveGeneration: observed.receiveGeneration
            ),
            connectionSequenceOverride: M10HostDiagnosticFileLog.shared.connectionSequence(for: session) ?? 0
        )
    }
#endif

    /// Logs only aggregate timing, roughly every ten seconds at 60 fps.
    private func logCaptureToSendStageIfDue() {
        let count = captureToSendCollector.retainedSampleCount
        guard count > 0, count % Self.stageLogSampleInterval == 0,
              let summary = captureToSendCollector.summary() else { return }
        let budget = LatencyBudget.v1.hostCaptureToSendNanoseconds
        let within = LatencyBudget.isWithinBudget(summary, budget: budget) ?? false
        startupLogger.notice(
            "M8 stage host-capture-to-send samples=\(summary.count, privacy: .public) p50Ns=\(summary.p50Nanoseconds, privacy: .public) p95Ns=\(summary.p95Nanoseconds, privacy: .public) budgetNs=\(budget, privacy: .public) withinBudget=\(within, privacy: .public)"
        )
    }

    /// Applies a controller decision to the live encoder. Logs only the
    /// numeric bitrate and a fixed reason code.
    private func applyBitrate(_ bitrate: UInt32?, reason: StaticString) {
        guard let bitrate, let encoder else { return }
        do {
            try encoder.updateAverageBitrate(bitrate)
            startupLogger.notice(
                "M8 bitrate bps=\(bitrate, privacy: .public) reason=\(String(describing: reason), privacy: .public)"
            )
        } catch {
            startupLogger.error(
                "M8 bitrate update failed (bps: \(bitrate, privacy: .public))"
            )
        }
    }

    private func requestKeyframe() {
        keyframeRequested = true
    }

    private func consumeKeyframeRequest() -> Bool {
        defer { keyframeRequested = false }
        return keyframeRequested
    }

    /// Local status-menu text only; never logged or sent to the Viewer.
    /// Bounded so an unusual app name cannot stretch the menu.
    private static func statusApplicationName(for window: CaptureWindow) -> String {
        let name = window.applicationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = (name?.isEmpty == false ? name : nil) ?? window.applicationIdentifier
        return display.count > 48 ? String(display.prefix(47)) + "…" : display
    }

    @MainActor
    private func bringSelectedApplicationToForeground(_ window: CaptureWindow) async -> Bool {
        await bringSelectedApplicationToForeground(
            window,
            explicitViewerSelection: true
        )
    }

    @MainActor
    private func bringSelectedApplicationToForeground(
        _ window: CaptureWindow,
        explicitViewerSelection: Bool
    ) async -> Bool {
        guard let application = NSRunningApplication(processIdentifier: window.processIdentifier),
              HostRuntimeForegroundActivationPolicy.permits(
                  explicitViewerSelection: explicitViewerSelection,
                  targetApplicationAvailable: true,
                  targetIsRegularApplication: application.activationPolicy == .regular
              ) else {
            startupLogger.error("Host foreground request skipped: selected app is not an available regular app")
            return false
        }

        let selection = HostInputWindowSelection(
            windowIdentifier: window.identifier,
            processIdentifier: window.processIdentifier,
            applicationIdentifier: window.applicationIdentifier,
            generation: 0,
            bounds: InputWindowBounds(
                originX: window.bounds.x,
                originY: window.bounds.y,
                width: window.bounds.width,
                height: window.bounds.height
            )
        )
        if CoreGraphicsAccessibilityWindowFocus.isSelectedWindowForeground(selection) {
            return true
        }

        let cooperativeAPIAvailable: Bool
        if #available(macOS 14.0, *) {
            cooperativeAPIAvailable = true
        } else {
            cooperativeAPIAvailable = false
        }
        let steps = HostForegroundActivationPlan.steps(
            cooperativeAPIAvailable: cooperativeAPIAvailable,
            accessibilityTrusted: AXIsProcessTrusted(),
            selectedProcessIsOnlyRunningInstance: Self.isOnlyRunningInstance(application)
        )
        for step in steps {
            let requested: Bool
            switch step {
            case .cooperativeYield:
                requested = await requestCooperativeActivation(of: application)
            case .accessibilityFrontmost:
                requested = CoreGraphicsAccessibilityWindowFocus
                    .activateSelectedApplicationIfAccessible(selection)
            case .launchServicesActivation:
                requested = await requestLaunchServicesActivation(of: application)
            }
            guard requested else {
                startupLogger.error(
                    "Host foreground request step was not accepted (step: \(step.rawValue, privacy: .public))"
                )
                continue
            }
            if await waitForSelectedWindowForeground(selection, title: window.title) {
                startupLogger.notice(
                    "Host brought the selected app forward (step: \(step.rawValue, privacy: .public))"
                )
                return true
            }
            startupLogger.error(
                "Host foreground request step did not make the selected window foreground (step: \(step.rawValue, privacy: .public))"
            )
        }
        startupLogger.error(
            "Host could not bring the selected app forward (steps tried: \(steps.count, privacy: .public))"
        )
        return false
    }

    /// The macOS 14 cooperative path: the Host must be frontmost before it can
    /// yield activation. A background menu-bar Host is often refused, which is
    /// why later steps exist.
    @MainActor
    private func requestCooperativeActivation(of application: NSRunningApplication) async -> Bool {
        guard #available(macOS 14.0, *) else { return false }
        let hostApplication = NSRunningApplication.current
        NSApplication.shared.activate()
        guard await waitForHostToBecomeFrontmost(
            processIdentifier: hostApplication.processIdentifier
        ),
        HostRuntimeCooperativeActivationPolicy.permitsYield(
            cooperativeAPIAvailable: true,
            hostIsFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier ==
                hostApplication.processIdentifier
        ) else {
            return false
        }
        NSApplication.shared.yieldActivation(to: application)
        return application.activate(from: hostApplication, options: [])
    }

    /// Asks LaunchServices to activate the already-running selected app. It is
    /// used only when that bundle has exactly one running instance, so it can
    /// never launch or activate a different copy of the app.
    @MainActor
    private func requestLaunchServicesActivation(of application: NSRunningApplication) async -> Bool {
        guard let bundleURL = application.bundleURL,
              Self.isOnlyRunningInstance(application) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.createsNewApplicationInstance = false
        let expectedProcessIdentifier = application.processIdentifier
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { opened, error in
                continuation.resume(
                    returning: error == nil && opened?.processIdentifier == expectedProcessIdentifier
                )
            }
        }
    }

    @MainActor
    private static func isOnlyRunningInstance(_ application: NSRunningApplication) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        return instances.count == 1 && instances.first?.processIdentifier == application.processIdentifier
    }

    /// Polls for the exact selected window to become foreground after one
    /// activation request. App activation may complete asynchronously; at most
    /// two bounded AXRaise attempts target the exact window. Activation alone
    /// is never treated as proof of focus.
    @MainActor
    private func waitForSelectedWindowForeground(
        _ selection: HostInputWindowSelection,
        title: String?
    ) async -> Bool {
        for attempt in 0 ..< 20 {
            if CoreGraphicsAccessibilityWindowFocus.isSelectedWindowForeground(selection) {
                return true
            }
            if attempt == 2 || attempt == 8 {
                _ = await Task.detached(priority: .userInitiated) {
                    CoreGraphicsAccessibilityWindowFocus.raiseSelectedWindowIfAccessible(
                        selection,
                        title: title
                    )
                }.value
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
        }
        return CoreGraphicsAccessibilityWindowFocus.isSelectedWindowForeground(selection)
    }

    @MainActor
    private func waitForHostToBecomeFrontmost(processIdentifier: pid_t) async -> Bool {
        for _ in 0 ..< 20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier {
                return true
            }
            if Task.isCancelled { return false }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
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
        stopEncodedFrameRelay()
        encoder?.reset()
        encoder = nil
        videoConfigSentGeneration = nil
        videoConfigSentAuthorizationGeneration = nil
        keyframeRequested = false
        captureToSendCollector.reset()
        bitrateController = nil
#if DEBUG
        M10HostVideoDiagnostics.shared.flushPendingWindow()
#endif
    }

    private func stopVideoPipeline() async {
        captureTask?.cancel()
        await captureSession.stop()
        if let captureTask {
            await captureTask.value
        }
        captureTask = nil
        stopEncodedFrameRelay()
        encoder?.reset()
        encoder = nil
        videoConfigSentGeneration = nil
        videoConfigSentAuthorizationGeneration = nil
        keyframeRequested = false
        captureToSendCollector.reset()
        bitrateController = nil
#if DEBUG
        M10HostVideoDiagnostics.shared.flushPendingWindow()
#endif
    }

    /// Ends the ordered send path. The send task is cancelled rather than
    /// awaited because a send failure inside it may itself stop the pipeline.
    private func stopEncodedFrameRelay() {
        encodedFrameRelay?.finish()
        encodedFrameRelay = nil
        encodedSendTask?.cancel()
        encodedSendTask = nil
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

    private func discoverWindowsForRuntime() async throws -> [CaptureWindow] {
#if DEBUG
        let permission = await captureSession.permissionState()
        let diagnosticPermission: M10HostScreenRecordingPermission =
            permission == .authorized ? .authorized : .denied
        recordDebugScreenRecordingPermission(permission)
        guard permission == .authorized else {
            recordDebugWindowCatalog(
                permission: .denied,
                outcome: .permissionDenied,
                counts: ScreenRecordingWindowDiscoveryCounts(
                    candidates: 0,
                    eligible: 0,
                    offScreen: 0,
                    nonBaseLayer: 0,
                    missingApplication: 0,
                    helperApplication: 0,
                    invalidWindow: 0
                )
            )
            throw CaptureCoreError.permissionDenied
        }

        do {
            let result = try await windowProvider.discoverWindowsWithDiagnostics()
            let outcome: M10HostDiscoveryOutcome
            if result.counts.eligible > 0 {
                outcome = .eligibleWindows
            } else if result.counts.candidates == 0 {
                outcome = .noCandidates
            } else {
                outcome = .allCandidatesFiltered
            }
            recordDebugWindowCatalog(
                permission: diagnosticPermission,
                outcome: outcome,
                counts: result.counts
            )
            return result.windows
        } catch {
            let latestPermission = await captureSession.permissionState()
            let permissionWasDenied = latestPermission != .authorized
            recordDebugScreenRecordingPermission(latestPermission)
            recordDebugWindowCatalog(
                permission: permissionWasDenied ? .denied : diagnosticPermission,
                outcome: permissionWasDenied ? .permissionDenied : .providerError,
                counts: ScreenRecordingWindowDiscoveryCounts(
                    candidates: 0,
                    eligible: 0,
                    offScreen: 0,
                    nonBaseLayer: 0,
                    missingApplication: 0,
                    helperApplication: 0,
                    invalidWindow: 0
                )
            )
            throw error
        }
#else
        return try await captureSession.discoverWindows()
#endif
    }

    private func recordDebugSessionState(_ snapshot: SessionSnapshot) {
#if DEBUG
        let state: M10HostSessionState
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
        let value = M10HostSessionDiagnosticSnapshot(
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
        guard lastDebugSessionState != value else { return }
        lastDebugSessionState = value
        M10HostDiagnosticFileLog.shared.record(
            .sessionState(
                state: value.state,
                authorized: value.authorized,
                windowAuthorized: value.windowAuthorized,
                videoCapability: value.videoCapability,
                mouseCapability: value.mouseCapability,
                keyboardCapability: value.keyboardCapability,
                windowSelectionCapability: value.windowSelectionCapability,
                clipboardCapability: value.clipboardCapability,
                backgroundControlCapability: value.backgroundControlCapability
            )
        )
#endif
    }

    private func recordDebugInputReadiness(_ status: HostInputStatus) {
#if DEBUG
        let state: M10HostInputReadiness
        switch status {
        case .ready: state = .ready
        case .inputStateCleanupPending: state = .cleanupPending
        case .sessionUnauthorized: state = .sessionUnauthorized
        case .selectionUnavailable: state = .selectionUnavailable
        case .capabilityUnavailable: state = .capabilityUnavailable
        case .permissionUnavailable: state = .permissionUnavailable
        case .focusUnavailable: state = .focusUnavailable
        }
        guard lastDebugInputReadiness != state else { return }
        lastDebugInputReadiness = state
        M10HostDiagnosticFileLog.shared.record(.inputReadiness(state))
#endif
    }

    private func recordDebugScreenRecordingPermission(_ permission: CapturePermissionState) {
#if DEBUG
        let state: M10HostScreenRecordingPermission =
            permission == .authorized ? .authorized : .denied
        guard lastDebugScreenRecordingPermission != state else { return }
        lastDebugScreenRecordingPermission = state
        M10HostDiagnosticFileLog.shared.record(.screenRecordingPermission(state))
#endif
    }

#if DEBUG
    private func recordDebugSessionFailure(_ error: SessionError?) {
        guard let error else { return }
        M10HostDiagnosticFileLog.shared.record(.sessionFailure(error.failureCategory))
        if let terminationClass = error.transportTerminationClass {
            M10HostDiagnosticFileLog.shared.record(.transportTermination(terminationClass))
        }
    }

    private func recordDebugWindowCatalog(
        permission: M10HostScreenRecordingPermission,
        outcome: M10HostDiscoveryOutcome,
        counts: ScreenRecordingWindowDiscoveryCounts
    ) {
        let value = M10HostWindowCatalogDiagnosticSnapshot(
            permission: permission,
            outcome: outcome,
            candidates: counts.candidates,
            eligible: counts.eligible,
            offScreen: counts.offScreen,
            nonBaseLayer: counts.nonBaseLayer,
            missingApplication: counts.missingApplication,
            helperApplication: counts.helperApplication,
            invalidWindow: counts.invalidWindow
        )
        guard lastDebugWindowCatalog != value else { return }
        lastDebugWindowCatalog = value
        M10HostDiagnosticFileLog.shared.record(
            .windowCatalog(
                permission: value.permission,
                outcome: value.outcome,
                candidates: value.candidates,
                eligible: value.eligible,
                offScreen: value.offScreen,
                nonBaseLayer: value.nonBaseLayer,
                missingApplication: value.missingApplication,
                helperApplication: value.helperApplication,
                invalidWindow: value.invalidWindow
            )
        )
    }
#endif

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
        guard HostRuntimeWindowCatalogPolicy.shouldPublish(
            windows,
            preserving: selectedWindow
        ) else {
            return false
        }
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
#if DEBUG
        M10HostDiagnosticFileLog.shared.record(.windowCatalogPublished(eligibleCount: UInt64(windows.count)))
#endif
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
    private var processTargetingAuthorized = false
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
                keyboardInputEnabled: snapshot.authorizedCapabilities.contains(.keyboardInput),
                processTargetingAuthorized: processTargetingAuthorized
            )
        }
    }

    func setProcessTargetingAuthorized(_ enabled: Bool) {
        lock.withLock {
            processTargetingAuthorized = enabled
            sessionStateValue = HostInputSessionState(
                authorized: sessionStateValue.authorized,
                authorizedWindowGeneration: sessionStateValue.authorizedWindowGeneration,
                mouseInputEnabled: sessionStateValue.mouseInputEnabled,
                keyboardInputEnabled: sessionStateValue.keyboardInputEnabled,
                processTargetingAuthorized: enabled
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
