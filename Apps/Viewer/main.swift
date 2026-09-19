import Darwin
import CodecCore
import Foundation
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

        do {
            let runtime = try ViewerRuntime(configuration: .load())
            runtime.run()
        } catch {
            fputs("MacRemoteApp Viewer failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
