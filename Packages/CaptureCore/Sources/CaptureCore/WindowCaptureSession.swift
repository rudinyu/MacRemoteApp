import Foundation

public actor WindowCaptureSession {
    public nonisolated let frames: CapturedFrameStream

    private let frameContinuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    private let frameGenerationGate: CapturedFrameGenerationGate
    private let windowProvider: any WindowDiscoveryProvider
    private let engineFactory: any WindowCaptureEngineFactory
    private let configuration: CaptureConfiguration

    private var state: CaptureSessionState = .idle
    private var selectedWindow: CaptureWindow?
    private var generation: UInt64 = 0
    private var permission: CapturePermissionState = .denied
    private var engine: (any WindowCaptureEngine)?
    private var relayTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    public init(
        windowProvider: any WindowDiscoveryProvider,
        engineFactory: (any WindowCaptureEngineFactory)? = nil,
        configuration: CaptureConfiguration = .default
    ) {
        let output = AsyncThrowingStream<CapturedFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, configuration.outputBufferCount))
        )
        let generationGate = CapturedFrameGenerationGate()
        self.frames = CapturedFrameStream(stream: output.stream, generationGate: generationGate)
        self.frameContinuation = output.continuation
        self.frameGenerationGate = generationGate
        self.windowProvider = windowProvider
        self.configuration = configuration
        self.engineFactory = engineFactory ?? SystemWindowCaptureEngineFactory(configuration: configuration)
    }

    deinit {
        relayTask?.cancel()
        monitorTask?.cancel()
        frameContinuation.finish()
    }

    public func snapshot() -> CaptureSessionSnapshot {
        CaptureSessionSnapshot(
            state: state,
            selectedWindow: selectedWindow,
            generation: generation,
            permission: permission
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
        if case let .failed(failure) = state {
            throw CaptureCoreError.sessionFailed(failure)
        }
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

        await stop()
        generation &+= 1
        let sessionGeneration = generation
        let newEngine = engineFactory.makeEngine()
        let relayTermination = CaptureRelayTermination()
        selectedWindow = window
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
        frameGenerationGate.advance(to: generation &+ 1)
        monitorTask?.cancel()
        monitorTask = nil
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
        selectedWindow = nil
        state = .stopped(.cancelled)
    }

    /// Rechecks permission and the selected window. The Host can call this
    /// after a permission notification or from the bounded monitor task.
    public func refreshSelection() async {
        guard case let .capturing(windowIdentifier, sessionGeneration) = state else {
            return
        }
        permission = await windowProvider.permissionState()
        guard isCapturing(generation: sessionGeneration) else { return }
        guard permission == .authorized else {
            await fail(.permissionDenied)
            return
        }
        do {
            let windows = try await windowProvider.discoverWindows()
            guard isCapturing(generation: sessionGeneration) else { return }
            guard let activeWindow = selectedWindow,
                  activeWindow.identifier == windowIdentifier else {
                return
            }
            guard let selected = windows.first(where: {
                $0.identifier == windowIdentifier &&
                    $0.hasSameOwner(as: activeWindow) &&
                    $0.eligible
            }) else {
                await fail(.windowUnavailable)
                return
            }
            selectedWindow = selected
            guard generation == sessionGeneration else { return }
        } catch {
            guard isCapturing(generation: sessionGeneration) else { return }
            await fail(.providerFailed(String(describing: error)))
        }
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
        guard case let .capturing(_, currentGeneration) = state else { return false }
        return currentGeneration == generation
    }

    private func receive(_ frame: CapturedFrame, generation: UInt64) {
        guard case let .capturing(windowIdentifier, currentGeneration) = state,
              currentGeneration == generation,
              frame.generation == generation,
              frame.windowIdentifier == windowIdentifier else {
            return
        }
        _ = frameContinuation.yield(frame)
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
        guard case let .capturing(_, currentGeneration) = state,
              currentGeneration == generation else {
            return
        }
        engine = nil
        relayTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        state = .stopped(nil)
        selectedWindow = nil
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
        await fail(failure)
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
        case let .starting(_, currentGeneration), let .capturing(_, currentGeneration):
            return currentGeneration == candidateGeneration
        default:
            return false
        }
    }

    private func fail(_ failure: CaptureFailure) async {
        frameGenerationGate.advance(to: generation &+ 1)
        monitorTask?.cancel()
        monitorTask = nil
        relayTask?.cancel()
        relayTask = nil
        let activeEngine = engine
        engine = nil
        state = .failed(failure)
        await activeEngine?.stop()
        frameContinuation.finish(throwing: failure)
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
