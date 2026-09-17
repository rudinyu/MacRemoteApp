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
        selectedWindow = window
        state = .starting(windowIdentifier: window.identifier, generation: sessionGeneration)
        engine = newEngine
        startRelay(for: newEngine, generation: sessionGeneration)

        do {
            try await newEngine.start(window: window, generation: sessionGeneration)
        } catch {
            await fail(.captureFailed(String(describing: error)))
            throw error
        }

        guard generation == sessionGeneration,
              state == .starting(windowIdentifier: window.identifier, generation: sessionGeneration) else {
            await newEngine.stop()
            return
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
        generation: UInt64
    ) {
        relayTask?.cancel()
        relayTask = Task { [weak self] in
            do {
                for try await frame in engine.frames {
                    await self?.receive(frame, generation: generation)
                }
                await self?.engineEnded(generation: generation)
            } catch {
                await self?.fail(.captureFailed(String(describing: error)))
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

    private func engineEnded(generation: UInt64) {
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

    private func fail(_ failure: CaptureFailure) async {
        frameGenerationGate.advance(to: generation &+ 1)
        monitorTask?.cancel()
        monitorTask = nil
        relayTask?.cancel()
        relayTask = nil
        let activeEngine = engine
        engine = nil
        await activeEngine?.stop()
        state = .failed(failure)
        frameContinuation.finish(throwing: failure)
    }
}
