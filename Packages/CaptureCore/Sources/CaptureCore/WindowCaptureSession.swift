import Foundation

public actor WindowCaptureSession {
    public nonisolated let frames: CapturedFrameStream

    private let frameChannel: CapturedFrameChannel
    private let frameGenerationGate: CapturedFrameGenerationGate
    private let windowProvider: any WindowDiscoveryProvider
    private let engineFactory: any WindowCaptureEngineFactory
    private let configuration: CaptureConfiguration

    private var state: CaptureSessionState = .idle
    private var selectedWindow: CaptureWindow?
    /// Descriptor used to size every engine in this capture generation. The
    /// selected descriptor may receive refreshed geometry, while the wire
    /// stream dimensions remain fixed until the Viewer selects a new window.
    private var captureEngineWindow: CaptureWindow?
    private var outputDimensions: CaptureOutputDimensions?
    private var generation: UInt64 = 0
    private var permission: CapturePermissionState = .denied
    private var engine: (any WindowCaptureEngine)?
    private var relayTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var consecutiveSelectionMisses = 0
    private var captureRestartAttempts = 0
    private static let maximumConsecutiveSelectionMisses = 3
    private static let maximumCaptureRestartAttempts = 2
    private static let captureRestartDelayNanoseconds: UInt64 = 250_000_000
    /// Retry cadence while WindowServer still has the selected window but
    /// ScreenCaptureKit cannot capture it (hidden app, minimized, other Space).
    private static let unavailableTargetRetryNanoseconds: UInt64 = 1_000_000_000

    public init(
        windowProvider: any WindowDiscoveryProvider,
        engineFactory: (any WindowCaptureEngineFactory)? = nil,
        configuration: CaptureConfiguration = .default
    ) {
        let channel = CapturedFrameChannel(bufferCount: configuration.outputBufferCount)
        let generationGate = CapturedFrameGenerationGate()
        self.frames = CapturedFrameStream(channel: channel, generationGate: generationGate)
        self.frameChannel = channel
        self.frameGenerationGate = generationGate
        self.windowProvider = windowProvider
        self.configuration = configuration
        self.engineFactory = engineFactory ?? SystemWindowCaptureEngineFactory(configuration: configuration)
    }

    deinit {
        relayTask?.cancel()
        monitorTask?.cancel()
        frameChannel.close()
    }

    public func snapshot() -> CaptureSessionSnapshot {
        CaptureSessionSnapshot(
            state: state,
            selectedWindow: selectedWindow,
            generation: generation,
            permission: permission,
            outputDimensions: outputDimensions
        )
    }

    public func permissionState() async -> CapturePermissionState {
        permission = await windowProvider.permissionState()
        return permission
    }

    public func requestPermission() async -> CapturePermissionState {
        permission = await windowProvider.requestPermission()
        return permission
    }

    public func discoverWindows() async throws -> [CaptureWindow] {
        permission = await windowProvider.permissionState()
        guard permission == .authorized else {
            throw CaptureCoreError.permissionDenied
        }
        return try await windowProvider.discoverWindows()
    }

    public func start(windowIdentifier: UInt64) async throws {
        prepareForStart()
        permission = await windowProvider.permissionState()
        guard permission == .authorized else {
            throw CaptureCoreError.permissionDenied
        }
        let windows: [CaptureWindow]
        do {
            windows = try await windowProvider.discoverWindows()
        } catch {
            throw CaptureCoreError.providerFailed(String(describing: error))
        }
        guard let window = windows.first(where: { $0.identifier == windowIdentifier }),
              window.eligible else {
            throw CaptureCoreError.invalidWindow
        }

        try await startResolvedWindow(window)
    }

    /// Starts from the exact descriptor validated by Host's selection and
    /// catalog generations. This rechecks the same owner through the full
    /// ScreenCaptureKit catalog, even if the app became inactive after the
    /// Viewer selected it.
    public func start(window expectedWindow: CaptureWindow) async throws {
        prepareForStart()
        permission = await windowProvider.permissionState()
        guard permission == .authorized else {
            throw CaptureCoreError.permissionDenied
        }
        guard expectedWindow.eligible else {
            throw CaptureCoreError.invalidWindow
        }

        let refresh: CaptureWindowRefreshResult
        do {
            refresh = try await windowProvider.resolveSelectedWindowForCapture(expectedWindow)
        } catch {
            if let captureError = error as? CaptureCoreError,
               captureError == .permissionDenied {
                permission = .denied
                throw CaptureCoreError.permissionDenied
            }
            throw CaptureCoreError.providerFailed(String(describing: error))
        }
        guard case let .available(window) = refresh,
              window.hasSameOwner(as: expectedWindow),
              window.eligible else {
            throw CaptureCoreError.windowUnavailable
        }

        try await startResolvedWindow(window)
    }

    private func prepareForStart() {
        if case let .failed(failure) = state {
            // A capture/provider failure invalidates the current selection,
            // but it must not permanently close the shared frame stream. The
            // Host reuses this actor after a permission recovery, window
            // replacement, or reconnect, so a later start must be allowed to
            // establish a fresh generation on the same stream.
            state = .stopped(failure)
        }
    }

    private func startResolvedWindow(_ window: CaptureWindow) async throws {
        await stop()
        generation &+= 1
        let sessionGeneration = generation
        // A fresh stream per generation: a consumer cancelled during the
        // previous pipeline must not terminate frame delivery for this one.
        frameChannel.replace()
        let newEngine = engineFactory.makeEngine()
        let relayTermination = CaptureRelayTermination()
        selectedWindow = window
        captureEngineWindow = window
        consecutiveSelectionMisses = 0
        captureRestartAttempts = 0
        // The engine sizes its stream from this same window value, so the
        // dimensions are pinned here for the whole generation.
        outputDimensions = configuration.outputDimensions(for: window)
        state = .starting(windowIdentifier: window.identifier, generation: sessionGeneration)
        engine = newEngine
        startRelay(
            for: newEngine,
            generation: sessionGeneration,
            termination: relayTermination
        )

        do {
            try await newEngine.start(window: window, generation: sessionGeneration)
        } catch {
            guard owns(engine: newEngine, windowIdentifier: window.identifier, generation: sessionGeneration) else {
                await newEngine.stop()
                throw error
            }
            await fail(.captureFailed(String(describing: error)))
            throw error
        }

        guard owns(engine: newEngine, windowIdentifier: window.identifier, generation: sessionGeneration) else {
            if case let .failed(failure) = state {
                throw CaptureCoreError.sessionFailed(failure)
            }
            await newEngine.stop()
            return
        }
        if let failure = relayTermination.completeStartup() {
            await fail(failure)
            throw CaptureCoreError.sessionFailed(failure)
        }
        state = .capturing(windowIdentifier: window.identifier, generation: sessionGeneration)
        startMonitor(generation: sessionGeneration)
    }

    public func stop() async {
        let stoppingGeneration = generation
        frameGenerationGate.advance(to: generation &+ 1)
        recoveryTask?.cancel()
        recoveryTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        consecutiveSelectionMisses = 0
        relayTask?.cancel()
        relayTask = nil
        let activeEngine = engine
        engine = nil
        guard activeEngine != nil || selectedWindow != nil else {
            if case .failed = state {
                return
            }
            state = .stopped(nil)
            return
        }
        state = .stopping
        await activeEngine?.stop()
        guard generation == stoppingGeneration else { return }
        selectedWindow = nil
        captureEngineWindow = nil
        outputDimensions = nil
        state = .stopped(.cancelled)
    }

    /// Rechecks permission and the selected window. The Host can call this
    /// after a permission notification or from the bounded monitor task.
    public func refreshSelection() async {
        let windowIdentifier: UInt64
        let sessionGeneration: UInt64
        let isRecovering: Bool
        switch state {
        case let .capturing(identifier, currentGeneration):
            windowIdentifier = identifier
            sessionGeneration = currentGeneration
            isRecovering = false
        case let .recovering(identifier, currentGeneration):
            windowIdentifier = identifier
            sessionGeneration = currentGeneration
            isRecovering = true
        default:
            return
        }
        permission = await windowProvider.permissionState()
        guard isCapturing(generation: sessionGeneration) else { return }
        guard permission == .authorized else {
            await fail(.permissionDenied)
            return
        }
        // The dedicated restart lookup revalidates the previously authorized
        // descriptor without requiring isActive. A normal liveness lookup can
        // report false precisely because the stream has ended, so it must not
        // consume the target-miss budget while recovery is in progress.
        guard !isRecovering else { return }
        do {
            guard let activeWindow = selectedWindow,
                  activeWindow.identifier == windowIdentifier else {
                return
            }
            let result = try await windowProvider.refreshSelectedWindow(activeWindow)
            guard isCapturing(generation: sessionGeneration) else { return }
            switch result {
            case let .available(selected):
                guard selected.hasSameOwner(as: activeWindow), selected.eligible else {
                    await fail(.windowUnavailable)
                    return
                }
                consecutiveSelectionMisses = 0
                selectedWindow = selected
            case .ownerMismatch:
                await fail(.windowUnavailable)
                return
            case .unavailable:
                await recordSelectionMiss(
                    .windowUnavailable,
                    window: activeWindow,
                    generation: sessionGeneration
                )
                return
            }
        } catch {
            guard isCapturing(generation: sessionGeneration) else { return }
            if let captureError = error as? CaptureCoreError,
               captureError == .permissionDenied {
                permission = .denied
                await fail(.permissionDenied)
            } else if let activeWindow = selectedWindow {
                await recordSelectionMiss(
                    .providerFailed(String(describing: error)),
                    window: activeWindow,
                    generation: sessionGeneration
                )
            }
        }
    }

    /// Counts a liveness miss toward the bounded target-loss budget. A target
    /// that WindowServer still lists for the same live owner is only
    /// temporarily uncapturable: an inactive, hidden, or minimized selected app
    /// must remain viewable in the session rather than ending it.
    private func recordSelectionMiss(
        _ failure: CaptureFailure,
        window: CaptureWindow,
        generation: UInt64
    ) async {
        guard isCapturing(generation: generation) else { return }
        let stillExists = await windowProvider.selectedWindowStillExists(window)
        guard isCapturing(generation: generation) else { return }
        if stillExists {
            consecutiveSelectionMisses = 0
            return
        }
        consecutiveSelectionMisses += 1
        guard consecutiveSelectionMisses >= Self.maximumConsecutiveSelectionMisses else {
            return
        }
        await fail(failure)
    }

    private func startRelay(
        for engine: any WindowCaptureEngine,
        generation: UInt64,
        termination: CaptureRelayTermination
    ) {
        relayTask?.cancel()
        relayTask = Task { [weak self] in
            do {
                for try await frame in engine.frames {
                    await self?.receive(frame, generation: generation)
                }
                let failure = CaptureFailure.captureFailed("capture stream ended during startup")
                termination.markTerminated(failure)
                await self?.engineEnded(generation: generation, startupFailure: failure)
            } catch {
                let failure = CaptureFailure.captureFailed(String(describing: error))
                termination.markTerminated(failure)
                await self?.relayFailed(
                    failure,
                    engine: engine,
                    generation: generation
                )
            }
        }
    }

    private func startMonitor(generation: UInt64) {
        monitorTask?.cancel()
        guard configuration.monitorIntervalNanoseconds > 0 else { return }
        let interval = configuration.monitorIntervalNanoseconds
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard let self else { return }
                guard await self.isCapturing(generation: generation) else { return }
                await self.refreshSelection()
            }
        }
    }

    private func isCapturing(generation: UInt64) -> Bool {
        switch state {
        case let .capturing(_, currentGeneration), let .recovering(_, currentGeneration):
            return currentGeneration == generation
        default:
            return false
        }
    }

    private func receive(_ frame: CapturedFrame, generation: UInt64) {
        guard case let .capturing(windowIdentifier, currentGeneration) = state,
              currentGeneration == generation,
              frame.generation == generation,
              frame.windowIdentifier == windowIdentifier else {
            return
        }
        // A delivered frame proves the stream recovered; later interruptions
        // get a fresh bounded restart budget instead of sharing one for the
        // whole selection.
        captureRestartAttempts = 0
        frameChannel.yield(frame)
    }

    private func engineEnded(
        generation: UInt64,
        startupFailure: CaptureFailure
    ) async {
        guard generation == self.generation else {
            return
        }
        if case .starting = state {
            await fail(startupFailure)
            return
        }
        guard isCapturing(generation: generation) else {
            return
        }
        await scheduleCaptureRestart(
            .captureFailed("capture stream ended unexpectedly"),
            generation: generation
        )
    }

    private func relayFailed(
        _ failure: CaptureFailure,
        engine failedEngine: any WindowCaptureEngine,
        generation failedGeneration: UInt64
    ) async {
        guard owns(engine: failedEngine, generation: failedGeneration) else {
            await failedEngine.stop()
            return
        }
        if case .starting = state {
            await fail(failure)
        } else {
            await scheduleCaptureRestart(failure, generation: failedGeneration)
        }
    }

    private func scheduleCaptureRestart(_ failure: CaptureFailure, generation failedGeneration: UInt64) async {
        guard isCapturing(generation: failedGeneration),
              generation == failedGeneration else {
            return
        }
        guard captureRestartAttempts < Self.maximumCaptureRestartAttempts,
              let selectedWindow else {
            await fail(failure)
            return
        }

        captureRestartAttempts += 1
        let nextGeneration = failedGeneration &+ 1
        generation = nextGeneration
        frameGenerationGate.advance(to: nextGeneration)
        state = .recovering(
            windowIdentifier: selectedWindow.identifier,
            generation: nextGeneration
        )
        let endedEngine = engine
        engine = nil
        relayTask = nil
        frameChannel.replace()
        monitorTask?.cancel()
        startMonitor(generation: nextGeneration)

        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.captureRestartDelayNanoseconds)
            } catch {
                return
            }
            await self?.recoverCaptureEngine(generation: nextGeneration)
        }
        await endedEngine?.stop()
    }

    private func recoverCaptureEngine(generation recoveryGeneration: UInt64) async {
        guard isRecovering(generation: recoveryGeneration),
              let expectedWindow = selectedWindow else {
            return
        }
        permission = await windowProvider.permissionState()
        guard isRecovering(generation: recoveryGeneration) else { return }
        guard permission == .authorized else {
            await fail(.permissionDenied)
            return
        }

        let refreshed: CaptureWindow
        do {
            switch try await windowProvider.resolveSelectedWindowForCapture(expectedWindow) {
            case let .available(window):
                guard window.hasSameOwner(as: expectedWindow), window.eligible else {
                    await fail(.windowUnavailable)
                    return
                }
                refreshed = window
            case .ownerMismatch:
                await fail(.windowUnavailable)
                return
            case .unavailable:
                await continueRecovery(after: .windowUnavailable, generation: recoveryGeneration)
                return
            }
        } catch {
            guard isRecovering(generation: recoveryGeneration) else { return }
            if let captureError = error as? CaptureCoreError,
               captureError == .permissionDenied {
                permission = .denied
                await fail(.permissionDenied)
            } else {
                await continueRecovery(
                    after: .providerFailed(String(describing: error)),
                    generation: recoveryGeneration
                )
            }
            return
        }
        guard isRecovering(generation: recoveryGeneration) else { return }
        selectedWindow = refreshed
        let engineWindow = captureEngineWindow ?? expectedWindow

        let newEngine = engineFactory.makeEngine()
        let relayTermination = CaptureRelayTermination()
        engine = newEngine
        startRelay(
            for: newEngine,
            generation: recoveryGeneration,
            termination: relayTermination
        )

        do {
            try await newEngine.start(window: engineWindow, generation: recoveryGeneration)
        } catch {
            guard isRecovering(generation: recoveryGeneration),
                  let currentEngine = engine,
                  currentEngine === newEngine else {
                await newEngine.stop()
                return
            }
            await continueRecovery(
                after: .captureFailed(String(describing: error)),
                generation: recoveryGeneration
            )
            return
        }
        guard isRecovering(generation: recoveryGeneration),
              let currentEngine = engine,
              currentEngine === newEngine else {
            await newEngine.stop()
            return
        }
        if let startupFailure = relayTermination.completeStartup() {
            await continueRecovery(after: startupFailure, generation: recoveryGeneration)
            return
        }
        state = .capturing(
            windowIdentifier: refreshed.identifier,
            generation: recoveryGeneration
        )
        recoveryTask = nil
        startMonitor(generation: recoveryGeneration)
    }

    /// A recovery attempt that could not capture the target consumes the
    /// bounded restart budget only when the target is really gone. While
    /// WindowServer still lists the selected window for its live owner, the
    /// session stays recovering and retries on a slower cadence.
    private func continueRecovery(
        after failure: CaptureFailure,
        generation recoveryGeneration: UInt64
    ) async {
        guard isRecovering(generation: recoveryGeneration),
              let expectedWindow = selectedWindow else { return }
        let stillExists = await windowProvider.selectedWindowStillExists(expectedWindow)
        guard isRecovering(generation: recoveryGeneration) else { return }
        guard stillExists else {
            await scheduleCaptureRestart(failure, generation: recoveryGeneration)
            return
        }
        let failedEngine = engine
        engine = nil
        relayTask?.cancel()
        relayTask = nil
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.unavailableTargetRetryNanoseconds)
            } catch {
                return
            }
            await self?.recoverCaptureEngine(generation: recoveryGeneration)
        }
        await failedEngine?.stop()
    }

    private func isRecovering(generation: UInt64) -> Bool {
        guard case let .recovering(_, currentGeneration) = state else { return false }
        return currentGeneration == generation
    }

    private func owns(
        engine candidate: any WindowCaptureEngine,
        windowIdentifier: UInt64,
        generation candidateGeneration: UInt64
    ) -> Bool {
        guard generation == candidateGeneration,
              state == .starting(
                  windowIdentifier: windowIdentifier,
                  generation: candidateGeneration
              ),
              let engine else {
            return false
        }
        return engine === candidate
    }

    private func owns(
        engine candidate: any WindowCaptureEngine,
        generation candidateGeneration: UInt64
    ) -> Bool {
        guard generation == candidateGeneration,
              let engine,
              engine === candidate else {
            return false
        }
        switch state {
        case let .starting(_, currentGeneration),
             let .capturing(_, currentGeneration),
             let .recovering(_, currentGeneration):
            return currentGeneration == candidateGeneration
        default:
            return false
        }
    }

    private func fail(_ failure: CaptureFailure) async {
        let failedGeneration = generation
        frameGenerationGate.advance(to: failedGeneration &+ 1)
        recoveryTask?.cancel()
        recoveryTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        relayTask?.cancel()
        relayTask = nil
        let activeEngine = engine
        engine = nil
        state = .failed(failure)
        await activeEngine?.stop()
        guard generation == failedGeneration else { return }
        selectedWindow = nil
        captureEngineWindow = nil
        outputDimensions = nil
        // End only this generation's stream so a waiting consumer observes
        // the failure instead of waiting forever. `frames` stays reusable:
        // the next start installs a fresh generation stream.
        frameChannel.finishCurrent(throwing: CaptureCoreError.sessionFailed(failure))
    }
}

private final class CaptureRelayTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var termination: CaptureFailure?
    private var startupCompleted = false

    /// Records relay termination and races with startup completion under one
    /// lock. The first terminal result is retained for the startup caller.
    @discardableResult
    func markTerminated(_ failure: CaptureFailure) -> Bool {
        lock.withLock {
            if termination == nil {
                termination = failure
            }
            return startupCompleted
        }
    }

    /// Claims the transition from starting to capturing. A relay that won the
    /// race first returns its exact failure instead, so start() cannot report a
    /// live capture for an already terminated stream. Once this claim wins, a
    /// later relay termination is a post-start stop rather than a stale
    /// failure of the startup operation.
    func completeStartup() -> CaptureFailure? {
        lock.withLock {
            if let termination {
                return termination
            }
            startupCompleted = true
            return nil
        }
    }
}
