import Foundation

/// Which pluggable transport a bridge line speaks.
public enum BridgeTransport: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    /// A plain, unobfuscated bridge — just an unlisted relay.
    case vanilla
    /// obfs4 (lyrebird). Needs a pluggable-transport binary to be registered.
    case obfs4
    /// Snowflake. Needs a pluggable-transport binary to be registered.
    case snowflake

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vanilla: "Plain bridge"
        case .obfs4: "obfs4"
        case .snowflake: "Snowflake"
        }
    }

    public var detail: String {
        switch self {
        case .vanilla:
            "An unlisted relay. Hides which relay you use, not that you use Tor."
        case .obfs4:
            "Disguises Tor traffic as random noise. The usual choice where Tor is blocked."
        case .snowflake:
            "Bounces through short-lived volunteer proxies. Good where bridges are also blocked."
        }
    }

    /// Whether this transport needs an external pluggable-transport provider.
    ///
    /// `vanilla` is spoken by Tor itself; the obfuscating transports are
    /// separate binaries Tor launches or dials via `ClientTransportPlugin`.
    public var requiresTransportProvider: Bool { self != .vanilla }
}

/// One parsed bridge line.
public struct BridgeLine: Sendable, Hashable, Codable, Identifiable {
    public let transport: BridgeTransport
    public let address: String
    public let port: UInt16
    public let fingerprint: String?
    /// Trailing `key=value` parameters (`cert=…`, `iat-mode=…`, `url=…`).
    public let parameters: [String: String]
    /// The original line, preserved verbatim so we hand Tor exactly what the
    /// user was given by BridgeDB.
    public let rawValue: String

    public var id: String { rawValue }

    public init(
        transport: BridgeTransport,
        address: String,
        port: UInt16,
        fingerprint: String?,
        parameters: [String: String],
        rawValue: String
    ) {
        self.transport = transport
        self.address = address
        self.port = port
        self.fingerprint = fingerprint
        self.parameters = parameters
        self.rawValue = rawValue
    }

    /// The `Bridge` torrc directive value for this line.
    public var torrcValue: String { rawValue }
}

/// The user's bridge configuration.
///
/// Applied at Tor start-up only. The embedded Tor library keeps process-global
/// state and cannot be restarted in-process, so changing this mid-session
/// requires a relaunch — see `TorKit.TorService`.
public struct BridgeConfig: Sendable, Hashable, Codable {
    public var isEnabled: Bool
    public var transport: BridgeTransport
    public var lines: [BridgeLine]

    public init(isEnabled: Bool = false, transport: BridgeTransport = .obfs4, lines: [BridgeLine] = []) {
        self.isEnabled = isEnabled
        self.transport = transport
        self.lines = lines
    }

    /// Bridges only actually take effect when enabled *and* usable.
    ///
    /// Snowflake is the exception: it ships with a built-in default bridge, so
    /// an empty line list is still valid there.
    public var isEffective: Bool {
        guard isEnabled else { return false }
        return !lines.isEmpty || transport == .snowflake
    }

    public static let disabled = BridgeConfig()
}
