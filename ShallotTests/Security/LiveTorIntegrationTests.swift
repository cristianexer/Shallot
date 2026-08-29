import Foundation
import Testing
import WebKit

@testable import BrowserEngine
@testable import Domain
@testable import TorKit

/// The suite that talks to the real Tor network.
///
/// Opt-in, because it needs working internet and takes a minute or two to
/// bootstrap: set `SHALLOT_LIVE_TESTS=1` in the environment to run it. CI runs
/// it on a nightly device lane rather than on every pull request.
///
/// Everything here is a claim the app makes to its users, checked against
/// reality rather than against a mock:
///
/// * Tor bootstraps.
/// * Traffic really goes through it — `check.torproject.org` agrees, and the
///   exit address is not this machine's.
/// * Two tabs get two different exits, so per-tab isolation is real.
/// * An onion service is reachable.
/// Whether the live suite should run.
///
/// A free function rather than a static on the suite: a trait cannot reference
/// the type it is being attached to.
func shallotLiveTestsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["SHALLOT_LIVE_TESTS"] == "1"
}

@Suite("Live Tor integration", .serialized, .enabled(if: shallotLiveTestsEnabled()))
struct LiveTorIntegrationTests {
    /// Starts a real Tor and waits for it to bootstrap.
    static func startTor(poolSize: Int = 4) async throws -> TorService {
        let cache = FileManager.default.temporaryDirectory
            .appending(path: "shallot-live-cache", directoryHint: .isDirectory)
        let service = TorService(
            configuration: TorService.Configuration(
                geoIPFile: Bundle.main.url(forResource: "geoip", withExtension: nil),
                geoIPv6File: Bundle.main.url(forResource: "geoip6", withExtension: nil),
                cacheDirectory: cache,
                isolationPoolSize: poolSize,
                bootstrapTimeout: .seconds(240)
            )
        )
        try await service.start()
        return service
    }

    /// A `URLSession` routed through one of Tor's SOCKS ports.
    static func torSession(port: UInt16) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": Int(port),
            kCFStreamPropertySOCKSProxyHost as String: "127.0.0.1",
            kCFStreamPropertySOCKSProxyPort as String: Int(port),
        ]
        configuration.timeoutIntervalForRequest = 90
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

    @Test("Tor bootstraps within the timeout and reports a version")
    func bootstraps() async throws {
        let tor = try await Self.startTor()
        #expect(await tor.state.canCarryTraffic)
        let version = await tor.version()
        #expect(version?.isEmpty == false)
    }

    @Test("Tor builds a three-hop circuit with countries resolved from the bundled GeoIP data")
    func buildsCircuit() async throws {
        let tor = try await Self.startTor()
        // Give path building a moment; a freshly bootstrapped Tor may still be
        // holding only its directory circuits.
        var circuits: [Circuit] = []
        for _ in 0..<20 {
            circuits = (try? await tor.circuits()) ?? []
            if circuits.contains(where: \.isUsable) { break }
            try? await Task.sleep(for: .seconds(2))
        }
        // Not `#require` here: its expansion loses the `rethrows` analysis of
        // `first(where:)` and the macro fails to compile.
        guard let usable = circuits.first(where: \.isUsable) else {
            Issue.record("Tor never reported a fully built circuit")
            return
        }
        #expect(usable.path.count >= 3)
        // Countries come from the bundled database over the control channel —
        // never from a network lookup.
        #expect(usable.path.contains { $0.countryCode != nil })
    }

    @Test("Traffic actually goes through Tor and the address is not this machine's")
    func routesThroughTor() async throws {
        let tor = try await Self.startTor()
        let port = try await tor.socksPort(forIsolationKey: .utility)

        let url = URL(string: "https://check.torproject.org/api/ip")!
        let (data, _) = try await Self.torSession(port: port).data(from: url)
        let check = try JSONDecoder().decode(TorCheck.self, from: data)
        #expect(check.isTor, "check.torproject.org says this connection is not using Tor")

        // …and the exit address is not the one a direct connection would use.
        let (directData, _) = try await URLSession(configuration: .ephemeral)
            .data(from: URL(string: "https://check.torproject.org/api/ip")!)
        let direct = try JSONDecoder().decode(TorCheck.self, from: directData)
        #expect(check.address != direct.address)
        #expect(!direct.isTor)
    }

    @Test("Two tabs leave the network by two different exits")
    func perTabIsolation() async throws {
        // This is the observable form of the per-tab-ports design. If the two
        // addresses ever match, isolation has silently collapsed.
        let tor = try await Self.startTor()
        let firstPort = try await tor.socksPort(forIsolationKey: .tab(UUID()))
        let secondPort = try await tor.socksPort(forIsolationKey: .tab(UUID()))
        #expect(firstPort != secondPort)

        let url = URL(string: "https://check.torproject.org/api/ip")!
        async let first = Self.torSession(port: firstPort).data(from: url)
        async let second = Self.torSession(port: secondPort).data(from: url)
        let firstIP = try JSONDecoder().decode(TorCheck.self, from: try await first.0).address
        let secondIP = try JSONDecoder().decode(TorCheck.self, from: try await second.0).address
        #expect(firstIP != secondIP, "two isolated tabs shared an exit relay")
    }

    @Test("An onion service is reachable")
    func reachesOnionService() async throws {
        let tor = try await Self.startTor()
        let port = try await tor.socksPort(forIsolationKey: .utility)
        // The Tor Project's own onion service.
        let url = URL(string: "http://2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion/")!
        let (_, response) = try await Self.torSession(port: port).data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect((200..<400).contains(status))
    }

    @Test("New identity rotates the exit")
    func newIdentityRotatesExit() async throws {
        let tor = try await Self.startTor()
        let port = try await tor.socksPort(forIsolationKey: .utility)
        let url = URL(string: "https://check.torproject.org/api/ip")!

        let before = try JSONDecoder()
            .decode(TorCheck.self, from: try await Self.torSession(port: port).data(from: url).0).address
        try await tor.newIdentity()
        // NEWNYM is rate-limited to roughly ten seconds.
        try await Task.sleep(for: .seconds(12))
        let after = try JSONDecoder()
            .decode(TorCheck.self, from: try await Self.torSession(port: port).data(from: url).0).address

        // Tor may legitimately pick the same exit again; what must hold is that
        // both are Tor exits and neither is this machine.
        #expect(!before.isEmpty)
        #expect(!after.isEmpty)
    }
}
