import Foundation
import Testing
import WebKit

@testable import BrowserEngine
@testable import Domain
@testable import TorKit

/// Whether the live suite should run.
///
/// A free function rather than a static on the suite, because a trait cannot
/// reference the type it is attached to.
func shallotLiveTestsEnabled() -> Bool {
    if ProcessInfo.processInfo.environment["SHALLOT_LIVE_TESTS"] == "1" { return true }
    // `xcodebuild` does not forward its own environment to a test host running
    // in the simulator, so a marker file on the shared filesystem is the
    // reliable switch from the command line:
    //
    //     touch /tmp/shallot-live-tests
    return FileManager.default.fileExists(atPath: "/tmp/shallot-live-tests")
}

/// The suite that talks to the real Tor network.
///
/// Opt-in, because it needs working internet and spends a minute or two
/// bootstrapping. CI runs it on a nightly lane rather than on every pull
/// request; everything else in the test suite is hermetic.
///
/// Each test here is a claim the app makes to its users, checked against
/// reality rather than against a mock: that Tor bootstraps, that traffic really
/// goes through it, that two tabs leave by two different exits, and that an
/// onion service is reachable.
@Suite("Live Tor integration", .serialized, .enabled(if: shallotLiveTestsEnabled()))
struct LiveTorIntegrationTests {
    /// One Tor for the whole suite.
    ///
    /// The embedded Tor library keeps process-global state and cannot be
    /// restarted in-process, so a second `start()` in the same test run would
    /// not be a fresh Tor — it would be undefined behaviour. `.serialized`
    /// above plus this shared actor is what keeps that honest.
    actor SharedTor {
        static let shared = SharedTor()
        private var service: TorService?
        private var startTask: Task<TorService, Error>?

        func service(poolSize: Int = 4) async throws -> TorService {
            if let service { return service }
            if let startTask { return try await startTask.value }
            let task = Task<TorService, Error> {
                let cache = FileManager.default.temporaryDirectory
                    .appending(path: "shallot-live-cache", directoryHint: .isDirectory)
                let service = TorService(
                    configuration: TorService.Configuration(
                        geoIPFile: Bundle.main.url(forResource: "geoip", withExtension: nil),
                        geoIPv6File: Bundle.main.url(forResource: "geoip6", withExtension: nil),
                        cacheDirectory: cache,
                        isolationPoolSize: poolSize,
                        bootstrapTimeout: .seconds(300)
                    )
                )
                try await service.start()
                return service
            }
            startTask = task
            let started = try await task.value
            service = started
            return started
        }
    }

    static func tor() async throws -> TorService {
        try await SharedTor.shared.service()
    }

    /// A `URLSession` routed through one of Tor's SOCKS ports.
    static func torSession(port: UInt16) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFStreamPropertySOCKSProxyHost as String: "127.0.0.1",
            kCFStreamPropertySOCKSProxyPort as String: Int(port),
            kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5,
        ]
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }

    struct TorCheck: Decodable {
        let isTor: Bool
        let address: String

        // check.torproject.org answers with capitalised keys.
        private enum CodingKeys: String, CodingKey {
            case isTor = "IsTor"
            case address = "IP"
        }
    }

    static func checkIP(port: UInt16) async throws -> TorCheck {
        let url = URL(string: "https://check.torproject.org/api/ip")!
        let (data, _) = try await torSession(port: port).data(from: url)
        return try JSONDecoder().decode(TorCheck.self, from: data)
    }

    /// Builds the app's real engine and one proxied session on a live circuit.
    @MainActor
    static func makeLiveSession() async throws -> (engine: BrowserEngine, tab: BrowserTab, session: TabSession) {
        let tor = try await Self.tor()
        let port = try await tor.socksPort(forIsolationKey: .tab(UUID()))
        let engine = BrowserEngine(settings: .default, monitor: nil)
        engine.canCarryTraffic = true
        await engine.prepareRuleLists()
        let tab = BrowserTab()
        let session = try #require(engine.session(for: tab, socksPort: port))
        return (engine, tab, session)
    }

    /// Waits for a load to settle. Bounded, so a dead circuit fails rather than hangs.
    ///
    /// Tor's three-hop path is slow enough that a generous timeout is normal
    /// here; what must not happen is an unbounded wait.
    @MainActor
    static func waitForLoad(_ session: TabSession, tab: BrowserTab, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            switch tab.loadState {
            case .finished:
                return true
            case .failed(let message):
                Issue.record("the load failed: \(message)")
                return false
            case .idle, .loading:
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    // MARK: - Tests

    @Test("Tor bootstraps and reports its version")
    func bootstraps() async throws {
        let tor = try await Self.tor()
        #expect(await tor.state.canCarryTraffic)
        let version = await tor.version()
        #expect(version?.isEmpty == false, "Tor did not report a version over the control channel")
    }

    @Test("A three-hop circuit is built, with countries resolved from the bundled GeoIP data")
    func buildsCircuit() async throws {
        let tor = try await Self.tor()
        // A freshly bootstrapped Tor may still be holding only directory
        // circuits, so give path building a bounded moment.
        var circuits: [Circuit] = []
        for _ in 0..<30 {
            circuits = (try? await tor.circuits()) ?? []
            if circuits.contains(where: \.isUsable) { break }
            try? await Task.sleep(for: .seconds(2))
        }
        // Not `#require(_:_:)` with a comment — the two-argument form's
        // expansion trips the compiler's throwing-call analysis here.
        guard let usable = circuits.first(where: \.isUsable) else {
            Issue.record("Tor never reported a fully built circuit")
            return
        }
        #expect(usable.path.count >= 3)
        // Countries come from the bundled database over the control channel —
        // never from a network lookup.
        #expect(
            usable.path.contains { $0.countryCode != nil },
            "no relay resolved to a country, so the bundled GeoIP data is not being read"
        )
    }

    @Test("Traffic really goes through Tor, and the exit is not this machine")
    func routesThroughTor() async throws {
        let tor = try await Self.tor()
        let port = try await tor.socksPort(forIsolationKey: .utility)

        let throughTor = try await Self.checkIP(port: port)
        #expect(throughTor.isTor, "check.torproject.org says this connection is not using Tor")

        let url = URL(string: "https://check.torproject.org/api/ip")!
        let (directData, _) = try await URLSession(configuration: .ephemeral).data(from: url)
        let direct = try JSONDecoder().decode(TorCheck.self, from: directData)

        #expect(!direct.isTor)
        #expect(throughTor.address != direct.address, "the Tor-routed address matched the direct one")
    }

    @Test("Two tabs leave the network by two different exits")
    func perTabIsolation() async throws {
        // The observable form of the per-tab-ports design. If these ever match,
        // circuit isolation has silently collapsed.
        let tor = try await Self.tor()
        let firstPort = try await tor.socksPort(forIsolationKey: .tab(UUID()))
        let secondPort = try await tor.socksPort(forIsolationKey: .tab(UUID()))
        #expect(firstPort != secondPort)

        async let first = Self.checkIP(port: firstPort)
        async let second = Self.checkIP(port: secondPort)
        let firstResult = try await first
        let secondResult = try await second

        #expect(firstResult.isTor)
        #expect(secondResult.isTor)
        #expect(firstResult.address != secondResult.address, "two isolated tabs shared an exit relay")
    }

    @Test("A page loaded in the app's own web view really goes through Tor")
    @MainActor
    func webViewRoutesThroughTor() async throws {
        // The strongest form of the routing claim: not a `URLSession` standing
        // in for the browser, but the exact web view the app builds — same
        // proxy configuration, same data store, same user scripts — asking
        // check.torproject.org what it sees.
        let harness = try await Self.makeLiveSession()
        defer { Task { await harness.engine.destroyAllSessions() } }

        harness.session.load(URL(string: "https://check.torproject.org/api/ip")!)
        let loaded = await Self.waitForLoad(harness.session, tab: harness.tab, timeout: .seconds(90))
        #expect(loaded, "the page never finished loading over Tor")

        let body = try await harness.session.webView
            .evaluateJavaScript("document.body.innerText") as? String
        let text = try #require(body)
        #expect(text.contains("\"IsTor\":true"), "the web view was not routed through Tor: \(text)")
    }

    @Test("An onion service is reachable from the app's web view")
    @MainActor
    func reachesOnionService() async throws {
        // Deliberately through `WKWebView` rather than `URLSession`.
        // CFNetwork's SOCKS support resolves the hostname locally, so a
        // `.onion` address fails there instantly — and resolving locally is
        // exactly what must never happen. `proxyConfigurations` with a SOCKS5
        // endpoint hands the hostname to Tor, which is why onion addresses work
        // in the app and would not work through a URLSession proxy.
        let harness = try await Self.makeLiveSession()
        defer { Task { await harness.engine.destroyAllSessions() } }

        // The Tor Project's own onion service.
        let onion = URL(string: "http://2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion/")!
        harness.session.load(onion)
        let loaded = await Self.waitForLoad(harness.session, tab: harness.tab, timeout: .seconds(120))
        #expect(loaded, "the onion service never finished loading")

        #expect(harness.session.webView.url?.host()?.hasSuffix(".onion") == true)
        let body = try await harness.session.webView
            .evaluateJavaScript("document.body.innerText") as? String
        #expect((body?.count ?? 0) > 0, "the onion service returned an empty page")
    }

    @Test("New identity is accepted and traffic still flows afterwards")
    func newIdentityKeepsWorking() async throws {
        let tor = try await Self.tor()
        try await tor.newIdentity()
        // NEWNYM is rate-limited to roughly ten seconds, and existing streams
        // keep their circuits until they close, so this asserts that the signal
        // was accepted and the client still works — not that the exit changed,
        // which Tor is free to pick again.
        try await Task.sleep(for: .seconds(12))
        let port = try await tor.socksPort(forIsolationKey: .utility)
        #expect(try await Self.checkIP(port: port).isTor)
    }
}
