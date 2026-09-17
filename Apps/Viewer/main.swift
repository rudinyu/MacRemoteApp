import CodecCore
import InputCore
import RemoteProtocol
import SecurityCore
import TransportCore

@main
struct ViewerApp {
    static func main() {
        let modules = [
            RemoteProtocolModule.name,
            CodecCoreModule.name,
            TransportCoreModule.name,
            InputCoreModule.name,
            SecurityCoreModule.name
        ]

        print("MacRemoteApp Viewer M0 foundation: \(modules.joined(separator: ", "))")
    }
}
