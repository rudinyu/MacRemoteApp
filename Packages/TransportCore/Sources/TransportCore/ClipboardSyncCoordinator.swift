import Foundation
import RemoteProtocol

/// Identifies one clipboard transfer without retaining its text.
public struct ClipboardTransferID: Equatable, Hashable, Sendable {
    public let generation: UInt64
    public let origin: DeviceRole

    public init(generation: UInt64, origin: DeviceRole) {
        self.generation = generation
        self.origin = origin
    }
}

/// The observable clipboard state intentionally contains no clipboard text or
/// digest. Apps can render this value in their session UI without creating a
/// sensitive diagnostic record.
public struct ClipboardSyncStatus: Equatable, Sendable {
    public let localEnabled: Bool
    public let remoteEnabled: Bool
    public let pendingOutgoing: ClipboardTransferID?
    public let pendingIncoming: ClipboardTransferID?

    public init(
        localEnabled: Bool,
        remoteEnabled: Bool,
        pendingOutgoing: ClipboardTransferID?,
        pendingIncoming: ClipboardTransferID?
    ) {
        self.localEnabled = localEnabled
        self.remoteEnabled = remoteEnabled
        self.pendingOutgoing = pendingOutgoing
        self.pendingIncoming = pendingIncoming
    }

    public var isEnabledForSession: Bool {
        localEnabled && remoteEnabled
    }
}

public enum ClipboardLocalUpdate: Equatable, Sendable {
    case disabled
    case remoteDisabled
    case tooLarge
    case queued
    case suppressedEcho
    case offer(ClipboardOfferMessage)
}

public enum ClipboardOfferHandling: Equatable, Sendable {
    case acknowledgement(ClipboardAcknowledgementMessage)
}

public enum ClipboardAcknowledgementHandling: Equatable, Sendable {
    case sendText(ClipboardTextMessage)
    case sendTextAndOffer(text: ClipboardTextMessage, offer: ClipboardOfferMessage)
    case sendOffer(ClipboardOfferMessage)
    case rejected(ClipboardAcknowledgementReason)
    case statusUpdated
    case ignored
}

public enum ClipboardTextHandling: Equatable, Sendable {
    case apply(text: String, transfer: ClipboardTransferID)
    case rejected(ClipboardAcknowledgementReason)
    case ignored
}

/// Pure, app-independent M7 clipboard policy.
///
/// The coordinator owns only bounded transient transfer state. AppKit
/// pasteboard access remains in `Apps/Host` and `Apps/Viewer`; callers send the
/// returned protocol messages through their authenticated SessionCoordinator.
/// The conflict policy is deterministic arrival order: a pending local offer
/// wins over a concurrent remote offer, while a local edit made after a remote
/// offer has been accepted cancels that incoming offer and becomes the new
/// local offer. Replayed generations are rejected.
public struct ClipboardSyncCoordinator: Sendable {
    private struct PendingStatus: Sendable {
        let generation: UInt64
        let enabled: Bool
        let remoteStateRevision: UInt64
    }

    private struct PendingOutgoing: Sendable {
        let id: ClipboardTransferID
        let text: String
    }

    private struct PendingIncoming: Sendable {
        let id: ClipboardTransferID
        let textByteCount: Int
    }

    private struct EchoSuppression: Sendable {
        let id: ClipboardTransferID
        let text: String
    }

    public let localRole: DeviceRole
    public private(set) var limits: ProtocolLimits

    private var localEnabled = false
    private var remoteEnabled = false
    private var nextGeneration: UInt64 = 0
    private var lastIncomingGeneration: UInt64?
    private var remoteStateRevision: UInt64 = 0
    private var pendingStatus: PendingStatus?
    private var pendingOutgoing: PendingOutgoing?
    private var queuedOutgoingText: String?
    private var pendingIncoming: PendingIncoming?
    private var echoSuppression: EchoSuppression?
    private var pendingCancellation: ClipboardOfferMessage?

    public init(localRole: DeviceRole, limits: ProtocolLimits = .default) {
        self.localRole = localRole
        self.limits = limits
    }

    /// Applies the negotiated Hello intersection before a new clipboard
    /// transfer is admitted. Any in-flight transfer is discarded because its
    /// byte bound was established under a different session contract.
    public mutating func updateLimits(_ limits: ProtocolLimits) {
        guard self.limits != limits else { return }
        self.limits = limits
        pendingOutgoing = nil
        queuedOutgoingText = nil
        pendingIncoming = nil
        echoSuppression = nil
        pendingCancellation = nil
    }

    public var status: ClipboardSyncStatus {
        ClipboardSyncStatus(
            localEnabled: localEnabled,
            remoteEnabled: remoteEnabled,
            pendingOutgoing: pendingOutgoing?.id,
            pendingIncoming: pendingIncoming?.id
        )
    }

    /// Enables or disables synchronization for this session. A status-only
    /// offer makes the local opt-in state visible to the peer without creating
    /// an ambiguous empty-text transfer.
    public mutating func setEnabled(_ enabled: Bool) -> ClipboardOfferMessage? {
        guard localEnabled != enabled else { return nil }
        localEnabled = enabled
        pendingOutgoing = nil
        queuedOutgoingText = nil
        pendingIncoming = nil
        echoSuppression = nil
        pendingCancellation = nil
        let offer = makeOffer(textByteCount: 0, enabled: enabled, hasText: false)
        pendingStatus = PendingStatus(
            generation: offer.generation,
            enabled: enabled,
            remoteStateRevision: remoteStateRevision
        )
        return offer
    }

    /// Consumes a local pasteboard text change. The raw text stays in this
    /// bounded in-memory coordinator until the peer acknowledges the offer;
    /// it is never included in status, error, or logging values.
    public mutating func localTextChanged(_ text: String) -> ClipboardLocalUpdate {
        guard localEnabled else {
            clearPendingTransfersWithCancellation()
            return .disabled
        }
        let textByteCount = text.utf8.count
        guard textByteCount <= clipboardTextAdmissionLimit else {
            clearPendingTransfersWithCancellation()
            return .tooLarge
        }

        if let echoSuppression,
           echoSuppression.text == text {
            self.echoSuppression = nil
            return .suppressedEcho
        }
        echoSuppression = nil

        pendingIncoming = nil
        guard remoteEnabled else { return .remoteDisabled }

        if pendingOutgoing != nil {
            queuedOutgoingText = text
            return .queued
        }

        return .offer(makeOutgoingOffer(text: text, byteCount: textByteCount))
    }

    /// Records a native pasteboard change that is not transferable as text.
    /// It still wins the local conflict policy and must cancel a remote offer
    /// or an older local text transfer instead of allowing stale text to be
    /// applied later.
    public mutating func localPasteboardChangedWithoutText() {
        clearPendingTransfersWithCancellation()
    }

    /// Returns a status-only offer that supersedes a previously announced
    /// text offer. This is the bounded cancellation signal for a native local
    /// change that cannot be transferred as text; without it, the peer could
    /// retain an accepted incoming generation forever.
    public mutating func takePendingCancellation() -> ClipboardOfferMessage? {
        defer { pendingCancellation = nil }
        return pendingCancellation
    }

    /// Validates a peer offer and returns the acknowledgement that the app
    /// should send. The text itself is not accepted until `receiveText`.
    public mutating func receiveOffer(
        _ offer: ClipboardOfferMessage
    ) -> ClipboardOfferHandling {
        let id = ClipboardTransferID(generation: offer.generation, origin: offer.origin)
        guard offer.origin != localRole else {
            return .acknowledgement(acknowledgement(for: offer, accepted: false, reason: .unsupported))
        }

        if let pendingIncoming, pendingIncoming.id == id {
            return .acknowledgement(acknowledgement(for: offer, accepted: true, reason: .accepted))
        }
        if let lastIncomingGeneration,
           offer.generation <= lastIncomingGeneration {
            return .acknowledgement(acknowledgement(for: offer, accepted: false, reason: .stale))
        }

        if !offer.enabled {
            remoteEnabled = false
            remoteStateRevision &+= 1
            lastIncomingGeneration = offer.generation
            pendingStatus = nil
            pendingOutgoing = nil
            queuedOutgoingText = nil
            pendingIncoming = nil
            echoSuppression = nil
            return .acknowledgement(acknowledgement(for: offer, accepted: false, reason: .disabled))
        }

        remoteEnabled = true
        remoteStateRevision &+= 1
        guard localEnabled else {
            return .acknowledgement(acknowledgement(for: offer, accepted: false, reason: .disabled))
        }
        guard Int(offer.textByteCount) <= clipboardTextAdmissionLimit else {
            return .acknowledgement(acknowledgement(for: offer, accepted: false, reason: .tooLarge))
        }

        // A newer offer from the same peer supersedes an older offer whose
        // text has not arrived yet. This pairs with the sender's status-only
        // cancellation offer and also makes a fresh text offer recover from a
        // local non-text edit observed between Offer and Text.
        if let pendingIncoming,
           pendingIncoming.id.origin == offer.origin,
           offer.generation > pendingIncoming.id.generation {
            self.pendingIncoming = nil
        }

        // A status-only enablement update is accepted but does not create a
        // text transfer which would wait forever for ClipboardText.
        if !offer.hasText {
            lastIncomingGeneration = offer.generation
            return .acknowledgement(acknowledgement(for: offer, accepted: true, reason: .accepted))
        }

        if let pendingOutgoing {
            if pendingOutgoing.id == id {
                return .acknowledgement(acknowledgement(for: offer, accepted: true, reason: .accepted))
            }
            return .acknowledgement(acknowledgement(for: offer, accepted: false, reason: .conflict))
        }
        if pendingIncoming != nil {
            return .acknowledgement(acknowledgement(for: offer, accepted: false, reason: .conflict))
        }

        pendingIncoming = PendingIncoming(
            id: id,
            textByteCount: Int(offer.textByteCount)
        )
        lastIncomingGeneration = offer.generation
        return .acknowledgement(acknowledgement(for: offer, accepted: true, reason: .accepted))
    }

    /// Applies an acknowledgement for the current local offer. A status-only
    /// offer has no pending outgoing text and is therefore safely ignored.
    public mutating func receiveAcknowledgement(
        _ acknowledgement: ClipboardAcknowledgementMessage
    ) -> ClipboardAcknowledgementHandling {
        guard acknowledgement.origin == localRole else {
            return .ignored
        }

        if let pendingStatus,
           pendingStatus.generation == acknowledgement.generation {
            self.pendingStatus = nil
            let accepted = acknowledgement.accepted && acknowledgement.reason == .accepted
            if pendingStatus.remoteStateRevision == remoteStateRevision {
                remoteEnabled = pendingStatus.enabled ? accepted : false
            }
            if !pendingStatus.enabled {
                pendingOutgoing = nil
                queuedOutgoingText = nil
                pendingIncoming = nil
                echoSuppression = nil
            }
            return .statusUpdated
        }

        guard let pendingOutgoing,
              pendingOutgoing.id.generation == acknowledgement.generation else {
            return .ignored
        }

        self.pendingOutgoing = nil
        let queuedText = queuedOutgoingText
        self.queuedOutgoingText = nil
        guard acknowledgement.accepted,
              acknowledgement.reason == .accepted else {
            if let queuedText, remoteEnabled {
                return .sendOffer(makeOutgoingOffer(text: queuedText, byteCount: queuedText.utf8.count))
            }
            return .rejected(acknowledgement.reason)
        }
        let textMessage = ClipboardTextMessage(
            generation: pendingOutgoing.id.generation,
            text: pendingOutgoing.text
        )
        guard let queuedText, remoteEnabled else {
            return .sendText(textMessage)
        }
        return .sendTextAndOffer(
            text: textMessage,
            offer: makeOutgoingOffer(text: queuedText, byteCount: queuedText.utf8.count)
        )
    }

    /// Applies text only after a matching offer was accepted. The exact byte
    /// count is checked again because this method is also used by app-level
    /// test doubles that may construct messages without decoding an envelope.
    public mutating func receiveText(_ message: ClipboardTextMessage) -> ClipboardTextHandling {
        guard let pendingIncoming,
              pendingIncoming.id.generation == message.generation else {
            return .ignored
        }
        guard message.text.count <= clipboardTextAdmissionLimit else {
            self.pendingIncoming = nil
            return .rejected(.tooLarge)
        }
        guard message.text.count == pendingIncoming.textByteCount,
              let text = String(data: message.text, encoding: .utf8) else {
            self.pendingIncoming = nil
            return .rejected(.unsupported)
        }

        self.pendingIncoming = nil
        lastIncomingGeneration = max(lastIncomingGeneration ?? 0, message.generation)
        echoSuppression = EchoSuppression(id: pendingIncoming.id, text: text)
        return .apply(text: text, transfer: pendingIncoming.id)
    }

    /// Consumes the echo marker immediately after the app has applied a
    /// received value to its native pasteboard. The app must not leave this
    /// marker armed until the next poll, otherwise a later user copy of the
    /// same text could be mistaken for the programmatic write.
    public mutating func consumeEchoSuppression() {
        echoSuppression = nil
    }

    /// Clears all transient text, offers, echo markers, and opt-in state when
    /// the authenticated session stops or reconnects.
    public mutating func reset() {
        localEnabled = false
        remoteEnabled = false
        nextGeneration = 0
        lastIncomingGeneration = nil
        remoteStateRevision = 0
        pendingOutgoing = nil
        queuedOutgoingText = nil
        pendingStatus = nil
        pendingIncoming = nil
        echoSuppression = nil
        pendingCancellation = nil
    }

    /// Drops in-flight transfer state after a transport send fails while
    /// preserving the user's explicit local/remote opt-in state. The next
    /// pasteboard change may start a fresh bounded Offer/ACK exchange.
    public mutating func discardPendingTransfers() {
        pendingOutgoing = nil
        queuedOutgoingText = nil
        pendingStatus = nil
        pendingIncoming = nil
        echoSuppression = nil
        pendingCancellation = nil
    }

    /// Invalidates an outgoing offer that was admitted under an obsolete app
    /// clipboard epoch. If a newer local edit was queued behind it, promote
    /// that edit to a fresh offer so the app bridge can retry immediately;
    /// otherwise simply clear the unsent offer. This prevents an offer whose
    /// epoch fence rejected its wire send from blocking every later edit.
    public mutating func recoverPendingOutgoingOffer(
        matching transferID: ClipboardTransferID
    ) -> ClipboardOfferMessage? {
        guard pendingOutgoing?.id == transferID else { return nil }
        pendingOutgoing = nil
        guard localEnabled,
              remoteEnabled,
              let queuedOutgoingText else {
            self.queuedOutgoingText = nil
            return nil
        }
        self.queuedOutgoingText = nil
        let byteCount = queuedOutgoingText.utf8.count
        guard byteCount <= clipboardTextAdmissionLimit else {
            return nil
        }
        return makeOutgoingOffer(text: queuedOutgoingText, byteCount: byteCount)
    }

    /// Returns the already-installed newer offer when its predecessor's text
    /// send was fenced by a newer clipboard epoch. The offer is not recreated
    /// or installed again: `receiveAcknowledgement` has already promoted the
    /// queued text into `pendingOutgoing`, and the app bridge only needs to
    /// retry that offer on the wire.
    public func retryPendingOutgoingOffer(
        after transferID: ClipboardTransferID
    ) -> ClipboardOfferMessage? {
        guard localEnabled,
              remoteEnabled,
              let pendingOutgoing,
              pendingOutgoing.id.origin == transferID.origin,
              pendingOutgoing.id.generation > transferID.generation else {
            return nil
        }
        let byteCount = pendingOutgoing.text.utf8.count
        guard byteCount <= clipboardTextAdmissionLimit,
              let textByteCount = UInt32(exactly: byteCount) else {
            return nil
        }
        return ClipboardOfferMessage(
            generation: pendingOutgoing.id.generation,
            origin: pendingOutgoing.id.origin,
            textByteCount: textByteCount,
            enabled: true,
            hasText: true
        )
    }

    private mutating func clearPendingTransfersWithCancellation() {
        let shouldCancel = pendingOutgoing != nil && localEnabled
        pendingOutgoing = nil
        queuedOutgoingText = nil
        pendingIncoming = nil
        echoSuppression = nil
        pendingCancellation = nil
        guard shouldCancel else { return }
        let cancellation = makeOffer(textByteCount: 0, enabled: true, hasText: false)
        pendingStatus = PendingStatus(
            generation: cancellation.generation,
            enabled: true,
            remoteStateRevision: remoteStateRevision
        )
        pendingCancellation = cancellation
    }

    private mutating func nextTransferID() -> ClipboardTransferID {
        precondition(nextGeneration < UInt64.max, "clipboard generation exhausted")
        nextGeneration += 1
        return ClipboardTransferID(generation: nextGeneration, origin: localRole)
    }

    private mutating func makeOffer(
        textByteCount: UInt32,
        enabled: Bool,
        hasText: Bool
    ) -> ClipboardOfferMessage {
        let id = nextTransferID()
        return ClipboardOfferMessage(
            generation: id.generation,
            origin: id.origin,
            textByteCount: textByteCount,
            enabled: enabled,
            hasText: hasText
        )
    }

    private mutating func makeOutgoingOffer(
        text: String,
        byteCount: Int
    ) -> ClipboardOfferMessage {
        let id = nextTransferID()
        pendingOutgoing = PendingOutgoing(id: id, text: text)
        return ClipboardOfferMessage(
            generation: id.generation,
            origin: id.origin,
            textByteCount: UInt32(byteCount),
            enabled: true,
            hasText: true
        )
    }

    private var clipboardTextAdmissionLimit: Int {
        min(limits.maxClipboardTextBytes, limits.maxFieldLength)
    }

    private func acknowledgement(
        for offer: ClipboardOfferMessage,
        accepted: Bool,
        reason: ClipboardAcknowledgementReason
    ) -> ClipboardAcknowledgementMessage {
        ClipboardAcknowledgementMessage(
            generation: offer.generation,
            origin: offer.origin,
            accepted: accepted,
            reason: reason
        )
    }
}
