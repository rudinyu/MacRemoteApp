import CodecCore
import InputCore
import RemoteProtocol
import SecurityCore
import TransportCore

@MainActor
@main
struct ViewerApp {
    static func main() {
        if CommandLine.arguments.contains("--m5-input-surface") {
            ViewerInputDemo().run()
            return
        }

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
