import Foundation
import ObjectiveC.runtime
import WebKit

/// Turns leaky WebKit features off inside the engine, where the running WebKit
/// gives us a way to.
///
/// ### Why this is written so defensively
///
/// WebKit's feature switches are not public API. They live behind
/// `+[WKPreferences _features]` and `-[WKPreferences _setEnabled:forFeature:]`,
/// the key strings move between releases, and on any given OS a feature may
/// simply not be listed. So every call here is guarded by a runtime check and
/// this type never throws, never crashes, and reports exactly what it managed
/// to turn off.
///
/// **This is the second layer, not the first.** The guaranteed mitigation is
/// the `.atDocumentStart` user script in `LeakMitigations`, which removes the
/// APIs from every page's global scope before any page script runs. If this
/// type disables nothing at all, the app is still protected — it just protects
/// at the JavaScript boundary rather than inside the engine.
///
/// Keeping every SPI name in this one file is deliberate: when Apple ships the
/// OS-level fix, this is the only place to revisit.
@MainActor
public enum WebKitFeatureFlags {
    /// What a pass actually managed to do.
    public struct Outcome: Sendable, Equatable {
        /// Feature keys that were found and switched off.
        public var disabled: [String] = []
        /// Feature keys we looked for and this OS did not expose.
        public var notFound: [String] = []
        /// True when the SPI itself is missing, so nothing could be attempted.
        public var interfaceUnavailable = false
    }

    /// Feature-key fragments, matched case-insensitively against `_WKFeature.key`.
    ///
    /// Fragments rather than exact names, because the keys have been spelled
    /// several different ways across releases.
    enum Fragments {
        static let webTransport = ["webtransport"]
        static let webAuthn = ["webauthentication", "webauthn", "relatedorigin", "digitalcredential"]
        static let webRTC = ["peerconnection", "webrtc", "mediarecorder", "mediastream"]
        static let dnsPrefetch = ["dnsprefetch"]
    }

    /// Disables everything `configuration` asks to block.
    @discardableResult
    public static func apply(
        _ configuration: LeakMitigations.Configuration,
        to preferences: WKPreferences
    ) -> Outcome {
        var wanted: [String] = []
        if configuration.blockWebTransport { wanted += Fragments.webTransport }
        if configuration.blockWebAuthn { wanted += Fragments.webAuthn }
        if configuration.blockWebRTC { wanted += Fragments.webRTC }
        if configuration.blockDNSPrefetch { wanted += Fragments.dnsPrefetch }
        return disableFeatures(matching: wanted, in: preferences)
    }

    /// Switches off every exposed feature whose key contains one of `fragments`.
    @discardableResult
    static func disableFeatures(matching fragments: [String], in preferences: WKPreferences) -> Outcome {
        var outcome = Outcome()
        guard !fragments.isEmpty else { return outcome }

        guard let features = availableFeatures(), let setter = featureSetter() else {
            outcome.interfaceUnavailable = true
            outcome.notFound = fragments
            return outcome
        }

        var matchedFragments = Set<String>()
        for feature in features {
            guard let key = (feature as AnyObject).value(forKey: "key") as? String else { continue }
            let lowered = key.lowercased()
            guard let fragment = fragments.first(where: { lowered.contains($0) }) else { continue }
            setter(preferences, Selector(("_setEnabled:forFeature:")), false, feature)
            outcome.disabled.append(key)
            matchedFragments.insert(fragment)
        }
        outcome.notFound = fragments.filter { !matchedFragments.contains($0) }
        return outcome
    }

    /// `+[WKPreferences _features]`, or `nil` when this OS does not expose it.
    static func availableFeatures() -> [AnyObject]? {
        let selector = Selector(("_features"))
        let metaclass: AnyObject = WKPreferences.self
        guard metaclass.responds(to: selector) else { return nil }
        guard let unmanaged = metaclass.perform(selector) else { return nil }
        return unmanaged.takeUnretainedValue() as? [AnyObject]
    }

    /// A typed function pointer for `-[WKPreferences _setEnabled:forFeature:]`.
    ///
    /// `perform(_:with:with:)` cannot carry a `BOOL` argument, so the method's
    /// implementation is fetched and called directly.
    static func featureSetter() -> ((WKPreferences, Selector, Bool, AnyObject) -> Void)? {
        typealias Implementation = @convention(c) (AnyObject, Selector, ObjCBool, AnyObject) -> Void
        let selector = Selector(("_setEnabled:forFeature:"))
        guard WKPreferences.instancesRespond(to: selector) else { return nil }
        guard let method = class_getInstanceMethod(WKPreferences.self, selector) else { return nil }
        let implementation = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
        return { preferences, selector, enabled, feature in
            implementation(preferences, selector, ObjCBool(enabled), feature)
        }
    }
}
