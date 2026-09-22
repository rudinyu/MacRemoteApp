import AppKit
import Darwin
import CaptureCore
import CodecCore
import InputCore
import os
import RemoteProtocol
import SecurityCore
import TransportCore

let macRemoteAppStartupLogger = Logger(
    subsystem: "com.rudinyu.MacRemoteApp",
    category: "startup"
)

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
        onSessionLifecycleReset: @escaping @Sendable () async -> Void = {}
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

    static func main() async {
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
            await MainActor.run {
                let application = NSApplication.shared
                application.setActivationPolicy(.accessory)
                let delegate = HostApplicationDelegate(runtime: runtime)
                application.delegate = delegate
                // NSApplication.delegate is weak. Keep the concrete delegate
                // alive for the whole event loop so launch/termination
                // callbacks cannot be lost before application.run() returns.
                withExtendedLifetime(delegate) {
                    application.run()
                }
            }
        } catch {
            await MainActor.run {
                presentHostStartupFailure(error)
            }
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

@MainActor
private final class HostApplicationDelegate: NSObject, NSApplicationDelegate {
    private let runtime: HostRuntime
    private var runtimeTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?
    private var terminationRequested = false

    init(runtime: HostRuntime) {
        self.runtime = runtime
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        installStatusItem()
        // Host is an accessory app, but permission consent belongs to the
        // signed application bundle rather than a shell or its terminal. Make
        // the bundle active before the runtime reaches the TCC APIs so macOS
        // can present Local Network and Screen Recording consent normally.
        NSApplication.shared.activate(ignoringOtherApps: true)
        runtimeTask = Task { [runtime] in
            do {
                try await runtime.run()
            } catch is CancellationError {
                await runtime.stop()
                NSApplication.shared.stop(nil)
            } catch {
                presentHostStartupFailure(error)
                macRemoteAppStartupLogger.error(
                    "MacRemoteApp Host startup failed (code: \(hostStartupErrorCode(error), privacy: .public))"
                )
                fputs("MacRemoteApp Host failed: \(error)\n", stderr)
                await runtime.stop()
                NSApplication.shared.stop(nil)
                exit(EXIT_FAILURE)
            }
            NSApplication.shared.stop(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        guard !terminationRequested else { return .terminateLater }
        guard let runtimeTask else { return .terminateNow }
        terminationRequested = true
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
        if let iconURL = Bundle.main.url(forResource: "MacRemoteAppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
        }

        let menu = NSMenu()
        let status = NSMenuItem(title: "Host is running", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let stopItem = NSMenuItem(
            title: "Stop session and quit",
            action: #selector(stopSessionAndQuit),
            keyEquivalent: "q"
        )
        stopItem.target = self
        menu.addItem(stopItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func stopSessionAndQuit() {
        NSApplication.shared.terminate(nil)
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
