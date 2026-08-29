import Foundation
import Testing

@testable import BrowserEngine
@testable import Domain
@testable import Features

/// Proves each setting actually reaches the thing it claims to control.
///
/// A preference screen is the easiest place in an app for a control to look
/// like it works and do nothing — the switch moves, the value persists, and
/// the behaviour never changes. These are the wires.
@Suite("Settings wiring")
@MainActor
struct SettingsWiringTests {
    /// Everything a browser needs, with nothing real behind it.
    struct Harness {
        let tor: MockTorService
        let engine: BrowserEngine
        let store: InMemorySettingsStore
        let session: BrowsingSession
        let monitor: MockMonitorFeed
        let browser: BrowserViewModel
        let settings: SettingsViewModel
    }

    static func makeHarness(
        settings initial: AppSettings = .default,
        behaviour: MockTorService.Behaviour = .immediate
    ) -> Harness {
        let tor = MockTorService(behaviour: behaviour)
        let store = InMemorySettingsStore(settings: initial)
        let monitor = MockMonitorFeed(events: [])
        let engine = BrowserEngine(settings: initial, monitor: monitor)
        let session = BrowsingSession()
        let browser = BrowserViewModel(
            session: session,
            tor: tor,
            engine: engine,
            settingsStore: store,
            monitor: monitor,
            favourites: InMemoryFavouritesRepository()
        )
        let settings = SettingsViewModel(
            store: store,
            appVersion: "test",
            torVersion: { "test" },
            transportAvailability: { !$0.requiresTransportProvider },
            onSettingsChanged: { _ in await browser.applySettingsChange() }
        )
        return Harness(
            tor: tor,
            engine: engine,
            store: store,
            session: session,
            monitor: monitor,
            browser: browser,
            settings: settings
        )
    }

    /// Polls until `condition` holds. Bounded, so a broken wire fails rather
    /// than hangs.
    @discardableResult
    static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - Reaching the engine

    @Test("Every engine-affecting setting reaches the browser engine")
    func settingsReachTheEngine() async {
        let harness = Self.makeHarness()
        #expect(harness.engine.settings.blockWebRTC)

        harness.settings.setBlockWebRTC(false)
        #expect(await Self.waitUntil { !harness.engine.settings.blockWebRTC })

        harness.settings.setSecurityLevel(.safest)
        #expect(await Self.waitUntil { harness.engine.settings.securityLevel == .safest })

        harness.settings.setHTTPSOnly(false)
        #expect(await Self.waitUntil { !harness.engine.settings.httpsOnly })
    }

    @Test("Turning off a leak mitigation tears down the web views built with it")
    func leakToggleRebuildsSessions() async throws {
        // The mitigation is a document-start user script fixed when the web
        // view is built. If the old session survived, the switch would have
        // moved and nothing would have changed until the next new tab.
        let harness = Self.makeHarness()
        try await harness.tor.start()
        let tab = harness.session.openTab(url: URL(string: "https://example.org")!)
        await harness.browser.prepareSession(for: tab)
        #expect(harness.engine.sessionCount == 1)

        harness.settings.setBlockWebAuthn(false)
        #expect(
            await Self.waitUntil { harness.engine.sessionCount == 0 },
            "the session built with the old mitigations should have been torn down"
        )
    }

    @Test("A setting a live web view never sees leaves the open tab alone")
    func unrelatedToggleKeepsSessions() async throws {
        let harness = Self.makeHarness()
        try await harness.tor.start()
        let tab = harness.session.openTab(url: URL(string: "https://example.org")!)
        await harness.browser.prepareSession(for: tab)

        harness.settings.setHideInAppSwitcher(false)
        // Give the change every chance to do the wrong thing.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(
            harness.engine.sessionCount == 1,
            "reloading someone's page because they changed an unrelated switch is gratuitous"
        )
    }

    @Test("A rebuilt session is put back on the page the tab was showing")
    func rebuiltSessionRestoresItsPage() async throws {
        let harness = Self.makeHarness()
        try await harness.tor.start()
        let url = URL(string: "https://example.org/article")!
        let tab = harness.session.openTab(url: url)
        await harness.browser.prepareSession(for: tab)

        harness.settings.setBlockWebRTC(false)
        #expect(await Self.waitUntil { harness.engine.sessionCount == 0 })

        // Coming back to the browser rebuilds it, on the same address.
        await harness.browser.prepareSession(for: tab)
        #expect(harness.engine.sessionCount == 1)
        #expect(harness.browser.activeTab?.url == url)
    }

    // MARK: - Circuit isolation

    @Test("Isolation per tab hands out one port per tab, and one port for all when off")
    func isolationSettingChangesPortAllocation() async throws {
        var isolated = AppSettings.default
        isolated.isolateCircuitPerTab = true
        let harness = Self.makeHarness(settings: isolated)
        try await harness.tor.start()

        let first = harness.session.openTab(url: nil)
        let second = harness.session.openTab(url: nil)
        await harness.browser.prepareSession(for: first)
        await harness.browser.prepareSession(for: second)
        #expect(first.socksPort != second.socksPort)

        let shared = Self.makeHarness(settings: {
            var settings = AppSettings.default
            settings.isolateCircuitPerTab = false
            return settings
        }())
        try await shared.tor.start()
        let third = shared.session.openTab(url: nil)
        let fourth = shared.session.openTab(url: nil)
        await shared.browser.prepareSession(for: third)
        await shared.browser.prepareSession(for: fourth)
        #expect(third.socksPort == fourth.socksPort)
    }

    // MARK: - Bridges and transports

    @Test("A bridge change asks for a relaunch, because Tor only reads them at start-up")
    func bridgeChangeRequestsRelaunch() {
        let harness = Self.makeHarness()
        #expect(!harness.settings.needsRelaunchForBridges)

        harness.settings.setBridgesEnabled(true)
        #expect(harness.settings.needsRelaunchForBridges)
    }

    @Test("The relaunch notice clears once Tor has started with those bridges")
    func relaunchNoticeClearsAfterStart() {
        // Otherwise the notice survives the relaunch that satisfied it and
        // stays on screen forever.
        let harness = Self.makeHarness()
        harness.settings.setBridgesEnabled(true)
        #expect(harness.settings.needsRelaunchForBridges)

        harness.store.markBridgesApplied()
        #expect(!harness.settings.needsRelaunchForBridges)
    }

    @Test("Bridge lines are parsed, kept and reported on")
    func bridgeLinesRoundTrip() {
        let harness = Self.makeHarness()
        harness.settings.bridgeText = """
            192.0.2.10:9001
            not a bridge at all
            192.0.2.11:9002 \(String(repeating: "AB", count: 20))
            """
        harness.settings.commitBridgeLines()

        #expect(harness.settings.settings.bridges.lines.count == 2)
        #expect(harness.settings.bridgeErrors.count == 1)
        #expect(harness.store.settings.bridges.lines.first?.port == 9001)
    }

    @Test("Only the transports this build can actually speak are offered")
    func transportAvailability() {
        // A plain bridge is spoken by Tor itself; obfs4 and Snowflake are
        // separate binaries this build does not bundle. Offering them and then
        // failing to connect is the worst outcome on the one network where a
        // user needs bridges to work.
        let harness = Self.makeHarness()
        #expect(harness.settings.isAvailable(.vanilla))
        #expect(!harness.settings.isAvailable(.obfs4))
        #expect(!harness.settings.isAvailable(.snowflake))
        #expect(harness.settings.unavailableReason(for: .obfs4).contains("Plain bridges work"))
    }

    @Test("A bridge configuration only takes effect when it is usable")
    func bridgeEffectiveness() {
        let harness = Self.makeHarness()
        harness.settings.setBridgesEnabled(true)
        harness.settings.setTransport(.vanilla)
        #expect(!harness.settings.settings.bridges.isEffective, "no lines yet")

        harness.settings.bridgeText = "192.0.2.10:9001"
        harness.settings.commitBridgeLines()
        #expect(harness.settings.settings.bridges.isEffective)
    }

    // MARK: - Per-site exceptions

    @Test("Revoking a per-site exception removes it and rebuilds the tab it applied to")
    func revokingAnExceptionRebuilds() async throws {
        var granted = AppSettings.default
        granted.setException(.webRTC, on: "meet.example", enabled: true)
        let harness = Self.makeHarness(settings: granted)
        try await harness.tor.start()
        let tab = harness.session.openTab(url: URL(string: "https://meet.example")!)
        await harness.browser.prepareSession(for: tab)

        let exception = try #require(harness.settings.siteExceptions.first)
        harness.settings.revokeException(exception)

        #expect(harness.settings.siteExceptions.isEmpty)
        #expect(await Self.waitUntil { harness.engine.sessionCount == 0 })
    }

    // MARK: - Search

    @Test("The chosen search engine is the one a typed query goes to")
    func searchEngineIsUsed() async throws {
        let harness = Self.makeHarness()
        try await harness.tor.start()
        harness.settings.setSearchEngine(.startpage)

        harness.browser.addressText = "how does tor work"
        harness.browser.submitAddress()

        // The omnibar is where the resolved URL lands. The tab's own `url` is
        // set by the web view once it navigates, which a scripted Tor on a dead
        // port never does — so asserting on it here would be testing the mock.
        #expect(
            await Self.waitUntil { harness.browser.addressText.contains("startpage.com") },
            "a typed query should go to the chosen engine, was \(harness.browser.addressText)"
        )
        #expect(harness.browser.addressText.contains("how%20does%20tor%20work"))
    }
}
