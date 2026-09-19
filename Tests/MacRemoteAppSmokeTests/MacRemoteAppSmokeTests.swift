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

    func testM8ClockSyncUsesMinimumRTTAndRequiresTwentyProbes() {
        var estimator = ClockSyncEstimator()
        for index in 0 ..< 20 {
            let hostSent = UInt64(index) * 10_000_000
            let reversePath: UInt64 = index == 7 ? 550_000 : 2_500_000
            let viewerReceived = hostSent + 2_000_000 + 550_000
            let viewerSent = viewerReceived + 100_000
            let hostReceived = viewerSent - 2_000_000 + reversePath
            XCTAssertTrue(
                estimator.append(
                    ClockSyncProbe(
                        hostSentNanoseconds: hostSent,
                        viewerReceivedNanoseconds: viewerReceived,
                        viewerSentNanoseconds: viewerSent,
                        hostReceivedNanoseconds: hostReceived
                    )
                )
            )
        }

        let estimate = try! XCTUnwrap(estimator.estimate())
        XCTAssertEqual(estimate.probeCount, 20)
        XCTAssertEqual(estimate.offsetNanoseconds, 2_000_000)
        XCTAssertEqual(estimate.minimumRoundTripNanoseconds, 1_100_000)
        XCTAssertTrue(estimate.oneWayMeasurementEligible)
    }

    func testM8ClockSyncOffsetAverageDoesNotOverflowAtSignedBoundary() {
        let maximum = UInt64(Int64.max)
        let probe = ClockSyncProbe(
            hostSentNanoseconds: 0,
            viewerReceivedNanoseconds: maximum,
            viewerSentNanoseconds: maximum,
            hostReceivedNanoseconds: 0
        )

        XCTAssertEqual(probe.offsetNanoseconds, Int64.max)
        XCTAssertEqual(probe.roundTripNanoseconds, 0)
    }

    func testM8ClockSyncOffsetAverageTruncatesMixedSignsTowardZero() {
        let probe = ClockSyncProbe(
            hostSentNanoseconds: 100,
            viewerReceivedNanoseconds: 102,
            viewerSentNanoseconds: 103,
            hostReceivedNanoseconds: 104
        )

        XCTAssertEqual(probe.offsetNanoseconds, 0)
        XCTAssertEqual(probe.roundTripNanoseconds, 3)
    }

    func testM8ClockSyncSpreadAndDriftDoNotOverflowAtSignedBoundary() throws {
        let maximum = UInt64(Int64.max)
        var estimator = ClockSyncEstimator()
        XCTAssertTrue(
            estimator.append(
                ClockSyncProbe(
                    hostSentNanoseconds: 0,
                    viewerReceivedNanoseconds: maximum,
                    viewerSentNanoseconds: maximum,
                    hostReceivedNanoseconds: 0
                )
            )
        )
        XCTAssertTrue(
            estimator.append(
                ClockSyncProbe(
                    hostSentNanoseconds: maximum,
                    viewerReceivedNanoseconds: 0,
                    viewerSentNanoseconds: 0,
                    hostReceivedNanoseconds: maximum
                )
            )
        )

        let estimate = try XCTUnwrap(estimator.estimate())
        XCTAssertEqual(estimate.residualOffsetUncertaintyNanoseconds, UInt64.max - 1)
        XCTAssertTrue(estimate.driftNanosecondsPerSecond.isFinite)
    }

    func testM8PercentilesAreDeterministicAndEmptySamplesAreRejected() {
        XCTAssertNil(PercentileSummary(samples: []))
        let summary = try! XCTUnwrap(
            PercentileSummary(samples: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        )
        XCTAssertEqual(summary.count, 10)
        XCTAssertEqual(summary.minimumNanoseconds, 10)
        XCTAssertEqual(summary.p50Nanoseconds, 50)
        XCTAssertEqual(summary.p95Nanoseconds, 100)
        XCTAssertEqual(summary.maximumNanoseconds, 100)
    }
}
