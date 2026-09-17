import TransportCore
import XCTest

final class TransportCoreTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(TransportCoreModule.name, "TransportCore")
    }
}
