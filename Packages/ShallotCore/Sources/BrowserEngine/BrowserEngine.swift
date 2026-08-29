import Domain
import Foundation
import WebKit

/// Owns every tab's web view and enforces the engine-level security controls.
///
/// Nothing above this type touches WebKit. Everything below the app's UI —
/// the proxy, the kill switch, the leak mitigations, the rule lists, the
/// security level — is applied here, in one place, on the way in.
@MainActor
@Observable
public final class BrowserEngine {
    /// The kill switch input.
    ///
    /// Set from the Tor state stream. While this is `false` no session will
    /// load anything: not a page, not a sub-resource, not a redirect. It is
    /// what stops a clearnet request when Tor drops mid-session.
    public var canCarryTraffic: Bool = false {
        didSet {
            guard oldValue != canCarryTraffic, !canCarryTraffic else { return }
            for session in sessions.values { session.stopLoading() }
            report(.init(kind: .killSwitch, message: "tor stopped · loads blocked"))
        }
    }

    /// Current user settings. Read on every navigation decision.
    public var settings: AppSettings

    /// Where security events go. Weak: the monitor outlives nothing here.
    public weak var monitor: (any MonitorFeeding)?

    private var sessions: [UUID: TabSession] = [:]
    private var ruleLists: [WKContentRuleList] = []
    /// The rule-list shape currently compiled, so we only recompile on change.
    private var compiledSignature: String?

    public init(settings: AppSettings = .default, monitor: (any MonitorFeeding)? = nil) {
        self.settings = settings
        self.monitor = monitor
    }

    /// Number of live web views. Used by the low-memory path and by tests
    /// asserting that tab churn does not leak sessions.
    public var sessionCount: Int { sessions.count }

    // MARK: - Rule lists

    /// Compiles the content rule lists for the current settings.
    ///
    /// Call before creating the first session, and again after the security
    /// level or HTTPS-only changes. Existing sessions keep the lists they were
    /// built with until they are rebuilt — which is what happens on the next
    /// New Identity, and what the Settings screen tells the user.
    public func prepareRuleLists() async {
        let strict = SecurityPolicy.usesStrictRules(settings.securityLevel)
        let signature = "\(settings.httpsOnly)|\(strict)"
        guard signature != compiledSignature else { return }
        ruleLists = await ContentBlocker.compile(httpsOnly: settings.httpsOnly, strict: strict)
        compiledSignature = signature
    }

    // MARK: - Sessions

    /// The session for `tab`, creating it if this is the first time.
    ///
    /// - Parameter socksPort: The isolated Tor port assigned to this tab. It is
    ///   fixed for the life of the session, because the proxy cannot be changed
    ///   on a live web view.
    /// - Returns: `nil` if a proxied session could not be built. The caller must
    ///   treat that as a refusal to browse, never as a reason to fall back.
    @discardableResult
    public func session(for tab: BrowserTab, socksPort: UInt16) -> TabSession? {
        if let existing = sessions[tab.id] { return existing }
        guard let session = TabSession(
            tab: tab,
            socksPort: socksPort,
            settings: settings,
            ruleLists: ruleLists,
            engine: self
        ) else {
            report(.init(kind: .failure, message: "refused to open a tab without a proxy"))
            return nil
        }
        tab.socksPort = socksPort
        sessions[tab.id] = session
        return session
    }

    public func existingSession(for tabID: UUID) -> TabSession? {
        sessions[tabID]
    }

    /// Loads `url` in `tab`, building the session if needed.
    public func load(_ url: URL, in tab: BrowserTab, socksPort: UInt16) {
        guard let session = session(for: tab, socksPort: socksPort) else { return }
        session.load(url)
    }

    /// Destroys one tab's session and wipes its data store.
    public func destroySession(for tabID: UUID) async {
        guard let session = sessions.removeValue(forKey: tabID) else { return }
        await session.teardown()
    }

    /// Destroys everything. Used by New Identity and by clear-on-exit.
    public func destroyAllSessions() async {
        let all = sessions
        sessions.removeAll()
        for session in all.values {
            await session.teardown()
        }
        // Any store that somehow outlived its session still goes.
        await WKWebsiteDataStore.nonPersistent().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }

    /// Sheds the web views of tabs that are not in front.
    ///
    /// Called under memory pressure. Tor stays up — dropping the engine would
    /// be far more disruptive than reloading a background tab.
    public func shedInactiveSessions(keeping activeTabID: UUID?) async {
        for (id, session) in sessions where id != activeTabID {
            sessions.removeValue(forKey: id)
            await session.teardown()
        }
    }

    // MARK: - Events

    /// Records a security event, if anything is listening.
    public func report(_ event: SecurityEvent) {
        monitor?.record(event)
    }
}
