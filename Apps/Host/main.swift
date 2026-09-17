import CaptureCore
import CodecCore
import InputCore
import RemoteProtocol
import SecurityCore
import TransportCore

@main
struct HostApp {
    static func main() {
        let modules = [
            RemoteProtocolModule.name,
            CaptureCoreModule.name,
            CodecCoreModule.name,
            TransportCoreModule.name,
            InputCoreModule.name,
            SecurityCoreModule.name
        ]

        print("MacRemoteApp Host M0 foundation: \(modules.joined(separator: ", "))")
    }
}
