import Foundation
import XCTest
@testable import Host

final class HostRuntimeRecoveryPolicyTests: XCTestCase {
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

    func testClipboardPromptRestorationRequiresHostToRemainFrontmost() {
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
