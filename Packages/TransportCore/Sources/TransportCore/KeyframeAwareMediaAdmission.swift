import RemoteProtocol

/// Keyframe-aware admission policy shared by the bounded media queues.
///
/// H.264 delta frames reference earlier frames, so dropping one delta frame
/// corrupts every later delta frame until the next keyframe. When the media
/// capacity is reached the policy therefore discards the incoming delta
/// frame, never an already queued one, and then discards every later delta
/// frame until a keyframe is admitted. A keyframe supersedes all queued delta
/// frames, so they are purged to make room for it and to prefer the newest
/// decodable picture. Required media such as `VideoConfig` is never dropped;
/// it may purge queued delta frames, which also starts a keyframe wait.
///
/// The policy owns no storage. Callers hold their own lock or actor isolation
/// and apply it to their queue.
struct KeyframeAwareMediaAdmission: Sendable {
    enum Kind: Sendable {
        case control
        case deltaFrame
        case keyframe
        case requiredMedia
    }

    struct Decision: Equatable, Sendable {
        /// Whether the incoming element should be appended or delivered.
        let admitIncoming: Bool
        /// Whether delta frames are now being skipped until a keyframe. A
        /// keyframe purging superseded delta frames does not set this: the
        /// keyframe itself restores decodability, so asking for another one
        /// would only add a bitrate spike under congestion.
        let awaitingKeyframe: Bool
    }

    private(set) var isAwaitingKeyframe = false

    mutating func admit<Element>(
        _ kind: Kind,
        into queue: inout [Element],
        maxMediaCount: Int,
        isMedia: (Element) -> Bool,
        kindOf: (Element) -> Kind
    ) throws -> Decision {
        func mediaCount() -> Int {
            queue.reduce(into: 0) { count, element in
                if isMedia(element) {
                    count += 1
                }
            }
        }
        func purgeDeltaFrames() -> Bool {
            let before = queue.count
            queue.removeAll { kindOf($0) == .deltaFrame }
            return queue.count != before
        }

        switch kind {
        case .control:
            return Decision(admitIncoming: true, awaitingKeyframe: false)
        case .deltaFrame:
            if isAwaitingKeyframe || mediaCount() >= maxMediaCount {
                isAwaitingKeyframe = true
                return Decision(admitIncoming: false, awaitingKeyframe: true)
            }
            return Decision(admitIncoming: true, awaitingKeyframe: false)
        case .keyframe:
            _ = purgeDeltaFrames()
            guard mediaCount() < maxMediaCount else {
                // Later delta frames reference the rejected keyframe.
                isAwaitingKeyframe = true
                throw TransportError.mediaBackpressure
            }
            isAwaitingKeyframe = false
            return Decision(admitIncoming: true, awaitingKeyframe: false)
        case .requiredMedia:
            guard mediaCount() >= maxMediaCount else {
                return Decision(admitIncoming: true, awaitingKeyframe: isAwaitingKeyframe)
            }
            guard purgeDeltaFrames(), mediaCount() < maxMediaCount else {
                isAwaitingKeyframe = true
                throw TransportError.mediaBackpressure
            }
            isAwaitingKeyframe = true
            return Decision(admitIncoming: true, awaitingKeyframe: true)
        }
    }

    /// Records that queued media was removed outside `admit`, for example by
    /// authorization invalidation. Later delta frames would reference a
    /// missing frame, so they are discarded until the next keyframe.
    mutating func noteMediaRemoved() {
        isAwaitingKeyframe = true
    }

    mutating func reset() {
        isAwaitingKeyframe = false
    }
}

extension Envelope {
    var mediaAdmissionKind: KeyframeAwareMediaAdmission.Kind {
        guard channel == .media else { return .control }
        guard messageType == .videoFrame else { return .requiredMedia }
        if flags.contains(.keyframe) { return .keyframe }
        // An undecodable frame is retained for the malformed-frame path
        // instead of being treated as disposable.
        guard let message = try? decodedMessage(),
              case let .videoFrame(frame) = message else {
            return .requiredMedia
        }
        return frame.keyframe ? .keyframe : .deltaFrame
    }
}
