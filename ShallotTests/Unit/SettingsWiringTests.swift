import Foundation
import WebKit
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

/// The two journeys a person takes constantly, checked end to end.
///
/// Both of these were reported as broken from a real device, which is exactly
/// the class of bug a view-model test catches and a screenshot does not.
@Suite("Browser journeys")
@MainActor
struct BrowserJourneyTests {
    /// A full coordinator over test doubles, taken through its launch
    /// sequence — which is what opens the engine's kill switch.
    static func makeApp(
        behaviour: MockTorService.Behaviour = .immediate
    ) async -> (AppModel, MockTorService, BrowserEngine) {
        let tor = MockTorService(behaviour: behaviour)
        let engine = BrowserEngine(settings: .default, monitor: nil)
        let monitor = MockMonitorFeed(events: [])
        let model = AppModel(
            tor: tor,
            engine: engine,
            session: BrowsingSession(),
            favouritesRepository: InMemoryFavouritesRepository(favourites: Favourite.journeySamples),
            settingsStore: InMemorySettingsStore(),
            monitorFeed: monitor,
            lock: MockAppLock(),
            appVersion: "test"
        )
        await model.start()
        _ = await waitUntil { engine.canCarryTraffic }
        return (model, tor, engine)
    }

    @discardableResult
    static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("Tapping a favourite closes the sheet and goes to the page")
    func openingAFavouriteNavigates() async throws {
        let (model, tor, _) = await Self.makeApp()
        _ = tor

        // As a phone would have it: the favourites list presented over the
        // browser.
        model.show(.favourites, isCompact: true)
        #expect(model.presentedSection == .favourites)

        let favourite = try #require(model.favourites.favourites.first)
        model.favourites.openFavourite(favourite)

        #expect(model.presentedSection == nil, "the sheet should close")
        #expect(model.section == .browser, "and the browser should be in front")
        #expect(
            await Self.waitUntil { model.browser.addressText.contains(favourite.url.host() ?? "") },
            "the favourite's address should be the one being opened, was \(model.browser.addressText)"
        )
    }

    @Test("On an iPad the same tap selects the browser rather than dismissing a sheet")
    func openingAFavouriteOnTheSplitShell() async throws {
        let (model, tor, _) = await Self.makeApp()
        _ = tor
        model.show(.favourites, isCompact: false)
        #expect(model.section == .favourites)
        #expect(model.presentedSection == nil)

        let favourite = try #require(model.favourites.favourites.first)
        model.favourites.openFavourite(favourite)
        #expect(model.section == .browser)
    }

    @Test("Reload asks the page to load again, and the tab shows that it is loading")
    func reloadRestartsTheLoad() async throws {
        let (model, tor, engine) = await Self.makeApp()
        _ = tor

        let url = URL(string: "https://example.org/article")!
        model.browser.open(url: url)
        #expect(
            await Self.waitUntil { engine.sessionCount == 1 },
            "opening should have built a session"
        )
        let tab = try #require(model.browser.activeTab)
        let session = try #require(engine.existingSession(for: tab.id))

        // Settle first, so the reload is what the assertion sees rather than
        // the tail of the original load.
        _ = await Self.waitUntil(timeout: .seconds(8)) { !session.webView.isLoading }

        model.browser.reload()
        #expect(
            await Self.waitUntil(timeout: .seconds(8)) { model.browser.isLoading || session.webView.isLoading },
            "reload should have started a load the omnibar can show progress for"
        )
    }

    @Test("Reload still works after a load that never arrived")
    func reloadAfterAFailedLoad() async throws {
        // The scripted Tor hands out a port nothing is listening on, so this
        // load fails — which is the case that matters. `url` never commits, and
        // reload used to key off `url`, so the one moment someone reaches for
        // reload was the one moment it was greyed out.
        let (model, tor, engine) = await Self.makeApp()
        _ = tor

        let url = URL(string: "https://unreachable.invalid/page")!
        model.browser.open(url: url)
        #expect(await Self.waitUntil { engine.sessionCount == 1 })

        let tab = try #require(model.browser.activeTab)
        // Deliberately not waiting for the load to fail: how long a dead port
        // takes to give up is a property of the machine, not of the app, and
        // this test is about what the tab remembers and what reload then does.
        #expect(
            await Self.waitUntil { tab.requestedURL == url },
            "the tab remembers what it was asked for"
        )
        #expect(model.browser.canReload, "and reload must be available to try again")

        // What reload will *do* is asserted as a value rather than by racing
        // the load: against a dead port the retry fails again faster than a
        // poll can see it start.
        let session = try #require(engine.existingSession(for: tab.id))
        #expect(
            ReloadPolicy.plan(
                canCarryTraffic: engine.canCarryTraffic,
                isShowingErrorPage: true,
                committedURL: session.webView.url,
                requestedURL: tab.requestedURL
            ) == .load(url),
            "reload should ask for the address again rather than doing nothing"
        )
    }

    @Test("Reload is refused while Tor is not carrying traffic")
    func reloadRespectsTheKillSwitch() async throws {
        let (model, tor, engine) = await Self.makeApp()
        _ = tor
        model.browser.open(url: URL(string: "https://example.org")!)
        #expect(await Self.waitUntil { engine.sessionCount == 1 })

        engine.canCarryTraffic = false
        model.browser.reload()
        let tab = try #require(model.browser.activeTab)
        #expect(
            await Self.waitUntil { if case .failed = tab.loadState { true } else { false } },
            "reloading with Tor down should be refused, not attempted"
        )
        _ = tor
    }
}

extension Favourite {
    /// A saved site for the journey tests.
    static let journeySamples: [Favourite] = [
        Favourite(title: "Example", url: URL(string: "https://example.org/start")!, sortIndex: 0)
    ]
}
