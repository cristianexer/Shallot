import Foundation
import Network
import WebKit

/// Points a website data store at Tor's SOCKS5 listener.
///
/// ### Three rules, each one learned the hard way
///
/// 1. **SOCKS5, never HTTP CONNECT.** WebKit's HTTP-CONNECT proxying has known
///    bugs; Apple's own guidance is to prefer SOCKS5. SOCKS5 also hands the
///    hostname to Tor for remote resolution, which is what keeps DNS off this
///    device — including for `.onion`, which nothing local could resolve
///    anyway.
/// 2. **Configure the store fully, then build the web view.** Mutating
///    `proxyConfigurations` on a live web view interrupts networking and has
///    been reported to crash on iOS 18. The store is finished before
///    `WKWebView.init` is ever called.
/// 3. **Non-persistent store, one per tab.** Nothing reaches disk, and two
///    tabs share no cookies, cache or storage — which is half of what per-tab
///    isolation means. The other half is the separate SOCKS port.
public enum ProxyConfigurator {
    /// Builds a fully configured, Tor-routed, ephemeral data store.
    ///
    /// - Parameter socksPort: The loopback SOCKS port assigned to this tab.
    /// - Returns: A store ready to be handed to a `WKWebViewConfiguration`, or
    ///   `nil` if the port is not a valid one — in which case the caller must
    ///   refuse to build a web view rather than build an unproxied one.
    public static func makeDataStore(socksPort: UInt16) -> WKWebsiteDataStore? {
        guard let proxy = makeProxyConfiguration(socksPort: socksPort) else { return nil }
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [proxy]
        return store
    }

    /// The SOCKS5 proxy configuration for a loopback port.
    public static func makeProxyConfiguration(socksPort: UInt16) -> ProxyConfiguration? {
        // `NWEndpoint.Port(rawValue: 0)` is `.any`, which is a perfectly valid
        // Port and a completely invalid proxy — it would build a store that
        // looks proxied and connects to nothing. Reject it here so the engine
        // refuses to make a web view at all.
        guard socksPort > 0, let port = NWEndpoint.Port(rawValue: socksPort) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        return ProxyConfiguration(socksv5Proxy: endpoint)
    }

    /// Confirms a store is actually proxied.
    ///
    /// Used by the engine before it will load anything, and asserted by the
    /// leak tests: a store that somehow lost its proxy must never be handed a
    /// URL.
    public static func isProxied(_ store: WKWebsiteDataStore) -> Bool {
        !store.proxyConfigurations.isEmpty
    }
}
