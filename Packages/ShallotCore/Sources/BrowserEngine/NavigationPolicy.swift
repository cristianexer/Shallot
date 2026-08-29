import Domain
import Foundation

/// Why a navigation was refused.
public enum NavigationBlockReason: Sendable, Equatable {
    /// Tor is not carrying traffic. The kill switch.
    case torNotRunning
    /// A scheme we will not hand to the web view (`file:`, `data:`, `javascript:`…).
    case disallowedScheme(String)
    /// An onion address that is not a valid v3 one.
    case invalidOnionAddress(String)
    /// HTTPS-only is on and this URL cannot be served securely.
    case insecureConnection
    /// No host to connect to.
    case missingHost

    /// What the error page tells the user.
    public var title: String {
        switch self {
        case .torNotRunning: "Not connected to Tor"
        case .disallowedScheme: "Blocked"
        case .invalidOnionAddress: "Not a valid onion address"
        case .insecureConnection: "Connection is not secure"
        case .missingHost: "Nothing to load"
        }
    }

    public var detail: String {
        switch self {
        case .torNotRunning:
            "Shallot will not load anything until Tor is carrying traffic — otherwise the request would go out over your ordinary connection and reveal your address."
        case .disallowedScheme(let scheme):
            "Shallot only opens http and https addresses. ‘\(scheme)’ can reach outside the Tor connection."
        case .invalidOnionAddress(let host):
            "‘\(host)’ is not a valid v3 onion address. It may be a typo, or an old v2 address that no longer exists."
        case .insecureConnection:
            "HTTPS-only is on and this site does not offer a secure connection. Turn HTTPS-only off in Settings if you accept the risk."
        case .missingHost:
            "That address has no site in it."
        }
    }

    /// The line written to the Monitor's event log.
    public var eventMessage: String {
        switch self {
        case .torNotRunning: "load blocked · tor not running"
        case .disallowedScheme(let scheme): "load blocked · scheme \(scheme)"
        case .invalidOnionAddress(let host): "load blocked · invalid onion \(host)"
        case .insecureConnection: "load blocked · no https available"
        case .missingHost: "load blocked · no host"
        }
    }

    public var eventKind: SecurityEvent.Kind {
        switch self {
        case .torNotRunning: .killSwitch
        case .disallowedScheme, .invalidOnionAddress, .missingHost: .leakBlocked
        case .insecureConnection: .leakBlocked
        }
    }
}

/// What to do with a navigation.
public enum NavigationDecision: Sendable, Equatable {
    case allow
    /// Cancel this one and load the upgraded URL instead.
    case upgrade(to: URL)
    case block(NavigationBlockReason)
}

/// The rules every request is measured against, expressed as pure functions.
///
/// Deliberately free of WebKit types so the security-critical decisions —
/// above all the kill switch — are tested directly rather than through a live
/// web view.
public enum NavigationPolicy {
    /// Inputs to a decision.
    public struct Context: Sendable, Equatable {
        public var url: URL
        public var isMainFrame: Bool
        /// Whether Tor is bootstrapped and carrying traffic.
        public var torCanCarryTraffic: Bool
        public var httpsOnly: Bool
        /// Set when we have already tried upgrading this URL, so a site that
        /// has no HTTPS listener produces a clear error instead of a loop.
        public var upgradeAlreadyAttempted: Bool

        public init(
            url: URL,
            isMainFrame: Bool = true,
            torCanCarryTraffic: Bool,
            httpsOnly: Bool = true,
            upgradeAlreadyAttempted: Bool = false
        ) {
            self.url = url
            self.isMainFrame = isMainFrame
            self.torCanCarryTraffic = torCanCarryTraffic
            self.httpsOnly = httpsOnly
            self.upgradeAlreadyAttempted = upgradeAlreadyAttempted
        }
    }

    /// Schemes WebKit uses internally that carry no network traffic.
    static let inertSchemes: Set<String> = ["about"]

    public static func decide(_ context: Context) -> NavigationDecision {
        let scheme = context.url.scheme?.lowercased() ?? ""

        // `about:blank` is how WebKit initialises a frame. It reaches no
        // network, so it is allowed even before Tor is up — otherwise the very
        // first frame of every tab would be refused.
        if inertSchemes.contains(scheme) { return .allow }

        // The kill switch, checked before anything else and for every frame.
        // If Tor is not carrying traffic, nothing leaves this device.
        guard context.torCanCarryTraffic else { return .block(.torNotRunning) }

        guard URLNormalizer.allowedSchemes.contains(scheme) else {
            return .block(.disallowedScheme(scheme.isEmpty ? "unknown" : scheme))
        }

        guard let host = context.url.host(), !host.isEmpty else {
            return .block(.missingHost)
        }

        if OnionAddress.isRejectedOnion(host) {
            return .block(.invalidOnionAddress(host))
        }

        if scheme == "http", context.httpsOnly, !OnionAddress.isOnion(host) {
            if context.upgradeAlreadyAttempted { return .block(.insecureConnection) }
            guard let upgraded = URLNormalizer.httpsUpgrade(for: context.url) else {
                return .block(.insecureConnection)
            }
            return .upgrade(to: upgraded)
        }

        return .allow
    }

    /// The security badge for a loaded URL.
    public static func security(for url: URL?) -> ConnectionSecurity {
        guard let url, let host = url.host() else { return .none }
        if OnionAddress.isOnion(host) { return OnionAddress.isValidV3(host) ? .onion : .insecure }
        return url.scheme?.lowercased() == "https" ? .secure : .insecure
    }
}
