import RemoteProtocol

public enum EnqueueResult: Equatable, Sendable {
    case queued
    case replacedOldestMedia
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
             .videoFrame, .inputEvent, .clipboardOffer, .clipboardText:
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

    var isDiscardableMedia: Bool {
        guard channel == .media, messageType == .videoFrame else { return false }
        guard !flags.contains(.keyframe) else { return false }
        guard let message = try? decodedMessage(),
              case let .videoFrame(frame) = message else {
            // If the frame cannot be decoded, fail closed and retain it for
            // the malformed-frame path instead of treating it as disposable.
            return false
        }
        return !frame.keyframe
    }
}

public actor BoundedFrameQueue {
    public let maxControlFrames: Int
    public let maxMediaFrames: Int

    private var controlFrames: [Envelope] = []
    private var mediaFrames: [Envelope] = []

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
            if mediaFrames.count >= maxMediaFrames {
                guard envelope.isDiscardableMedia,
                      let discardableIndex = mediaFrames.firstIndex(where: { $0.isDiscardableMedia }) else {
                    throw TransportError.mediaBackpressure
                }
                // Prefer the newest frame. The removed frame was not yet
                // admitted to the wire, so a media sequence gap is expected
                // and is handled as a monotonic media sequence by the session.
                mediaFrames.remove(at: discardableIndex)
                mediaFrames.append(envelope)
                return .replacedOldestMedia
            }
            mediaFrames.append(envelope)
            return .queued
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
    }

    public func removeProtectedMessages() {
        // Control sequence numbers are strict. Replace an invalidated
        // protected control envelope with an optional tombstone so the peer
        // can advance its sequence without seeing the stale payload. Protected
        // media is best-effort and can be discarded outright.
        controlFrames = controlFrames.map {
            $0.authorizationInvalidationTombstone ?? $0
        }
        mediaFrames.removeAll(where: \.isProtectedSessionMessage)
    }
}
