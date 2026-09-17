import Foundation

/// A small FIFO mutex for actor methods that must keep ownership across an
/// await. SessionCoordinator uses it to serialize sequence-number admission.
internal final class AsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            var resumeImmediately = false
            lock.lock()
            if isLocked {
                waiters.append(continuation)
            } else {
                isLocked = true
                resumeImmediately = true
            }
            lock.unlock()

            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                isLocked = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
