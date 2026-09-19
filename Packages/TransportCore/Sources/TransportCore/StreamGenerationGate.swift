import Foundation

/// Rejects media and input work that belongs to a previous selected-window
/// epoch. App composition owns when the epoch advances; this value type keeps
/// the comparison deterministic and independent of transport timing.
public struct StreamGenerationGate: Equatable, Sendable {
    public private(set) var generation: UInt64?

    public init(generation: UInt64? = nil) {
        self.generation = generation
    }

    public mutating func advance(to generation: UInt64) {
        guard self.generation == nil || generation >= self.generation! else { return }
        self.generation = generation
    }

    public mutating func revoke() {
        generation = nil
    }

    public func accepts(_ candidate: UInt64) -> Bool {
        generation == candidate
    }
}
