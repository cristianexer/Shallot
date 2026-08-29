import Foundation
import Testing

@testable import Domain
@testable import Monitoring

/// Waits for `condition` to become true, or gives up.
///
/// `MonitorService` consumes the Tor engine's `AsyncStream`s in its own tasks,
/// so nothing it publishes is ready on the line after the trigger. Polling with
/// a deadline keeps that fact from turning into either a flake or a hang.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite("Bandwidth sampling")
struct BandwidthSamplerTests {
    private func sample(down: Int, up: Int = 1_024, interval: TimeInterval = 1) -> BandwidthSample {
        BandwidthSample(downBytes: down, upBytes: up, interval: interval)
    }

    @Test("The window never grows past its size, and the oldest samples fall off")
    func windowIsBounded() {
        var sampler = BandwidthSampler(windowSize: 4)
        for index in 0..<10 {
            sampler.append(sample(down: index * 1_024))
        }

        #expect(sampler.samples.count == 4)
        #expect(sampler.samples.map(\.downBytes) == [6, 7, 8, 9].map { $0 * 1_024 })
        #expect(!sampler.samples.contains { $0.downBytes < 6 * 1_024 })
        #expect(sampler.latest?.downBytes == 9 * 1_024)
    }

    @Test("A window that is not yet full keeps everything in order")
    func partialWindowKeepsEverything() {
        var sampler = BandwidthSampler(windowSize: 48)
        for index in 0..<3 { sampler.append(sample(down: index * 1_024)) }

        #expect(sampler.samples.count == 3)
        #expect(sampler.latest?.downBytes == 2 * 1_024)
    }

    @Test("The peak rate is never zero, so the sparkline never divides by it")
    func peakIsNeverZero() {
        var sampler = BandwidthSampler()
        #expect(sampler.peakDownRate == 1)

        sampler.append(sample(down: 0, up: 0))
        sampler.append(sample(down: 0, up: 0))
        #expect(sampler.peakDownRate == 1)

        sampler.append(sample(down: 10 * 1_024))
        #expect(sampler.peakDownRate == 10)
    }

    @Test("Every sparkline height sits in 0...1 and the peak sample reaches the top")
    func normalisedHeightsAreBounded() {
        var sampler = BandwidthSampler(windowSize: 8)
        for down in [3, 17, 1, 42, 8] {
            sampler.append(sample(down: down * 1_024))
        }
        let heights = sampler.normalisedHeights()

        #expect(heights.count == 5)
        #expect(heights.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(heights[3] == 1.0)
        #expect(heights.max() == 1.0)
    }

    @Test("An empty window draws no sparkline rather than an undefined one")
    func emptyHeights() {
        #expect(BandwidthSampler().normalisedHeights().isEmpty)
    }

    @Test("Differencing two counter readings gives the traffic in between")
    func differenceOfRisingCounters() {
        let delta = BandwidthSampler.difference(
            read: 10_240,
            written: 3_072,
            previousRead: 5_120,
            previousWritten: 1_024,
            interval: 2
        )

        #expect(delta.downBytes == 5_120)
        #expect(delta.upBytes == 2_048)
        #expect(delta.downKilobytesPerSecond == 2.5)
        #expect(delta.upKilobytesPerSecond == 1)
    }

    @Test("A counter that went backwards reports nothing, not a negative rate")
    func counterResetClampsToZero() {
        // Tor restarting its accounting must not spike the chart or draw
        // downwards; zero for that one interval is the honest answer.
        let delta = BandwidthSampler.difference(
            read: 100,
            written: 50,
            previousRead: 500_000,
            previousWritten: 400_000,
            interval: 1
        )

        #expect(delta.downBytes == 0)
        #expect(delta.upBytes == 0)
        #expect(delta.downKilobytesPerSecond == 0)
        #expect(delta.upKilobytesPerSecond == 0)
    }

    @Test("A sample covering no time reports no rate rather than dividing by zero")
    func zeroIntervalYieldsZeroRate() {
        let delta = BandwidthSampler.difference(
            read: 4_096, written: 4_096, previousRead: 0, previousWritten: 0, interval: 0
        )

        #expect(delta.downKilobytesPerSecond == 0)
        #expect(delta.upKilobytesPerSecond == 0)
    }
}

@Suite("The in-memory event log")
struct EventLogTests {
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ message: String,
        kind: SecurityEvent.Kind = .info,
        at offset: TimeInterval = 0
    ) -> SecurityEvent {
        SecurityEvent(timestamp: Self.origin.addingTimeInterval(offset), kind: kind, message: message)
    }

    @Test("The newest event is the first one the terminal shows")
    func newestFirst() {
        var log = EventLog()
        log.append(event("first"))
        log.append(event("second", at: 10))
        log.append(event("third", at: 20))

        #expect(log.events.map(\.message) == ["third", "second", "first"])
    }

    @Test("The log stops at its capacity and forgets the oldest lines")
    func capacityIsBounded() {
        var log = EventLog(capacity: 3)
        for index in 0..<6 {
            log.append(event("event \(index)", at: TimeInterval(index) * 10))
        }

        #expect(log.events.count == 3)
        #expect(log.events.map(\.message) == ["event 5", "event 4", "event 3"])
    }

    @Test("A repeated line within two seconds is coalesced into the one already shown")
    func identicalBurstIsCoalesced() {
        // One sub-resource load can fire this event dozens of times a second;
        // without coalescing it would push everything else off the screen.
        var log = EventLog()
        log.append(event("DNS resolved via Tor · example.org", kind: .dnsViaTor))
        log.append(event("DNS resolved via Tor · example.org", kind: .dnsViaTor, at: 0.5))
        log.append(event("DNS resolved via Tor · example.org", kind: .dnsViaTor, at: 1.9))

        #expect(log.events.count == 1)
    }

    @Test("A different message in the same burst is kept, not swallowed")
    func differentMessageIsNotCoalesced() {
        var log = EventLog()
        log.append(event("DNS resolved via Tor · example.org", kind: .dnsViaTor))
        log.append(event("DNS resolved via Tor · other.example", kind: .dnsViaTor, at: 0.1))

        #expect(log.events.map(\.message) == [
            "DNS resolved via Tor · other.example",
            "DNS resolved via Tor · example.org",
        ])
    }

    @Test("The same message from a different kind of event is kept")
    func differentKindIsNotCoalesced() {
        var log = EventLog()
        log.append(event("example.org", kind: .dnsViaTor))
        log.append(event("example.org", kind: .trackerBlocked, at: 0.1))

        #expect(log.events.count == 2)
        #expect(log.events.first?.kind == .trackerBlocked)
    }

    @Test("The same message more than two seconds later is a new line")
    func repeatAfterTheWindowIsKept() {
        var log = EventLog()
        log.append(event("DNS resolved via Tor · example.org", kind: .dnsViaTor))
        log.append(event("DNS resolved via Tor · example.org", kind: .dnsViaTor, at: 2.5))

        #expect(log.events.count == 2)
    }

    @Test("Coalescing only compares against the newest line, so an interleaved repeat is kept")
    func onlyTheNewestLineCoalesces() {
        var log = EventLog()
        log.append(event("a", kind: .dnsViaTor))
        log.append(event("b", kind: .dnsViaTor, at: 0.1))
        log.append(event("a", kind: .dnsViaTor, at: 0.2))

        #expect(log.events.map(\.message) == ["a", "b", "a"])
    }

    @Test("Clearing leaves nothing behind")
    func clearEmptiesTheLog() {
        var log = EventLog()
        for index in 0..<5 { log.append(event("event \(index)", at: TimeInterval(index) * 10)) }

        log.clear()

        #expect(log.events.isEmpty)
        #expect(log.recent(10).isEmpty)
    }

    @Test("recent(_:) takes from the newest end and never over-reads")
    func recentTakesTheNewest() {
        var log = EventLog()
        for index in 0..<5 { log.append(event("event \(index)", at: TimeInterval(index) * 10)) }

        #expect(log.recent(2).map(\.message) == ["event 4", "event 3"])
        #expect(log.recent(0).isEmpty)
        #expect(log.recent(50).count == 5)
    }
}

@MainActor
@Suite("The monitor service")
struct MonitorServiceTests {
    static let generalCircuit = Circuit(
        id: "1",
        status: .built,
        path: [
            RelayNode(fingerprint: "AAAA1111", nickname: "frankfurtnode", countryCode: "DE", countryName: "Germany", position: .guardRelay),
            RelayNode(fingerprint: "BBBB2222", nickname: "amsix-mid", countryCode: "NL", countryName: "Netherlands", position: .middle),
            RelayNode(fingerprint: "CCCC3333", nickname: "parisexit9", countryCode: "FR", countryName: "France", position: .exit),
        ],
        purpose: "GENERAL"
    )

    /// A directory fetch. Also three hops, also BUILT, and reported *after* the
    /// browsing circuit — so only its purpose keeps it out of the chain view.
    static let directoryCircuit = Circuit(
        id: "2",
        status: .built,
        path: [
            RelayNode(fingerprint: "DDDD4444", nickname: "dirguard", countryCode: "SE", countryName: "Sweden", position: .guardRelay),
            RelayNode(fingerprint: "EEEE5555", nickname: "dirmid", countryCode: "CH", countryName: "Switzerland", position: .middle),
            RelayNode(fingerprint: "FFFF6666", nickname: "dirend", countryCode: "IS", countryName: "Iceland", position: .exit),
        ],
        purpose: "DIR_FETCH"
    )

    @Test("Once Tor is up the bootstrap reads 100 and the circuit list fills in")
    func reachesRunning() async throws {
        let tor = MockTorService()
        let service = MonitorService(tor: tor)
        service.start()
        try await tor.start()

        let bootstrapped = await waitUntil { service.bootstrapProgress == 100 }
        #expect(bootstrapped)
        let listed = await waitUntil { !service.circuits.isEmpty }
        #expect(listed)

        await service.refreshCircuits()
        #expect(service.circuits == [.sample])
        #expect(service.streamCount == 1)
    }

    @Test("A refresh while Tor is down leaves the monitor's figures untouched")
    func refreshWithoutTorChangesNothing() async {
        let tor = MockTorService()
        let service = MonitorService(tor: tor)

        await service.refreshCircuits()

        #expect(service.circuits.isEmpty)
        #expect(service.streamCount == 0)
    }

    @Test("A recorded event appears at the top of the log")
    func recordedEventsSurface() {
        let service = MonitorService(tor: MockTorService())
        service.record(SecurityEvent(kind: .trackerBlocked, message: "tracker blocked · doubleclick.net"))
        service.record(SecurityEvent(kind: .httpsUpgraded, message: "HTTPS upgraded · example.org"))

        #expect(service.events.count == 2)
        #expect(service.events.first?.kind == .httpsUpgraded)
        #expect(service.events.last?.message == "tracker blocked · doubleclick.net")
    }

    @Test("Security events emitted by Tor reach the log")
    func streamedEventsSurface() async throws {
        let tor = MockTorService()
        let service = MonitorService(tor: tor)
        service.start()
        try await tor.start()

        // The service subscribes from its own task, so the first emission can
        // be made before anyone is listening. Keep offering it, but bounded.
        var delivered = false
        for _ in 0..<50 where !delivered {
            await tor.emit(event: SecurityEvent(kind: .circuitBuilt, message: "circuit built · 3 hops"))
            delivered = await waitUntil(timeout: .milliseconds(40)) { !service.events.isEmpty }
        }

        #expect(delivered)
        #expect(service.events.first?.kind == .circuitBuilt)
        #expect(service.events.first?.message == "circuit built · 3 hops")
    }

    @Test("Bandwidth samples from Tor build up the sparkline")
    func streamedBandwidthSurfaces() async throws {
        let tor = MockTorService()
        let service = MonitorService(tor: tor)
        service.start()
        try await tor.start()

        let sample = BandwidthSample(downBytes: 8 * 1_024, upBytes: 1_024, interval: 1)
        var delivered = false
        for _ in 0..<50 where !delivered {
            await tor.emit(bandwidth: sample)
            delivered = await waitUntil(timeout: .milliseconds(40)) { service.latestBandwidth != nil }
        }

        #expect(delivered)
        #expect(service.latestBandwidth?.downKilobytesPerSecond == 8)
        #expect(!service.bandwidthHistory.isEmpty)
        #expect(service.sparklineHeights.allSatisfy { $0 == 1.0 })
    }

    @Test("The chain shows the browsing circuit, not the newer directory fetch")
    func primaryCircuitPrefersGeneralPurpose() async throws {
        let tor = MockTorService()
        await tor.setCircuits([Self.generalCircuit, Self.directoryCircuit])
        let service = MonitorService(tor: tor)
        try await tor.start()

        await service.refreshCircuits()

        #expect(service.circuits.count == 2)
        #expect(service.primaryCircuit?.id == Self.generalCircuit.id)
    }

    @Test("With only a directory fetch to show, the newest usable circuit is used")
    func primaryCircuitFallsBackToAnyUsableCircuit() async throws {
        let tor = MockTorService()
        await tor.setCircuits([Self.directoryCircuit])
        let service = MonitorService(tor: tor)
        try await tor.start()

        await service.refreshCircuits()

        #expect(service.primaryCircuit?.id == Self.directoryCircuit.id)
    }

    @Test("A half-built circuit is never offered as the path")
    func primaryCircuitIgnoresUnusableCircuits() async throws {
        let tor = MockTorService()
        let launched = Circuit(id: "9", status: .launched, path: [], purpose: "GENERAL")
        await tor.setCircuits([launched])
        let service = MonitorService(tor: tor)
        try await tor.start()

        await service.refreshCircuits()

        #expect(service.circuits.count == 1)
        #expect(service.primaryCircuit == nil)
    }

    @Test("Asking for a new identity while Tor is down is logged, not thrown")
    func newIdentityFailureIsRecorded() async {
        let tor = MockTorService()
        let service = MonitorService(tor: tor)

        await service.requestNewCircuit()

        let failure = service.events.first
        #expect(failure?.kind == .failure)
        #expect(failure?.message.contains("could not rotate circuits") == true)
        #expect(service.circuits.isEmpty)
    }

    @Test("A successful new identity records no failure")
    func newIdentitySucceedsWhenRunning() async throws {
        let tor = MockTorService()
        let service = MonitorService(tor: tor)
        try await tor.start()

        await service.requestNewCircuit()

        #expect(!service.events.contains { $0.kind == .failure })
        #expect(service.circuits == [.sample])
    }
}
