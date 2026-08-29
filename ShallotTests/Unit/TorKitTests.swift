import Foundation
import Testing

@testable import Domain
@testable import TorKit

@Suite("Circuit status parsing")
struct CircuitStatusParserTests {
    /// A captured `GETINFO circuit-status` data block, including the shapes Tor
    /// only emits under load: a pathless LAUNCHED circuit, a relay with no
    /// nickname, and the `=` separator used for named relays.
    static let fixture = """
        1 BUILT $AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA~frankfurtnode,$BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB~amsixmid,$CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC~parisexit9 BUILD_FLAGS=NEED_CAPACITY PURPOSE=GENERAL TIME_CREATED=2026-08-29T09:00:00.000000
        2 LAUNCHED  BUILD_FLAGS=NEED_CAPACITY PURPOSE=GENERAL
        3 BUILT $DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=namedrelay,$EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE PURPOSE=HS_CLIENT_REND
        4 FAILED $FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF~deadguard PURPOSE=GENERAL REASON=TIMEOUT
        """

    @Test("Every line becomes a circuit")
    func parsesAllLines() {
        #expect(CircuitStatusParser.parse(Self.fixture).count == 4)
    }

    @Test("A built three-hop circuit is parsed in full")
    func parsesBuiltCircuit() throws {
        let circuit = try #require(CircuitStatusParser.parse(Self.fixture).first)
        #expect(circuit.id == "1")
        #expect(circuit.status == .built)
        #expect(circuit.purpose == "GENERAL")
        #expect(circuit.path.count == 3)
        #expect(circuit.path[0].nickname == "frankfurtnode")
        #expect(circuit.path[0].position == .guardRelay)
        #expect(circuit.path[1].position == .middle)
        #expect(circuit.path[2].position == .exit)
        #expect(circuit.isUsable)
    }

    @Test("A pathless LAUNCHED circuit does not mistake its flags for a path")
    func handlesPathlessCircuit() throws {
        let circuits = CircuitStatusParser.parse(Self.fixture)
        let launched = try #require(circuits.first { $0.id == "2" })
        #expect(launched.status == .launched)
        #expect(launched.path.isEmpty)
        #expect(launched.purpose == "GENERAL")
        #expect(!launched.isUsable)
    }

    @Test("Both long-name separators are understood, and a bare fingerprint works")
    func handlesLongNameForms() throws {
        let circuits = CircuitStatusParser.parse(Self.fixture)
        let circuit = try #require(circuits.first { $0.id == "3" })
        #expect(circuit.path[0].nickname == "namedrelay")
        #expect(circuit.path[1].nickname == "")
        #expect(circuit.path[1].fingerprint == String(repeating: "E", count: 40))
        // Two hops is not a browsing path, so it must not be offered as one.
        #expect(!circuit.isUsable)
    }

    @Test("An unknown status does not throw away the circuit")
    func unknownStatus() {
        let circuit = CircuitStatusParser.parseLine("9 SOMETHINGNEW $AA~x PURPOSE=GENERAL")
        #expect(circuit?.status == .unknown)
    }

    @Test("Junk lines are dropped rather than crashing", arguments: ["", "   ", "1", "\n"])
    func ignoresJunk(_ line: String) {
        #expect(CircuitStatusParser.parseLine(line) == nil)
    }

    @Test("Long names split on either separator")
    func splitsLongNames() {
        #expect(CircuitStatusParser.splitLongName("$ABC~nick") == ("ABC", "nick"))
        #expect(CircuitStatusParser.splitLongName("$ABC=nick") == ("ABC", "nick"))
        #expect(CircuitStatusParser.splitLongName("$ABC") == ("ABC", ""))
        #expect(CircuitStatusParser.splitLongName("ABC") == ("ABC", ""))
    }

    @Test("A named relay's = separator is not mistaken for an attribute")
    func namedRelaySeparator() {
        // Tor writes a Named relay as `$fingerprint=nickname`. Treating any
        // field containing `=` as a KEY=VALUE attribute silently dropped the
        // whole path for those circuits.
        #expect(!CircuitStatusParser.isAttribute("$AAAA=namedrelay,$BBBB"))
        #expect(CircuitStatusParser.isAttribute("PURPOSE=GENERAL"))
        #expect(CircuitStatusParser.isAttribute("BUILD_FLAGS=NEED_CAPACITY"))
        #expect(CircuitStatusParser.isAttribute("TIME_CREATED=2026-08-29T09:00:00"))
        #expect(!CircuitStatusParser.isAttribute("$AAAA~nick"))
    }

    @Test("A single-hop path is labelled as a guard, not an exit")
    func singleHopPosition() {
        let path = CircuitStatusParser.parsePath("$AA~only")
        #expect(path.count == 1)
        #expect(path[0].position == .guardRelay)
    }
}

@Suite("Router status parsing")
struct RouterStatusParserTests {
    @Test("The relay address is taken from the r line")
    func findsAddress() {
        let raw = """
            r frankfurtnode AAAAAAAAAAAAAAAAAAAAAAAA BBBBBBBBBBBBBBBBBBBBBBBB 2026-08-29 09:00:00 192.0.2.42 9001 9030
            s Fast Guard Running Stable Valid
            w Bandwidth=12000
            """
        #expect(RouterStatusParser.address(in: raw) == "192.0.2.42")
    }

    @Test("Output without an r line yields nothing rather than a wrong answer")
    func missingLine() {
        #expect(RouterStatusParser.address(in: "s Fast Guard\nw Bandwidth=1") == nil)
        #expect(RouterStatusParser.address(in: "") == nil)
    }
}

@Suite("SOCKS port pool")
struct SocksPortPoolTests {
    let ports: [UInt16] = [39_051, 39_052, 39_053, 39_054]

    @Test("A key keeps the same port across calls, so a tab keeps its circuit")
    func assignmentIsStable() {
        var pool = SocksPortPool(ports: ports)
        let key = IsolationKey.tab(UUID())
        let first = pool.port(for: key)
        #expect(pool.port(for: key) == first)
        #expect(pool.assignmentCount == 1)
    }

    @Test("Distinct keys get distinct ports while the pool has room")
    func distinctKeysGetDistinctPorts() {
        var pool = SocksPortPool(ports: ports)
        let assigned = (0..<4).map { _ in pool.port(for: .tab(UUID())) }
        #expect(Set(assigned).count == 4)
        #expect(pool.freePortCount == 0)
    }

    @Test("Past capacity, keys share the least-loaded port rather than failing")
    func sharesWhenExhausted() {
        var pool = SocksPortPool(ports: [39_051, 39_052])
        let first = pool.port(for: .tab(UUID()))
        let second = pool.port(for: .tab(UUID()))
        let third = pool.port(for: .tab(UUID()))
        #expect(first != second)
        #expect([first, second].contains(third))
        #expect(pool.assignmentCount == 3)
    }

    @Test("Releasing frees the port again")
    func releaseFreesPort() {
        var pool = SocksPortPool(ports: ports)
        let key = IsolationKey.tab(UUID())
        _ = pool.port(for: key)
        #expect(pool.freePortCount == 3)
        pool.release(key)
        #expect(pool.freePortCount == 4)
        #expect(!pool.isAssigned(key))
    }

    @Test("Releasing an unknown key is a no-op, not corruption")
    func releaseUnknown() {
        var pool = SocksPortPool(ports: ports)
        pool.release(.tab(UUID()))
        pool.release(.tab(UUID()))
        #expect(pool.freePortCount == 4)
    }

    @Test("Rapid open/close churn leaks no ports")
    func churnDoesNotLeak() {
        // Losing a port on every close would silently collapse isolation long
        // before it ever became visible in the UI.
        var pool = SocksPortPool(ports: ports)
        for _ in 0..<500 {
            let key = IsolationKey.tab(UUID())
            _ = pool.port(for: key)
            pool.release(key)
        }
        #expect(pool.freePortCount == ports.count)
        #expect(pool.assignmentCount == 0)
    }

    @Test("Double release does not free a port twice")
    func doubleRelease() {
        var pool = SocksPortPool(ports: ports)
        let key = IsolationKey.tab(UUID())
        _ = pool.port(for: key)
        pool.release(key)
        pool.release(key)
        #expect(pool.freePortCount == 4)
    }

    @Test("New identity drops every assignment")
    func releaseAll() {
        var pool = SocksPortPool(ports: ports)
        for _ in 0..<4 { _ = pool.port(for: .tab(UUID())) }
        pool.releaseAll()
        #expect(pool.assignmentCount == 0)
        #expect(pool.freePortCount == 4)
    }
}

@Suite("Port reservation")
struct PortReservationTests {
    @Test("Reservation returns the requested number of distinct ports")
    func reservesDistinctPorts() throws {
        let ports = try PortReservation.reserve(count: 6, from: 41_000)
        #expect(ports.count == 6)
        #expect(Set(ports).count == 6)
        #expect(ports.allSatisfy { $0 >= 41_000 })
    }

    @Test("A port that nothing is listening on reads as available")
    func availability() {
        #expect(PortReservation.isAvailable(41_500))
    }

    @Test("An impossible request throws rather than returning too few")
    func exhaustion() {
        #expect(throws: PortReservation.Error.self) {
            try PortReservation.reserve(count: 50, from: 41_600, window: 3)
        }
    }
}

@Suite("Pluggable transport availability")
struct TransportAvailabilityTests {
    @Test("Plain bridges need no provider")
    func vanillaAlwaysAvailable() {
        #expect(TransportAvailability.isAvailable(.vanilla, provider: nil))
    }

    @Test("Obfuscating transports are unavailable without a provider")
    func obfuscatedNeedProvider() {
        #expect(!TransportAvailability.isAvailable(.obfs4, provider: nil))
        #expect(!TransportAvailability.isAvailable(.snowflake, provider: nil))
    }

    @Test("A provider that supports a transport makes it available")
    func withProvider() {
        struct StubProvider: PluggableTransportProviding {
            func supports(_ transport: BridgeTransport) -> Bool { transport == .obfs4 }
            func start(_ transport: BridgeTransport) async throws -> UInt16 { 39_999 }
            func stop() async {}
        }
        #expect(TransportAvailability.isAvailable(.obfs4, provider: StubProvider()))
        #expect(!TransportAvailability.isAvailable(.snowflake, provider: StubProvider()))
    }

    @Test("The ClientTransportPlugin line is the shape Tor expects")
    func transportPluginLine() {
        struct StubProvider: PluggableTransportProviding {
            func supports(_ transport: BridgeTransport) -> Bool { true }
            func start(_ transport: BridgeTransport) async throws -> UInt16 { 39_999 }
            func stop() async {}
        }
        #expect(
            StubProvider().clientTransportPluginValue(for: .obfs4, port: 39_999)
                == "obfs4 socks5 127.0.0.1:39999"
        )
    }
}
