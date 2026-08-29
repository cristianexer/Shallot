import Foundation
import Testing
import WebKit

@testable import BrowserEngine
@testable import Domain

/// The leak suite. These must pass to ship.
///
/// Everything here runs against a **real** `WKWebView`, built the way the app
/// builds one — same proxy, same user scripts, same rule lists — and asks the
/// live engine what a page can actually see. A unit test on the script's text
/// proves we wrote the right string; this proves WebKit honoured it.
///
/// The pages are loaded from strings with an `https://` base URL, so no request
/// leaves the machine and the suite is hermetic. What is being measured is what
/// the page's JavaScript environment contains, which is exactly the surface the
/// documented WebKit proxy bypasses reach through.
@Suite("WebKit proxy-bypass mitigations", .serialized)
@MainActor
struct WebKitLeakTests {
    /// A base URL that resolves to nothing. Nothing is fetched from it.
    static let baseURL = URL(string: "https://leak-probe.invalid/")!

    // MARK: - Harness

    /// Builds an engine and one session exactly as the app would.
    static func makeSession(
        settings: AppSettings = .default,
        canCarryTraffic: Bool = true
    ) async -> (engine: BrowserEngine, tab: BrowserTab, session: TabSession)? {
        let monitor = MockMonitorFeed(events: [])
        let engine = BrowserEngine(settings: settings, monitor: monitor)
        engine.canCarryTraffic = canCarryTraffic
        await engine.prepareRuleLists()
        let tab = BrowserTab(url: baseURL)
        guard let session = engine.session(for: tab, socksPort: 39_051) else { return nil }
        return (engine, tab, session)
    }

    /// A sentinel appended to every probe page.
    ///
    /// Waiting on `isLoading` is not enough: on a slow machine the check can
    /// run before the load has started, and querying the *previous* document
    /// returns an empty DOM — which would read as a mitigation working when
    /// nothing had been tested at all. Waiting for an element that only exists
    /// in the new page cannot be fooled that way.
    static let readyMarker = "shallot-probe-ready"

    /// Loads `html` and waits until that document is the one on screen.
    @discardableResult
    static func load(
        _ html: String,
        into session: TabSession,
        timeout: Duration = .seconds(30)
    ) async -> Bool {
        session.webView.loadHTMLString(
            html + "<div id=\"\(readyMarker)\"></div>",
            baseURL: baseURL
        )
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let found = await evaluate(
                "!!document.getElementById('\(readyMarker)')",
                in: session
            )
            if found == "true" { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Polls `condition` until it holds or the timeout expires. Never hangs.
    @discardableResult
    static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    /// Evaluates `script` in the page and returns the result as a string.
    static func evaluate(_ script: String, in session: TabSession) async -> String? {
        let result = try? await session.webView.evaluateJavaScript("String(\(script))")
        return result as? String
    }

    // MARK: - DNS prefetching

    @Test("DNS prefetch hints in the markup are removed before they can resolve")
    func stripsStaticPrefetchHints() async throws {
        let harness = try #require(await Self.makeSession())
        defer { Task { await harness.engine.destroyAllSessions() } }

        await Self.load(
            """
            <!doctype html><html><head>
            <link rel="dns-prefetch" href="//prefetch-probe.invalid">
            <link rel="preconnect" href="//preconnect-probe.invalid">
            <link rel="stylesheet" href="data:text/css,">
            </head><body>probe</body></html>
            """,
            into: harness.session
        )

        // Both hints are gone; the unrelated stylesheet link is untouched.
        let risky = await Self.evaluate(
            "document.querySelectorAll('link[rel=\"dns-prefetch\"], link[rel=\"preconnect\"]').length",
            in: harness.session
        )
        #expect(risky == "0")
        let stylesheets = await Self.evaluate(
            "document.querySelectorAll('link[rel=\"stylesheet\"]').length",
            in: harness.session
        )
        #expect(stylesheets == "1")
    }

    @Test("The document-level prefetch control is set to off")
    func setsPrefetchControlMeta() async throws {
        let harness = try #require(await Self.makeSession())
        defer { Task { await harness.engine.destroyAllSessions() } }

        await Self.load("<!doctype html><html><head></head><body>probe</body></html>", into: harness.session)

        let content = await Self.evaluate(
            "(document.querySelector('meta[http-equiv=\"x-dns-prefetch-control\"]')||{}).content",
            in: harness.session
        )
        #expect(content == "off")
    }

    @Test("A prefetch hint injected by script after load is removed too")
    func stripsDynamicPrefetchHints() async throws {
        // The static sweep is the easy half. A page that adds the hint later —
        // which is how a real tracker would do it — is the half that needs the
        // observer, so it is tested separately.
        let harness = try #require(await Self.makeSession())
        defer { Task { await harness.engine.destroyAllSessions() } }

        await Self.load(
            """
            <!doctype html><html><head></head><body>
            <script>
              var link = document.createElement('link');
              link.rel = 'dns-prefetch';
              link.href = '//late-probe.invalid';
              document.head.appendChild(link);
            </script>
            </body></html>
            """,
            into: harness.session
        )

        _ = await Self.waitUntil(timeout: .seconds(2)) { true }
        let remaining = await Self.evaluate(
            "document.querySelectorAll('link[rel=\"dns-prefetch\"]').length",
            in: harness.session
        )
        #expect(remaining == "0")
    }

    // MARK: - The three documented bypasses

    @Test("WebTransport is not reachable from a page")
    func webTransportUnavailable() async throws {
        let harness = try #require(await Self.makeSession())
        defer { Task { await harness.engine.destroyAllSessions() } }
        await Self.load("<!doctype html><html><body>probe</body></html>", into: harness.session)

        #expect(await Self.evaluate("typeof window.WebTransport", in: harness.session) == "undefined")
    }

    @Test("WebAuthn is not reachable from a page")
    func webAuthnUnavailable() async throws {
        // The worst of the three: a related-origin request needs no user
        // interaction at all, so a page that can reach this API can leak the
        // real IP without anyone touching the screen.
        let harness = try #require(await Self.makeSession())
        defer { Task { await harness.engine.destroyAllSessions() } }
        await Self.load("<!doctype html><html><body>probe</body></html>", into: harness.session)

        #expect(await Self.evaluate("typeof window.PublicKeyCredential", in: harness.session) == "undefined")
        #expect(await Self.evaluate("typeof navigator.credentials", in: harness.session) == "undefined")
    }

    @Test("WebRTC cannot gather candidates, so no address is discovered")
    func webRTCUnavailable() async throws {
        let harness = try #require(await Self.makeSession())
        defer { Task { await harness.engine.destroyAllSessions() } }
        await Self.load("<!doctype html><html><body>probe</body></html>", into: harness.session)

        #expect(await Self.evaluate("typeof window.RTCPeerConnection", in: harness.session) == "undefined")
        #expect(await Self.evaluate("typeof window.webkitRTCPeerConnection", in: harness.session) == "undefined")
        #expect(
            await Self.evaluate("typeof (navigator.mediaDevices||{}).getUserMedia", in: harness.session)
                == "undefined"
        )
    }

    @Test("A page that tries to construct RTCPeerConnection throws instead of connecting")
    func webRTCConstructionFails() async throws {
        let harness = try #require(await Self.makeSession())
        defer { Task { await harness.engine.destroyAllSessions() } }

        await Self.load(
            """
            <!doctype html><html><body><script>
              window.__probe = 'not-attempted';
              try {
                new RTCPeerConnection({iceServers: [{urls: 'stun:stun.l.google.com:19302'}]});
                window.__probe = 'CONNECTED';
              } catch (error) {
                window.__probe = 'blocked';
              }
            </script></body></html>
            """,
            into: harness.session
        )

        let outcome = await Self.evaluate("window.__probe", in: harness.session)
        #expect(outcome == "blocked", "an RTC probe must not be able to construct a peer connection")
    }

    // MARK: - The escape hatch

    @Test("A per-site opt-in restores a feature, and only for that site")
    func perSiteOptInIsReal() async throws {
        // If this ever fails in the other direction — the exception not taking
        // effect — the Settings row would be a lie. If it fails by leaking to
        // another host, the exception is a global switch wearing a per-site label.
        var settings = AppSettings.default
        settings.setException(.webRTC, on: "leak-probe.invalid", enabled: true)

        let granted = try #require(await Self.makeSession(settings: settings))
        await Self.load("<!doctype html><html><body>probe</body></html>", into: granted.session)
        #expect(
            await Self.evaluate("typeof window.RTCPeerConnection", in: granted.session) == "function",
            "the opt-in did not take effect, so the Settings row is a lie"
        )
        await granted.engine.destroyAllSessions()

        // The same settings, a different host: still blocked. Without this the
        // exception would be a global switch wearing a per-site label.
        #expect(LeakMitigations.Configuration(settings: settings, host: "other-host.invalid").blockWebRTC)
        #expect(LeakMitigations.Configuration(settings: settings, host: nil).blockWebRTC)
        // And the opt-in is per feature, not a blanket unlock for that host.
        #expect(LeakMitigations.Configuration(settings: settings, host: "leak-probe.invalid").blockWebAuthn)
    }

    // MARK: - Proxying and the kill switch

    @Test("Every session's data store is proxied and non-persistent")
    func sessionsAreProxied() async throws {
        let harness = try #require(await Self.makeSession())
        defer { Task { await harness.engine.destroyAllSessions() } }

        let store = harness.session.webView.configuration.websiteDataStore
        #expect(ProxyConfigurator.isProxied(store))
        #expect(!store.isPersistent)
        #expect(harness.session.socksPort == 39_051)
    }

    @Test("With Tor down, nothing loads — the engine refuses and shows why")
    func killSwitchBlocksLoads() async throws {
        // The single most important behaviour in the app: a request made while
        // Tor is not carrying traffic would go out over the ordinary
        // connection and reveal the user's real address.
        let harness = try #require(await Self.makeSession(canCarryTraffic: false))
        defer { Task { await harness.engine.destroyAllSessions() } }

        harness.session.load(URL(string: "https://should-never-load.invalid/")!)
        await Self.waitUntil(timeout: .seconds(3)) { !harness.session.webView.isLoading }

        // The web view is showing our own block page, not the target.
        #expect(harness.session.webView.url?.host() != "should-never-load.invalid")
        let body = await Self.evaluate("document.body.innerText", in: harness.session)
        #expect(body?.contains("Not connected to Tor") == true)
        if case .failed = harness.tab.loadState {} else {
            Issue.record("the tab should be in a failed state, was \(harness.tab.loadState)")
        }
    }

    @Test("Dropping Tor mid-session stops every tab immediately")
    func killSwitchStopsInFlightLoads() async throws {
        let harness = try #require(await Self.makeSession(canCarryTraffic: true))
        defer { Task { await harness.engine.destroyAllSessions() } }
        await Self.load("<!doctype html><html><body>probe</body></html>", into: harness.session)

        harness.engine.canCarryTraffic = false
        harness.session.load(URL(string: "https://should-never-load.invalid/")!)
        await Self.waitUntil(timeout: .seconds(3)) { !harness.session.webView.isLoading }
        #expect(harness.session.webView.url?.host() != "should-never-load.invalid")
    }

    // MARK: - Security levels

    @Test("Safest actually stops page scripts from running")
    func safestDisablesPageScripts() async throws {
        // Measured through `WKWebView.title` rather than an injected script, so
        // the answer reflects what the *page* could do, not what the app can.
        var settings = AppSettings.default
        settings.securityLevel = .safest
        let harness = try #require(await Self.makeSession(settings: settings))
        defer { Task { await harness.engine.destroyAllSessions() } }

        await Self.load(
            "<!doctype html><html><head><title>QUIET</title></head><body><script>document.title='SCRIPT RAN';</script></body></html>",
            into: harness.session
        )
        #expect(harness.session.webView.title != "SCRIPT RAN")
    }

    @Test("Standard lets a page's scripts run, so the difference is real")
    func standardAllowsPageScripts() async throws {
        var settings = AppSettings.default
        settings.securityLevel = .standard
        let harness = try #require(await Self.makeSession(settings: settings))
        defer { Task { await harness.engine.destroyAllSessions() } }

        await Self.load(
            "<!doctype html><html><head><title>QUIET</title></head><body><script>document.title='SCRIPT RAN';</script></body></html>",
            into: harness.session
        )
        await Self.waitUntil(timeout: .seconds(3)) { harness.session.webView.title == "SCRIPT RAN" }
        #expect(harness.session.webView.title == "SCRIPT RAN")
    }

    // MARK: - Fingerprinting surface

    @Test("Every install reports the same user agent")
    func uniformUserAgent() async throws {
        let harness = try #require(await Self.makeSession())
        defer { Task { await harness.engine.destroyAllSessions() } }
        await Self.load("<!doctype html><html><body>probe</body></html>", into: harness.session)

        let agent = await Self.evaluate("navigator.userAgent", in: harness.session)
        // The device's own string carries the exact iOS build, which is a
        // fingerprint. One fixed string makes Shallot users look like each other.
        #expect(agent == TabSession.uniformUserAgent)
    }

    // MARK: - Content rule lists

    @Test("Both rule lists compile — a list WebKit rejects protects nothing")
    func ruleListsCompile() async {
        let lists = await ContentBlocker.compile(httpsOnly: true, strict: true)
        #expect(lists.count == 2)
    }
}
