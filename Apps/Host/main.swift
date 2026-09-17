import AppKit
import CaptureCore
import CodecCore
import InputCore
import RemoteProtocol
import SecurityCore
import TransportCore

@main
struct HostApp {
    static func main() async {
        if CommandLine.arguments.contains("--m3-list-windows") {
            await MainActor.run {
                _ = NSApplication.shared
                NSApplication.shared.setActivationPolicy(.prohibited)
            }
            await listWindows()
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

        print("MacRemoteApp Host M3 foundation: \(modules.joined(separator: ", "))")
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
