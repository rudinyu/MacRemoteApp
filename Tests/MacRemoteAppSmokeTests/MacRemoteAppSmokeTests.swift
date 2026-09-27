import CaptureCore
import CodecCore
import Foundation
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

    func testM8ViewerInitiatedClockProbeNormalizesToViewerMinusHostOffset() {
        // Viewer V1 -> Host H2/H3 -> Viewer V4. The direction-specific probe
        // keeps H3/V4/V1/H2 and should retain the Viewer-minus-Host offset
        // sign while measuring the path around Host work.
        let viewerInitiated = ClockSyncProbe(
            hostSentNanoseconds: 2_000_300,
            viewerReceivedNanoseconds: 1_000_400,
            viewerSentNanoseconds: 1_000_000,
            hostReceivedNanoseconds: 2_000_100,
            direction: .viewerInitiated
        )

        XCTAssertEqual(viewerInitiated.offsetNanoseconds, -1_000_000)
        XCTAssertEqual(viewerInitiated.roundTripNanoseconds, 200)
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

    func testM10PresentationCollectorIsBoundedAndFailsClosedWithoutClockEvidence() throws {
        var collector = BoundedPresentationSampleCollector(
            warmupFrameCount: 2,
            maximumSamples: 2
        )
        collector.append(
            captureTimestampNanoseconds: 1_000_000,
            presentedTimestampNanoseconds: 1_000_100
        )
        collector.append(
            captureTimestampNanoseconds: 1_000_000,
            presentedTimestampNanoseconds: 1_000_200
        )
        collector.append(
            captureTimestampNanoseconds: 1_000_000,
            presentedTimestampNanoseconds: 1_000_600
        )
        collector.append(
            captureTimestampNanoseconds: 1_000_000,
            presentedTimestampNanoseconds: 1_000_800
        )
        collector.append(
            captureTimestampNanoseconds: 1_000_000,
            presentedTimestampNanoseconds: 1_001_000
        )

        let ineligible = ClockSyncEstimate(
            probeCount: 19,
            offsetNanoseconds: 100,
            minimumRoundTripNanoseconds: 1_000_000,
            residualOffsetUncertaintyNanoseconds: 1_000_000,
            driftNanosecondsPerSecond: 0
        )
        let withheld = collector.snapshot(clockSync: ineligible)
        XCTAssertFalse(withheld.oneWayMeasurementEligible)
        XCTAssertNil(withheld.captureToDisplay)
        XCTAssertEqual(withheld.presentedFrameCount, 5)
        XCTAssertEqual(withheld.retainedSampleCount, 2)
        XCTAssertEqual(withheld.droppedSampleCount, 1)

        let eligible = ClockSyncEstimate(
            probeCount: 20,
            offsetNanoseconds: 100,
            minimumRoundTripNanoseconds: 1_000_000,
            residualOffsetUncertaintyNanoseconds: 5_000_000,
            driftNanosecondsPerSecond: 0
        )
        let measured = collector.snapshot(clockSync: eligible)
        let latency = try XCTUnwrap(measured.captureToDisplay)
        XCTAssertTrue(measured.oneWayMeasurementEligible)
        XCTAssertEqual(measured.validFrameSamples, 2)
        XCTAssertEqual(latency.p50Nanoseconds, 500)
        XCTAssertEqual(latency.p95Nanoseconds, 700)
    }

    func testM10HostAppUsesDirectAppKitEntryAndStartsRuntimeBeforeUISetup() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Apps/Host/main.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)

        func line(containing text: String) -> Int? {
            lines.firstIndex { $0.contains(text) }
        }

        let mainDeclaration = try XCTUnwrap(line(containing: "static func main() async"))
        XCTAssertEqual(lines[mainDeclaration - 1].trimmingCharacters(in: .whitespaces), "@MainActor")
        XCTAssertNotNil(line(containing: "runtimeTask = Task.detached(priority: .userInitiated)"))

        let runtimeTaskLine = try XCTUnwrap(line(containing: "runtimeTask = Task.detached(priority: .userInitiated)"))
        let statusItemLine = try XCTUnwrap(line(containing: "installStatusItem()"))
        let activationLine = try XCTUnwrap(line(containing: "NSApplication.shared.activate(ignoringOtherApps: true)"))
        XCTAssertLessThan(runtimeTaskLine, statusItemLine)
        XCTAssertLessThan(runtimeTaskLine, activationLine)

        XCTAssertFalse(source.contains("await MainActor.run {\n                let application = NSApplication.shared"))
        XCTAssertTrue(source.contains("await MainActor.run {\n                    NSApplication.shared.stop(nil)"))
    }

    func testM10HostPairingCodeIsProjectedWhenLocalTrustAutoConsents() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimeSource = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Host/HostRuntime.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Host/main.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(runtimeSource.contains("case pairing(code: String)"))
        XCTAssertTrue(runtimeSource.contains("publish(.pairing(code: challenge.confirmationCode))"))
        XCTAssertTrue(runtimeSource.contains("guard consent?.localConsent != true else"))
        XCTAssertTrue(appSource.contains("Pairing code: —"))
        XCTAssertTrue(appSource.contains("pairingCodeMenuItem?.title = \"Pairing code: \\(code)\""))
    }

    func testM10ViewerDisplaysDerivedCodeAndRequiresExplicitConsent() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let promptSource = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Viewer/ViewerPairingPrompt.swift"),
            encoding: .utf8
        )
        let runtimeSource = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Viewer/ViewerRuntime.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(promptSource.contains("static func requestConsent("))
        XCTAssertTrue(promptSource.contains("Compare this code with the code shown on \\(displayName)"))
        XCTAssertTrue(promptSource.contains("alert.addButton(withTitle: \"Accept\")"))
        XCTAssertTrue(promptSource.contains("alert.addButton(withTitle: \"Deny\")"))
        XCTAssertFalse(promptSource.contains("NSTextField(frame:"))
        XCTAssertTrue(runtimeSource.contains("case .consent(accepted: true):"))
        XCTAssertTrue(runtimeSource.contains("confirmationCode: challenge.confirmationCode"))
    }

    func testM10PairingRecoveryAndHostNameControlsAreUserFacing() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preferencesSource = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Host/HostPreferences.swift"),
            encoding: .utf8
        )
        let hostRuntimeSource = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Host/HostRuntime.swift"),
            encoding: .utf8
        )
        let hostAppSource = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Host/main.swift"),
            encoding: .utf8
        )
        let viewerSource = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Viewer/ViewerRuntime.swift"),
            encoding: .utf8
        )
        let hostMainSource = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Host/main.swift"),
            encoding: .utf8
        )
        let viewerMainSource = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Viewer/main.swift"),
            encoding: .utf8
        )
        let uninstallerSource = try String(
            contentsOf: rootURL.appendingPathComponent("scripts/dmg-uninstall.sh"),
            encoding: .utf8
        )
        let captureProviderSource = try String(
            contentsOf: rootURL.appendingPathComponent(
                "Packages/CaptureCore/Sources/CaptureCore/ScreenRecordingWindowProvider.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(preferencesSource.contains("maximumServiceNameUTF8Bytes = 63"))
        XCTAssertTrue(preferencesSource.contains("MacRemoteApp.Host.serviceName"))
        XCTAssertTrue(hostRuntimeSource.contains("func forgetAllPairings() async throws -> Int"))
        XCTAssertTrue(hostRuntimeSource.contains("configuration.serviceName = validated"))
        XCTAssertTrue(hostRuntimeSource.contains("func updateServiceName(_ serviceName: String) throws"))
        XCTAssertTrue(hostRuntimeSource.contains("defaultIdentityLabel = \"MacRemoteApp.host\""))
        XCTAssertTrue(hostRuntimeSource.contains("defaultTrustStoreService = \"com.rudinyu.MacRemoteApp.Host.trust\""))
        XCTAssertTrue(hostRuntimeSource.contains("KeychainTrustStore(service: Configuration.defaultTrustStoreService)"))
        XCTAssertTrue(hostAppSource.contains("Rename Host…"))
        XCTAssertTrue(hostAppSource.contains("Forget saved pairings…"))
        XCTAssertTrue(hostAppSource.contains("runtime.forgetAllPairings()"))
        XCTAssertTrue(viewerSource.contains("onForgetPairings"))
        XCTAssertTrue(viewerSource.contains("Forget saved pairings…"))
        XCTAssertTrue(viewerSource.contains("defaultIdentityLabel = \"MacRemoteApp.viewer\""))
        XCTAssertTrue(viewerSource.contains("defaultTrustStoreService = \"com.rudinyu.MacRemoteApp.Viewer.trust\""))
        XCTAssertTrue(viewerSource.contains("KeychainTrustStore(service: Configuration.defaultTrustStoreService)"))
        XCTAssertTrue(viewerSource.contains("Saved pairings cleared; choose a Host to pair again"))
        XCTAssertTrue(viewerSource.contains("clearHostSelection()"))
        XCTAssertTrue(viewerSource.contains("Choose MacRemoteApp Host"))
        XCTAssertTrue(hostMainSource.contains("--remove-all-data"))
        XCTAssertTrue(viewerMainSource.contains("--remove-all-data"))
        XCTAssertTrue(hostMainSource.contains("HostRuntime.Configuration.defaultTrustStoreService"))
        XCTAssertTrue(viewerMainSource.contains("ViewerRuntime.Configuration.defaultTrustStoreService"))
        XCTAssertTrue(uninstallerSource.contains("opposite_app_path"))
        XCTAssertTrue(uninstallerSource.contains("\"${bundle_binary}\" --remove-all-data"))
        XCTAssertTrue(captureProviderSource.contains("isLikelyUserFacingApplication"))
        XCTAssertTrue(captureProviderSource.contains("seekpreview"))
    }

    func testM10ConnectionWindowSwitchingAndDeviceNamesAreWired() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preferences = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Host/HostPreferences.swift"),
            encoding: .utf8
        )
        let hostRuntime = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Host/HostRuntime.swift"),
            encoding: .utf8
        )
        let viewerRuntime = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Viewer/ViewerRuntime.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(preferences.contains("ProcessInfo.processInfo.hostName"))
        XCTAssertTrue(preferences.contains("return shortHostName(hostName)"))
        XCTAssertTrue(hostRuntime.contains("deviceName: configuration.serviceName"))
        XCTAssertTrue(hostRuntime.contains("snapshot.state == .streaming"))
        XCTAssertTrue(hostRuntime.contains("bringSelectedApplicationToForeground(selected)"))
        XCTAssertTrue(hostRuntime.contains("frontmostApplication?.processIdentifier == window.processIdentifier"))
        // A remote foreground change must be visible on the Host.
        XCTAssertTrue(hostRuntime.contains("broughtToFront: didForegroundSelectedApplication"))
        XCTAssertTrue(hostRuntime.contains("Viewer brought \\(application) to the front and is sharing it"))
        XCTAssertTrue(viewerRuntime.contains("deviceName: Self.localDeviceName"))
        XCTAssertTrue(viewerRuntime.contains("case .connected: return \"Connected\""))
        XCTAssertTrue(viewerRuntime.contains("case .reconnecting: return \"Reconnecting…\""))
        XCTAssertTrue(viewerRuntime.contains("connectHostButton.isEnabled = isDisconnected"))
    }
}
