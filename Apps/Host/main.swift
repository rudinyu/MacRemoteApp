import AppKit
import AppSupport
import Darwin
import CaptureCore
import CodecCore
import Foundation
import InputCore
import os
import RemoteProtocol
import SecurityCore
import TransportCore

let macRemoteAppStartupLogger = Logger(
    subsystem: "com.rudinyu.MacRemoteApp",
    category: "startup"
)

private let hostApplicationMetadata = ApplicationMetadata(bundle: .main)

@main
struct HostApp {
    /// Host session composition entry point. The concrete listener/window
    /// lifecycle calls this once per authenticated SessionCoordinator so the
    /// input stream always has one consumer tied to that session.
    static func startInputSession(
        _ session: SessionCoordinator,
        contextProvider: any HostInputContextProvider,
        injectionAdapter: any HostInputInjectionAdapter,
        onNonInputMessage: @escaping @Sendable (MessagePayload) async -> Void,
        onSessionLifecycleReset: @escaping @Sendable () async -> Void = {},
        onInputStatusChange: @escaping @Sendable (HostInputStatus) async -> Void = { _ in }
    ) async -> HostInputSessionRuntime {
        let clipboardController = await MainActor.run {
            HostClipboardSessionController(session: session)
        }
        let runtime = HostInputSessionRuntime(
            session: session,
            contextProvider: contextProvider,
            injectionAdapter: injectionAdapter,
            onNonInputMessage: { message in
                try? await clipboardController.handle(message)
                await onNonInputMessage(message)
            },
            onSessionLifecycleChange: { active in
                if active {
                    await clipboardController.startPolling()
                } else {
                    await clipboardController.stopPolling()
                }
            },
            onSessionLifecycleReset: {
                let snapshot = await session.snapshot()
                await clipboardController.resetForSessionLifecycleIfStale(snapshot)
                await onSessionLifecycleReset()
            },
            onInputStatusChange: onInputStatusChange,
            setClipboardEnabled: { enabled in
                try await clipboardController.setEnabled(enabled)
            },
            clipboardStatus: {
                await clipboardController.status
            }
        )
        await runtime.start()
        return runtime
    }

    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--remove-all-data") {
            do {
                try await removeAllLocalData()
            } catch {
                fputs("MacRemoteApp Host data cleanup failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }

#if DEBUG
        M10MainActorStallMonitor.shared.start(role: .host)
#endif

#if DEBUG
        if CommandLine.arguments.contains("--m3-list-windows") {
            await MainActor.run {
                _ = NSApplication.shared
                NSApplication.shared.setActivationPolicy(.prohibited)
            }
            await listWindows()
            return
        }

        if CommandLine.arguments.contains("--m2-physical-host") {
            do {
                try await M2PhysicalHostSmoke.run()
            } catch {
                fputs("M2 physical host smoke failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }

        if CommandLine.arguments.contains("--m7-physical-host") {
            do {
                try await M2PhysicalHostSmoke.run(clipboardOptIn: true)
            } catch {
                fputs("M7 physical host clipboard smoke failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
#endif

        do {
            let runtime = try HostRuntime(configuration: .load())
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let delegate = HostApplicationDelegate(runtime: runtime)
            application.delegate = delegate
            // NSApplication.delegate is weak. Keep the concrete delegate
            // alive for the whole event loop so launch/termination
            // callbacks cannot be lost before application.run() returns.
            // The AppKit loop is the application's MainActor lifecycle; do
            // not hide this synchronous loop inside MainActor.run from an
            // async entry point.
            withExtendedLifetime(delegate) {
                application.run()
            }
        } catch {
            presentHostStartupFailure(error)
            macRemoteAppStartupLogger.error(
                "MacRemoteApp Host startup failed (code: \(hostStartupErrorCode(error), privacy: .public))"
            )
            fputs("MacRemoteApp Host failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

#if DEBUG
    private static func listWindows() async {
        let provider = ScreenRecordingWindowProvider()
        let permission = await provider.permissionState()
        print("Screen Recording permission: \(permission.rawValue)")
        guard permission == .authorized else {
            print("Grant Screen Recording permission, then rerun --m3-list-windows.")
            return
        }

        do {
            let windows = try await provider.discoverWindows()
            print("Eligible windows: \(windows.count)")
            for window in windows {
                print(
                    "window=\(window.identifier) app=\(window.applicationIdentifier) " +
                        "size=\(Int(window.bounds.width))x\(Int(window.bounds.height))"
                )
            }
        } catch {
            print("Window discovery failed: \(error)")
        }
    }
#endif
}

private func removeAllLocalData() async throws {
    // Clean up these legacy control-grant records before removing pairing
    // trust. They have no current authorization role.
    _ = try await KeychainControlGrantStore().removeAll()
    try await KeychainTrustStore(
        service: HostRuntime.Configuration.defaultTrustStoreService
    ).removeAll()
    try await KeychainIdentityProvider(
        label: HostRuntime.Configuration.defaultIdentityLabel
    ).removeGeneratedIdentity()
    UserDefaults.standard.removePersistentDomain(forName: "com.rudinyu.MacRemoteApp.Host")
    UserDefaults.standard.synchronize()
}

@MainActor
private final class HostApplicationDelegate: NSObject, NSApplicationDelegate {
    private let runtime: HostRuntime
    private var runtimeTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var controlStatusTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var renameHostMenuItem: NSMenuItem?
    private var pairingCodeMenuItem: NSMenuItem?
    private var forgetPairingsMenuItem: NSMenuItem?
    private var controlStatusMenuItem: NSMenuItem?
    private var controlToggleMenuItem: NSMenuItem?
    private var controlRevokeMenuItem: NSMenuItem?
    private var retryItem: NSMenuItem?
    private var applicationMenu: ApplicationMenu?
    private var settingsWindow: SettingsWindowController?
    private var latestStatus: HostRuntimeStatus = .starting
    private var latestControlStatus: HostControlStatus = .unavailable
    private var currentHostName = HostPreferences.load()
    private var terminationRequested = false

    init(runtime: HostRuntime) {
        self.runtime = runtime
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        macRemoteAppStartupLogger.info("Host application did finish launching")
        // NSApplication.run() is a synchronous AppKit run loop entered from
        // main(). A normal Task created here inherits MainActor isolation and
        // can remain queued behind that run loop, preventing HostRuntime from
        // ever reaching its permission startup stages. Start the resident
        // runtime task before any synchronous accessory-app UI setup, keep it
        // off MainActor, and only hop back for UI and termination actions.
        // This ordering also leaves a task-start marker if an AppKit status
        // item or activation call stalls during launch.
        runtimeTask = Task.detached(priority: .userInitiated) { [runtime] in
            macRemoteAppStartupLogger.info("Host runtime task starting")
            do {
                try await runtime.run()
            } catch is CancellationError {
                await runtime.stop()
                await MainActor.run {
                    NSApplication.shared.stop(nil)
                }
            } catch {
                await MainActor.run {
                    presentHostStartupFailure(error)
                }
                macRemoteAppStartupLogger.error(
                    "MacRemoteApp Host startup failed (code: \(hostStartupErrorCode(error), privacy: .public))"
                )
                fputs("MacRemoteApp Host failed: \(error)\n", stderr)
                await runtime.stop()
                await MainActor.run {
                    NSApplication.shared.stop(nil)
                }
                exit(EXIT_FAILURE)
            }
            await MainActor.run {
                NSApplication.shared.stop(nil)
            }
        }
        installStatusItem()
        let menu = ApplicationMenu(
            applicationName: "MacRemoteApp Host",
            metadata: hostApplicationMetadata,
            onSettings: { [weak self] in self?.showSettings() },
            onShowWindow: { [weak self] in self?.showSettings() },
            onActivate: { NSApplication.shared.setActivationPolicy(.regular) },
            onAboutClose: { [weak self] in self?.restoreAccessoryWhenWindowsClose() }
        )
        applicationMenu = menu
        menu.install()
        // Host is an accessory app, but permission consent belongs to the
        // signed application bundle rather than a shell or its terminal. Make
        // the bundle active before the runtime reaches the TCC APIs so macOS
        // can present Local Network and Screen Recording consent normally.
        NSApplication.shared.activate(ignoringOtherApps: true)
        statusTask = Task { @MainActor [weak self, runtime] in
            var iterator = runtime.statusUpdates.makeAsyncIterator()
            while !Task.isCancelled, let status = await iterator.next() {
                self?.apply(status: status)
            }
        }
        controlStatusTask = Task { @MainActor [weak self, runtime] in
            var iterator = runtime.controlStatusUpdates.makeAsyncIterator()
            while !Task.isCancelled, let status = await iterator.next() {
                self?.apply(controlStatus: status)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        guard !terminationRequested else { return .terminateLater }
        guard let runtimeTask else { return .terminateNow }
        terminationRequested = true
        statusTask?.cancel()
        controlStatusTask?.cancel()
        runtimeTask.cancel()
        Task { @MainActor [weak self] in
            await runtimeTask.value
            guard let self else { return }
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
            self.runtimeTask = nil
        }
        return .terminateLater
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "MacRemoteApp Host"
        item.button?.toolTip = "MacRemoteApp Host — listening for a paired Viewer"
        item.button?.image = HostStatusItemIcon.makeTemplateImage()
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.autoenablesItems = false
        let status = NSMenuItem(title: "Host: Starting", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status
        let version = NSMenuItem(
            title: "Version \(hostApplicationMetadata.displayVersionDetails)",
            action: nil,
            keyEquivalent: ""
        )
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "About MacRemoteApp Host", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let renameItem = NSMenuItem(
            title: "Rename Host…",
            action: #selector(renameHost),
            keyEquivalent: ""
        )
        renameItem.target = self
        menu.addItem(renameItem)
        renameHostMenuItem = renameItem
        let pairingCode = NSMenuItem(
            title: "Pairing code: —",
            action: nil,
            keyEquivalent: ""
        )
        pairingCode.isEnabled = false
        pairingCode.isHidden = true
        menu.addItem(pairingCode)
        pairingCodeMenuItem = pairingCode
        let forgetPairings = NSMenuItem(
            title: "Forget saved pairings…",
            action: #selector(forgetSavedPairings),
            keyEquivalent: ""
        )
        forgetPairings.target = self
        menu.addItem(forgetPairings)
        forgetPairingsMenuItem = forgetPairings
        let controlStatus = NSMenuItem(title: "Control: Unavailable", action: nil, keyEquivalent: "")
        controlStatus.isEnabled = false
        menu.addItem(controlStatus)
        controlStatusMenuItem = controlStatus
        let controlToggle = NSMenuItem(
            title: "Viewer Control Unavailable",
            action: #selector(toggleViewerControl),
            keyEquivalent: ""
        )
        controlToggle.target = self
        controlToggle.isEnabled = false
        menu.addItem(controlToggle)
        controlToggleMenuItem = controlToggle
        let controlRevoke = NSMenuItem(
            title: "Unpair Viewer…",
            action: #selector(revokeViewerControl),
            keyEquivalent: ""
        )
        controlRevoke.target = self
        controlRevoke.isEnabled = false
        menu.addItem(controlRevoke)
        controlRevokeMenuItem = controlRevoke
        let retry = NSMenuItem(
            title: "Retry setup",
            action: #selector(retrySetup),
            keyEquivalent: "r"
        )
        retry.target = self
        retry.isEnabled = false
        menu.addItem(retry)
        retryItem = retry
        menu.addItem(.separator())

#if DEBUG
        let debugLog = NSMenuItem(
            title: "Open Debug Log…",
            action: #selector(openDebugLog),
            keyEquivalent: ""
        )
        debugLog.target = self
        menu.addItem(debugLog)
        menu.addItem(.separator())
#endif

        let stopItem = NSMenuItem(
            title: "Quit MacRemoteApp Host",
            action: #selector(stopSessionAndQuit),
            keyEquivalent: "q"
        )
        stopItem.target = self
        menu.addItem(stopItem)
        item.menu = menu
        statusItem = item
    }

    private func apply(status: HostRuntimeStatus) {
        latestStatus = status
        statusMenuItem?.title = "Host: \(status.description)"
        if case let .pairing(code) = status {
            pairingCodeMenuItem?.title = "Pairing code: \(code)"
            pairingCodeMenuItem?.isHidden = false
        } else {
            pairingCodeMenuItem?.isHidden = true
        }
        let canRetry: Bool
        switch status {
        case .needsScreenRecording, .needsLocalNetwork, .listenerFailed, .failed:
            canRetry = true
        case .starting, .connected, .sharing, .recovering, .pairing, .listening, .stopped:
            canRetry = false
        }
        retryItem?.isEnabled = canRetry
        // Remote viewing/control is visible in the menu bar without opening
        // the menu, alongside macOS's own screen-recording indicator.
        if case .sharing = status {
            statusItem?.button?.contentTintColor = .systemOrange
        } else if case .recovering = status {
            statusItem?.button?.contentTintColor = .systemOrange
        } else {
            statusItem?.button?.contentTintColor = nil
        }
        statusItem?.button?.toolTip = "MacRemoteApp Host — \(status.description)"
        refreshSettings()
    }

    private func apply(controlStatus: HostControlStatus) {
        latestControlStatus = controlStatus
        controlStatusMenuItem?.title = "Control: \(controlStatus.description)"
        switch controlStatus {
        case .active:
            controlToggleMenuItem?.title = "Pause Viewer Control"
            controlToggleMenuItem?.isEnabled = true
            controlRevokeMenuItem?.isEnabled = true
        case .paused:
            controlToggleMenuItem?.title = "Resume Viewer Control"
            controlToggleMenuItem?.isEnabled = true
            controlRevokeMenuItem?.isEnabled = true
        case .requiresConsent:
            controlToggleMenuItem?.title = "Pair Viewer to Enable Control"
            controlToggleMenuItem?.isEnabled = false
            controlRevokeMenuItem?.isEnabled = false
        case .persistenceFailure:
            controlToggleMenuItem?.title = "Viewer Unpair Failed"
            controlToggleMenuItem?.isEnabled = false
            controlRevokeMenuItem?.title = "Retry Viewer Unpair…"
            controlRevokeMenuItem?.isEnabled = true
        case .negotiating:
            controlToggleMenuItem?.title = "Checking Paired Viewer…"
            controlToggleMenuItem?.isEnabled = false
            controlRevokeMenuItem?.isEnabled = false
        case .unavailable, .unsupported, .revoked:
            switch controlStatus {
            case .unavailable:
                controlToggleMenuItem?.title = "Viewer Control Unavailable"
            case .unsupported:
                controlToggleMenuItem?.title = "Viewer Does Not Support P6"
            case .revoked:
                controlToggleMenuItem?.title = "Viewer Pairing Revoked"
            default:
                break
            }
            controlToggleMenuItem?.isEnabled = false
            controlRevokeMenuItem?.title = "Unpair Viewer…"
            controlRevokeMenuItem?.isEnabled = false
        }
        refreshSettings()
    }

    @objc private func toggleViewerControl() {
        Task { await runtime.toggleViewerControl() }
    }

    @objc private func revokeViewerControl() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unpair this Viewer?"
        alert.informativeText = "This removes the Viewer’s saved pairing and ends its active session. The Viewer must be paired again before reconnecting."
        alert.addButton(withTitle: "Unpair Viewer")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await runtime.revokeViewerControl() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    @objc private func showAbout() { applicationMenu?.showAbout() }

    @objc private func showSettings() {
        // A resident Host stays accessory-only until the operator opens a
        // window. Promote it while that window is open so the standard app
        // menu and Dock window restoration are available.
        NSApplication.shared.setActivationPolicy(.regular)
        if settingsWindow == nil {
            let controller = SettingsWindowController(
                title: "Host Settings",
                subtitle: "Manage this Host and check its current macOS permissions.",
                metadata: hostApplicationMetadata,
                sections: [
                    .init("Host", fields: [
                        .init("name", "Host name"), .init("status", "Status"),
                        .init("transport", "Transport", "LAN / TLS"),
                        .init("trust", "Trust", "Viewer pairings saved in Keychain"),
                        .init("control", "Viewer control")
                    ]),
                    .init("Permissions", fields: [
                        .init("screen", "Screen Recording"),
                        .init("input", "PostEvent input"),
                        .init("accessibility", "Accessibility"),
                        .init("network", "Local discovery")
                    ])
                ]
            )
            controller.addNote("Permission checks refresh when you return to the Host. Local discovery reflects the service state; macOS manages Local Network permission.")
            controller.addAction("rename", title: "Rename Host…") { [weak self] in self?.renameHost() }
            controller.addAction("permissions", title: "Privacy & Security Settings…") {
                guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") else { return }
                NSWorkspace.shared.open(url)
            }
            controller.addAction("retry", title: "Retry setup") { [weak self] in self?.retrySetup() }
            controller.addAction("forget", title: "Forget saved pairings…") { [weak self] in self?.forgetSavedPairings() }
            controller.onClose = { [weak self] in self?.restoreAccessoryWhenWindowsClose() }
            settingsWindow = controller
        }
        refreshSettings()
        settingsWindow?.present()
    }

    private func refreshSettings() {
        guard let settingsWindow else { return }
        settingsWindow.setValue(currentHostName, for: "name")
        settingsWindow.setValue(latestStatus.description, for: "status")
        settingsWindow.setValue(latestControlStatus.description, for: "control")
        settingsWindow.setValue(CGPreflightScreenCaptureAccess() ? "Granted" : "Not granted", for: "screen")
        settingsWindow.setValue(CGPreflightPostEventAccess() ? "Granted" : "Not granted", for: "input")
        settingsWindow.setValue(AXIsProcessTrusted() ? "Granted" : "Not granted (optional)", for: "accessibility")
        let discovery: String
        switch latestStatus {
        case .listening, .pairing, .connected: discovery = "Bonjour service active"
        case .needsLocalNetwork: discovery = "Local Network access required"
        case .listenerFailed: discovery = "Bonjour service unavailable"
        case .stopped: discovery = "Stopped"
        default: discovery = "Not ready"
        }
        settingsWindow.setValue(discovery, for: "network")
        settingsWindow.setAction("retry", enabled: retryItem?.isEnabled == true)
    }

    private func restoreAccessoryWhenWindowsClose() {
        // willClose arrives before isVisible changes. Defer one run-loop turn.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.settingsWindow?.window?.isVisible != true,
                  self.settingsWindow?.window?.isMiniaturized != true,
                  self.applicationMenu?.isAboutVisible != true else { return }
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    @objc private func retrySetup() {
        Task { [runtime] in
            await runtime.requestRetry()
        }
    }

    @objc private func renameHost() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Rename this MacRemoteApp Host?"
        alert.informativeText =
            "This name is visible to Viewers and other devices that browse MacRemoteApp on the local network. It is not the Host's security identity."
        let field = NSTextField(string: HostPreferences.load())
        field.placeholderString = HostPreferences.defaultServiceName
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let name = HostPreferences.validatedServiceName(field.stringValue) else {
            showHostSettingsError(
                "Host name must contain visible characters and be at most 63 UTF-8 bytes."
            )
            return
        }

        HostPreferences.save(name)
        renameHostMenuItem?.title = "Rename Host…"
        statusItem?.button?.toolTip = "MacRemoteApp Host — \(name)"
        Task { [weak self, runtime] in
            do {
                try await runtime.updateServiceName(name)
                self?.currentHostName = name
                self?.refreshSettings()
            } catch {
                await MainActor.run {
                    self?.showHostSettingsError("The Host name could not be applied. The previous advertised name remains active.")
                }
            }
        }
    }

    @objc private func forgetSavedPairings() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Forget all saved pairings?"
        alert.informativeText =
            "This removes saved Viewer trust records from this Mac and stops the active session. The Host's own TLS identity, permissions, and Host name remain unchanged. The next connection must be paired again."
        alert.addButton(withTitle: "Forget Pairings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor [weak self, runtime] in
            do {
                let count = try await runtime.forgetAllPairings()
                self?.statusMenuItem?.title = "Host: Listening for a paired Viewer"
                self?.statusItem?.button?.toolTip =
                    count == 0
                    ? "MacRemoteApp Host — no saved pairings"
                    : "MacRemoteApp Host — saved pairings cleared"
            } catch {
                self?.showHostSettingsError("Saved pairings could not be cleared. Check Keychain access and try again.")
            }
        }
    }

    @objc private func stopSessionAndQuit() {
        NSApplication.shared.terminate(nil)
    }

#if DEBUG
    @objc private func openDebugLog() {
        let url = M10HostDiagnosticFileLog.logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
#endif

    private func showHostSettingsError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MacRemoteApp Host"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
private func presentHostStartupFailure(_ error: Error) {
    let isPermissionFailure: Bool
    let permissionSettingsURL: URL?
    let message: String
    if let runtimeError = error as? HostRuntimeError {
        switch runtimeError {
        case .permission:
            isPermissionFailure = true
            permissionSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            message = "Screen Recording permission is required. Open Privacy & Security > Screen Recording, enable MacRemoteApp Host, then relaunch the Host."
        case .localNetwork:
            isPermissionFailure = true
            permissionSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
            message = "Local Network access is required. Open Privacy & Security > Local Network, enable MacRemoteApp Host, then relaunch the Host."
        case let .listener(listenerMessage):
            isPermissionFailure = false
            permissionSettingsURL = nil
            message = listenerMessage
        case .configuration:
            isPermissionFailure = false
            permissionSettingsURL = nil
            message = "The Host configuration is invalid. Check the documented configuration and relaunch the app."
        default:
            isPermissionFailure = false
            permissionSettingsURL = nil
            message = "The Host could not start. Check the debug guide for a safe recovery path."
        }
    } else if error is SecurityCoreError {
        isPermissionFailure = false
        permissionSettingsURL = nil
        message = "The Host could not enroll its local Keychain identity. Check Keychain access and relaunch the app."
    } else {
        isPermissionFailure = false
        permissionSettingsURL = nil
        message = "The Host could not start. Check the debug guide for a safe recovery path."
    }

    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "MacRemoteApp Host could not start"
    alert.informativeText = message
    if isPermissionFailure {
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = permissionSettingsURL {
            NSWorkspace.shared.open(url)
        }
    } else {
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private func hostStartupErrorCode(_ error: Error) -> String {
    if let runtimeError = error as? HostRuntimeError {
        switch runtimeError {
        case .configuration: return "configuration"
        case .permission: return "permission"
        case .localNetwork: return "local-network"
        case .listener: return "listener"
        case .sessionEnded: return "session-ended"
        case .sessionTimedOut: return "session-timeout"
        case .pairingTimedOut: return "pairing-timeout"
        case .staleWindowGeneration: return "stale-window"
        }
    }
    if error is SecurityCoreError {
        return "security"
    }
    return "unknown"
}
