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

public final class NetworkBonjourListener: @unchecked Sendable {
    private let listener: NWListener
    private let callbackQueue: DispatchQueue
    private let limits: ProtocolLimits
    private let authentication: PeerAuthenticationState
    private let tlsOptions: TLSOptions

    public var onConnection: (@Sendable (NetworkFramedTransport) -> Void)?

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

    public func cancel() {
        listener.cancel()
    }
}
