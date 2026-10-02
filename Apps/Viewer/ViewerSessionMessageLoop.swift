import RemoteProtocol
import TransportCore

/// The Viewer-side single consumer for messages delivered by a
/// SessionCoordinator. Clipboard messages are handled by the AppKit bridge;
/// the remaining messages continue to the Viewer stream/render dispatcher.
@MainActor
final class ViewerSessionMessageLoop {
    private let session: SessionCoordinator
    private let clipboardController: ViewerClipboardSessionController
    private let onMessage: @MainActor (MessagePayload) async -> Void
    private var task: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    var onClipboardStatusChange: (@MainActor () -> Void)?

    init(
        session: SessionCoordinator,
        onMessage: @escaping @MainActor (MessagePayload) async -> Void = { _ in }
    ) {
        self.session = session
        self.clipboardController = ViewerClipboardSessionController(session: session)
        self.onMessage = onMessage
        clipboardController.onStatusChange = { [weak self] in
            self?.onClipboardStatusChange?()
        }
    }

    var clipboardStatus: ClipboardSyncStatus {
        clipboardController.status
    }

    func setClipboardEnabled(_ enabled: Bool) async throws {
        try await clipboardController.setEnabled(enabled)
    }

    func start() {
        guard task == nil else { return }
        clipboardController.startPolling()
        lifecycleTask = Task { @MainActor [weak self] in
            await self?.monitorSessionLifecycle()
        }
        task = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    func stop() async {
        // Invalidate pasteboard admissions before the first suspension. A
        // handler already waiting on SessionCoordinator's admission mutex
        // must observe the new epoch and refuse to write after cancellation.
        clipboardController.stopPolling()
        lifecycleTask?.cancel()
        await lifecycleTask?.value
        lifecycleTask = nil
        task?.cancel()
        await task?.value
        task = nil
    }

    private func run() async {
        var iterator = session.incomingMessages.makeAsyncIterator()
        do {
            while let message = try await iterator.next() {
                try? await clipboardController.handle(message)
                await onMessage(message)
            }
        } catch {
            // SessionCoordinator owns the redacted failure state. The Viewer
            // loop only stops dispatching and never logs transport details.
        }
        clipboardController.stopPolling()
        lifecycleTask?.cancel()
        lifecycleTask = nil
        task = nil
    }

    private func monitorSessionLifecycle() async {
        var previous = await session.snapshot()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            let current = await session.snapshot()
            if current.authorizationGeneration != previous.authorizationGeneration ||
                current.reconnectGeneration != previous.reconnectGeneration ||
                current.authorized != previous.authorized ||
                current.authorizedWindowGeneration != previous.authorizedWindowGeneration {
                await clipboardController.resetForSessionLifecycleIfStale(current)
            }
            previous = current
        }
    }

    deinit {
        task?.cancel()
        lifecycleTask?.cancel()
    }
}
