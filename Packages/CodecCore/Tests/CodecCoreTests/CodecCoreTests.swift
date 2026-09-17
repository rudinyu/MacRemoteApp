import CodecCore
import XCTest

final class CodecCoreTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(CodecCoreModule.name, "CodecCore")
    }
}
