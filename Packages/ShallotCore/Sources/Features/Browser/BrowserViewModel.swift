import BrowserEngine
import Domain
import Foundation
import Observation
import WebKit

/// Drives the browser screen: tabs, the omnibar, and every load.
///
/// It is the only place that connects a tab to a Tor SOCKS port and to a web
/// view, and it never lets those two happen out of order — a web view is not
/// created until the port that will proxy it is known.
@MainActor
@Observable
public final class BrowserViewModel {
    @ObservationIgnored public let session: any BrowsingSessioning
    @ObservationIgnored private let tor: any TorServicing
    @ObservationIgnored private let engine: BrowserEngine
    @ObservationIgnored private let settingsStore: any SettingsStoring
    @ObservationIgnored private let monitor: any MonitorFeeding
    @ObservationIgnored private let favourites: any FavouritesRepository

    /// What the omnibar's text field holds while editing.
    public var addressText: String = ""
    public var isEditingAddress = false

    /// Tabs whose session is currently being prepared, so the UI can show the
    /// connecting state rather than an empty canvas.
    public private(set) var preparingTabIDs: Set<UUID> = []

    /// Set when a load is refused because Tor is not up yet.
    public private(set) var pendingURL: URL?

    public init(
        session: any BrowsingSessioning,
        tor: any TorServicing,
        engine: BrowserEngine,
        settingsStore: any SettingsStoring,
        monitor: any MonitorFeeding,
        favourites: any FavouritesRepository
    ) {
        self.session = session
        self.tor = tor
        self.engine = engine
        self.settingsStore = settingsStore
        self.monitor = monitor
        self.favourites = favourites
    }

    // MARK: - Derived state

    public var tabs: [BrowserTab] { session.tabs }
    public var activeTab: BrowserTab? { session.activeTab }
    public var settings: AppSettings { settingsStore.settings }

    /// Whether the web canvas should be shown instead of the start page.
    public var isShowingWebContent: Bool {
        guard let activeTab else { return false }
        return activeTab.url != nil
    }

    public var canGoBack: Bool { activeTab?.canGoBack ?? false }
    public var canGoForward: Bool { activeTab?.canGoForward ?? false }
    public var loadProgress: Double { activeTab?.loadState.progress ?? 0 }
    public var isLoading: Bool { activeTab?.loadState.isLoading ?? false }

    /// The web view for `tab`, if its session has been built.
    public func webView(for tab: BrowserTab) -> WKWebView? {
        engine.existingSession(for: tab.id)?.webView
    }

    /// Whether the active page is already saved.
    public var isActivePageSaved: Bool {
        guard let url = activeTab?.url else { return false }
        return favourites.contains(url: url)
    }

    // MARK: - Tabs

    /// Ensures there is a tab to show, and that it has a session ready.
    public func onAppear() async {
        let tab = ensureActiveTab()
        await prepareSession(for: tab)
    }

    @discardableResult
    public func newTab() -> BrowserTab {
        let tab = session.openTab(url: nil)
        addressText = ""
        isEditingAddress = false
        Task { await prepareSession(for: tab) }
        return tab
    }

    public func selectTab(_ id: UUID) {
        session.selectTab(id)
        syncAddressField()
        monitor.destinationLabel = session.activeTab?.url?.host()
        if let tab = session.activeTab {
            Task { await prepareSession(for: tab) }
        }
    }

    public func closeTab(_ id: UUID) {
        session.closeTab(id)
        Task {
            await engine.destroySession(for: id)
            await tor.releaseIsolation(.tab(id))
            // Closing the last tab should land on the start page, not on
            // nothing at all.
            let tab = ensureActiveTab()
            await prepareSession(for: tab)
            syncAddressField()
        }
    }

    // MARK: - Navigation

    /// Interprets whatever is in the omnibar and acts on it.
    public func submitAddress() {
        let input = addressText
        isEditingAddress = false
        switch URLNormalizer.resolve(input, httpsOnly: settings.httpsOnly) {
        case .url(let url):
            open(url: url)
        case .search(let query):
            guard let url = settings.searchEngine.searchURL(for: query) else { return }
            open(url: url)
        case .invalidOnion(let host):
            monitor.record(
                SecurityEvent(kind: .leakBlocked, message: "refused invalid onion · \(host)")
            )
            activeTab?.loadState = .failed(message: "Not a valid onion address")
        case .empty:
            break
        }
    }

    /// Opens `url` in the active tab, creating one if needed.
    public func open(url: URL) {
        let tab = ensureActiveTab()
        syncAddressField(to: url)
        Task { await load(url, in: tab) }
    }

    /// Opens `url` in a new tab and brings it forward.
    public func openInNewTab(url: URL) {
        let tab = session.openTab(url: nil)
        syncAddressField(to: url)
        Task { await load(url, in: tab) }
    }

    public func reload() {
        guard let tab = activeTab, let session = engine.existingSession(for: tab.id) else { return }
        session.reload()
    }

    public func goBack() {
        guard let tab = activeTab else { return }
        engine.existingSession(for: tab.id)?.goBack()
    }

    public func goForward() {
        guard let tab = activeTab else { return }
        engine.existingSession(for: tab.id)?.goForward()
    }

    public func stopLoading() {
        guard let tab = activeTab else { return }
        engine.existingSession(for: tab.id)?.stopLoading()
    }

    /// Clears everything and asks Tor for a brand-new identity.
    ///
    /// Order matters: tear the web views down *first* so nothing is mid-flight
    /// on an old circuit when the new one is requested.
    public func newIdentity() async {
        await engine.destroyAllSessions()
        session.closeAllTabs()
        for tab in tabs { await tor.releaseIsolation(tab.isolationKey) }
        do {
            try await tor.newIdentity()
        } catch {
            monitor.record(SecurityEvent(kind: .failure, message: "new identity failed · \(error)"))
        }
        addressText = ""
        pendingURL = nil
        monitor.destinationLabel = nil
        let tab = ensureActiveTab()
        await prepareSession(for: tab)
    }

    /// Saves or unsaves the current page.
    public func toggleFavourite() {
        guard let tab = activeTab, let url = tab.url else { return }
        if let existing = favourites.favourites.first(where: { $0.url == url }) {
            try? favourites.delete(id: existing.id)
        } else {
            let title = tab.title.isEmpty ? (url.host() ?? url.absoluteString) : tab.title
            try? favourites.add(title: title, url: url)
        }
    }

    /// Raises the security level for this tab only, for a site that JavaScript
    /// being off has broken.
    public func allowJavaScriptForActiveTab() {
        guard let tab = activeTab else { return }
        tab.securityLevelOverride = .safer
        if let host = tab.url.flatMap({ URLNormalizer.registrableHost(for: $0) }) {
            settingsStore.update { $0.setException(.javaScript, on: host, enabled: true) }
        }
        reload()
    }

    // MARK: - Session lifecycle

    /// Assigns an isolated SOCKS port to `tab` and builds its web view.
    ///
    /// Does nothing until Tor is carrying traffic. That is the kill switch at
    /// its earliest point: with no port there is no proxied store, and with no
    /// proxied store the engine refuses to make a web view at all.
    public func prepareSession(for tab: BrowserTab) async {
        guard engine.existingSession(for: tab.id) == nil else { return }
        guard await tor.state.canCarryTraffic else { return }
        guard !preparingTabIDs.contains(tab.id) else { return }

        preparingTabIDs.insert(tab.id)
        defer { preparingTabIDs.remove(tab.id) }

        let key = settings.isolateCircuitPerTab ? tab.isolationKey : IsolationKey.utility
        guard let port = try? await tor.socksPort(forIsolationKey: key) else { return }
        await engine.prepareRuleLists()
        _ = engine.session(for: tab, socksPort: port)
    }

    private func load(_ url: URL, in tab: BrowserTab) async {
        await prepareSession(for: tab)
        guard let tabSession = engine.existingSession(for: tab.id) else {
            // Tor is not ready. Remember the destination and open it the
            // moment it is, rather than dropping the tap on the floor.
            pendingURL = url
            monitor.record(SecurityEvent(kind: .killSwitch, message: "load held · waiting for tor"))
            return
        }
        pendingURL = nil
        // The Monitor's chain ends at whatever the active tab is talking to.
        monitor.destinationLabel = url.host()
        tabSession.load(url)
    }

    /// Called when Tor reaches `.running`, to flush anything that was held.
    public func torBecameReady() async {
        let tab = ensureActiveTab()
        await prepareSession(for: tab)
        if let pendingURL {
            self.pendingURL = nil
            await load(pendingURL, in: tab)
        }
    }

    /// Drops background tabs' web views under memory pressure. Tor stays up.
    public func shedMemory() async {
        await engine.shedInactiveSessions(keeping: session.activeTabID)
        monitor.record(SecurityEvent(kind: .info, message: "background tabs unloaded · low memory"))
    }

    // MARK: - Helpers

    @discardableResult
    private func ensureActiveTab() -> BrowserTab {
        if let tab = session.activeTab { return tab }
        return session.openTab(url: nil)
    }

    /// Keeps the omnibar text in step with the active tab.
    public func syncAddressField(to url: URL? = nil) {
        let target = url ?? activeTab?.url
        addressText = target?.absoluteString ?? ""
    }
}
