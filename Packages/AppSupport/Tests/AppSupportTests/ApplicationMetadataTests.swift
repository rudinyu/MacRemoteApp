import XCTest
@testable import AppSupport

final class ApplicationMetadataTests: XCTestCase {
    func testMacRemoteAppVersionAndBuildDisplay() {
        let metadata = ApplicationMetadata(version: "0.2", build: "1001")

        XCTAssertEqual(metadata.displayVersion, "0.2.1001")
        XCTAssertEqual(metadata.displayVersionDetails, "0.2.1001 (Build 1001)")
    }

    func testConventionalShortVersionIsNotExpandedToFourComponents() {
        let metadata = ApplicationMetadata(version: "0.2.1", build: "1002")

        XCTAssertEqual(metadata.displayVersion, "0.2.1")
        XCTAssertEqual(metadata.displayVersionDetails, "0.2.1 (Build 1002)")
    }

    func testEmptyValuesUseDevelopmentFallbacks() {
        let metadata = ApplicationMetadata(version: "  ", build: "")

        XCTAssertEqual(metadata.version, "Development")
        XCTAssertEqual(metadata.build, "unbundled")
    }
}
