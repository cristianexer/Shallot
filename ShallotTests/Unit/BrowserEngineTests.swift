import Foundation
import Testing
import WebKit

@testable import BrowserEngine
@testable import Domain

@Suite("Navigation policy — the kill switch and HTTPS-only")
struct NavigationPolicyTests {
    static let httpsURL = URL(string: "https://example.org/page")!
    static let httpURL = URL(string: "http://example.org/page")!
    static let onionURL = URL(string: "http://\(String(repeating: "a", count: 56)).onion/x")!

    @Test("Nothing loads while Tor is not carrying traffic")
    func killSwitchBlocksEverything() {
        // The single most important assertion in the suite: if this ever passes
        // when it should not, the app leaks the user's real address.
        for url in [Self.httpsURL, Self.httpURL, Self.onionURL] {
            let decision = NavigationPolicy.decide(
                .init(url: url, torCanCarryTraffic: false)
            )
            #expect(decision == .block(.torNotRunning), "\(url) was not blocked")
        }
    }

    @Test("The kill switch applies to sub-frames too, not just the main frame")
    func killSwitchCoversSubframes() {
        let decision = NavigationPolicy.decide(
            .init(url: Self.httpsURL, isMainFrame: false, torCanCarryTraffic: false)
        )
        #expect(decision == .block(.torNotRunning))
    }

    @Test("about: is allowed even before Tor is up — it reaches no network")
    func aboutBlankIsAllowed() {
        let decision = NavigationPolicy.decide(
            .init(url: URL(string: "about:blank")!, torCanCarryTraffic: false)
        )
        #expect(decision == .allow)
    }

    @Test("An https page over a running Tor is allowed")
    func allowsHTTPSOverTor() {
        #expect(NavigationPolicy.decide(.init(url: Self.httpsURL, torCanCarryTraffic: true)) == .allow)
    }

    @Test("http is upgraded when HTTPS-only is on")
    func upgradesHTTP() {
        let decision = NavigationPolicy.decide(
            .init(url: Self.httpURL, torCanCarryTraffic: true, httpsOnly: true)
        )
        #expect(decision == .upgrade(to: URL(string: "https://example.org/page")!))
    }

    @Test("A second upgrade attempt becomes a clear error, not a loop")
    func upgradeDoesNotLoop() {
        let decision = NavigationPolicy.decide(
            .init(
                url: Self.httpURL,
                torCanCarryTraffic: true,
                httpsOnly: true,
                upgradeAlreadyAttempted: true
            )
        )
        #expect(decision == .block(.insecureConnection))
    }

    @Test("Onion services are never upgraded — their address is the security")
    func onionNotUpgraded() {
        let decision = NavigationPolicy.decide(
            .init(url: Self.onionURL, torCanCarryTraffic: true, httpsOnly: true)
        )
        #expect(decision == .allow)
    }

    @Test("Invalid onion addresses are refused even with Tor up")
    func refusesInvalidOnion() {
        let url = URL(string: "http://expyuzz4wqqyqhjn.onion")!
        let decision = NavigationPolicy.decide(.init(url: url, torCanCarryTraffic: true))
        #expect(decision == .block(.invalidOnionAddress("expyuzz4wqqyqhjn.onion")))
    }

    @Test("Proxy-escaping schemes are refused", arguments: [
        "file:///etc/passwd", "data:text/html,<b>x", "ftp://example.org", "ws://example.org",
    ])
    func refusesEscapingSchemes(_ raw: String) {
        let url = URL(string: raw)!
        let decision = NavigationPolicy.decide(.init(url: url, torCanCarryTraffic: true))
        guard case .block(.disallowedScheme) = decision else {
            Issue.record("\(raw) was not refused: \(decision)")
            return
        }
    }

    @Test("http is left alone when HTTPS-only is off")
    func allowsHTTPWhenOptedOut() {
        let decision = NavigationPolicy.decide(
            .init(url: Self.httpURL, torCanCarryTraffic: true, httpsOnly: false)
        )
        #expect(decision == .allow)
    }

    @Test("The security badge reflects the connection")
    func securityBadge() {
        #expect(NavigationPolicy.security(for: Self.onionURL) == .onion)
        #expect(NavigationPolicy.security(for: Self.httpsURL) == .secure)
        #expect(NavigationPolicy.security(for: Self.httpURL) == .insecure)
        #expect(NavigationPolicy.security(for: nil) == .none)
        // A malformed onion must not be badged as verified.
        #expect(NavigationPolicy.security(for: URL(string: "http://expyuzz4wqqyqhjn.onion")!) == .insecure)
    }

    @Test("Every block reason explains itself")
    func reasonsAreExplained() {
        let reasons: [NavigationBlockReason] = [
            .torNotRunning, .disallowedScheme("file"), .invalidOnionAddress("x.onion"),
            .insecureConnection, .missingHost,
        ]
        for reason in reasons {
            #expect(!reason.title.isEmpty)
            #expect(!reason.detail.isEmpty)
            #expect(!reason.eventMessage.isEmpty)
        }
        #expect(NavigationBlockReason.torNotRunning.eventKind == .killSwitch)
    }
}

@Suite("Leak mitigation script")
struct LeakMitigationsTests {
    @Test("DNS prefetching is turned off and prefetch hints are stripped")
    func dnsPrefetch() {
        let source = LeakMitigations.source(for: .strict)
        #expect(source.contains("x-dns-prefetch-control"))
        #expect(source.contains("'off'"))
        #expect(source.contains("dns-prefetch"))
        #expect(source.contains("preconnect"))
        // Hints injected after parsing must be caught too.
        #expect(source.contains("MutationObserver"))
    }

    @Test("WebTransport is removed")
    func webTransport() {
        #expect(LeakMitigations.source(for: .strict).contains("'WebTransport'"))
    }

    @Test("WebAuthn entry points are removed")
    func webAuthn() {
        let source = LeakMitigations.source(for: .strict)
        #expect(source.contains("'credentials'"))
        #expect(source.contains("'PublicKeyCredential'"))
    }

    @Test("WebRTC entry points are removed")
    func webRTC() {
        let source = LeakMitigations.source(for: .strict)
        #expect(source.contains("'RTCPeerConnection'"))
        #expect(source.contains("'webkitRTCPeerConnection'"))
        #expect(source.contains("'getUserMedia'"))
    }

    @Test("Turning a mitigation off removes exactly that part of the script")
    func selectiveDisabling() {
        var configuration = LeakMitigations.Configuration.strict
        configuration.blockWebRTC = false
        let source = LeakMitigations.source(for: configuration)
        #expect(!source.contains("'RTCPeerConnection'"))
        // …and leaves the rest alone.
        #expect(source.contains("'WebTransport'"))
    }

    @Test("A per-site opt-in relaxes only that feature, on that host")
    func perSiteOptIn() {
        var settings = AppSettings.default
        settings.setException(.webRTC, on: "meet.example", enabled: true)

        let allowed = LeakMitigations.Configuration(settings: settings, host: "meet.example")
        #expect(!allowed.blockWebRTC)
        #expect(allowed.blockWebAuthn)
        #expect(allowed.blockWebTransport)

        let other = LeakMitigations.Configuration(settings: settings, host: "other.example")
        #expect(other.blockWebRTC)
    }

    @Test("The script runs before page scripts, in every frame")
    func injectionTiming() {
        let scripts = LeakMitigations.userScripts(for: .strict)
        #expect(scripts.count == 1)
        // Anything later would let a page capture a reference first, and
        // main-frame-only would leave third-party iframes unprotected.
        #expect(scripts[0].injectionTime == .atDocumentStart)
        #expect(scripts[0].isForMainFrameOnly == false)
    }

    @Test("The script is syntactically balanced")
    func balanced() {
        let source = LeakMitigations.source(for: .strict)
        #expect(source.filter { $0 == "{" }.count == source.filter { $0 == "}" }.count)
        #expect(source.filter { $0 == "(" }.count == source.filter { $0 == ")" }.count)
    }
}

@Suite("Content blocking rules")
struct ContentBlockerTests {
    @Test("The base list is valid JSON with a rule per tracker")
    func baseListIsValid() throws {
        let json = ContentBlocker.baseRules(httpsOnly: false)
        let rules = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        #expect(rules?.count == ContentBlocker.trackerHosts.count)
    }

    @Test("HTTPS-only adds a make-https rule that WebKit applies before the delegate")
    func httpsUpgradeRule() throws {
        let json = ContentBlocker.baseRules(httpsOnly: true)
        #expect(json.contains("make-https"))
        let rules = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        #expect(rules.count == ContentBlocker.trackerHosts.count + 1)
        // …and is absent when the user turns HTTPS-only off.
        #expect(!ContentBlocker.baseRules(httpsOnly: false).contains("make-https"))
    }

    @Test("The upgrade rule leaves onion services and top-level navigation alone")
    func upgradeRuleExemptsOnionAndDocuments() throws {
        // Upgrading an onion URL breaks it: the address already authenticates
        // and encrypts the connection, and onion services rarely serve 443.
        // Top-level navigation belongs to NavigationPolicy, which knows that.
        let json = ContentBlocker.baseRules(httpsOnly: true)
        let rules = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        let upgrade = try #require(
            rules.first { ($0["action"] as? [String: String])?["type"] == "make-https" }
        )
        let trigger = try #require(upgrade["trigger"] as? [String: Any])
        #expect((trigger["unless-domain"] as? [String])?.contains("*onion") == true)
        #expect((trigger["resource-type"] as? [String])?.contains("document") == false)
    }

    @Test("Tracker filters match the host and its subdomains, third-party only")
    func trackerFilters() {
        let filter = ContentBlocker.urlFilter(forHost: "doubleclick.net")
        #expect(filter == "^https?://([^/]+\\.)?doubleclick\\.net")
        #expect(ContentBlocker.baseRules(httpsOnly: false).contains("third-party"))
    }

    @Test("The strict list blocks third-party fonts, scripts and cookies")
    func strictList() throws {
        let json = ContentBlocker.strictRules()
        let rules = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        #expect(rules.count == 3)
        #expect(json.contains("font"))
        #expect(json.contains("block-cookies"))
    }

    @Test("Only Standard skips the strict list")
    func strictAppliesFromSaferUp() {
        #expect(!SecurityPolicy.usesStrictRules(.standard))
        #expect(SecurityPolicy.usesStrictRules(.safer))
        #expect(SecurityPolicy.usesStrictRules(.safest))
    }
}

@Suite("Security policy")
@MainActor
struct SecurityPolicyTests {
    @Test("Safest turns JavaScript off, the others leave it on")
    func javaScriptMapping() {
        #expect(SecurityPolicy.webpagePreferences(for: .standard).allowsContentJavaScript)
        #expect(SecurityPolicy.webpagePreferences(for: .safer).allowsContentJavaScript)
        #expect(!SecurityPolicy.webpagePreferences(for: .safest).allowsContentJavaScript)
    }

    @Test("A configuration built for Safest cannot run page scripts")
    func appliesToConfiguration() {
        let configuration = WKWebViewConfiguration()
        SecurityPolicy.apply(.safest, to: configuration)
        #expect(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
        // Media must not start on its own — that is a request the user did not make.
        #expect(configuration.mediaTypesRequiringUserActionForPlayback == .all)
        #expect(!configuration.allowsPictureInPictureMediaPlayback)
    }

    @Test("The change summary names the consequence that matters")
    func changeSummary() {
        #expect(SecurityPolicy.changeSummary(from: .safer, to: .safest).contains("JavaScript"))
        #expect(SecurityPolicy.changeSummary(from: .safest, to: .safer).contains("JavaScript"))
    }
}

@Suite("Proxy configuration")
@MainActor
struct ProxyConfiguratorTests {
    @Test("A data store is created already proxied and non-persistent")
    func makesProxiedStore() throws {
        let store = try #require(ProxyConfigurator.makeDataStore(socksPort: 39_051))
        #expect(ProxyConfigurator.isProxied(store))
        // Non-persistent means no history, cookies or cache ever reach disk.
        #expect(!store.isPersistent)
    }

    @Test("Port zero is refused rather than producing an unproxied store")
    func refusesInvalidPort() {
        // Returning an unproxied store here would be a silent clearnet leak.
        #expect(ProxyConfigurator.makeProxyConfiguration(socksPort: 0) == nil)
        #expect(ProxyConfigurator.makeDataStore(socksPort: 0) == nil)
    }

    @Test("A plain non-persistent store is correctly reported as unproxied")
    func detectsUnproxiedStore() {
        #expect(!ProxyConfigurator.isProxied(WKWebsiteDataStore.nonPersistent()))
    }
}

@Suite("Error pages")
struct ErrorPageTests {
    @Test("Hostile text in a host cannot inject script into our own error page")
    func escapesInjection() {
        let url = URL(string: "https://example.org/%3Cscript%3E")!
        let html = ErrorPage.html(for: .insecureConnection, url: url)
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;") || !html.contains("<script"))
    }

    @Test("Escaping covers every dangerous character")
    func escaping() {
        #expect(ErrorPage.escape("<a href=\"x\">&'") == "&lt;a href=&quot;x&quot;&gt;&amp;&#39;")
    }

    @Test("An onion that cannot be reached says so specifically")
    func onionGuidance() {
        let url = URL(string: "http://\(String(repeating: "a", count: 56)).onion")!
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        #expect(ErrorPage.detail(for: error, url: url).lowercased().contains("onion"))
    }

    @Test("Every block reason produces a complete page")
    func rendersEveryReason() {
        let reasons: [NavigationBlockReason] = [
            .torNotRunning, .disallowedScheme("file"), .invalidOnionAddress("x.onion"),
            .insecureConnection, .missingHost,
        ]
        for reason in reasons {
            let html = ErrorPage.html(for: reason, url: URL(string: "https://example.org")!)
            #expect(html.contains("<!doctype html>"))
            #expect(html.contains(reason.title))
        }
    }
}
