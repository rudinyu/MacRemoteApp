import AppKit
import Darwin
import CaptureCore
import CodecCore
import InputCore
import RemoteProtocol
import SecurityCore
import TransportCore

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
    private var terminationRequested = false

    init(runtime: HostRuntime) {
        self.runtime = runtime
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        runtimeTask = Task { [runtime] in
            do {
                try await runtime.run()
            } catch {
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
}
