import Foundation
import InputCore
import RemoteProtocol
import TransportCore

/// M6 supports one active Host input session for the selected window. Starting
/// a replacement session stops the previous input loop before the new session
/// can reuse that target. This is a Host composition invariant, not merely a
/// cleanup-lease optimization: two authenticated Viewers must never inject
/// concurrently into the same selected window.
actor HostInputSessionLeaseRegistry {
    static let shared = HostInputSessionLeaseRegistry()

    // Keep the active runtime strongly owned until it has finished releasing
    // any admitted pressed state. A weak reference would allow an abandoned
    // runtime to disappear while its cleanup worker still holds an active
    // target-bound lease, leaving the registry unable to await safe recovery
    // before admitting a replacement.
    private var activeRuntime: HostInputSessionRuntime?
    private var activeLease: HostInputSessionCleanupLease?

    func activate(
        runtime: HostInputSessionRuntime,
        lease: HostInputSessionCleanupLease
    ) async {
        if let activeRuntime, activeRuntime === runtime {
            activeLease = lease
            return
        }

        // Keep the previous lease registered and valid while its runtime
        // drains the input stream and retries any target-bound cleanup. A
        // replacement session must not reuse the selected window while an
        // old release worker can still post into it.
        if let previousRuntime = activeRuntime {
            let previousLease = activeLease
            await previousRuntime.shutdownForReplacement()
            previousLease?.invalidate()
            if activeRuntime === previousRuntime {
                activeRuntime = nil
                activeLease = nil
            }
        } else {
            // Defensive recovery for an inconsistent lease/runtime pair. A
            // normal lifecycle keeps both values together; an orphaned lease
            // must still be invalidated before another runtime is admitted.
            activeLease?.invalidate()
            activeLease = nil
        }

        // The actor is re-entrant while awaiting the previous runtime. If a
        // second replacement was requested in that interval, stop the
        // runtime that won the race before publishing this one. This keeps
        // the registry's one-runtime invariant even for concurrent starts.
        if let currentRuntime = activeRuntime, currentRuntime !== runtime {
            let currentLease = activeLease
            await currentRuntime.shutdownForReplacement()
            currentLease?.invalidate()
            if activeRuntime === currentRuntime {
                activeRuntime = nil
                activeLease = nil
            }
        }

        activeRuntime = runtime
        activeLease = lease
    }

    func deactivate(_ runtime: HostInputSessionRuntime) {
        guard activeRuntime === runtime else { return }
        activeLease?.invalidate()
        activeRuntime = nil
        activeLease = nil
    }
}

/// Host composition owns one input loop for each authenticated session. The
/// runtime is deliberately small: session policy and current macOS facts stay
/// with the caller, while this object guarantees that the authenticated
/// message stream has exactly one input consumer and that it is stopped with
/// the session.
final actor HostInputSessionRuntime {
    private let loop: HostInputSessionLoop
    private var cleanupLease: HostInputSessionCleanupLease
    private var task: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var isStarting = false

    init(
        session: SessionCoordinator,
        contextProvider: any HostInputContextProvider,
        injectionAdapter: any HostInputInjectionAdapter,
        onNonInputMessage: @escaping @Sendable (MessagePayload) async -> Void
    ) {
        let controller = HostInputController(
            contextProvider: contextProvider,
            injectionAdapter: injectionAdapter
        )
        let handler = HostInputMessageHandler(controller: controller)
        let cleanupLease = HostInputSessionCleanupLease()
        self.cleanupLease = cleanupLease
        self.loop = HostInputSessionLoop(
            session: session,
            handler: handler,
            cleanupLease: cleanupLease,
            onNonInputMessage: onNonInputMessage
        )
    }

    func start() async {
        guard task == nil, !isStarting else { return }
        isStarting = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration

        // A reconnect must not start admitting input while a previous
        // session still owns pressed state. The cleanup lease remains valid
        // until this wait completes.
        await waitForCleanupReconciliation()
        guard isStarting, generation == lifecycleGeneration else {
            isStarting = false
            await HostInputSessionLeaseRegistry.shared.deactivate(self)
            return
        }

        let cleanupLease = HostInputSessionCleanupLease()
        self.cleanupLease = cleanupLease
        loop.replaceCleanupLease(cleanupLease)
        await HostInputSessionLeaseRegistry.shared.activate(
            runtime: self,
            lease: cleanupLease
        )
        guard isStarting, generation == lifecycleGeneration else {
            isStarting = false
            await HostInputSessionLeaseRegistry.shared.deactivate(self)
            return
        }

        let loop = self.loop
        isStarting = false
        task = Task { [weak self, loop] in
            await loop.run()
            if let self {
                await self.inputLoopDidFinish()
            } else {
                // The runtime handle may be released while the stream is
                // still unwinding. Start the target-bound retry directly from
                // the loop so cleanup does not depend on the actor surviving.
                _ = loop.startCleanupReconciliation()
            }
        }
    }

    private func inputLoopDidFinish() {
        // A SessionCoordinator can reopen its incoming stream after
        // reconnect. Clear the completed task before the next lifecycle owner
        // calls start(), otherwise the task-nil guard would strand the new
        // stream without an input consumer.
        task = nil
        beginCleanupReconciliation()
    }

    func stop() async {
        lifecycleGeneration &+= 1
        isStarting = false
        if let task {
            task.cancel()
            await task.value
            self.task = nil
        }
        loop.reset()
        beginCleanupReconciliation()
        await waitForCleanupReconciliation()
        await HostInputSessionLeaseRegistry.shared.deactivate(self)
    }

    /// Stops the input consumer without releasing the registry lease until
    /// target-bound cleanup has completed. The registry calls this while it
    /// is handing ownership to a replacement runtime.
    func shutdownForReplacement() async {
        lifecycleGeneration &+= 1
        isStarting = false
        if let task {
            task.cancel()
            await task.value
            self.task = nil
        }
        loop.reset()
        beginCleanupReconciliation()
        await waitForCleanupReconciliation()
    }

    /// Call before the Host's CaptureCore selection provider changes. This
    /// gives the input controller the old target while it is still current so
    /// held keys/buttons can be released before a new selection is admitted.
    func selectionWillChange() async {
        await loop.selectionWillChange()
    }

    func selectionDidChange() async {
        await loop.selectionDidChange()
    }

    func withSelectionReplacement(
        _ operation: @escaping @Sendable () async -> Void
    ) async {
        await loop.withSelectionReplacement(operation)
    }

    func status() -> HostInputStatus {
        loop.status()
    }

    private func beginCleanupReconciliation() {
        guard cleanupTask == nil else { return }
        cleanupGeneration &+= 1
        let generation = cleanupGeneration
        let loop = self.loop
        cleanupTask = Task { [weak self, loop] in
            let worker = loop.startCleanupReconciliation()
            await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            await self?.cleanupDidFinish(generation: generation)
        }
    }

    private func cleanupDidFinish(generation: UInt64) {
        guard generation == cleanupGeneration else { return }
        cleanupTask = nil
    }

    /// Waits until target-bound cleanup has completed. A replacement session
    /// is intentionally blocked during a permission/focus outage: admitting
    /// another runtime while the old OS key/button state may still be down
    /// would be less safe than temporarily delaying reconnection.
    private func waitForCleanupReconciliation() async {
        while let cleanupTask {
            await cleanupTask.value
        }
    }

    deinit {
        task?.cancel()
        // The registry normally retains this runtime until cleanup completes.
        // Do not cancel the unstructured cleanup task here: it owns the
        // target-bound loop strongly and must outlive this actor if teardown
        // races with a temporary Accessibility or focus outage.
    }
}
