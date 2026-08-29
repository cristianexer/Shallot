import Foundation
import Testing

@testable import Domain

@Suite("Bridge line parsing")
struct BridgeLineParserTests {
    @Test("A plain address and port parses as a vanilla bridge")
    func vanilla() throws {
        let line = try BridgeLineParser.parse("192.0.2.10:9001")
        #expect(line.transport == .vanilla)
        #expect(line.address == "192.0.2.10")
        #expect(line.port == 9001)
        #expect(line.fingerprint == nil)
    }

    @Test("The torrc keyword is tolerated")
    func stripsKeyword() throws {
        let line = try BridgeLineParser.parse("Bridge 192.0.2.10:9001")
        #expect(line.address == "192.0.2.10")
    }

    @Test("A fingerprint after the endpoint is captured and upper-cased")
    func fingerprint() throws {
        let fingerprint = String(repeating: "a1b2", count: 10)
        let line = try BridgeLineParser.parse("192.0.2.10:9001 \(fingerprint)")
        #expect(line.fingerprint == fingerprint.uppercased())
    }

    @Test("An obfs4 line keeps its parameters and its exact text")
    func obfs4() throws {
        let raw = "obfs4 192.0.2.10:9001 \(String(repeating: "AB", count: 20)) cert=abcDEF123 iat-mode=0"
        let line = try BridgeLineParser.parse(raw)
        #expect(line.transport == .obfs4)
        #expect(line.parameters["cert"] == "abcDEF123")
        #expect(line.parameters["iat-mode"] == "0")
        // Handed to Tor verbatim, so nothing is lost in translation.
        #expect(line.torrcValue == raw)
    }

    @Test("An obfs4 line without a cert is refused rather than silently failing later")
    func obfs4NeedsCert() {
        #expect(throws: BridgeLineParser.ParseError.self) {
            try BridgeLineParser.parse("obfs4 192.0.2.10:9001 \(String(repeating: "AB", count: 20))")
        }
    }

    @Test("IPv6 endpoints in brackets parse")
    func ipv6() throws {
        let line = try BridgeLineParser.parse("[2001:db8::1]:443")
        #expect(line.address == "2001:db8::1")
        #expect(line.port == 443)
    }

    @Test("Snowflake lines parse and keep their url parameter")
    func snowflake() throws {
        let line = try BridgeLineParser.parse("snowflake 192.0.2.3:80 \(String(repeating: "CD", count: 20)) url=https://example.org/")
        #expect(line.transport == .snowflake)
        #expect(line.parameters["url"] == "https://example.org/")
    }

    @Test("Malformed lines throw rather than crash", arguments: [
        "", "not-an-address", "192.0.2.10:notaport", "192.0.2.10:0", "obfs4",
    ])
    func malformed(_ input: String) {
        #expect(throws: (any Error).self) { try BridgeLineParser.parse(input) }
    }

    @Test("A bad fingerprint is reported as such")
    func badFingerprint() {
        #expect(throws: BridgeLineParser.ParseError.invalidFingerprint("zzzz")) {
            try BridgeLineParser.parse("192.0.2.10:9001 zzzz")
        }
    }

    @Test("A paste keeps the good lines and reports the bad ones")
    func mixedPaste() {
        let text = """
            # bridges from BridgeDB
            192.0.2.10:9001
            garbage line here

            192.0.2.11:9002
            """
        let result = BridgeLineParser.parseAll(text)
        // "garbage line here" has spaces, so it fails on the port; the comment
        // and the blank line are skipped entirely.
        #expect(result.lines.count == 2)
        #expect(result.errors.count == 1)
    }

    @Test("Only vanilla bridges work without a transport binary")
    func transportRequirements() {
        #expect(!BridgeTransport.vanilla.requiresTransportProvider)
        #expect(BridgeTransport.obfs4.requiresTransportProvider)
        #expect(BridgeTransport.snowflake.requiresTransportProvider)
    }

    @Test("A config is only effective when enabled and usable")
    func effectiveness() {
        #expect(!BridgeConfig(isEnabled: false, transport: .vanilla, lines: []).isEffective)
        #expect(!BridgeConfig(isEnabled: true, transport: .obfs4, lines: []).isEffective)
        // Snowflake ships with a default bridge, so no lines is still valid.
        #expect(BridgeConfig(isEnabled: true, transport: .snowflake, lines: []).isEffective)
    }
}

@Suite("Browsing session")
@MainActor
struct BrowsingSessionTests {
    @Test("Opening a tab makes it active")
    func opening() {
        let session = BrowsingSession()
        let tab = session.openTab(url: nil)
        #expect(session.activeTabID == tab.id)
        #expect(session.tabs.count == 1)
    }

    @Test("Every tab gets its own isolation key")
    func distinctIsolation() {
        let session = BrowsingSession()
        let first = session.openTab(url: nil)
        let second = session.openTab(url: nil)
        #expect(first.isolationKey != second.isolationKey)
    }

    @Test("Closing the active tab activates its neighbour")
    func closingActivatesNeighbour() {
        let session = BrowsingSession()
        let first = session.openTab(url: nil)
        let second = session.openTab(url: nil)
        let third = session.openTab(url: nil)
        session.selectTab(second.id)
        session.closeTab(second.id)
        #expect(session.activeTabID == third.id)
        #expect(session.tabs.map(\.id) == [first.id, third.id])
    }

    @Test("Closing the last tab leaves nothing active")
    func closingLast() {
        let session = BrowsingSession()
        let tab = session.openTab(url: nil)
        session.closeTab(tab.id)
        #expect(session.tabs.isEmpty)
        #expect(session.activeTabID == nil)
    }

    @Test("The tab count is bounded, recycling the oldest inactive tab")
    func boundedTabs() {
        let session = BrowsingSession(maximumTabs: 3)
        var ids: [UUID] = []
        for _ in 0..<6 { ids.append(session.openTab(url: nil).id) }
        #expect(session.tabs.count <= 3)
        #expect(session.activeTabID == ids.last)
    }

    @Test("Closing every tab clears the session")
    func closeAll() {
        let session = BrowsingSession()
        _ = session.openTab(url: nil)
        _ = session.openTab(url: nil)
        session.closeAllTabs()
        #expect(session.tabs.isEmpty)
        #expect(session.activeTabID == nil)
    }

    @Test("ensureActiveTab always yields something to show")
    func ensureActive() {
        let session = BrowsingSession()
        let tab = session.ensureActiveTab()
        #expect(session.activeTabID == tab.id)
        #expect(session.ensureActiveTab().id == tab.id)
    }

    @Test("Selecting a tab that is gone is ignored")
    func selectMissing() {
        let session = BrowsingSession()
        let tab = session.openTab(url: nil)
        session.selectTab(UUID())
        #expect(session.activeTabID == tab.id)
    }
}

@Suite("Async broadcast")
struct AsyncBroadcastTests {
    @Test("Every subscriber receives every value")
    func fansOut() async {
        var broadcast = AsyncBroadcast<Int>()
        let first = broadcast.stream()
        let second = broadcast.stream()
        broadcast.yield(1)
        broadcast.yield(2)
        broadcast.finish()

        var firstValues: [Int] = []
        for await value in first { firstValues.append(value) }
        var secondValues: [Int] = []
        for await value in second { secondValues.append(value) }

        #expect(firstValues == [1, 2])
        #expect(secondValues == [1, 2])
    }

    @Test("A priming value is replayed so late subscribers see current state")
    func primes() async {
        var broadcast = AsyncBroadcast<String>()
        let stream = broadcast.stream(priming: "current")
        broadcast.finish()
        var values: [String] = []
        for await value in stream { values.append(value) }
        #expect(values == ["current"])
    }

    @Test("Subscribers are counted so leaks are visible")
    func counts() {
        var broadcast = AsyncBroadcast<Int>()
        _ = broadcast.stream()
        _ = broadcast.stream()
        #expect(broadcast.subscriberCount == 2)
        broadcast.finish()
        #expect(broadcast.subscriberCount == 0)
    }
}
