import Foundation
import CaptureCore
import InputCore
import RemoteProtocol
import SecurityCore
import TransportCore
import XCTest
@testable import Host

final class HostRuntimeRecoveryPolicyTests: XCTestCase {
    func testProductionHostAdvertisesP6BackgroundControlForNegotiation() {
        XCTAssertTrue(HostRuntime.capabilities.contains(.backgroundControl))
    }

    func testCaptureRecoveryKeepsAuthenticatedSessionUntilRecoveryEnds() {
        XCTAssertTrue(HostRuntimeCaptureLivenessPolicy.keepsAuthenticatedSession(
            for: .capturing(windowIdentifier: 3, generation: 7)
        ))
        XCTAssertTrue(HostRuntimeCaptureLivenessPolicy.keepsAuthenticatedSession(
            for: .recovering(windowIdentifier: 3, generation: 8)
        ))
        XCTAssertFalse(HostRuntimeCaptureLivenessPolicy.keepsAuthenticatedSession(for: .stopped(nil)))
        XCTAssertFalse(HostRuntimeCaptureLivenessPolicy.keepsAuthenticatedSession(
            for: .failed(.windowUnavailable)
        ))
    }

    func testHostReportsCaptureRecoveryInsteadOfClaimingVideoIsLive() {
        XCTAssertEqual(
            HostRuntimeStatus.recovering(application: "Notes").description,
            "Restoring video for Notes"
        )
    }

    func testSameWindowSelectReachesRestoreEvenWhenTheAppIsHidden() {
        let current = CaptureWindow(
            identifier: 21,
            applicationIdentifier: "com.example.notes",
            bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
            processIdentifier: 210,
            eligible: true
        )
        let moved = CaptureWindow(
            identifier: 21,
            applicationIdentifier: "com.example.notes",
            bounds: WindowBounds(x: 40, y: 40, width: 800, height: 600),
            processIdentifier: 210,
            eligible: true
        )
        XCTAssertEqual(
            HostSameWindowSelectionPolicy.restoreTarget(
                current: current,
                refresh: .available(moved),
                windowStillExists: false
            ),
            moved,
            "A resolvable target restores with its refreshed geometry."
        )
        XCTAssertEqual(
            HostSameWindowSelectionPolicy.restoreTarget(
                current: current,
                refresh: .unavailable,
                windowStillExists: true
            ),
            current,
            "A hidden, minimized, or other-Space window that still exists must reach restore."
        )
        XCTAssertEqual(
            HostSameWindowSelectionPolicy.restoreTarget(
                current: current,
                refresh: nil,
                windowStillExists: true
            ),
            current,
            "A failed ScreenCaptureKit lookup falls back to the WindowServer record."
        )
    }

    func testSameWindowSelectRejectsClosedOrReusedWindows() {
        let current = CaptureWindow(
            identifier: 22,
            applicationIdentifier: "com.example.notes",
            bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
            processIdentifier: 220,
            eligible: true
        )
        let reused = CaptureWindow(
            identifier: 22,
            applicationIdentifier: "com.example.other",
            bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
            processIdentifier: 221,
            eligible: true
        )
        XCTAssertNil(HostSameWindowSelectionPolicy.restoreTarget(
            current: current,
            refresh: .ownerMismatch,
            windowStillExists: true
        ))
        XCTAssertNil(HostSameWindowSelectionPolicy.restoreTarget(
            current: current,
            refresh: .available(reused),
            windowStillExists: true
        ))
        XCTAssertNil(
            HostSameWindowSelectionPolicy.restoreTarget(
                current: current,
                refresh: .unavailable,
                windowStillExists: false
            ),
            "A closed window must not trigger app activation."
        )
    }

    func testCaptureLossSummaryUsesFixedCategories() {
        XCTAssertEqual(
            HostRuntimeCaptureLivenessPolicy.summary(for: .failed(.windowUnavailable)),
            "failed-window-unavailable"
        )
        XCTAssertEqual(
            HostRuntimeCaptureLivenessPolicy.summary(for: .failed(.captureFailed("detail text"))),
            "failed-capture-failed",
            "Free-form platform error text must not reach the log."
        )
        XCTAssertEqual(HostRuntimeCaptureLivenessPolicy.summary(for: .stopped(nil)), "stopped-none")
    }

    func testTransientCatalogGapDoesNotPublishAnEmptySelectedWindowList() {
        let selected = CaptureWindow(
            identifier: 19,
            applicationIdentifier: "com.example.notes",
            bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
            processIdentifier: 190,
            eligible: true
        )
        let otherWindow = CaptureWindow(
            identifier: 20,
            applicationIdentifier: "com.example.browser",
            bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
            processIdentifier: 200,
            eligible: true
        )

        XCTAssertFalse(HostRuntimeWindowCatalogPolicy.shouldPublish(
            [otherWindow],
            preserving: selected
        ), "publishing this snapshot would make the Viewer clear its active selection")
        XCTAssertTrue(HostRuntimeWindowCatalogPolicy.shouldPublish(
            [selected, otherWindow],
            preserving: selected
        ))
        XCTAssertTrue(HostRuntimeWindowCatalogPolicy.shouldPublish(
            [otherWindow],
            preserving: nil
        ))
    }

    func testSameOwnerReselectionReassertsExistingSelection() {
        XCTAssertEqual(
            HostRuntimeWindowSelectionAction.resolve(currentWindowHasSameOwner: true),
            .restoreExistingSelection
        )
        XCTAssertEqual(
            HostRuntimeWindowSelectionAction.resolve(currentWindowHasSameOwner: false),
            .activateRequestedSelection
        )
    }

    func testForegroundRestorationRequiresTheSameAuthorizedSelection() {
        XCTAssertTrue(permitsRestore())
        XCTAssertFalse(permitsRestore(activeSession: false))
        XCTAssertFalse(permitsRestore(selectionTransitionInProgress: true))
        XCTAssertFalse(permitsRestore(authorized: false))
        XCTAssertFalse(permitsRestore(selectedWindowMatches: false))
        XCTAssertFalse(permitsRestore(requestGeneration: 8, selectedWindowGeneration: 9))
        XCTAssertFalse(permitsRestore(authorizedWindowGeneration: 8))
    }

    func testForegroundRestorationCanRequireHostToRemainFrontmost() {
        XCTAssertFalse(permitsRestore(requiresHostFrontmost: true, hostIsFrontmost: false))
        XCTAssertTrue(permitsRestore(requiresHostFrontmost: true, hostIsFrontmost: true))
    }

    func testForegroundActivationFallsBackFromCooperativeYieldToAccessibilityAndLaunchServices() {
        XCTAssertEqual(
            HostForegroundActivationPlan.steps(
                cooperativeAPIAvailable: true,
                accessibilityTrusted: true,
                selectedProcessIsOnlyRunningInstance: true
            ),
            [.cooperativeYield, .accessibilityFrontmost, .launchServicesActivation],
            "A refused cooperative request from the menu-bar Host must not end the attempt."
        )
        XCTAssertEqual(
            HostForegroundActivationPlan.steps(
                cooperativeAPIAvailable: false,
                accessibilityTrusted: true,
                selectedProcessIsOnlyRunningInstance: true
            ),
            [.accessibilityFrontmost, .launchServicesActivation],
            "macOS 13 still gets the non-cooperative public requests."
        )
    }

    func testForegroundActivationSkipsStepsWhosePreconditionsAreMissing() {
        XCTAssertEqual(
            HostForegroundActivationPlan.steps(
                cooperativeAPIAvailable: true,
                accessibilityTrusted: false,
                selectedProcessIsOnlyRunningInstance: true
            ),
            [.cooperativeYield, .launchServicesActivation],
            "Without Accessibility trust the AX request is not attempted."
        )
        XCTAssertEqual(
            HostForegroundActivationPlan.steps(
                cooperativeAPIAvailable: true,
                accessibilityTrusted: true,
                selectedProcessIsOnlyRunningInstance: false
            ),
            [.cooperativeYield, .accessibilityFrontmost],
            "LaunchServices could pick another running copy, so it is skipped."
        )
        XCTAssertEqual(
            HostForegroundActivationPlan.steps(
                cooperativeAPIAvailable: false,
                accessibilityTrusted: false,
                selectedProcessIsOnlyRunningInstance: false
            ),
            []
        )
    }

    func testForegroundActivationRequiresExplicitSelectionAndRegularTarget() {
        XCTAssertTrue(HostRuntimeForegroundActivationPolicy.permits(
            explicitViewerSelection: true,
            targetApplicationAvailable: true,
            targetIsRegularApplication: true
        ))
        XCTAssertFalse(HostRuntimeForegroundActivationPolicy.permits(
            explicitViewerSelection: false,
            targetApplicationAvailable: true,
            targetIsRegularApplication: true
        ))
        XCTAssertFalse(HostRuntimeForegroundActivationPolicy.permits(
            explicitViewerSelection: true,
            targetApplicationAvailable: false,
            targetIsRegularApplication: true
        ))
        XCTAssertFalse(HostRuntimeForegroundActivationPolicy.permits(
            explicitViewerSelection: true,
            targetApplicationAvailable: true,
            targetIsRegularApplication: false
        ))
    }

    func testUnconfirmedForegroundActivationRemovesEveryInputCapabilityIncludingP6() {
        let capabilities: Set<Capability> = [
            .mouseInput,
            .keyboardInput,
            .inputSourceSync,
            .backgroundControl,
            .textClipboard
        ]
        XCTAssertEqual(
            HostRuntimeForegroundActivationPolicy.authorizedCapabilities(
                capabilities,
                afterForegroundConfirmation: false,
                inputCapabilities: [.mouseInput, .keyboardInput]
            ),
            [.textClipboard],
            "failed activation must not leave negotiated P6 or input-source authorization active"
        )
        XCTAssertEqual(
            HostRuntimeForegroundActivationPolicy.authorizedCapabilities(
                capabilities,
                afterForegroundConfirmation: true,
                inputCapabilities: [.mouseInput, .keyboardInput]
            ),
            capabilities
        )
    }

    func testCooperativeActivationRequiresSupportedAPIAndConfirmedHostForeground() {
        XCTAssertTrue(HostRuntimeCooperativeActivationPolicy.permitsYield(
            cooperativeAPIAvailable: true,
            hostIsFrontmost: true
        ))
        XCTAssertFalse(HostRuntimeCooperativeActivationPolicy.permitsYield(
            cooperativeAPIAvailable: true,
            hostIsFrontmost: false
        ))
        XCTAssertFalse(HostRuntimeCooperativeActivationPolicy.permitsYield(
            cooperativeAPIAvailable: false,
            hostIsFrontmost: true
        ))
    }

    func testUnauthorizedVideoSendRecoversOnlyAfterAuthorizationTransition() {
        XCTAssertTrue(HostRuntimeVideoAuthorizationRecoveryPolicy.shouldRecover(
            capturedAuthorizationGeneration: 12,
            capturedWindowGeneration: 7,
            capturedAuthorized: true,
            freshAuthorizationGeneration: 13,
            freshWindowGeneration: 7,
            freshAuthorized: true
        ))
        XCTAssertTrue(HostRuntimeVideoAuthorizationRecoveryPolicy.shouldRecover(
            capturedAuthorizationGeneration: 12,
            capturedWindowGeneration: 7,
            capturedAuthorized: true,
            freshAuthorizationGeneration: 13,
            freshWindowGeneration: nil,
            freshAuthorized: false
        ))
        XCTAssertTrue(HostRuntimeVideoAuthorizationRecoveryPolicy.shouldRecover(
            capturedAuthorizationGeneration: 12,
            capturedWindowGeneration: 7,
            capturedAuthorized: true,
            freshAuthorizationGeneration: 13,
            freshWindowGeneration: 8,
            freshAuthorized: true
        ))
        XCTAssertFalse(HostRuntimeVideoAuthorizationRecoveryPolicy.shouldRecover(
            capturedAuthorizationGeneration: 12,
            capturedWindowGeneration: 7,
            capturedAuthorized: true,
            freshAuthorizationGeneration: 12,
            freshWindowGeneration: 7,
            freshAuthorized: true
        ))
        XCTAssertFalse(HostRuntimeVideoAuthorizationRecoveryPolicy.shouldRecover(
            capturedAuthorizationGeneration: 12,
            capturedWindowGeneration: 7,
            capturedAuthorized: false,
            freshAuthorizationGeneration: 13,
            freshWindowGeneration: nil,
            freshAuthorized: false
        ))
    }

    func testCallbackTeardownSchedulerReturnsBeforeLoopTeardown() async {
        let probe = DeferredTeardownProbe()
        let teardownTask = await probe.receiveMessageCallback()

        await teardownTask.value

        let observedCallbackReturn = await probe.teardownObservedCallbackReturn()
        XCTAssertTrue(observedCallbackReturn)
    }

    func testAuthorizationFenceDrainsInputAcrossFailedOverlappingTransition() async throws {
        try await withInputFenceHarness { harness in
            let initialAuthorization = await harness.viewer.snapshot()
            try await sendKey(
                56,
                pressed: true,
                authorizationGeneration: initialAuthorization.authorizationGeneration,
                controlGeneration: 1,
                through: harness.viewer
            )
            try await sendMarker(
                1,
                authorizationGeneration: initialAuthorization.authorizationGeneration,
                through: harness.viewer
            )
            try await waitForMarker(1, recorder: harness.recorder)
            XCTAssertTrue(harness.adapter.hasKey(56, pressed: true))

            let firstEntered = HostInputTestSignal()
            let releaseFirst = HostInputTestSignal()
            let secondEntered = HostInputTestSignal()
            let releaseSecond = HostInputTestSignal()
            let failedFence = Task {
                try await harness.runtime.withAuthorizationFence(session: harness.host) {
                    await firstEntered.signal()
                    await releaseFirst.wait()
                    throw HostInputFenceTestError.expectedFailure
                }
            }
            await firstEntered.wait()

            XCTAssertTrue(
                harness.adapter.hasKey(56, pressed: false),
                "the first authorization fence must release Host-held state before its operation"
            )

            let successfulFence = Task {
                try await harness.runtime.withAuthorizationFence(session: harness.host) {
                    await secondEntered.signal()
                    await releaseSecond.wait()
                    return try await harness.host.authorize(
                        windowGeneration: 7,
                        capabilities: harness.capabilities
                    )
                }
            }
            await secondEntered.wait()

            // The host authorization is still live here, so only the runtime's
            // admission barrier prevents an event queued during the transition.
            try await sendKey(
                57,
                pressed: true,
                authorizationGeneration: initialAuthorization.authorizationGeneration,
                controlGeneration: 1,
                through: harness.viewer
            )
            try await sendMarker(
                2,
                authorizationGeneration: initialAuthorization.authorizationGeneration,
                through: harness.viewer
            )
            try await waitForMarker(2, recorder: harness.recorder)
            XCTAssertFalse(harness.adapter.hasKey(57, pressed: true))

            await releaseFirst.signal()
            do {
                _ = try await failedFence.value
                XCTFail("the first overlapping fence operation should fail")
            } catch HostInputFenceTestError.expectedFailure {
                // A failed transition must release only its own barrier depth.
            }

            XCTAssertFalse(
                harness.adapter.hasKey(57, pressed: true),
                "the remaining authorization fence must continue blocking stale input after the failure"
            )
            await releaseSecond.signal()
            let transition = try await successfulFence.value
            let currentAuthorization = try await waitForViewerAuthorization(
                after: initialAuthorization.authorizationGeneration,
                viewer: harness.viewer
            )
            XCTAssertEqual(transition.authorizationGeneration, currentAuthorization.authorizationGeneration)

            try await sendPointerMove(
                100,
                authorizationGeneration: currentAuthorization.authorizationGeneration,
                controlGeneration: 1,
                through: harness.viewer
            )
            try await sendMarker(
                3,
                authorizationGeneration: currentAuthorization.authorizationGeneration,
                through: harness.viewer
            )
            try await waitForMarker(3, recorder: harness.recorder)

            let commands = harness.adapter.snapshot()
            let releasedIndex = try XCTUnwrap(commands.firstIndex { command in
                if case let .key(_, keyCode, _, pressed) = command {
                    return keyCode == 56 && !pressed
                }
                return false
            })
            let nextInputIndex = try XCTUnwrap(commands.firstIndex { command in
                if case .pointerMove = command { return true }
                return false
            })
            XCTAssertLessThan(releasedIndex, nextInputIndex)
            XCTAssertFalse(harness.adapter.hasKey(57, pressed: true))
            XCTAssertTrue(harness.adapter.hasPointerMove)
        }
    }

    func testLocalInputAdmissionFalseThenTrueResetsBeforeFreshInput() async throws {
        try await withInputFenceHarness { harness in
            let authorization = await harness.viewer.snapshot()
            try await sendKey(
                61,
                pressed: true,
                authorizationGeneration: authorization.authorizationGeneration,
                controlGeneration: 1,
                through: harness.viewer
            )
            try await sendMarker(
                11,
                authorizationGeneration: authorization.authorizationGeneration,
                through: harness.viewer
            )
            try await waitForMarker(11, recorder: harness.recorder)
            XCTAssertTrue(harness.adapter.hasKey(61, pressed: true))

            await harness.runtime.setLocalInputAdmission(false, revision: 2, session: harness.host)
            XCTAssertTrue(
                harness.adapter.hasKey(61, pressed: false),
                "local pause must release held state before completing its transition"
            )
            await harness.runtime.setLocalInputAdmission(true, revision: 3, session: harness.host)

            try await sendKey(
                62,
                pressed: true,
                authorizationGeneration: authorization.authorizationGeneration,
                controlGeneration: 1,
                through: harness.viewer
            )
            try await sendMarker(
                12,
                authorizationGeneration: authorization.authorizationGeneration,
                through: harness.viewer
            )
            try await waitForMarker(12, recorder: harness.recorder)
            XCTAssertFalse(
                harness.adapter.hasKey(62, pressed: true),
                "a message from the pre-pause local control epoch must not be admitted after resume"
            )

            try await sendKey(
                63,
                pressed: true,
                authorizationGeneration: authorization.authorizationGeneration,
                controlGeneration: 3,
                through: harness.viewer
            )
            try await sendMarker(
                13,
                authorizationGeneration: authorization.authorizationGeneration,
                through: harness.viewer
            )
            try await waitForMarker(13, recorder: harness.recorder)
            let commands = harness.adapter.snapshot()
            let releasedIndex = try XCTUnwrap(commands.firstIndex { command in
                if case let .key(_, keyCode, _, pressed) = command {
                    return keyCode == 61 && !pressed
                }
                return false
            })
            let resumedInputIndex = try XCTUnwrap(commands.firstIndex { command in
                if case let .key(_, keyCode, _, pressed) = command {
                    return keyCode == 63 && pressed
                }
                return false
            })
            XCTAssertLessThan(releasedIndex, resumedInputIndex)
            XCTAssertTrue(harness.adapter.hasKey(63, pressed: true))
        }
    }

    private func withInputFenceHarness(
        _ operation: (HostInputFenceHarness) async throws -> Void
    ) async throws {
        let harness = try await makeInputFenceHarness()
        do {
            try await operation(harness)
        } catch {
            await stop(harness)
            throw error
        }
        await stop(harness)
    }

    private func stop(_ harness: HostInputFenceHarness) async {
        await harness.runtime.stop()
        await harness.host.stop()
        await harness.viewer.stop()
    }

    private func makeInputFenceHarness() async throws -> HostInputFenceHarness {
        let hostIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-fence-test-host".utf8))
        let viewerIdentity = try PeerIdentity(publicKeyRepresentation: Data("host-fence-test-viewer".utf8))
        let transports = InMemoryTransport.makePair(
            firstAuthentication: .trusted(viewerIdentity),
            secondAuthentication: .trusted(hostIdentity)
        )
        try await transports.first.start()
        try await transports.second.start()

        let capabilities: Set<Capability> = [
            .pingPong,
            .h264Video,
            .receiverReport,
            .mouseInput,
            .keyboardInput,
            .backgroundControl
        ]
        let host = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .host,
                implementationIdentifier: "host-fence-test-host",
                capabilities: capabilities
            ),
            transport: transports.first
        )
        let viewer = SessionCoordinator(
            configuration: SessionConfiguration(
                role: .viewer,
                implementationIdentifier: "host-fence-test-viewer",
                capabilities: capabilities
            ),
            transport: transports.second
        )
        async let hostStart: Void = host.start()
        async let viewerStart: Void = viewer.start()
        try await hostStart
        try await viewerStart
        _ = try await waitForHostSnapshot(of: host) { $0.state == .capabilitiesNegotiated }
        _ = try await waitForHostSnapshot(of: viewer) { $0.state == .capabilitiesNegotiated }

        let bounds = InputWindowBounds(originX: 0, originY: 0, width: 100, height: 100)
        let selection = HostInputWindowSelection(
            windowIdentifier: 7,
            processIdentifier: 70,
            applicationIdentifier: "com.example.input-target",
            generation: 7,
            bounds: bounds
        )
        let context = HostInputContext(
            sessionAuthorized: true,
            authorizedWindowGeneration: 7,
            selectedWindow: selection,
            currentWindowIdentifier: 7,
            currentProcessIdentifier: 70,
            currentApplicationIdentifier: "com.example.input-target",
            currentWindowBounds: bounds,
            permission: .authorized,
            focus: .eligible,
            mouseInputEnabled: true,
            keyboardInputEnabled: true
        )
        let recorder = HostInputTestRecorder()
        let adapter = HostInputCommandRecorder()
        let runtime = HostInputSessionRuntime(
            session: host,
            contextProvider: FixedHostInputContextProvider(context: context),
            injectionAdapter: adapter,
            onNonInputMessage: { message in
                if case let .receiverReport(report) = message {
                    await recorder.recordMarker(report.receivedFrames)
                }
            }
        )
        let harness = HostInputFenceHarness(
            host: host,
            viewer: viewer,
            runtime: runtime,
            recorder: recorder,
            adapter: adapter,
            capabilities: capabilities
        )
        await runtime.start()
        do {
            await runtime.setLocalInputAdmission(true, revision: 1, session: host)
            try await host.authorize(windowGeneration: 7, capabilities: capabilities)
            _ = try await waitForViewerAuthorization(after: 0, viewer: viewer)
            return harness
        } catch {
            await stop(harness)
            throw error
        }
    }

    private func waitForHostSnapshot(
        of session: SessionCoordinator,
        timeout: Duration = .seconds(5),
        satisfying predicate: (SessionSnapshot) -> Bool
    ) async throws -> SessionSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let snapshot = await session.snapshot()
            if predicate(snapshot) { return snapshot }
            guard clock.now < deadline else { throw HostInputFenceTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForViewerAuthorization(
        after generation: UInt64,
        viewer: SessionCoordinator
    ) async throws -> SessionSnapshot {
        try await waitForHostSnapshot(of: viewer) {
            $0.authorizationGeneration > generation &&
                $0.authorized &&
                $0.authorizedWindowGeneration == 7
        }
    }

    private func waitForMarker(
        _ marker: UInt32,
        recorder: HostInputTestRecorder
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while true {
            if await recorder.hasMarker(marker) { return }
            guard clock.now < deadline else { throw HostInputFenceTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func sendKey(
        _ keyCode: UInt16,
        pressed: Bool,
        authorizationGeneration: UInt64,
        controlGeneration: UInt64,
        through viewer: SessionCoordinator
    ) async throws {
        let input = InputEventMessage(
            kind: pressed ? .keyDown : .keyUp,
            windowGeneration: 7,
            keyCode: keyCode,
            modifiers: 0,
            controlGeneration: controlGeneration
        )
        _ = try await viewer.send(
            .inputEvent(input),
            expectedAuthorizationGeneration: authorizationGeneration
        )
    }

    private func sendPointerMove(
        _ sequence: UInt16,
        authorizationGeneration: UInt64,
        controlGeneration: UInt64,
        through viewer: SessionCoordinator
    ) async throws {
        let input = InputEventMessage(
            kind: .pointerMove,
            windowGeneration: 7,
            x: sequence,
            y: sequence,
            controlGeneration: controlGeneration
        )
        _ = try await viewer.send(
            .inputEvent(input),
            expectedAuthorizationGeneration: authorizationGeneration
        )
    }

    private func sendMarker(
        _ marker: UInt32,
        authorizationGeneration: UInt64,
        through viewer: SessionCoordinator
    ) async throws {
        _ = try await viewer.send(
            .receiverReport(ReceiverReportMessage(
                generation: 7,
                queuingDelayMicroseconds: 0,
                receivedFrames: marker,
                discardedFrames: 0
            )),
            expectedAuthorizationGeneration: authorizationGeneration
        )
    }

    private func permitsRestore(
        activeSession: Bool = true,
        selectionTransitionInProgress: Bool = false,
        authorized: Bool = true,
        selectedWindowMatches: Bool = true,
        requestGeneration: UInt64? = 9,
        selectedWindowGeneration: UInt64? = 9,
        authorizedWindowGeneration: UInt64? = 9,
        requiresHostFrontmost: Bool = false,
        hostIsFrontmost: Bool = false
    ) -> Bool {
        HostRuntimeForegroundRestorationPolicy.permits(
            activeSession: activeSession,
            selectionTransitionInProgress: selectionTransitionInProgress,
            authorized: authorized,
            selectedWindowMatches: selectedWindowMatches,
            requestGeneration: requestGeneration,
            selectedWindowGeneration: selectedWindowGeneration,
            authorizedWindowGeneration: authorizedWindowGeneration,
            requiresHostFrontmost: requiresHostFrontmost,
            hostIsFrontmost: hostIsFrontmost
        )
    }

}

private struct HostInputFenceHarness {
    let host: SessionCoordinator
    let viewer: SessionCoordinator
    let runtime: HostInputSessionRuntime
    let recorder: HostInputTestRecorder
    let adapter: HostInputCommandRecorder
    let capabilities: Set<Capability>
}

private enum HostInputFenceTestError: Error, CustomStringConvertible {
    case expectedFailure
    case timedOut

    var description: String {
        switch self {
        case .expectedFailure: "expected failure"
        case .timedOut: "timed out"
        }
    }
}

private struct FixedHostInputContextProvider: HostInputContextProvider {
    let context: HostInputContext

    func currentContext() -> HostInputContext { context }

    func currentReleaseContext(for target: HostInputTarget) -> HostInputContext? {
        context
    }
}

private final class HostInputCommandRecorder: HostInputInjectionAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [HostInputCommand] = []

    func inject(_ command: HostInputCommand) throws {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func release(_ command: HostInputCommand) throws {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func snapshot() -> [HostInputCommand] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }

    func hasKey(_ keyCode: UInt16, pressed: Bool) -> Bool {
        snapshot().contains { command in
            if case let .key(_, observedKeyCode, _, observedPressed) = command {
                return observedKeyCode == keyCode && observedPressed == pressed
            }
            return false
        }
    }

    var hasPointerMove: Bool {
        snapshot().contains { command in
            if case .pointerMove = command { return true }
            return false
        }
    }
}

private actor HostInputTestRecorder {
    private var markers: Set<UInt32> = []

    func recordMarker(_ marker: UInt32) {
        markers.insert(marker)
    }

    func hasMarker(_ marker: UInt32) -> Bool {
        markers.contains(marker)
    }
}

private actor HostInputTestSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor DeferredTeardownProbe {
    private var callbackReturned = false
    private var callbackHadReturnedWhenTeardownStarted = false

    func receiveMessageCallback() -> Task<Void, Never> {
        let task = HostRuntimeCallbackTeardownScheduler.schedule { [weak self] in
            await self?.stopLoop()
        }
        callbackReturned = true
        return task
    }

    func teardownObservedCallbackReturn() -> Bool {
        callbackHadReturnedWhenTeardownStarted
    }

    private func stopLoop() {
        callbackHadReturnedWhenTeardownStarted = callbackReturned
    }
}
