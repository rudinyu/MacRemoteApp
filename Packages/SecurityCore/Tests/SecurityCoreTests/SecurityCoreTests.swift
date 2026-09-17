import SecurityCore
import XCTest

final class SecurityCoreTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(SecurityCoreModule.name, "SecurityCore")
    }
}
