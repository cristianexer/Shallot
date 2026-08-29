import Domain
import Foundation

/// Supplies the obfuscating pluggable transports Tor cannot speak on its own.
///
/// obfs4 and Snowflake are separate programs written in Go. On iOS they are
/// linked in as a framework (IPtProxy is the usual one) and run in-process,
/// listening on a loopback SOCKS port that Tor is then told to dial with
/// `ClientTransportPlugin <name> socks5 127.0.0.1:<port>`.
///
/// Shallot does not bundle that framework — it is a ~140 MB binary and the
/// decision to add it belongs to whoever ships the app. The seam is here so
/// that adding it is a one-line change in `AppContainer`:
///
/// ```swift
/// torConfiguration.transportProvider = IPtProxyTransportProvider()
/// ```
///
/// Until one is registered, plain bridges work in full and the obfuscating
/// transports are shown in Settings as unavailable, with the reason — rather
/// than being offered and then quietly failing to connect.
public protocol PluggableTransportProviding: Sendable {
    /// Whether this provider can run `transport`.
    func supports(_ transport: BridgeTransport) -> Bool

    /// Starts `transport` and returns the loopback SOCKS5 port Tor should dial.
    func start(_ transport: BridgeTransport) async throws -> UInt16

    /// Stops any running transport.
    func stop() async
}

extension PluggableTransportProviding {
    /// The `ClientTransportPlugin` torrc value for a running transport.
    func clientTransportPluginValue(for transport: BridgeTransport, port: UInt16) -> String {
        "\(transport.rawValue) socks5 127.0.0.1:\(port)"
    }
}

/// Which transports are actually usable in this build.
public enum TransportAvailability {
    /// - Returns: `true` when `transport` can be used right now.
    public static func isAvailable(_ transport: BridgeTransport, provider: (any PluggableTransportProviding)?) -> Bool {
        guard transport.requiresTransportProvider else { return true }
        guard let provider else { return false }
        return provider.supports(transport)
    }

    /// Why a transport is unavailable, for the Settings row.
    public static func unavailableReason(for transport: BridgeTransport) -> String {
        "\(transport.title) needs a pluggable-transport binary, which this build does not include. Plain bridges work without one."
    }
}
