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
            try await runtime.run()
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
