import Darwin
import CodecCore
import InputCore
import RemoteProtocol
import SecurityCore
import TransportCore

@MainActor
@main
struct ViewerApp {
    static func startSession(
        _ session: SessionCoordinator,
        onMessage: @escaping @MainActor (MessagePayload) async -> Void = { _ in }
    ) -> ViewerSessionMessageLoop {
        let runtime = ViewerSessionMessageLoop(session: session, onMessage: onMessage)
        runtime.start()
        return runtime
    }

    static func main() async {
#if DEBUG
        if CommandLine.arguments.contains("--m5-input-surface") {
            let demo = ViewerInputDemo()
            demo.run()
            return
        }

        if CommandLine.arguments.contains("--m2-physical-viewer") {
            do {
                try await M2PhysicalViewerSmoke.run()
            } catch {
                fputs("M2 physical viewer smoke failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }

        if CommandLine.arguments.contains("--m7-physical-viewer") {
            do {
                try await M2PhysicalViewerSmoke.run(clipboardOptIn: true)
            } catch {
                fputs("M7 physical viewer clipboard smoke failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
#endif

        let modules = [
            RemoteProtocolModule.name,
            CodecCoreModule.name,
            TransportCoreModule.name,
            InputCoreModule.name,
            SecurityCoreModule.name
        ]

        print("MacRemoteApp Viewer M5 foundation: \(modules.joined(separator: ", "))")
    }
}
