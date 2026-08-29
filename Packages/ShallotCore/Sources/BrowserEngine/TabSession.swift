import Domain
import Foundation
import UIKit
import WebKit

/// One tab's web view and everything wired to it.
///
/// Built once per tab, fully configured before `WKWebView.init` — the proxy,
/// the data store, the leak mitigations and the rule lists are all in place
/// before the view exists, because WebKit does not tolerate having its proxy
/// changed underneath a live web view.
@MainActor
public final class TabSession: NSObject {
    public let tabID: UUID
    public let socksPort: UInt16
    public let webView: WKWebView

    /// The tab model this session writes its state back into.
    private weak var tab: BrowserTab?
    private weak var engine: BrowserEngine?

    private var observations: [NSKeyValueObservation] = []
    /// URLs we have already tried to upgrade, so a site with no HTTPS listener
    /// produces one clear error instead of an upgrade loop.
    private var attemptedUpgrades: Set<URL> = []
    /// What the leak-mitigation script was told to block, for the event log.
    private let mitigations: LeakMitigations.Configuration
    /// Where the page was the last time we decided to show or hide the chrome.
    private var lastChromeDecisionOffset: CGFloat = 0

    /// True while the web view is showing one of our own error pages.
    ///
    /// An error page is a successful load as far as WebKit is concerned, so
    /// without this the delegate callbacks would report the tab as finished and
    /// the user's tab would look like a page that loaded fine.
    private var isPresentingErrorPage = false

    init?(
        tab: BrowserTab,
        socksPort: UInt16,
        settings: AppSettings,
        ruleLists: [WKContentRuleList],
        engine: BrowserEngine
    ) {
        // No proxy, no web view. Building an unproxied web view and hoping the
        // navigation delegate catches everything is not good enough — WebKit
        // makes requests that never reach the delegate.
        guard let dataStore = ProxyConfigurator.makeDataStore(socksPort: socksPort) else { return nil }

        self.tabID = tab.id
        self.socksPort = socksPort
        self.tab = tab
        self.engine = engine

        let host = tab.url.flatMap { URLNormalizer.registrableHost(for: $0) }
        let mitigations = LeakMitigations.Configuration(settings: settings, host: host)
        self.mitigations = mitigations

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore

        let level = settings.effectiveSecurityLevel(for: host, tabOverride: tab.securityLevelOverride)
        SecurityPolicy.apply(level, to: configuration)
        WebKitFeatureFlags.apply(mitigations, to: configuration.preferences)

        let controller = WKUserContentController()
        for script in LeakMitigations.userScripts(for: mitigations) {
            controller.addUserScript(script)
        }
        for list in ruleLists {
            controller.add(list)
        }
        configuration.userContentController = controller

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        // A content controller retains its message handlers strongly, and the
        // configuration retains the controller, and this object retains the web
        // view — registering `self` directly would be a retain cycle that keeps
        // an entire web view alive for the life of the process. The proxy holds
        // this object weakly and breaks it.
        controller.add(WeakScriptMessageHandler(self), name: LeakMitigations.messageHandlerName)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // A single user-agent string shared by every Shallot install. The
        // device's own string carries the exact iOS build, which is a
        // fingerprint; one uniform string makes users look like each other.
        webView.customUserAgent = Self.uniformUserAgent

        observeState()
    }

    /// Fixed for every install, deliberately.
    public static let uniformUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    // No `deinit` cleanup: a deinitialiser is not guaranteed to run on the main
    // actor, and reaching into main-actor state from one would be a crash
    // waiting for the right release order. `teardown()` is the single teardown
    // path, and `BrowserEngine` calls it on every route a session can leave by.

    // MARK: - Loading

    /// Loads `url`, refusing if the policy says so.
    public func load(_ url: URL) {
        attemptedUpgrades.removeAll()
        isPresentingErrorPage = false
        lastChromeDecisionOffset = 0
        engine?.revealChrome()
        let decision = NavigationPolicy.decide(
            NavigationPolicy.Context(
                url: url,
                torCanCarryTraffic: engine?.canCarryTraffic ?? false,
                httpsOnly: engine?.settings.httpsOnly ?? true
            )
        )
        switch decision {
        case .allow:
            webView.load(URLRequest(url: url))
        case .upgrade(let upgraded):
            attemptedUpgrades.insert(url)
            engine?.report(.init(kind: .httpsUpgraded, message: "HTTPS upgraded · \(upgraded.host() ?? "")"))
            webView.load(URLRequest(url: upgraded))
        case .block(let reason):
            present(reason, for: url)
        }
    }

    public func reload() {
        guard engine?.canCarryTraffic == true else {
            present(.torNotRunning, for: webView.url)
            return
        }
        // `reloadFromOrigin` skips the cache. The store is non-persistent so
        // there is little cache to skip, but it also re-runs the upgrade and
        // policy decisions from scratch, which is what a user means by reload.
        webView.reloadFromOrigin()
    }

    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }
    public func stopLoading() { webView.stopLoading() }

    /// Tears the session down and wipes everything it held.
    public func teardown() async {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        observations.removeAll()
        // Belt and braces: the store is non-persistent and dies with the
        // process anyway, but New Identity promises "cleared now", not
        // "cleared eventually".
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    // MARK: - State mirroring

    private func observeState() {
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab = self.tab, !self.isPresentingErrorPage else { return }
                    if webView.isLoading {
                        tab.loadState = .loading(progress: webView.estimatedProgress)
                    }
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab = self.tab else { return }
                    let title = webView.title ?? ""
                    if !title.isEmpty { tab.title = title }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab = self.tab else { return }
                    // `about:blank` is WebKit's own scratch page and is not
                    // something the address bar should ever show.
                    guard let url = webView.url, url.scheme != "about" else { return }
                    tab.url = url
                    tab.security = NavigationPolicy.security(for: url)
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.tab?.canGoBack = webView.canGoBack
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.tab?.canGoForward = webView.canGoForward
                }
            },
            // Observing the offset rather than becoming the scroll view's
            // delegate: WebKit sets that delegate itself, and replacing it
            // breaks zooming and rubber-banding in ways that only show up on
            // device.
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                MainActor.assumeIsolated {
                    self?.updateChromeVisibility(for: scrollView)
                }
            },
        ]
    }

    /// Hides the chrome when the page is scrolled down, brings it back when
    /// scrolled up or when the top is in reach.
    ///
    /// The threshold is what stops it flickering: a few points of rubber-band
    /// or an inertial wobble must not toggle the whole bar.
    private func updateChromeVisibility(for scrollView: UIScrollView) {
        guard let engine else { return }
        let decision = ChromeVisibilityPolicy.decide(
            offset: scrollView.contentOffset.y + scrollView.adjustedContentInset.top,
            anchor: lastChromeDecisionOffset,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height
        )
        if let anchor = decision.anchor { lastChromeDecisionOffset = anchor }
        if let isVisible = decision.isVisible, engine.isChromeVisible != isVisible {
            engine.isChromeVisible = isVisible
        }
    }

    private func present(_ reason: NavigationBlockReason, for url: URL?) {
        isPresentingErrorPage = true
        tab?.loadState = .failed(message: reason.title)
        engine?.report(.init(kind: reason.eventKind, message: reason.eventMessage))
        webView.loadHTMLString(ErrorPage.html(for: reason, url: url), baseURL: nil)
    }
}

// MARK: - WKNavigationDelegate

extension TabSession: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let url = navigationAction.request.url ?? URL(string: "about:blank")!
        let host = URLNormalizer.registrableHost(for: url)
        let settings = engine?.settings ?? .default

        // The security level is decided per navigation, so a per-site opt-in
        // takes effect on the very next load rather than at the next launch.
        let level = settings.effectiveSecurityLevel(for: host, tabOverride: tab?.securityLevelOverride)
        preferences.allowsContentJavaScript = level.allowsJavaScript

        let decision = NavigationPolicy.decide(
            NavigationPolicy.Context(
                url: url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
                torCanCarryTraffic: engine?.canCarryTraffic ?? false,
                httpsOnly: settings.httpsOnly,
                upgradeAlreadyAttempted: attemptedUpgrades.contains(url)
            )
        )

        switch decision {
        case .allow:
            if url.scheme != "about", let host, !host.isEmpty {
                // SOCKS5 hands the hostname to Tor rather than resolving it
                // here. This is the line the Monitor shows as "no leak".
                engine?.report(.init(kind: .dnsViaTor, message: "DNS resolved via Tor · \(host)"))
            }
            decisionHandler(.allow, preferences)
        case .upgrade(let upgraded):
            attemptedUpgrades.insert(url)
            engine?.report(.init(kind: .httpsUpgraded, message: "HTTPS upgraded · \(upgraded.host() ?? "")"))
            decisionHandler(.cancel, preferences)
            webView.load(URLRequest(url: upgraded))
        case .block(let reason):
            decisionHandler(.cancel, preferences)
            // Only a main-frame block is worth replacing the page for; a
            // blocked sub-resource should leave the page it came from intact.
            if navigationAction.targetFrame?.isMainFrame ?? true {
                present(reason, for: url)
            } else {
                engine?.report(.init(kind: reason.eventKind, message: reason.eventMessage))
            }
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isPresentingErrorPage else { return }
        tab?.loadState = .loading(progress: 0.05)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isPresentingErrorPage else { return }
        tab?.loadState = .finished
        if let url = webView.url, url.scheme != "about" {
            tab?.url = url
            tab?.security = NavigationPolicy.security(for: url)
        }
        let title = webView.title ?? ""
        if !title.isEmpty { tab?.title = title }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        handleLoadFailure(error, url: webView.url)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        handleLoadFailure(error, url: webView.url)
    }

    private func handleLoadFailure(_ error: any Error, url: URL?) {
        let nsError = error as NSError
        // A cancelled navigation is what our own policy does when it upgrades
        // or blocks; showing an error for it would overwrite the real message.
        guard nsError.code != NSURLErrorCancelled else { return }
        isPresentingErrorPage = true
        tab?.loadState = .failed(message: nsError.localizedDescription)
        engine?.report(.init(kind: .failure, message: "load failed · \(nsError.localizedDescription)"))
        webView.loadHTMLString(
            ErrorPage.html(for: nsError, url: url ?? tab?.url),
            baseURL: nil
        )
    }
}

// MARK: - WKUIDelegate

extension TabSession: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // `target="_blank"` and `window.open` are loaded in this tab rather
        // than a new one. A new tab built from WebKit's own configuration would
        // not carry our proxy, our data store or our user scripts — it would be
        // an unproxied window, which is precisely the leak we exist to prevent.
        if let url = navigationAction.request.url {
            load(url)
        }
        return nil
    }
}

// MARK: - WKScriptMessageHandler

extension TabSession: WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == LeakMitigations.messageHandlerName else { return }
        let what = (message.body as? String) ?? "unknown"
        engine?.report(.init(kind: .leakBlocked, message: "blocked · \(Self.describe(what))"))
    }

    static func describe(_ token: String) -> String {
        switch token {
        case "dns-prefetch": "DNS prefetch hint removed"
        case "WebTransport": "WebTransport probe"
        case "credentials", "PublicKeyCredential": "WebAuthn probe"
        case "RTCPeerConnection", "webkitRTCPeerConnection": "WebRTC probe"
        default: token
        }
    }
}

/// Forwards script messages without keeping its target alive.
///
/// `WKUserContentController` retains its handlers strongly. This sits in
/// between so a `TabSession` can be released normally.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
