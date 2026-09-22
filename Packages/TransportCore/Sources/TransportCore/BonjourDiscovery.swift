@preconcurrency import Network
import Foundation
import RemoteProtocol

public protocol BonjourDiscovery: AnyObject, Sendable {
    var updates: AsyncStream<[DiscoveredService]> { get }

    func start()
    func cancel()
}

public final class NetworkBonjourDiscovery: BonjourDiscovery, @unchecked Sendable {
    public let updates: AsyncStream<[DiscoveredService]>

    private let browser: NWBrowser
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var continuation: AsyncStream<[DiscoveredService]>.Continuation?
    private var isCancelled = false

    public init(
        configuration: BonjourConfiguration = .default,
        callbackQueue: DispatchQueue = DispatchQueue(label: "MacRemoteApp.BonjourDiscovery")
    ) {
        let stream = AsyncStream<[DiscoveredService]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.updates = stream.stream
        self.continuation = stream.continuation
        self.callbackQueue = callbackQueue

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        self.browser = NWBrowser(
            for: .bonjour(type: configuration.serviceType, domain: configuration.domain),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.finish()
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results: results)
        }
    }

    public func start() {
        lock.lock()
        let shouldStart = !isCancelled
        lock.unlock()
        guard shouldStart else { return }
        browser.start(queue: callbackQueue)
    }

    public func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
        browser.cancel()
        finish()
    }

    private func publish(results: Set<NWBrowser.Result>) {
        let services = results.compactMap(Self.service(from:)).sorted {
            $0.identifier < $1.identifier
        }
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        continuation?.yield(services)
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }

    private static func service(from result: NWBrowser.Result) -> DiscoveredService? {
        guard case let .service(name, type, domain, _) = result.endpoint else {
            return nil
        }
        return DiscoveredService(
            identifier: "\(name)|\(type)|\(domain)",
            name: name,
            type: type,
            domain: domain,
            endpoint: result.endpoint
        )
    }
}

public final class InMemoryBonjourDiscovery: BonjourDiscovery, @unchecked Sendable {
    public let updates: AsyncStream<[DiscoveredService]>

    private let lock = NSLock()
    private var continuation: AsyncStream<[DiscoveredService]>.Continuation?
    private var isCancelled = false

    public init() {
        let stream = AsyncStream<[DiscoveredService]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.updates = stream.stream
        self.continuation = stream.continuation
    }

    public func start() {}

    public func publish(_ services: [DiscoveredService]) {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        continuation?.yield(services.sorted { $0.identifier < $1.identifier })
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        isCancelled = true
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }
}

public enum BonjourListenerState: Sendable, Equatable {
    case setup
    case waiting
    case ready
    case failed(String)
    case cancelled
}

public enum BonjourListenerStartupError: Error, CustomStringConvertible, Sendable {
    case failed(String)
    case cancelled
    case timedOut

    public var description: String {
        switch self {
        case let .failed(code):
            return "Bonjour listener failed to publish the Host service (\(code))"
        case .cancelled:
            return "Bonjour listener was cancelled before it became ready"
        case .timedOut:
            return "Bonjour listener did not become ready before the startup deadline"
        }
    }
}

public final class NetworkBonjourListener: @unchecked Sendable {
    private let listener: NWListener
    private let callbackQueue: DispatchQueue
    private let limits: ProtocolLimits
    private let authentication: PeerAuthenticationState
    private let tlsOptions: TLSOptions

    public var onConnection: (@Sendable (NetworkFramedTransport) -> Void)?
    public var onStateUpdate: (@Sendable (BonjourListenerState) -> Void)?

    private static func failureCode(for error: NWError) -> String {
        let description = String(describing: error).lowercased()
        if description.contains("posix") {
            return "posix"
        }
        if description.contains("dns") {
            return "dns"
        }
        if description.contains("tls") {
            return "tls"
        }
        return "network"
    }

    public init(
        serviceName: String,
        configuration: BonjourConfiguration = .default,
        tlsOptions: TLSOptions,
        limits: ProtocolLimits = .default,
        authentication: PeerAuthenticationState,
        callbackQueue: DispatchQueue = DispatchQueue(label: "MacRemoteApp.BonjourListener")
    ) throws {
        self.limits = limits
        self.authentication = authentication
        self.tlsOptions = tlsOptions
        self.callbackQueue = callbackQueue

        let listener = try NWListener(using: tlsOptions.makeParameters())
        listener.service = NWListener.Service(name: serviceName, type: configuration.serviceType, domain: configuration.domain)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            let mappedState: BonjourListenerState
            switch state {
            case .setup:
                mappedState = .setup
            case .waiting:
                mappedState = .waiting
            case .ready:
                mappedState = .ready
            case let .failed(error):
                mappedState = .failed(Self.failureCode(for: error))
            case .cancelled:
                mappedState = .cancelled
            @unknown default:
                mappedState = .failed("unknown")
            }
            self?.onStateUpdate?(mappedState)
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            let connectionTLSOptions = self.tlsOptions.connectionScoped()
            guard let transport = try? NetworkFramedTransport(
                connection: connection,
                tlsOptions: connectionTLSOptions,
                limits: self.limits,
                authentication: self.authentication
            ) else {
                connection.cancel()
                return
            }
            self.onConnection?(transport)
            Task {
                try? await transport.start()
            }
        }
    }

    public func start() {
        listener.start(queue: callbackQueue)
    }

    /// Starts Bonjour and waits until Network.framework reports a terminal
    /// startup state. Waiting for readiness lets the Host sequence Local
    /// Network consent before asking for Screen Recording, and it also makes
    /// listener publication failures visible to the app lifecycle. The Host
    /// uses the two-minute default so macOS has time to present Local Network
    /// consent, while a stalled `.waiting` state still produces recoverable
    /// startup guidance instead of hanging forever. Pass `nil` only for an
    /// explicitly unbounded diagnostic wait.
    public func startAndWaitForReadiness(
        timeoutNanoseconds: UInt64? = 120_000_000_000
    ) async throws {
        let stateStream = AsyncStream<BonjourListenerState>.makeStream()
        onStateUpdate = { state in
            stateStream.continuation.yield(state)
        }
        defer {
            stateStream.continuation.finish()
            onStateUpdate = nil
        }

        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            start()
            enum StartupWaitResult: Sendable {
                case state(BonjourListenerState)
                case timedOut
                case cancelled
            }
            let result = await withTaskGroup(of: StartupWaitResult.self) { group in
                group.addTask {
                    guard let state = await stateStream.stream.first(where: {
                        switch $0 {
                        case .ready, .failed(_), .cancelled:
                            return true
                        case .setup, .waiting:
                            return false
                        }
                    }) else {
                        return .cancelled
                    }
                    return .state(state)
                }
                if let timeoutNanoseconds {
                    group.addTask {
                        do {
                            try await Task.sleep(nanoseconds: timeoutNanoseconds)
                            return .timedOut
                        } catch {
                            return .cancelled
                        }
                    }
                }
                let firstResult = await group.next() ?? .cancelled
                group.cancelAll()
                return firstResult
            }
            try Task.checkCancellation()
            switch result {
            case let .state(state):
                switch state {
                case .ready:
                    return
                case let .failed(code):
                    cancel()
                    throw BonjourListenerStartupError.failed(code)
                case .cancelled:
                    throw BonjourListenerStartupError.cancelled
                case .setup, .waiting:
                    throw BonjourListenerStartupError.failed("unexpected-state")
                }
            case .timedOut:
                cancel()
                throw BonjourListenerStartupError.timedOut
            case .cancelled:
                throw BonjourListenerStartupError.cancelled
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    public func cancel() {
        listener.cancel()
    }
}
