import Domain
import Foundation
import WebKit

/// Translates a `SecurityLevel` into concrete WebKit configuration.
///
/// One place, so "what does Safer actually do" has a single answer that a test
/// can assert against.
public enum SecurityPolicy {
    /// Per-navigation preferences for a level.
    ///
    /// `allowsContentJavaScript` is public API and applied in
    /// `webView(_:decidePolicyFor:preferences:decisionHandler:)`. On an engine
    /// we cannot patch, switching JavaScript off is the strongest realistic
    /// anti-fingerprinting lever there is — which is exactly what Safest does.
    public static func webpagePreferences(for level: SecurityLevel) -> WKWebpagePreferences {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = level.allowsJavaScript
        return preferences
    }

    /// Applies the level to a fresh configuration, before the web view exists.
    public static func apply(_ level: SecurityLevel, to configuration: WKWebViewConfiguration) {
        configuration.defaultWebpagePreferences.allowsContentJavaScript = level.allowsJavaScript

        // Media that starts on its own is a network request the user did not
        // ask for, and at Safest it is also a codec-fingerprinting surface.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        // "Look up", "Share" and friends can hand a selection to another
        // process; picture-in-picture keeps a media connection alive outside
        // the page. Neither belongs in a browser whose whole job is to keep
        // what you are reading inside one sandbox.
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.suppressesIncrementalRendering = false
        configuration.upgradeKnownHostsToHTTPS = true
    }

    /// Whether the strict content rule list applies at this level.
    public static func usesStrictRules(_ level: SecurityLevel) -> Bool {
        level.usesStrictBlocking
    }

    /// A short, honest description of what changed, for the toast after a
    /// level switch.
    public static func changeSummary(from old: SecurityLevel, to new: SecurityLevel) -> String {
        guard old != new else { return new.title }
        if new == .safest { return "JavaScript is now off on every site" }
        if old == .safest { return "JavaScript is on again" }
        return new == .standard ? "Blocking relaxed" : "Blocking tightened"
    }
}
