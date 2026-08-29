import Foundation
import SwiftUI
import Testing
import TorKit

@testable import BrowserEngine
@testable import Domain
@testable import Features

// MARK: - Shared helpers

/// Waits for `condition` to hold, and gives up rather than hanging when it
/// never does.
///
/// Several of these view models do their work in a detached `Task`, so the
/// effect lands some time after the call returns. A bounded poll keeps that
/// honest: a broken expectation fails the test instead of wedging the suite.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Everything a `BrowserViewModel` needs, wired to the in-memory doubles.
@MainActor
private struct BrowserHarness {
    let tor: MockTorService
    let session: BrowsingSession
    let engine: BrowserEngine
    let settingsStore: InMemorySettingsStore
    let monitor: MockMonitorFeed
    let favourites: InMemoryFavouritesRepository
    let viewModel: BrowserViewModel

    init(
        behaviour: MockTorService.Behaviour = .immediate,
        settings: AppSettings = .default,
        saved: [Favourite] = []
    ) {
        tor = MockTorService(behaviour: behaviour)
        session = BrowsingSession()
        engine = BrowserEngine(settings: settings)
        settingsStore = InMemorySettingsStore(settings: settings)
        // An empty event log, so every assertion below is about an event this
        // test caused rather than about the preview samples.
        monitor = MockMonitorFeed(events: [])
        favourites = InMemoryFavouritesRepository(favourites: saved)
        viewModel = BrowserViewModel(
            session: session,
            tor: tor,
            engine: engine,
            settingsStore: settingsStore,
            monitor: monitor,
            favourites: favourites
        )
    }

    func startTor() async {
        try? await tor.start()
    }
}

// MARK: - Browser

@Suite("Browser omnibar")
@MainActor
struct BrowserOmnibarTests {
    @Test("A bare host is opened as a URL rather than searched for")
    func bareHostBecomesAURL() async {
        let harness = BrowserHarness()
        await harness.startTor()
        let model = harness.viewModel

        model.addressText = "example.org"
        model.submitAddress()

        #expect(model.addressText == "https://example.org")
        let loaded = await waitUntil { harness.engine.sessionCount == 1 }
        #expect(loaded, "the host was never handed to the engine")
        #expect(model.pendingURL == nil)
    }

    @Test("A multi-word query goes to the configured search engine")
    func queryGoesToSearchEngine() async throws {
        let harness = BrowserHarness(settings: AppSettings(searchEngine: .duckDuckGo))
        await harness.startTor()
        let model = harness.viewModel

        model.addressText = "how to use tor"
        model.submitAddress()

        let expected = try #require(SearchEngine.duckDuckGo.searchURL(for: "how to use tor"))
        // Pins that the engine actually consulted is the configured one, not
        // the default onion engine it was built with.
        #expect(expected.host() == "duckduckgo.com")
        #expect(model.addressText == expected.absoluteString)
        let loaded = await waitUntil { harness.engine.sessionCount == 1 }
        #expect(loaded, "the search URL was never handed to the engine")
    }

    @Test("An invalid onion address is refused, logged, and never loaded")
    func invalidOnionIsNeverLoaded() async throws {
        let harness = BrowserHarness()
        await harness.startTor()
        let model = harness.viewModel
        await model.onAppear()
        let tab = try #require(model.activeTab)

        model.addressText = "abcdefg.onion"
        model.submitAddress()

        // The whole point: a typo-squat of a real service must not be resolved
        // even once, so there is nothing to observe on the wire.
        #expect(tab.url == nil)
        #expect(model.pendingURL == nil)
        #expect(tab.loadState == .failed(message: "Not a valid onion address"))
        #expect(
            harness.monitor.events.contains {
                $0.kind == .leakBlocked && $0.message.contains("abcdefg.onion")
            }
        )
    }

    @Test("An empty omnibar does nothing at all")
    func emptyInputIsIgnored() async {
        let harness = BrowserHarness()
        await harness.startTor()
        let model = harness.viewModel

        model.addressText = "   "
        model.submitAddress()

        #expect(model.tabs.isEmpty)
        #expect(harness.engine.sessionCount == 0)
    }
}

@Suite("Browser kill switch")
@MainActor
struct BrowserKillSwitchTests {
    @Test("No web view is created while Tor is still bootstrapping, and the destination is held")
    func heldUntilTorIsCarryingTraffic() async {
        let harness = BrowserHarness(behaviour: .stalled)
        await harness.startTor()
        let model = harness.viewModel
        let destination = URL(string: "https://example.org/page")!

        model.open(url: destination)

        let held = await waitUntil { model.pendingURL == destination }
        #expect(held, "the destination was dropped instead of held")
        // A web view without a proxy is a clearnet leak, so none is built at
        // all — the refusal happens before WebKit is involved.
        #expect(harness.engine.sessionCount == 0)
        #expect(harness.monitor.events.contains { $0.kind == .killSwitch })

        await harness.tor.forceState(.running)
        await model.torBecameReady()

        #expect(model.pendingURL == nil)
        #expect(harness.engine.sessionCount == 1)
    }

    @Test("Nothing is held when there was nothing to hold")
    func readinessWithNoPendingLoadJustPreparesATab() async {
        let harness = BrowserHarness(behaviour: .stalled)
        await harness.startTor()
        await harness.tor.forceState(.running)

        await harness.viewModel.torBecameReady()

        #expect(harness.viewModel.pendingURL == nil)
        #expect(harness.viewModel.tabs.count == 1)
    }
}

@Suite("Browser tabs")
@MainActor
struct BrowserTabTests {
    @Test("A new tab becomes the active one and clears the omnibar")
    func newTabBecomesActive() {
        let harness = BrowserHarness(behaviour: .stalled)
        let model = harness.viewModel
        model.addressText = "left over"

        let first = model.newTab()
        let second = model.newTab()

        #expect(model.tabs.map(\.id) == [first.id, second.id])
        #expect(harness.session.activeTabID == second.id)
        #expect(model.addressText.isEmpty)
        #expect(!model.isEditingAddress)
    }

    @Test("Closing a tab hands the front position to a neighbour")
    func closingActivatesNeighbour() async {
        let harness = BrowserHarness(behaviour: .stalled)
        let model = harness.viewModel
        let first = model.newTab()
        let second = model.newTab()

        model.closeTab(second.id)

        #expect(model.tabs.map(\.id) == [first.id])
        #expect(harness.session.activeTabID == first.id)
        let settled = await waitUntil { model.activeTab?.id == first.id }
        #expect(settled)
    }

    @Test("Closing the last tab still leaves a tab to show")
    func closingTheLastTabLeavesAStartPage() async {
        let harness = BrowserHarness(behaviour: .stalled)
        let model = harness.viewModel
        let only = model.newTab()

        model.closeTab(only.id)

        // Landing on nothing at all would read as the app having crashed.
        let replaced = await waitUntil { model.tabs.count == 1 }
        #expect(replaced, "closing the last tab left nothing to show")
        #expect(model.activeTab != nil)
        #expect(model.activeTab?.id != only.id)
        #expect(harness.session.activeTabID == model.activeTab?.id)
    }
}

@Suite("Browser favourites and per-site exceptions")
@MainActor
struct BrowserPageActionTests {
    @Test("Saving the active page adds it, and saving again removes it")
    func toggleFavourite() {
        let harness = BrowserHarness(behaviour: .stalled)
        let model = harness.viewModel
        let tab = model.newTab()
        tab.url = URL(string: "https://example.org/news")!
        tab.title = "Example News"

        #expect(!model.isActivePageSaved)

        model.toggleFavourite()

        #expect(model.isActivePageSaved)
        #expect(harness.favourites.favourites.count == 1)
        #expect(harness.favourites.favourites.first?.title == "Example News")

        model.toggleFavourite()

        #expect(!model.isActivePageSaved)
        #expect(harness.favourites.favourites.isEmpty)
    }

    @Test("An untitled page is saved under its host")
    func titlelessPageFallsBackToHost() {
        let harness = BrowserHarness(behaviour: .stalled)
        let model = harness.viewModel
        let tab = model.newTab()
        tab.url = URL(string: "https://example.org/news")!

        model.toggleFavourite()

        #expect(harness.favourites.favourites.first?.title == "example.org")
    }

    @Test("Allowing JavaScript raises this tab only and grants an exception for that host only")
    func javaScriptExceptionIsScopedToOneHost() {
        let harness = BrowserHarness(
            behaviour: .stalled,
            settings: AppSettings(securityLevel: .safest)
        )
        let model = harness.viewModel
        let tab = model.newTab()
        tab.url = URL(string: "https://broken.example/app")!

        model.allowJavaScriptForActiveTab()

        #expect(tab.securityLevelOverride == .safer)
        let settings = harness.settingsStore.settings
        #expect(settings.allows(.javaScript, on: "broken.example"))
        // The escape hatch is per site: granting it here must not weaken
        // anywhere else, nor unlock any other feature.
        #expect(!settings.allows(.javaScript, on: "other.example"))
        #expect(!settings.allows(.webRTC, on: "broken.example"))
        #expect(settings.securityLevel == .safest)
    }
}

@Suite("Browser circuit isolation")
@MainActor
struct BrowserIsolationTests {
    @Test("Each tab is given its own SOCKS port when circuits are isolated per tab")
    func isolatedTabsGetDistinctPorts() async {
        let harness = BrowserHarness(settings: AppSettings(isolateCircuitPerTab: true))
        await harness.startTor()
        let first = harness.session.openTab(url: nil)
        let second = harness.session.openTab(url: nil)

        await harness.viewModel.prepareSession(for: first)
        await harness.viewModel.prepareSession(for: second)

        #expect(first.socksPort != nil)
        #expect(second.socksPort != nil)
        #expect(first.socksPort != second.socksPort)
        let checkedOut = await harness.tor.checkedOutPortCount
        #expect(checkedOut == 2)
    }

    @Test("Tabs share the utility port when circuit isolation is off")
    func sharedPortWhenIsolationIsOff() async {
        let harness = BrowserHarness(settings: AppSettings(isolateCircuitPerTab: false))
        await harness.startTor()
        let first = harness.session.openTab(url: nil)
        let second = harness.session.openTab(url: nil)

        await harness.viewModel.prepareSession(for: first)
        await harness.viewModel.prepareSession(for: second)

        #expect(first.socksPort != nil)
        #expect(first.socksPort == second.socksPort)
        let checkedOut = await harness.tor.checkedOutPortCount
        #expect(checkedOut == 1)
        let utilityPort = try? await harness.tor.socksPort(forIsolationKey: .utility)
        #expect(utilityPort == first.socksPort)
    }

    @Test("Preparing a tab twice reuses the session it already has")
    func preparingIsIdempotent() async {
        let harness = BrowserHarness()
        await harness.startTor()
        let tab = harness.session.openTab(url: nil)

        await harness.viewModel.prepareSession(for: tab)
        let port = tab.socksPort
        await harness.viewModel.prepareSession(for: tab)

        #expect(harness.engine.sessionCount == 1)
        #expect(tab.socksPort == port)
    }
}

// MARK: - Favourites

/// Captures the URLs the favourites screen asked the browser to open.
@MainActor
private final class OpenRecorder {
    var urls: [URL] = []
}

@Suite("Favourites")
@MainActor
struct FavouritesViewModelTests {
    private static let onionHost = String(repeating: "a", count: 56) + ".onion"

    private func makeModel(
        saved: [Favourite] = [],
        recorder: OpenRecorder = OpenRecorder()
    ) -> (FavouritesViewModel, InMemoryFavouritesRepository) {
        let repository = InMemoryFavouritesRepository(favourites: saved)
        let model = FavouritesViewModel(
            repository: repository,
            open: { url in recorder.urls.append(url) }
        )
        return (model, repository)
    }

    @Test("A valid v3 onion address is accepted and defaulted to http")
    func addsOnionAddress() throws {
        let (model, repository) = makeModel()
        model.beginAdding()
        model.newTitle = "Hidden"
        model.newAddress = Self.onionHost

        model.commitAdd()

        let saved = try #require(repository.favourites.first)
        // Onion services carry their own transport security and usually never
        // obtained a certificate for port 443.
        #expect(saved.url.absoluteString == "http://\(Self.onionHost)")
        #expect(saved.isOnion)
        #expect(model.errorMessage == nil)
        #expect(!model.isAdding)
    }

    @Test("A valid https address is accepted")
    func addsHTTPSAddress() throws {
        let (model, repository) = makeModel()
        model.beginAdding()
        model.newTitle = "Example"
        model.newAddress = "https://example.org/news"

        model.commitAdd()

        let saved = try #require(repository.favourites.first)
        #expect(saved.url.absoluteString == "https://example.org/news")
        #expect(model.errorMessage == nil)
        #expect(!model.isAdding)
    }

    @Test("Text that is not an address is refused and nothing is saved")
    func refusesNonAddress() {
        let (model, repository) = makeModel()
        model.beginAdding()
        model.newTitle = "Nonsense"
        model.newAddress = "just some words"

        model.commitAdd()

        #expect(repository.favourites.isEmpty)
        #expect(model.errorMessage == "That is not an address Shallot can open.")
        // The sheet stays open so the user can correct the address.
        #expect(model.isAdding)
    }

    @Test("A malformed onion address is refused by name")
    func refusesInvalidOnion() {
        let (model, repository) = makeModel()
        model.beginAdding()
        model.newAddress = "abcdefg.onion"

        model.commitAdd()

        #expect(repository.favourites.isEmpty)
        #expect(model.errorMessage?.contains("abcdefg.onion") == true)
        #expect(model.errorMessage?.contains("v3 onion") == true)
    }

    @Test("Renaming loads the current title and stores the new one")
    func rename() throws {
        let (model, repository) = makeModel(saved: Favourite.samples)
        let target = try #require(repository.favourites.first)

        model.beginRenaming(target)
        #expect(model.editedTitle == target.title)

        model.editedTitle = "  Renamed  "
        model.commitRename()

        #expect(repository.favourites.first?.title == "Renamed")
        #expect(model.editing == nil)
    }

    @Test("A rename to nothing is discarded rather than saved")
    func emptyRenameIsDiscarded() throws {
        let (model, repository) = makeModel(saved: Favourite.samples)
        let target = try #require(repository.favourites.first)

        model.beginRenaming(target)
        model.editedTitle = "   "
        model.commitRename()

        // A blank title would leave an unidentifiable tile on the grid.
        #expect(repository.favourites.first?.title == target.title)
        #expect(model.editing == nil)
    }

    @Test("Deleting removes exactly the one favourite")
    func delete() throws {
        let (model, repository) = makeModel(saved: Favourite.samples)
        let target = try #require(repository.favourites.first)

        model.delete(target)

        #expect(repository.favourites.count == Favourite.samples.count - 1)
        #expect(!repository.favourites.contains { $0.id == target.id })
    }

    @Test("Onion and clearnet favourites are listed separately and completely")
    func partition() {
        let (model, _) = makeModel(saved: Favourite.samples)

        #expect(model.onionFavourites.allSatisfy { $0.isOnion })
        #expect(model.clearnetFavourites.allSatisfy { !$0.isOnion })
        #expect(model.onionFavourites.count == 3)
        #expect(model.clearnetFavourites.count == 2)
        #expect(model.onionFavourites.count + model.clearnetFavourites.count == model.favourites.count)
        #expect(!model.isEmpty)
    }

    @Test("Opening a favourite hands its URL to the browser")
    func openFavourite() throws {
        let recorder = OpenRecorder()
        let (model, repository) = makeModel(saved: Favourite.samples, recorder: recorder)
        let target = try #require(repository.favourites.first)

        model.openFavourite(target)

        #expect(recorder.urls == [target.url])
    }
}

// MARK: - Monitor

@Suite("Monitor")
@MainActor
struct MonitorViewModelTests {
    private static let failedCircuit = Circuit(
        id: "2",
        status: .failed,
        path: Circuit.sample.path,
        purpose: "GENERAL"
    )
    private static let twoHopCircuit = Circuit(
        id: "3",
        status: .built,
        path: Array(Circuit.sample.path.prefix(2)),
        purpose: "GENERAL"
    )

    private func makeModel(feed: MockMonitorFeed) -> MonitorViewModel {
        MonitorViewModel(feed: feed, onNewIdentity: {})
    }

    @Test("Only fully built three-hop circuits are counted")
    func circuitCountIgnoresUnusableCircuits() {
        let feed = MockMonitorFeed(
            circuits: [Self.failedCircuit, Self.twoHopCircuit, .sample]
        )
        let model = makeModel(feed: feed)

        #expect(model.circuits.count == 3)
        #expect(model.circuitCount == 1)
    }

    @Test("The displayed path is the primary circuit's, skipping unusable ones")
    func pathComesFromThePrimaryCircuit() {
        let feed = MockMonitorFeed(
            circuits: [Self.failedCircuit, Self.twoHopCircuit, .sample]
        )
        let model = makeModel(feed: feed)

        #expect(model.path == Circuit.sample.path)
        #expect(model.hasCircuit)
    }

    @Test("With no usable circuit there is no path to show")
    func noCircuitMeansNoPath() {
        let model = makeModel(feed: MockMonitorFeed(circuits: [Self.failedCircuit]))

        #expect(model.path.isEmpty)
        #expect(!model.hasCircuit)
        #expect(model.circuitCount == 0)
    }

    @Test("Sparkline values are normalised into 0...1 with the peak at the top")
    func sparklineIsNormalised() {
        let feed = MockMonitorFeed(bandwidthHistory: BandwidthSample.sampleHistory)
        let model = makeModel(feed: feed)

        #expect(model.sparkline.count == BandwidthSample.sampleHistory.count)
        #expect(model.sparkline.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(model.sparkline.contains { $0 > 0.99 })
    }

    @Test("An idle connection produces a flat sparkline rather than a division by zero")
    func sparklineSurvivesZeroTraffic() {
        let idle = (0..<4).map { _ in BandwidthSample(downBytes: 0, upBytes: 0, interval: 1) }
        let model = makeModel(feed: MockMonitorFeed(bandwidthHistory: idle))

        #expect(model.sparkline == [0, 0, 0, 0])
    }

    @Test("With no samples yet there is no sparkline")
    func sparklineIsEmptyWithoutSamples() {
        let model = makeModel(feed: MockMonitorFeed(bandwidthHistory: []))

        #expect(model.sparkline.isEmpty)
    }

    @Test("Recent events honour the limit and are newest first")
    func recentEventsAreBoundedAndOrdered() throws {
        let feed = MockMonitorFeed(events: SecurityEvent.samples)
        let model = makeModel(feed: feed)

        #expect(model.recentEvents(limit: 3).count == 3)
        #expect(model.recentEvents(limit: 3).map(\.id) == SecurityEvent.samples.prefix(3).map(\.id))
        #expect(model.recentEvents(limit: 99).count == SecurityEvent.samples.count)

        let newest = SecurityEvent(kind: .circuitBuilt, message: "circuit built · 3 hops")
        feed.record(newest)

        let head = try #require(model.recentEvents(limit: 1).first)
        #expect(head.id == newest.id)
    }

    @Test("Asking for a new circuit reaches the feed and clears the working flag")
    func requestNewCircuitReachesTheFeed() async {
        let feed = MockMonitorFeed()
        let model = makeModel(feed: feed)

        await model.requestNewCircuit()

        #expect(feed.didRequestNewCircuit)
        #expect(!model.isWorking)
    }
}

// MARK: - Settings

@Suite("Settings")
@MainActor
struct SettingsViewModelTests {
    private func makeModel(
        store: InMemorySettingsStore,
        availability: @escaping (BridgeTransport) -> Bool = {
            TransportAvailability.isAvailable($0, provider: nil)
        }
    ) -> SettingsViewModel {
        SettingsViewModel(
            store: store,
            appVersion: "1.0 (test)",
            torVersion: { "0.4.8.x (mock)" },
            transportAvailability: availability,
            onSettingsChanged: { _ in }
        )
    }

    @Test("Every setter is written straight through to the store")
    func settersPersist() {
        let store = InMemorySettingsStore()
        let model = makeModel(store: store)

        model.setSecurityLevel(.safest)
        model.setSearchEngine(.startpage)
        model.setHTTPSOnly(false)
        model.setBlockWebRTC(false)
        model.setBlockWebAuthn(false)
        model.setBlockWebTransport(false)
        model.setBlockDNSPrefetch(false)
        model.setIsolateCircuitPerTab(false)
        model.setClearOnExit(false)
        model.setRequireBiometricUnlock(true)
        model.setHideInAppSwitcher(false)

        let settings = store.settings
        #expect(settings.securityLevel == .safest)
        #expect(settings.searchEngine == .startpage)
        #expect(!settings.httpsOnly)
        #expect(!settings.blockWebRTC)
        #expect(!settings.blockWebAuthn)
        #expect(!settings.blockWebTransport)
        #expect(!settings.blockDNSPrefetch)
        #expect(!settings.isolateCircuitPerTab)
        #expect(!settings.clearOnExit)
        #expect(settings.requireBiometricUnlock)
        #expect(!settings.hideInAppSwitcher)
        #expect(model.settings == settings)
    }

    @Test("Changing bridges raises the relaunch notice")
    func bridgeChangeNeedsRelaunch() {
        let store = InMemorySettingsStore()
        let model = makeModel(store: store)
        #expect(!model.needsRelaunchForBridges)

        model.setBridgesEnabled(true)

        // The embedded Tor keeps process-global state and cannot be
        // reconfigured in place, so the user has to be told.
        #expect(model.needsRelaunchForBridges)

        model.setTransport(.snowflake)
        #expect(store.settings.bridges.transport == .snowflake)
        #expect(model.needsRelaunchForBridges)
    }

    @Test("Committing bridge lines keeps the good ones and names the bad ones")
    func commitBridgeLines() {
        let fingerprint = String(repeating: "A", count: 40)
        let store = InMemorySettingsStore()
        let model = makeModel(store: store)
        model.bridgeText = """
            192.0.2.10:9001
            obfs4 203.0.113.4:443 \(fingerprint) cert=abcdef iat-mode=0
            obfs4 198.51.100.7:8080 \(fingerprint)
            definitely not a bridge
            """

        model.commitBridgeLines()

        // A censored user pastes a whole block; rejecting all of it because one
        // line is mangled would leave them with no way to connect.
        let lines = store.settings.bridges.lines
        #expect(lines.count == 2)
        #expect(lines.map(\.transport) == [.vanilla, .obfs4])
        #expect(lines.first?.address == "192.0.2.10")
        #expect(lines.first?.port == 9001)

        #expect(model.bridgeErrors.count == 2)
        #expect(model.bridgeErrors.contains { $0.contains("198.51.100.7:8080") && $0.contains("cert") })
        #expect(model.bridgeErrors.contains { $0.contains("definitely not a bridge") })
        #expect(!model.isEditingBridges)
    }

    @Test("A plain bridge is usable without a pluggable transport, obfuscating ones are not")
    func transportAvailability() {
        let model = makeModel(store: InMemorySettingsStore())

        // Vanilla is spoken by Tor itself; the others are separate binaries
        // this build does not ship.
        #expect(model.isAvailable(.vanilla))
        #expect(!model.isAvailable(.obfs4))
        #expect(!model.isAvailable(.snowflake))
        #expect(model.unavailableReason(for: .obfs4).contains("obfs4"))
    }

    @Test("Revoking an exception removes it and leaves the others alone")
    func revokeException() {
        var seeded = AppSettings.default
        seeded.setException(.javaScript, on: "broken.example", enabled: true)
        seeded.setException(.webRTC, on: "meet.example", enabled: true)
        let store = InMemorySettingsStore(settings: seeded)
        let model = makeModel(store: store)
        #expect(model.siteExceptions.count == 2)

        model.revokeException(SiteException(host: "broken.example", feature: .javaScript))

        #expect(!store.settings.allows(.javaScript, on: "broken.example"))
        #expect(store.settings.allows(.webRTC, on: "meet.example"))
        #expect(model.siteExceptions.map(\.id) == ["meet.example|webRTC"])
    }

    @Test("The honesty statement is present and names the fingerprinting limitation")
    func honestyStatement() {
        let model = makeModel(store: InMemorySettingsStore())
        let statement = model.honestyStatement.lowercased()

        // Shipped without a disclosure triangle: a user must not have to go
        // looking for what this app cannot do.
        #expect(!statement.isEmpty)
        #expect(statement.contains("fingerprint"))
        #expect(statement.contains("onion"))
        #expect(model.torVersion == "0.4.8.x (mock)")
    }
}

// MARK: - App shell

/// An `AppModel` and the doubles it was built from.
@MainActor
private struct AppHarness {
    let tor: MockTorService
    let engine: BrowserEngine
    let lock: MockAppLock
    let settingsStore: InMemorySettingsStore
    let feed: MockMonitorFeed
    let model: AppModel

    init(
        behaviour: MockTorService.Behaviour = .immediate,
        settings: AppSettings = .default,
        lock appLock: MockAppLock = MockAppLock()
    ) {
        tor = MockTorService(behaviour: behaviour)
        engine = BrowserEngine(settings: settings)
        lock = appLock
        settingsStore = InMemorySettingsStore(settings: settings)
        feed = MockMonitorFeed(events: [])
        model = AppModel(
            tor: tor,
            engine: engine,
            session: BrowsingSession(),
            favouritesRepository: InMemoryFavouritesRepository(),
            settingsStore: settingsStore,
            monitorFeed: feed,
            lock: appLock,
            appVersion: "1.0 (test)"
        )
    }
}

@Suite("App shell launch and kill switch")
@MainActor
struct AppModelLaunchTests {
    @Test("Launching reaches a running Tor and opens the engine's kill switch")
    func startReachesRunning() async {
        let harness = AppHarness()
        #expect(!harness.engine.canCarryTraffic)

        await harness.model.start()

        let running = await waitUntil { harness.model.torState == .running }
        #expect(running)
        let carrying = await waitUntil { harness.engine.canCarryTraffic }
        #expect(carrying)
        #expect(harness.model.torVersion == "0.4.8.x (mock)")
    }

    @Test("Tor dropping mid-session closes the kill switch again")
    func torDroppingClosesTheKillSwitch() async {
        let harness = AppHarness()
        await harness.model.start()
        let carrying = await waitUntil { harness.engine.canCarryTraffic }
        #expect(carrying)

        await harness.tor.forceState(.failed(reason: "relay dropped"))

        // This is the leak that matters: traffic must stop the instant Tor
        // stops, without waiting for a navigation to be attempted.
        let stopped = await waitUntil { !harness.engine.canCarryTraffic }
        #expect(stopped, "traffic was still permitted after Tor dropped")
        #expect(harness.model.torState == .failed(reason: "relay dropped"))
    }

    @Test("A failing Tor is reported rather than silently left off")
    func failedStartIsReported() async {
        let harness = AppHarness(behaviour: .failing(reason: "no network"))

        await harness.model.start()

        #expect(!harness.engine.canCarryTraffic)
        if case .failed = harness.model.torState {} else {
            Issue.record("expected a failed state, got \(harness.model.torState)")
        }
        #expect(harness.feed.events.contains { $0.kind == .failure })
    }

    @Test("Launching twice does not start Tor twice")
    func startIsIdempotent() async {
        let harness = AppHarness()
        await harness.model.start()
        let running = await waitUntil { harness.model.torState == .running }
        #expect(running)

        await harness.tor.forceState(.off)
        await harness.model.start()

        let torState = await harness.tor.state
        #expect(torState == .off)
    }
}

@Suite("App shell scene phases")
@MainActor
struct AppModelScenePhaseTests {
    @Test("Going inactive raises the app-switcher shield")
    func inactiveObscures() {
        let harness = AppHarness()

        harness.model.handle(scenePhase: .inactive)

        // `.inactive` is when the switcher snapshot is taken, so the shield has
        // to be up before `.background` is ever reached.
        #expect(harness.model.isObscured)

        harness.model.handle(scenePhase: .active)
        #expect(!harness.model.isObscured)
    }

    @Test("Going to the background locks the app when biometric unlock is required")
    func backgroundLocks() {
        let lock = MockAppLock(isAvailable: true)
        let harness = AppHarness(
            settings: AppSettings(requireBiometricUnlock: true),
            lock: lock
        )

        harness.model.handle(scenePhase: .background)

        #expect(harness.model.isObscured)
        #expect(lock.isLocked)
    }

    @Test("Going to the background does not lock when unlock was not asked for")
    func backgroundDoesNotLockByDefault() {
        let lock = MockAppLock(isAvailable: true)
        let harness = AppHarness(lock: lock)

        harness.model.handle(scenePhase: .background)

        #expect(harness.model.isObscured)
        #expect(!lock.isLocked)
    }

    @Test("Going to the background does not lock a device with no biometry")
    func backgroundDoesNotLockWithoutBiometry() {
        let lock = MockAppLock(isAvailable: false)
        let harness = AppHarness(
            settings: AppSettings(requireBiometricUnlock: true),
            lock: lock
        )

        harness.model.handle(scenePhase: .background)

        // Locking behind an unavailable authenticator would strand the user.
        #expect(!lock.isLocked)
    }
}
