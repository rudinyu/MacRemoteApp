import InputCore
import XCTest

final class InputCoreTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(InputCoreModule.name, "InputCore")
    }
}
