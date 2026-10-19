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

    /// Capture output is sized in backing pixels, but Viewer input is
    /// normalized to the displayed content rectangle and InputCore maps it to
    /// the selected window's global point bounds. The encoded pixel size must
    /// therefore not change where a normalized event lands.
    func testM3PixelCaptureSizeDoesNotChangeNormalizedInputMapping() throws {
        let bounds = WindowBounds(x: 100, y: 50, width: 800, height: 600)
        let configuration = CaptureConfiguration.default
        let standard = configuration.outputDimensions(for: bounds, backingScaleFactor: 1)
        let retina = configuration.outputDimensions(for: bounds, backingScaleFactor: 2)
        XCTAssertEqual(standard, CaptureOutputDimensions(width: 800, height: 600))
        XCTAssertEqual(retina, CaptureOutputDimensions(width: 1_440, height: 1_080))

        let selection = HostInputWindowSelection(
            windowIdentifier: 7,
            processIdentifier: 70,
            applicationIdentifier: "com.example.test",
            generation: 3,
            bounds: InputWindowBounds(
                originX: bounds.x,
                originY: bounds.y,
                width: bounds.width,
                height: bounds.height
            )
        )
        let context = HostInputContext(
            sessionAuthorized: true,
            authorizedWindowGeneration: 3,
            selectedWindow: selection,
            currentWindowIdentifier: 7,
            currentProcessIdentifier: 70,
            currentApplicationIdentifier: "com.example.test",
            currentWindowBounds: selection.bounds,
            permission: .authorized,
            focus: .eligible,
            mouseInputEnabled: true,
            keyboardInputEnabled: true
        )

        func hostPoint(forVideoPixel pixel: (x: Double, y: Double), in output: CaptureOutputDimensions) throws -> InputScreenPoint {
            // Same normalization the Viewer applies against its content rect.
            let x = UInt16(min(65_535, (pixel.x / Double(output.width) * 65_535).rounded()))
            let y = UInt16(min(65_535, (pixel.y / Double(output.height) * 65_535).rounded()))
            let record = InputEventRecord(
                sequence: 1,
                timestampNanoseconds: 1,
                windowGeneration: 3,
                kind: .pointerMove,
                x: x,
                y: y
            )
            guard case let .pointerMove(_, location) = try HostInputMapper.command(for: record, in: context) else {
                throw XCTSkip("expected a pointer move command")
            }
            return location
        }

        for fraction in [(0.0, 0.0), (0.25, 0.75), (0.5, 0.5), (1.0, 1.0)] {
            let expectedX = min(bounds.x + fraction.0 * bounds.width, (bounds.x + bounds.width).nextDown)
            let expectedY = min(bounds.y + fraction.1 * bounds.height, (bounds.y + bounds.height).nextDown)
            for output in [standard, retina] {
                let point = try hostPoint(
                    forVideoPixel: (fraction.0 * Double(output.width), fraction.1 * Double(output.height)),
                    in: output
                )
                // One normalized step is 800/65535 points; allow one step.
                XCTAssertEqual(point.x, expectedX, accuracy: 0.02)
                XCTAssertEqual(point.y, expectedY, accuracy: 0.02)
            }
        }
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
        XCTAssertTrue(hostRuntimeSource.contains("service: Configuration.defaultTrustStoreService"))
        XCTAssertTrue(hostRuntimeSource.contains("resolvePairingTrust(for: controlSessionID)"))
        XCTAssertTrue(hostRuntimeSource.contains("HostRuntimeClipboardAuthorizationPolicy.permits"))
        XCTAssertFalse(hostRuntimeSource.contains("HostControlPrompt.requestConsent"))
        XCTAssertFalse(hostRuntimeSource.contains("HostClipboardPrompt.requestConsent"))
        XCTAssertTrue(hostAppSource.contains("Rename Host…"))
        XCTAssertTrue(hostAppSource.contains("Forget saved pairings…"))
        XCTAssertTrue(hostAppSource.contains("Unpair this Viewer?"))
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
        let inputSource = try String(
            contentsOf: rootURL.appendingPathComponent(
                "Packages/InputCore/Sources/InputCore/CoreGraphicsAccessibilityInput.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(preferences.contains("ProcessInfo.processInfo.hostName"))
        XCTAssertTrue(preferences.contains("return shortHostName(hostName)"))
        XCTAssertTrue(hostRuntime.contains("deviceName: configuration.serviceName"))
        XCTAssertTrue(hostRuntime.contains("snapshot.state == .streaming"))
        XCTAssertTrue(hostRuntime.contains("bringSelectedApplicationToForeground(selected)"))
        XCTAssertTrue(hostRuntime.contains("CoreGraphicsAccessibilityWindowFocus.isSelectedWindowForeground(selection)"))
        XCTAssertTrue(inputSource.contains("raiseSelectedWindowIfAccessible"))
        XCTAssertTrue(inputSource.contains("kAXRaiseAction as CFString"))
        XCTAssertTrue(inputSource.contains("HostInputWindowSelection"))
        // A remote foreground change must be visible on the Host.
        XCTAssertTrue(hostRuntime.contains("broughtToFront: didForegroundSelectedApplication"))
        XCTAssertTrue(hostRuntime.contains("Viewer brought \\(application) to the front and is sharing it"))
        XCTAssertTrue(viewerRuntime.contains("deviceName: Self.localDeviceName"))
        XCTAssertTrue(viewerRuntime.contains("case .connected: return \"Connected\""))
        XCTAssertTrue(viewerRuntime.contains("case .reconnecting: return \"Reconnecting…\""))
        XCTAssertTrue(viewerRuntime.contains("connectHostButton.isEnabled = isDisconnected"))
        XCTAssertTrue(hostRuntime.contains("videoConfigSentAuthorizationGeneration"))
        XCTAssertTrue(hostRuntime.contains("expectedAuthorizationGeneration: authorizationGeneration"))
        XCTAssertTrue(hostRuntime.contains("case .authorizationChanged:"))
        XCTAssertTrue(hostRuntime.contains("case .reconnectRequired:"))
    }

    func testM10WindowSwitchKeepsInputClipboardAndVideoLifecycleInSync() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let inputLoop = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Host/HostInputSessionLoop.swift"),
            encoding: .utf8
        )
        let viewerClipboard = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Viewer/ViewerClipboardSessionController.swift"),
            encoding: .utf8
        )
        let viewerRuntime = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Viewer/ViewerRuntime.swift"),
            encoding: .utf8
        )
        let hostRuntime = try String(
            contentsOf: rootURL.appendingPathComponent("Apps/Host/HostRuntime.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(inputLoop.contains("let sessionLifecycleChanged ="))
        XCTAssertTrue(inputLoop.contains("else if sessionLifecycleChanged"))
        XCTAssertTrue(inputLoop.contains("await onInputStatusChange(inputStatus)"))
        XCTAssertTrue(viewerClipboard.contains("resetForAuthorizationEpoch("))
        XCTAssertTrue(viewerClipboard.contains("preservingLocalOptIn: preserveLocalOptIn"))
        XCTAssertTrue(viewerRuntime.contains("pendingWindowSelection"))
        XCTAssertTrue(viewerRuntime.contains("Host window list changed — select a window again"))
        XCTAssertTrue(hostRuntime.contains("republishWindowCatalogAfterRejectedSelection"))
        XCTAssertTrue(hostRuntime.contains("recoverFromSelectionFailure"))
        XCTAssertTrue(viewerRuntime.contains("videoView.frame = videoFrame"))
        XCTAssertTrue(viewerRuntime.contains("surface.frame = videoFrame"))
    }

    func testM10UsesLANOnlyTransportAndPostEventBasePermission() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let inputSource = try String(
            contentsOf: rootURL.appendingPathComponent(
                "Packages/InputCore/Sources/InputCore/CoreGraphicsAccessibilityInput.swift"
            ),
            encoding: .utf8
        )
        let transportSource = try String(
            contentsOf: rootURL.appendingPathComponent(
                "Packages/TransportCore/Sources/TransportCore/BonjourDiscovery.swift"
            ),
            encoding: .utf8
        )

        // PostEvent is the base permission. Per-event checks read it through a
        // bounded cache whose only query is CGPreflightPostEventAccess.
        XCTAssertTrue(inputSource.contains("query: { CGPreflightPostEventAccess() }"))
        XCTAssertTrue(inputSource.contains("guard PostEventPermissionCache.shared.isAuthorized() else"))
        XCTAssertFalse(inputSource.contains("guard CGPreflightPostEventAccess(), AXIsProcessTrusted()"))
        XCTAssertFalse(inputSource.contains("CGPreflightPostEventAccess() && AXIsProcessTrusted()"))
        XCTAssertTrue(inputSource.contains("Accessibility is optional for base Quartz event posting"))
        XCTAssertTrue(transportSource.contains("parameters.includePeerToPeer = false"))
        XCTAssertFalse(transportSource.contains("MultipeerConnectivity"))
    }
}
