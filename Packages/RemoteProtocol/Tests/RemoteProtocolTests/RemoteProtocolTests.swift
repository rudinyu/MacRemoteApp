import RemoteProtocol
import XCTest

final class RemoteProtocolTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(RemoteProtocolModule.name, "RemoteProtocol")
    }
}
