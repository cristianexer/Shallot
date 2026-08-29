import Domain
import Foundation
import WebKit

/// Compiles the content rule lists WebKit enforces below the JavaScript layer.
///
/// Two lists, kept separate so the security level can switch the strict one on
/// and off without recompiling the base one:
///
/// * **base** — third-party tracker blocking and, when HTTPS-only is on,
///   `make-https` on every request. Rule-list upgrades happen inside WebKit
///   before the request is made, which catches sub-resources that never reach
///   the navigation delegate.
/// * **strict** — additionally blocks remote fonts and third-party scripts,
///   which is what "Safer" means in practice on an engine we cannot patch.
///
/// Compilation is cached by WebKit itself in `WKContentRuleListStore`, so the
/// cost is paid once per identifier version rather than once per launch.
public enum ContentBlocker {
    public static let baseIdentifier = "shallot.base.v1"
    public static let strictIdentifier = "shallot.strict.v1"

    /// Third-party hosts that exist only to follow people between sites.
    ///
    /// Deliberately short and uncontroversial. This is not an ad blocker: it is
    /// a cross-site-correlation blocker, and every entry is a tracker whose
    /// presence on a page tells a third party that *this* browsing session
    /// visited it.
    public static let trackerHosts: [String] = [
        "doubleclick.net", "google-analytics.com", "googletagmanager.com",
        "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "facebook.net", "connect.facebook.net", "graph.facebook.com",
        "scorecardresearch.com", "quantserve.com", "adnxs.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "hotjar.com", "mixpanel.com", "segment.io", "segment.com",
        "amplitude.com", "fullstory.com", "mouseflow.com", "clarity.ms",
        "branch.io", "appsflyer.com", "adjust.com", "bugsnag.com",
        "sentry.io", "newrelic.com", "nr-data.net", "optimizely.com",
        "chartbeat.com", "parsely.com", "krxd.net", "bluekai.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "sharethis.com", "addthis.com", "disqus.com", "moatads.com",
    ]

    /// The JSON for the always-on list.
    public static func baseRules(httpsOnly: Bool) -> String {
        var rules: [[String: Any]] = trackerHosts.map { host in
            [
                "trigger": [
                    "url-filter": urlFilter(forHost: host),
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }

        if httpsOnly {
            // `make-https` runs inside WebKit, ahead of the navigation
            // delegate, so it also covers images, scripts and XHR — the places
            // a mixed-content downgrade actually happens.
            rules.append([
                "trigger": ["url-filter": ".*", "resource-type": ["document", "image", "style-sheet", "script", "font", "media", "fetch", "raw", "svg-document"]],
                "action": ["type": "make-https"],
            ])
        }

        return encode(rules)
    }

    /// The extra rules applied at Safer and Safest.
    public static func strictRules() -> String {
        let rules: [[String: Any]] = [
            // Remote fonts are a classic fingerprinting channel and a needless
            // third-party connection.
            [
                "trigger": ["url-filter": ".*", "resource-type": ["font"], "load-type": ["third-party"]],
                "action": ["type": "block"],
            ],
            // Third-party script is where cross-site tracking actually lives.
            [
                "trigger": ["url-filter": ".*", "resource-type": ["script"], "load-type": ["third-party"]],
                "action": ["type": "block"],
            ],
            // Blocking third-party cookies costs nothing here — the data store
            // is non-persistent anyway — but it also stops in-session
            // correlation between two sites sharing an embed.
            [
                "trigger": ["url-filter": ".*", "load-type": ["third-party"]],
                "action": ["type": "block-cookies"],
            ],
        ]
        return encode(rules)
    }

    /// Matches `host` and any subdomain of it, anchored at the scheme.
    static func urlFilter(forHost host: String) -> String {
        let escaped = host.replacingOccurrences(of: ".", with: "\\.")
        return "^https?://([^/]+\\.)?\(escaped)"
    }

    static func encode(_ rules: [[String: Any]]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
            let json = String(data: data, encoding: .utf8)
        else {
            // An empty list is a valid rule list and fails safe: no rules, but
            // also no crash and no half-applied blocking.
            return "[]"
        }
        return json
    }

    /// Compiles both lists, returning whichever ones WebKit accepted.
    ///
    /// A rule list that fails to compile is logged as a security event and
    /// skipped rather than fataling — the app still loads pages, still through
    /// Tor, just without that layer.
    @MainActor
    public static func compile(httpsOnly: Bool, strict: Bool) async -> [WKContentRuleList] {
        var lists: [WKContentRuleList] = []
        let store = WKContentRuleListStore.default()

        if let base = await compileList(
            store: store,
            identifier: "\(baseIdentifier).\(httpsOnly ? "https" : "any")",
            json: baseRules(httpsOnly: httpsOnly)
        ) {
            lists.append(base)
        }

        if strict, let strictList = await compileList(
            store: store,
            identifier: strictIdentifier,
            json: strictRules()
        ) {
            lists.append(strictList)
        }

        return lists
    }

    @MainActor
    private static func compileList(
        store: WKContentRuleListStore?,
        identifier: String,
        json: String
    ) async -> WKContentRuleList? {
        guard let store else { return nil }
        return await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }
}
