import RemoteProtocol

public enum EnqueueResult: Equatable, Sendable {
    case queued
    /// Media was discarded and the queue now skips delta frames until the
    /// next keyframe. The sender should produce a keyframe. A keyframe that
    /// only purges superseded delta frames reports `.queued`.
    case discardedMedia
}

extension Envelope {
    /// Optional control-plane marker used when an admitted protected control
    /// envelope is invalidated before delivery. Keeping its sequence number
    /// preserves the strict control sequence without exposing the stale
    /// payload to the peer.
    static let authorizationInvalidationMessageType = MessageType.unknown(0x7FFE)

    var isProtectedSessionMessage: Bool {
        switch messageType {
        case .windowList, .windowSelection, .streamConfig, .videoConfig,
             .videoFrame, .inputEvent, .inputSourceSelection,
             .inputSourceAcknowledgement, .clipboardOffer, .clipboardText,
             .clipboardAcknowledgement, .keyframeRequest, .receiverReport:
            return true
        default:
            return false
        }
    }

    var authorizationInvalidationTombstone: Envelope? {
        guard channel == .control, isProtectedSessionMessage else { return nil }
        return try? Envelope(
            version: version,
            channel: channel,
            messageType: Self.authorizationInvalidationMessageType,
            sequence: sequence,
            timestamp: timestamp,
            limits: .default
        )
    }
}

public actor BoundedFrameQueue {
    public let maxControlFrames: Int
    public let maxMediaFrames: Int

    private var controlFrames: [Envelope] = []
    private var mediaFrames: [Envelope] = []
    private var mediaAdmission = KeyframeAwareMediaAdmission()

    public init(maxControlFrames: Int = 128, maxMediaFrames: Int = 3) throws {
        guard maxControlFrames > 0, maxMediaFrames > 0 else {
            throw TransportError.protocolViolation("queue limits must be positive")
        }
        self.maxControlFrames = maxControlFrames
        self.maxMediaFrames = maxMediaFrames
    }

    public func enqueue(_ envelope: Envelope) throws -> EnqueueResult {
        switch envelope.channel {
        case .control:
            guard controlFrames.count < maxControlFrames else {
                throw TransportError.controlBackpressure
            }
            controlFrames.append(envelope)
            return .queued
        case .media:
            let decision = try mediaAdmission.admit(
                envelope.mediaAdmissionKind,
                into: &mediaFrames,
                maxMediaCount: maxMediaFrames,
                isMedia: { _ in true },
                kindOf: \.mediaAdmissionKind
            )
            if decision.admitIncoming {
                mediaFrames.append(envelope)
            }
            return decision.awaitingKeyframe ? .discardedMedia : .queued
        }
    }

    public func dequeue() -> Envelope? {
        if !controlFrames.isEmpty {
            return controlFrames.removeFirst()
        }
        guard !mediaFrames.isEmpty else {
            return nil
        }
        return mediaFrames.removeFirst()
    }

    public func counts() -> (control: Int, media: Int) {
        (controlFrames.count, mediaFrames.count)
    }

    public func removeAll() {
        controlFrames.removeAll(keepingCapacity: false)
        mediaFrames.removeAll(keepingCapacity: false)
        mediaAdmission.reset()
    }

    public func removeProtectedMessages() {
        // Control sequence numbers are strict. Replace an invalidated
        // protected control envelope with an optional tombstone so the peer
        // can advance its sequence without seeing the stale payload. Protected
        // media is best-effort and can be discarded outright.
        controlFrames = controlFrames.map {
            $0.authorizationInvalidationTombstone ?? $0
        }
        let mediaCount = mediaFrames.count
        mediaFrames.removeAll(where: \.isProtectedSessionMessage)
        if mediaFrames.count != mediaCount {
            mediaAdmission.noteMediaRemoved()
        }
    }
}
