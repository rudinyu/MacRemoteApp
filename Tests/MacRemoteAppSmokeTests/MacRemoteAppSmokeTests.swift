import CaptureCore
import CodecCore
import InputCore
import RemoteProtocol
import SecurityCore
import XCTest
import TransportCore

final class MacRemoteAppSmokeTests: XCTestCase {
    func testAllSharedModulesRemainImportable() {
        XCTAssertEqual(RemoteProtocolModule.name, "RemoteProtocol")
        XCTAssertEqual(CaptureCoreModule.name, "CaptureCore")
        XCTAssertEqual(CodecCoreModule.name, "CodecCore")
        XCTAssertEqual(TransportCoreModule.name, "TransportCore")
        XCTAssertEqual(InputCoreModule.name, "InputCore")
        XCTAssertEqual(SecurityCoreModule.name, "SecurityCore")
    }
}
