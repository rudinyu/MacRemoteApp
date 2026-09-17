import CaptureCore
import XCTest

final class CaptureCoreTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(CaptureCoreModule.name, "CaptureCore")
    }
}
