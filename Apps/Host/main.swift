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
        onNonInputMessage: @escaping @Sendable (MessagePayload) async -> Void
    ) async -> HostInputSessionRuntime {
        let runtime = HostInputSessionRuntime(
            session: session,
            contextProvider: contextProvider,
            injectionAdapter: injectionAdapter,
            onNonInputMessage: onNonInputMessage
        )
        await runtime.start()
        return runtime
    }

    static func main() async {
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

        let modules = [
            RemoteProtocolModule.name,
            CaptureCoreModule.name,
            CodecCoreModule.name,
            TransportCoreModule.name,
            InputCoreModule.name,
            SecurityCoreModule.name
        ]

        print("MacRemoteApp Host M6 input foundation: \(modules.joined(separator: ", "))")
    }

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
}
