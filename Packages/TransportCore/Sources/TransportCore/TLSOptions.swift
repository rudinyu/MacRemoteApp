@preconcurrency import Network
import Dispatch
import Foundation
import Security
import SecurityCore

public enum TLSAuthenticationMode: Sendable {
    case trusted(TrustedPeer)
    case pairingBootstrap(expectedPeer: PeerIdentity?)
}

/// Immutable TLS configuration. Authentication state is derived from the
/// connection's negotiated TLS metadata rather than stored in this object, so
/// a Bonjour listener can safely use the same configuration for many peers.
public final class TLSOptions: @unchecked Sendable {
    public let initialAuthentication: PeerAuthenticationState = .pending
    public let peerAuthenticationRequired = true

    private let mode: TLSAuthenticationMode
    private let localIdentity: SecIdentity?
    private let verificationQueue: DispatchQueue

    public init(
        mode: TLSAuthenticationMode,
        localIdentity: SecIdentity? = nil,
        verificationQueue: DispatchQueue = DispatchQueue(label: "MacRemoteApp.TLSVerification")
    ) {
        self.mode = mode
        self.localIdentity = localIdentity
        self.verificationQueue = verificationQueue
    }

    /// Returns a fresh options object for an accepted connection. The mode is
    /// immutable, and the returned object has no mutable authentication state
    /// shared with any other connection.
    public func connectionScoped() -> TLSOptions {
        TLSOptions(
            mode: mode,
            localIdentity: localIdentity,
            verificationQueue: verificationQueue
        )
    }

    public func makeParameters() -> NWParameters {
        let parameters = NWParameters(tls: makeProtocolOptions(), tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    /// Resolves authentication only from the peer identity negotiated by this
    /// connection. A configured trust record is never reported as trusted
    /// before a peer certificate has actually been presented.
    public func resolvedAuthentication(for connection: NWConnection) -> PeerAuthenticationState {
        guard let identity = presentedPeerIdentity(for: connection) else {
            return .pending
        }
        return authentication(for: identity)
    }

    /// Returns the public identity actually presented by a negotiated
    /// connection. This is used by transport verification and is intentionally
    /// limited to the public-key fingerprint; certificate/private-key bytes
    /// are never exposed to callers or diagnostics.
    public func presentedPeerIdentity(for connection: NWConnection) -> PeerIdentity? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata else {
            return nil
        }
        return Self.peerIdentity(from: metadata.securityProtocolMetadata)
    }

    /// Kept intentionally conservative for callers that do not have a
    /// connection. Without negotiated peer metadata the identity is unknown.
    public func resolvedAuthentication() -> PeerAuthenticationState {
        .pending
    }

    private func makeProtocolOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_peer_authentication_required(
            options.securityProtocolOptions,
            true
        )
        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions,
            .TLSv13
        )
        if let localIdentity,
           let identity = sec_identity_create(localIdentity) {
            sec_protocol_options_set_local_identity(
                options.securityProtocolOptions,
                identity
            )
        }
        let mode = mode
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, trust, complete in
                guard let presentedIdentity = Self.peerIdentity(from: trust) else {
                    complete(false)
                    return
                }
                switch mode {
                case let .trusted(trustedPeer):
                    complete(
                        PeerTrustEvaluator().decision(
                            for: presentedIdentity,
                            trustedPeer: trustedPeer
                        ) == .trusted
                    )
                case let .pairingBootstrap(expectedPeer):
                    complete(expectedPeer == nil || expectedPeer == presentedIdentity)
                }
            },
            verificationQueue
        )
        return options
    }

    /// Applies the same fail-closed identity policy used by the TLS verify
    /// block to a peer identity obtained from negotiated connection metadata.
    public func authentication(for presentedIdentity: PeerIdentity) -> PeerAuthenticationState {
        switch mode {
        case let .trusted(trustedPeer):
            guard PeerTrustEvaluator().decision(
                for: presentedIdentity,
                trustedPeer: trustedPeer
            ) == .trusted else {
                return .rejected
            }
            return .trusted(presentedIdentity)
        case let .pairingBootstrap(expectedPeer):
            if let expectedPeer, expectedPeer != presentedIdentity {
                return .rejected
            }
            return .pairingRequired(presentedIdentity)
        }
    }

    private static func peerIdentity(from trust: sec_trust_t) -> PeerIdentity? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let certificate = chain.first,
              let publicKey = SecCertificateCopyKey(certificate) else {
            return nil
        }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }
        return try? PeerIdentity(publicKeyRepresentation: representation)
    }

    private static func peerIdentity(from metadata: sec_protocol_metadata_t) -> PeerIdentity? {
        guard let publicKeyData = sec_protocol_metadata_copy_peer_public_key(metadata) else {
            return nil
        }
        let dispatchData = unsafeBitCast(publicKeyData, to: DispatchData.self)
        guard dispatchData.count > 0 else {
            return nil
        }
        let representation = dispatchData.withUnsafeBytes { (buffer: UnsafePointer<UInt8>) in
            Data(bytes: buffer, count: dispatchData.count)
        }
        return try? PeerIdentity(publicKeyRepresentation: representation)
    }
}
