import Foundation

/// Where the omnibar sends a query that is not a URL.
public enum SearchEngine: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    /// DuckDuckGo's onion service. The default: the query never leaves Tor.
    case duckDuckGoOnion
    case duckDuckGo
    case startpage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .duckDuckGoOnion: "DuckDuckGo (onion)"
        case .duckDuckGo: "DuckDuckGo"
        case .startpage: "Startpage"
        }
    }

    private var searchBase: String {
        switch self {
        case .duckDuckGoOnion:
            "https://duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion/"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .startpage: "https://www.startpage.com/sp/search"
        }
    }

    /// Builds the search URL for `query`.
    public func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: searchBase)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// The engine's home page, opened when the user taps the search shortcut.
    public var homeURL: URL? { URL(string: searchBase) }
}

/// One site the user has deliberately re-enabled a risky feature for.
///
/// The §9 mitigations are on by default and globally. This is the escape hatch:
/// the trade-off stays in the user's hands, per site, and is visible in Settings.
public struct SiteException: Sendable, Hashable, Codable, Identifiable {
    public enum Feature: String, Sendable, Hashable, Codable, CaseIterable {
        case webAuthn
        case webTransport
        case webRTC
        case javaScript

        public var title: String {
            switch self {
            case .webAuthn: "Passkeys (WebAuthn)"
            case .webTransport: "WebTransport"
            case .webRTC: "WebRTC"
            case .javaScript: "JavaScript"
            }
        }

        /// The concrete risk, stated plainly — no hand-waving.
        public var risk: String {
            switch self {
            case .webAuthn:
                "WebKit can service a passkey request outside the proxy, revealing your real IP with no interaction."
            case .webTransport:
                "WebTransport opens a direct connection that bypasses the proxy, revealing your real IP."
            case .webRTC:
                "WebRTC discovers and shares your local and public IP addresses."
            case .javaScript:
                "Scripts widen the fingerprinting surface considerably."
            }
        }
    }

    public let host: String
    public let feature: Feature

    public var id: String { "\(host)|\(feature.rawValue)" }

    public init(host: String, feature: Feature) {
        self.host = host
        self.feature = feature
    }
}

/// Everything the user can configure. Persisted via `SettingsStoring`.
///
/// Nothing security-critical is stored here in plaintext — this is preferences
/// only. There are no credentials or tokens in Shallot at all; if that ever
/// changes they belong in the Keychain, never here.
public struct AppSettings: Sendable, Hashable, Codable {
    // MARK: Security
    public var securityLevel: SecurityLevel

    // MARK: Connection
    public var bridges: BridgeConfig
    public var searchEngine: SearchEngine

    // MARK: Privacy
    public var httpsOnly: Bool
    public var blockWebRTC: Bool
    public var blockWebAuthn: Bool
    public var blockWebTransport: Bool
    public var blockDNSPrefetch: Bool
    public var isolateCircuitPerTab: Bool
    public var clearOnExit: Bool

    // MARK: Lock
    public var requireBiometricUnlock: Bool
    public var hideInAppSwitcher: Bool

    // MARK: Escape hatches
    public var siteExceptions: [SiteException]

    public init(
        securityLevel: SecurityLevel = .safer,
        bridges: BridgeConfig = .disabled,
        searchEngine: SearchEngine = .duckDuckGoOnion,
        httpsOnly: Bool = true,
        blockWebRTC: Bool = true,
        blockWebAuthn: Bool = true,
        blockWebTransport: Bool = true,
        blockDNSPrefetch: Bool = true,
        isolateCircuitPerTab: Bool = true,
        clearOnExit: Bool = true,
        requireBiometricUnlock: Bool = false,
        hideInAppSwitcher: Bool = true,
        siteExceptions: [SiteException] = []
    ) {
        self.securityLevel = securityLevel
        self.bridges = bridges
        self.searchEngine = searchEngine
        self.httpsOnly = httpsOnly
        self.blockWebRTC = blockWebRTC
        self.blockWebAuthn = blockWebAuthn
        self.blockWebTransport = blockWebTransport
        self.blockDNSPrefetch = blockDNSPrefetch
        self.isolateCircuitPerTab = isolateCircuitPerTab
        self.clearOnExit = clearOnExit
        self.requireBiometricUnlock = requireBiometricUnlock
        self.hideInAppSwitcher = hideInAppSwitcher
        self.siteExceptions = siteExceptions
    }

    public static let `default` = AppSettings()

    /// Whether `feature` has been deliberately re-enabled for `host`.
    public func allows(_ feature: SiteException.Feature, on host: String?) -> Bool {
        guard let host else { return false }
        return siteExceptions.contains { $0.host == host && $0.feature == feature }
    }

    /// Adds or removes a per-site exception.
    public mutating func setException(_ feature: SiteException.Feature, on host: String, enabled: Bool) {
        let exception = SiteException(host: host, feature: feature)
        siteExceptions.removeAll { $0 == exception }
        if enabled { siteExceptions.append(exception) }
    }

    /// The effective security level for a host, honouring any per-site opt-in.
    public func effectiveSecurityLevel(for host: String?, tabOverride: SecurityLevel?) -> SecurityLevel {
        if let tabOverride { return tabOverride }
        if securityLevel == .safest, allows(.javaScript, on: host) { return .safer }
        return securityLevel
    }
}
