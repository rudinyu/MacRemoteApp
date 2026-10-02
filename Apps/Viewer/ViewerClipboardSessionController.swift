import AppKit
import RemoteProtocol
import TransportCore

/// Viewer-side M7 composition. Only this app-layer type touches NSPasteboard;
/// the transfer policy and all wire validation live in TransportCore and
/// RemoteProtocol.
@MainActor
final class ViewerClipboardSessionController {
    private let session: SessionCoordinator
    private let pasteboard: NSPasteboard
    private var coordinator: ClipboardSyncCoordinator
    private var lastChangeCount: Int
    private var pollingTask: Task<Void, Never>?
    private var authorizationEpoch: UInt64?
    private var clipboardStateEpoch: UInt64 = 0
    private var lifecycleEpoch: UInt64 = 0

    private(set) var status: ClipboardSyncStatus
    var onStatusChange: (() -> Void)?

    init(
        session: SessionCoordinator,
        pasteboard: NSPasteboard = .general,
        limits: ProtocolLimits = .default
    ) {
        self.session = session
        self.pasteboard = pasteboard
        self.coordinator = ClipboardSyncCoordinator(localRole: .viewer, limits: limits)
        self.lastChangeCount = pasteboard.changeCount
        self.status = coordinator.status
    }

    /// The Viewer UI calls this from its event/timer loop. Reading only the
    /// public `.string` type intentionally rejects images, files, rich text,
    /// and arbitrary pasteboard types.
    func pollPasteboard() async {
        let expectedLifecycleEpoch = lifecycleEpoch
        let sessionSnapshot = await session.snapshot()
        guard lifecycleEpoch == expectedLifecycleEpoch, !Task.isCancelled else { return }
        guard hasClipboardAuthorization(sessionSnapshot) else {
            resetForSessionLifecycle()
            return
        }
        guard await bindAuthorizationEpoch(sessionSnapshot) else { return }
        coordinator.updateLimits(sessionSnapshot.effectiveProtocolLimits)

        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        clipboardStateEpoch &+= 1
        guard coordinator.status.localEnabled else {
            coordinator.localPasteboardChangedWithoutText()
            await sendPendingCancellation(
                expectedAuthorizationGeneration: sessionSnapshot.authorizationGeneration,
                expectedClipboardStateEpoch: clipboardStateEpoch
            )
            return
        }
        guard let text = pasteboard.string(forType: .string) else {
            coordinator.localPasteboardChangedWithoutText()
            await sendPendingCancellation(
                expectedAuthorizationGeneration: sessionSnapshot.authorizationGeneration,
                expectedClipboardStateEpoch: clipboardStateEpoch
            )
            return
        }
        await processLocalText(
            text,
            expectedAuthorizationGeneration: sessionSnapshot.authorizationGeneration,
            expectedClipboardStateEpoch: clipboardStateEpoch
        )
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollPasteboard()
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        resetForSessionLifecycle()
    }

    func setEnabled(_ enabled: Bool) async throws {
        let expectedLifecycleEpoch = lifecycleEpoch
        let sessionSnapshot = await session.snapshot()
        guard lifecycleEpoch == expectedLifecycleEpoch else {
            throw SessionError.authorizationChanged
        }
        guard hasClipboardAuthorization(sessionSnapshot) else {
            resetForSessionLifecycle()
            throw SessionError.unauthorizedMessage(.clipboardOffer)
        }
        guard await bindAuthorizationEpoch(sessionSnapshot) else {
            throw SessionError.authorizationChanged
        }
        coordinator.updateLimits(sessionSnapshot.effectiveProtocolLimits)
        clipboardStateEpoch &+= 1

        guard let offer = coordinator.setEnabled(enabled) else {
            publishStatus()
            return
        }
        publishStatus()
        try await send(
            .clipboardOffer(offer),
            expectedAuthorizationGeneration: sessionSnapshot.authorizationGeneration
        )
    }

    /// The session's single message consumer forwards clipboard messages here.
    func handle(_ message: MessagePayload) async throws {
        switch message.messageType {
        case .clipboardOffer, .clipboardAcknowledgement, .clipboardText:
            break
        default:
            return
        }

        let expectedLifecycleEpoch = lifecycleEpoch
        let entryAuthorization = await session.snapshot()
        guard lifecycleEpoch == expectedLifecycleEpoch else { return }
        guard hasClipboardAuthorization(entryAuthorization) else {
            resetForSessionLifecycle()
            return
        }
        guard await bindAuthorizationEpoch(entryAuthorization) else {
            return
        }
        coordinator.updateLimits(entryAuthorization.effectiveProtocolLimits)
        let entryClipboardStateEpoch = clipboardStateEpoch
        let entryPasteboardChangeCount = pasteboard.changeCount

        switch message {
        case let .clipboardOffer(offer):
            guard case let .acknowledgement(acknowledgement) = coordinator.receiveOffer(offer) else {
                return
            }
            publishStatus()
            try await send(
                .clipboardAcknowledgement(acknowledgement),
                expectedAuthorizationGeneration: entryAuthorization.authorizationGeneration
            )
        case let .clipboardAcknowledgement(acknowledgement):
            if coordinator.status.pendingOutgoing != nil,
               pasteboard.changeCount != lastChangeCount {
                try await reconcileLocalPasteboardBeforeAcknowledgement(
                    expectedAuthorizationGeneration: entryAuthorization.authorizationGeneration
                )
                return
            }
            switch coordinator.receiveAcknowledgement(acknowledgement) {
            case let .sendText(text):
                publishStatus()
                try await send(
                    .clipboardText(text),
                    expectedAuthorizationGeneration: entryAuthorization.authorizationGeneration,
                    expectedClipboardStateEpoch: entryClipboardStateEpoch
                )
            case let .sendTextAndOffer(text, offer):
                publishStatus()
                try await send(
                    .clipboardText(text),
                    expectedAuthorizationGeneration: entryAuthorization.authorizationGeneration,
                    expectedClipboardStateEpoch: entryClipboardStateEpoch
                )
                try await send(
                    .clipboardOffer(offer),
                    expectedAuthorizationGeneration: entryAuthorization.authorizationGeneration,
                    expectedClipboardStateEpoch: entryClipboardStateEpoch
                )
            case let .sendOffer(offer):
                publishStatus()
                try await send(
                    .clipboardOffer(offer),
                    expectedAuthorizationGeneration: entryAuthorization.authorizationGeneration,
                    expectedClipboardStateEpoch: entryClipboardStateEpoch
                )
            case .rejected, .statusUpdated, .ignored:
                publishStatus()
            }
        case let .clipboardText(text):
            if case let .apply(value, _) = coordinator.receiveText(text) {
                do {
                    let applied = try await session.withIncomingClipboardAdmission(
                        expectedAuthorizationGeneration: entryAuthorization.authorizationGeneration
                    ) { @MainActor [self] in
                        guard authorizationEpoch == entryAuthorization.authorizationGeneration,
                              clipboardStateEpoch == entryClipboardStateEpoch,
                              pasteboard.changeCount == entryPasteboardChangeCount,
                              lastChangeCount == entryPasteboardChangeCount,
                              coordinator.status.localEnabled,
                              coordinator.status.remoteEnabled else {
                            return false
                        }
                        let remoteWriteGeneration = pasteboard.clearContents()
                        guard pasteboard.setString(value, forType: .string) else {
                            return false
                        }
                        coordinator.consumeEchoSuppression()
                        // `setString` does not provide an atomic snapshot of
                        // the pasteboard. Another app can write immediately
                        // after it, so preserve the generation created by our
                        // clear rather than sampling a newer local copy.
                        lastChangeCount = remoteWriteGeneration
                        return true
                    }
                    guard applied else {
                        let current = await session.snapshot()
                        guard hasClipboardAuthorization(current),
                              current.authorizationGeneration == entryAuthorization.authorizationGeneration,
                              authorizationEpoch == entryAuthorization.authorizationGeneration else {
                            return
                        }
                        if clipboardStateEpoch == entryClipboardStateEpoch {
                            clipboardStateEpoch &+= 1
                        }
                        // The native pasteboard changed while the remote text
                        // was waiting for admission. Clear only the echo
                        // marker; preserve opt-in state and any newer local
                        // transfer so the next poll can reconcile it.
                        coordinator.consumeEchoSuppression()
                        publishStatus()
                        return
                    }
                } catch {
                    resetForSessionLifecycleIfCurrent(
                        expectedAuthorizationGeneration: entryAuthorization.authorizationGeneration,
                        expectedClipboardStateEpoch: entryClipboardStateEpoch
                    )
                    return
                }
            }
            publishStatus()
        default:
            break
        }
    }

    func reset() {
        resetForSessionLifecycle()
    }

    func resetForSessionLifecycle() {
        lifecycleEpoch &+= 1
        coordinator.reset()
        authorizationEpoch = nil
        clipboardStateEpoch &+= 1
        lastChangeCount = pasteboard.changeCount
        publishStatus()
    }

    func resetForSessionLifecycleIfStale(_ snapshot: SessionSnapshot) async {
        guard hasClipboardAuthorization(snapshot) else {
            resetForSessionLifecycle()
            return
        }
        guard authorizationEpoch != snapshot.authorizationGeneration else {
            return
        }
        _ = await bindAuthorizationEpoch(snapshot)
    }

    private func processLocalText(
        _ text: String,
        expectedAuthorizationGeneration: UInt64,
        expectedClipboardStateEpoch: UInt64
    ) async {
        guard clipboardStateEpoch == expectedClipboardStateEpoch,
              authorizationEpoch == expectedAuthorizationGeneration else {
            return
        }
        let update = coordinator.localTextChanged(text)
        let cancellation = coordinator.takePendingCancellation()
        publishStatus()
        do {
            if let cancellation {
                try await send(
                    .clipboardOffer(cancellation),
                    expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                    expectedClipboardStateEpoch: expectedClipboardStateEpoch
                )
            }
            if case let .offer(offer) = update {
                try await send(
                    .clipboardOffer(offer),
                    expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                    expectedClipboardStateEpoch: expectedClipboardStateEpoch
                )
            }
        } catch {
            // The send helper has already reset and closed the session because
            // a failed transfer could leave the peer waiting for this offer.
        }
    }

    private func reconcileLocalPasteboardBeforeAcknowledgement(
        expectedAuthorizationGeneration: UInt64
    ) async throws {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        clipboardStateEpoch &+= 1
        coordinator.localPasteboardChangedWithoutText()
        let cancellation = coordinator.takePendingCancellation()
        publishStatus()
        if let cancellation {
            try await send(
                .clipboardOffer(cancellation),
                expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                expectedClipboardStateEpoch: clipboardStateEpoch
            )
        }
        guard coordinator.status.localEnabled,
              let text = pasteboard.string(forType: .string) else {
            return
        }
        await processLocalText(
            text,
            expectedAuthorizationGeneration: expectedAuthorizationGeneration,
            expectedClipboardStateEpoch: clipboardStateEpoch
        )
    }

    private func sendPendingCancellation(
        expectedAuthorizationGeneration: UInt64,
        expectedClipboardStateEpoch: UInt64
    ) async {
        let cancellation = coordinator.takePendingCancellation()
        publishStatus()
        guard let cancellation else { return }
        do {
            try await send(
                .clipboardOffer(cancellation),
                expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                expectedClipboardStateEpoch: expectedClipboardStateEpoch
            )
        } catch {
            // The send helper fails closed and stops the session.
        }
    }

    private func send(
        _ message: MessagePayload,
        expectedAuthorizationGeneration: UInt64,
        expectedClipboardStateEpoch: UInt64? = nil
    ) async throws {
        let expectedTransferID = localTransferID(for: message)
        let currentSnapshot = await session.snapshot()
        guard hasClipboardAuthorization(currentSnapshot),
              currentSnapshot.authorizationGeneration == expectedAuthorizationGeneration,
              authorizationEpoch == expectedAuthorizationGeneration else {
            discardPendingTransfersIfCurrent(
                expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                expectedClipboardStateEpoch: expectedClipboardStateEpoch
            )
            throw SessionError.authorizationChanged
        }
        if let expectedClipboardStateEpoch {
            guard clipboardStateEpoch == expectedClipboardStateEpoch else {
                await recoverPendingOutgoingAfterStaleClipboardEpoch(
                    expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                    expectedClipboardStateEpoch: expectedClipboardStateEpoch,
                    expectedTransferID: expectedTransferID
                )
                throw SessionError.authorizationChanged
            }
        }
        do {
            try await session.send(
                message,
                expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                localAdmission: { @MainActor [weak self] in
                    guard let self else { return false }
                    guard self.authorizationEpoch == expectedAuthorizationGeneration else {
                        return false
                    }
                    guard let expectedClipboardStateEpoch else { return true }
                    return self.clipboardStateEpoch == expectedClipboardStateEpoch
                }
            )
        } catch {
            let currentSnapshot = await session.snapshot()
            let lifecycleChanged =
                !hasClipboardAuthorization(currentSnapshot) ||
                currentSnapshot.authorizationGeneration != expectedAuthorizationGeneration ||
                authorizationEpoch != expectedAuthorizationGeneration
            if lifecycleChanged {
                if let expectedClipboardStateEpoch {
                    await recoverPendingOutgoingAfterStaleClipboardEpoch(
                        expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                        expectedClipboardStateEpoch: expectedClipboardStateEpoch,
                        expectedTransferID: expectedTransferID
                    )
                }
                discardPendingTransfersIfCurrent(
                    expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                    expectedClipboardStateEpoch: expectedClipboardStateEpoch
                )
                throw error
            }
            if let sessionError = error as? SessionError,
               sessionError == .authorizationChanged ||
               sessionError == .reconnectRequired {
                // These are session/epoch fences, not transport failures. An
                // older clipboard task must never stop a replacement session.
                if let expectedClipboardStateEpoch {
                    await recoverPendingOutgoingAfterStaleClipboardEpoch(
                        expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                        expectedClipboardStateEpoch: expectedClipboardStateEpoch,
                        expectedTransferID: expectedTransferID
                    )
                }
                discardPendingTransfersIfCurrent(
                    expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                    expectedClipboardStateEpoch: expectedClipboardStateEpoch
                )
                throw error
            }
            // A failed clipboard send can leave the peer with an accepted
            // offer or pending text. Fail closed so both session lifecycle
            // handlers discard the transfer state instead of continuing with
            // different local state machines.
            let failureLifecycleEpoch = lifecycleEpoch
            let failureClipboardStateEpoch = clipboardStateEpoch
            let stopped = await session.stopIfCurrent(
                reason: .shutdown,
                expectedAuthorizationGeneration: currentSnapshot.authorizationGeneration,
                expectedReconnectGeneration: currentSnapshot.reconnectGeneration
            )
            guard stopped else { throw error }
            guard lifecycleEpoch == failureLifecycleEpoch,
                  authorizationEpoch == currentSnapshot.authorizationGeneration,
                  clipboardStateEpoch == failureClipboardStateEpoch else {
                throw error
            }
            coordinator.reset()
            authorizationEpoch = nil
            clipboardStateEpoch &+= 1
            publishStatus()
            throw error
        }
    }

    private func recoverPendingOutgoingAfterStaleClipboardEpoch(
        expectedAuthorizationGeneration: UInt64,
        expectedClipboardStateEpoch: UInt64,
        expectedTransferID: ClipboardTransferID?
    ) async {
        guard clipboardStateEpoch != expectedClipboardStateEpoch,
              authorizationEpoch == expectedAuthorizationGeneration,
              let expectedTransferID else {
            return
        }
        let currentSnapshot = await session.snapshot()
        guard hasClipboardAuthorization(currentSnapshot),
              currentSnapshot.authorizationGeneration == expectedAuthorizationGeneration,
              authorizationEpoch == expectedAuthorizationGeneration,
              clipboardStateEpoch != expectedClipboardStateEpoch else {
            return
        }
        let retryOffer: ClipboardOfferMessage?
        if coordinator.status.pendingOutgoing == expectedTransferID {
            retryOffer = coordinator.recoverPendingOutgoingOffer(matching: expectedTransferID)
        } else {
            // An acknowledgement may have promoted a queued local edit while
            // the older text message was waiting for admission. Keep that
            // newer pending offer and retry it instead of leaving it stranded.
            retryOffer = coordinator.retryPendingOutgoingOffer(after: expectedTransferID)
        }
        publishStatus()
        guard let retryOffer else { return }
        let retryEpoch = clipboardStateEpoch
        publishStatus()
        do {
            try await send(
                .clipboardOffer(retryOffer),
                expectedAuthorizationGeneration: expectedAuthorizationGeneration,
                expectedClipboardStateEpoch: retryEpoch
            )
        } catch {
            // The retry path applies the same authorization and lifecycle
            // fences; the original stale operation remains rejected.
        }
    }

    private func localTransferID(for message: MessagePayload) -> ClipboardTransferID? {
        switch message {
        case let .clipboardOffer(offer):
            guard offer.origin == coordinator.localRole else { return nil }
            return ClipboardTransferID(generation: offer.generation, origin: offer.origin)
        case let .clipboardText(text):
            return ClipboardTransferID(
                generation: text.generation,
                origin: coordinator.localRole
            )
        default:
            return nil
        }
    }

    private func discardPendingTransfersIfCurrent(
        expectedAuthorizationGeneration: UInt64,
        expectedClipboardStateEpoch: UInt64? = nil
    ) {
        guard authorizationEpoch == expectedAuthorizationGeneration,
              expectedClipboardStateEpoch.map({ clipboardStateEpoch == $0 }) ?? true else {
            return
        }
        coordinator.discardPendingTransfers()
        publishStatus()
    }

    private func resetForSessionLifecycleIfCurrent(
        expectedAuthorizationGeneration: UInt64,
        expectedClipboardStateEpoch: UInt64
    ) {
        guard authorizationEpoch == expectedAuthorizationGeneration,
              clipboardStateEpoch == expectedClipboardStateEpoch else {
            return
        }
        resetForSessionLifecycle()
    }

    private func bindAuthorizationEpoch(_ snapshot: SessionSnapshot) async -> Bool {
        let generation = snapshot.authorizationGeneration
        guard let authorizationEpoch else {
            self.authorizationEpoch = generation
            return true
        }
        guard authorizationEpoch != generation else { return true }

        let preserveLocalOptIn = coordinator.status.localEnabled
        lifecycleEpoch &+= 1
        let reenableOffer = coordinator.resetForAuthorizationEpoch(
            preservingLocalOptIn: preserveLocalOptIn
        )
        self.authorizationEpoch = generation
        clipboardStateEpoch &+= 1
        lastChangeCount = pasteboard.changeCount
        publishStatus()

        guard let reenableOffer else { return true }
        do {
            try await send(
                .clipboardOffer(reenableOffer),
                expectedAuthorizationGeneration: generation
            )
            return authorizationEpoch == generation
        } catch {
            // A generation fence is recoverable: the lifecycle monitor will
            // reconcile the next authorized snapshot. Transport failures are
            // already closed by `send` and reset this controller.
            return false
        }
    }

    private func hasClipboardAuthorization(
        _ snapshot: SessionSnapshot,
        matching generation: UInt64? = nil
    ) -> Bool {
        guard snapshot.authorized,
              snapshot.authorizedCapabilities.contains(.textClipboard) else {
            return false
        }
        if let generation {
            return snapshot.authorizationGeneration == generation
        }
        return true
    }

    private func publishStatus() {
        status = coordinator.status
        onStatusChange?()
    }

    deinit {
        pollingTask?.cancel()
    }
}
