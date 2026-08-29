import Foundation
import Observation

/// How a page load is progressing, for the omnibar's progress line.
public enum TabLoadState: Sendable, Hashable {
    case idle
    case loading(progress: Double)
    case finished
    case failed(message: String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var progress: Double {
        switch self {
        case .idle: 0
        case .loading(let progress): progress
        case .finished: 1
        case .failed: 0
        }
    }
}

/// What the omnibar shield should say about the connection.
public enum ConnectionSecurity: Sendable, Hashable {
    /// Nothing loaded yet.
    case none
    /// An onion service — end-to-end encrypted and authenticated by its address.
    case onion
    /// Plain HTTPS over Tor.
    case secure
    /// Loaded, but not over TLS. Only reachable when HTTPS-only is off.
    case insecure

    public var label: String {
        switch self {
        case .none: ""
        case .onion: "ONION · VERIFIED"
        case .secure: "HTTPS · OVER TOR"
        case .insecure: "NOT SECURE"
        }
    }
}

/// One open tab.
///
/// Everything here is in-memory and dies with the process. Nothing about a tab
/// is ever written to disk — no history, no cookies, no cache.
@MainActor
@Observable
public final class BrowserTab: Identifiable {
    public let id: UUID

    /// The isolation domain — and therefore the Tor circuit — this tab uses.
    public let isolationKey: IsolationKey

    /// The Tor SOCKS port this tab's web view is proxied through.
    ///
    /// Assigned once, before the web view is created: WebKit does not tolerate
    /// mutating `proxyConfigurations` on a live web view.
    public var socksPort: UInt16?

    /// The address that actually committed, as reported by the web view.
    public var url: URL?

    /// The address this tab was last asked to open, whether or not it arrived.
    ///
    /// `url` only appears once a load commits, so a page that failed — or an
    /// onion service that timed out — would leave the tab looking empty and
    /// take reload away with it, at exactly the moment reload is what you want.
    public var requestedURL: URL?

    public var title: String

    /// A picture of what this tab was last showing.
    ///
    /// Kept on the tab rather than in the engine so a tab whose web view has
    /// been shed under memory pressure still has something to show in the tab
    /// overview. `Data` rather than an image type because `Domain` stays free
    /// of UI frameworks.
    public var thumbnail: Data?
    public var loadState: TabLoadState
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var security: ConnectionSecurity

    /// Per-tab override of the global security level, used when the user opts a
    /// broken site up a level.
    public var securityLevelOverride: SecurityLevel?

    public init(
        id: UUID = UUID(),
        url: URL? = nil,
        title: String = "",
        loadState: TabLoadState = .idle,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        security: ConnectionSecurity = .none,
        securityLevelOverride: SecurityLevel? = nil
    ) {
        self.id = id
        self.isolationKey = .tab(id)
        self.url = url
        self.title = title
        self.loadState = loadState
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.security = security
        self.securityLevelOverride = securityLevelOverride
    }

    /// What the overview shows when there is no thumbnail: a new tab, or one
    /// that has not painted yet.
    public var hasThumbnail: Bool { thumbnail != nil }

    /// True while the tab is showing the start page rather than a web page.
    public var isShowingStartPage: Bool { url == nil && requestedURL == nil }

    /// Whether there is anything for reload to act on.
    public var canReload: Bool { url != nil || requestedURL != nil }

    /// What the address pill displays.
    public var displayAddress: String {
        guard let url else { return "" }
        return url.host() ?? url.absoluteString
    }
}
