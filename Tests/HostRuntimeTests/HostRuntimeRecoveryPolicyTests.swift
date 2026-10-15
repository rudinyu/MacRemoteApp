import Foundation
import CaptureCore
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
        XCTAssertFalse(permitsRestore(processTargetingNegotiated: true))
    }

    func testForegroundRestorationCanRequireHostToRemainFrontmost() {
        XCTAssertFalse(permitsRestore(requiresHostFrontmost: true, hostIsFrontmost: false))
        XCTAssertTrue(permitsRestore(requiresHostFrontmost: true, hostIsFrontmost: true))
    }

    func testForegroundActivationRequiresExplicitLegacySelectionAndRegularTarget() {
        XCTAssertTrue(HostRuntimeForegroundActivationPolicy.permits(
            explicitViewerSelection: true,
            processTargetingNegotiated: false,
            targetApplicationAvailable: true,
            targetIsRegularApplication: true
        ))
        XCTAssertFalse(HostRuntimeForegroundActivationPolicy.permits(
            explicitViewerSelection: false,
            processTargetingNegotiated: false,
            targetApplicationAvailable: true,
            targetIsRegularApplication: true
        ))
        XCTAssertFalse(HostRuntimeForegroundActivationPolicy.permits(
            explicitViewerSelection: true,
            processTargetingNegotiated: true,
            targetApplicationAvailable: true,
            targetIsRegularApplication: true
        ))
        XCTAssertFalse(HostRuntimeForegroundActivationPolicy.permits(
            explicitViewerSelection: true,
            processTargetingNegotiated: false,
            targetApplicationAvailable: false,
            targetIsRegularApplication: true
        ))
        XCTAssertFalse(HostRuntimeForegroundActivationPolicy.permits(
            explicitViewerSelection: true,
            processTargetingNegotiated: false,
            targetApplicationAvailable: true,
            targetIsRegularApplication: false
        ))
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

    private func permitsRestore(
        activeSession: Bool = true,
        selectionTransitionInProgress: Bool = false,
        authorized: Bool = true,
        selectedWindowMatches: Bool = true,
        requestGeneration: UInt64? = 9,
        selectedWindowGeneration: UInt64? = 9,
        authorizedWindowGeneration: UInt64? = 9,
        processTargetingNegotiated: Bool = false,
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
            processTargetingNegotiated: processTargetingNegotiated,
            requiresHostFrontmost: requiresHostFrontmost,
            hostIsFrontmost: hostIsFrontmost
        )
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
