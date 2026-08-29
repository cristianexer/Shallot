import Domain
import XCTest

@testable import BrowserEngine
@testable import Monitoring
@testable import TorKit

/// Performance budgets for the work Shallot does on every launch and every load.
///
/// Tor's three-hop path has a latency floor nothing here can move, and trying to
/// move it would mean fewer hops or weaker isolation. So these measure Shallot's
/// *own* overhead — parsing, script generation, rule compilation, web-view
/// construction — which is the part we can be held responsible for.
///
/// XCTest rather than Swift Testing, because the metric APIs live there.
final class PerformanceTests: XCTestCase {
    /// A circuit-status block the size Tor produces on a busy session.
    private static let largeCircuitStatus: String = (1...200)
        .map { index in
            "\(index) BUILT $\(String(repeating: "A", count: 40))~relay\(index),"
                + "$\(String(repeating: "B", count: 40))~mid\(index),"
                + "$\(String(repeating: "C", count: 40))~exit\(index) PURPOSE=GENERAL"
        }
        .joined(separator: "\n")

    func testCircuitStatusParsingIsCheapEnoughToPoll() {
        // Parsed on every Monitor refresh, so it must stay well clear of a
        // frame budget even with a couple of hundred circuits open.
        measure(metrics: [XCTClockMetric()]) {
            let circuits = CircuitStatusParser.parse(Self.largeCircuitStatus)
            XCTAssertEqual(circuits.count, 200)
        }
    }

    func testLeakMitigationScriptGenerationIsCheap() {
        // Regenerated for every tab, because the per-site opt-ins can differ.
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<200 {
                _ = LeakMitigations.source(for: .strict)
            }
        }
    }

    func testContentRuleJSONGenerationIsCheap() {
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<50 {
                _ = ContentBlocker.baseRules(httpsOnly: true)
                _ = ContentBlocker.strictRules()
            }
        }
    }

    func testBandwidthSamplingHoldsABoundedWindow() {
        // Runs once a second for the whole session; an unbounded window here
        // would be a slow memory leak in the most visible screen.
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            var sampler = BandwidthSampler(windowSize: 48)
            for index in 0..<10_000 {
                sampler.append(BandwidthSample(downBytes: index, upBytes: index, interval: 1))
            }
            XCTAssertEqual(sampler.samples.count, 48)
        }
    }

    func testEventLogHoldsABoundedWindow() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            var log = EventLog(capacity: 200)
            for index in 0..<10_000 {
                log.append(SecurityEvent(kind: .info, message: "event \(index)"))
            }
            XCTAssertEqual(log.events.count, 200)
        }
    }

    func testSocksPortPoolChurnIsConstantTime() {
        // Rapid tab open/close must not degrade, and must not leak ports.
        measure(metrics: [XCTClockMetric()]) {
            var pool = SocksPortPool(ports: Array(39_051...39_058))
            for _ in 0..<5_000 {
                let key = IsolationKey.tab(UUID())
                _ = pool.port(for: key)
                pool.release(key)
            }
            XCTAssertEqual(pool.freePortCount, 8)
        }
    }

    @MainActor
    func testBuildingATabSessionIsFastEnoughForATap() {
        // A tab's web view is built on the tap that opens it, with the proxy,
        // the user scripts and the rule lists all applied up front.
        let engine = BrowserEngine(settings: .default, monitor: nil)
        engine.canCarryTraffic = true
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let tab = BrowserTab(url: URL(string: "https://example.org")!)
            let session = engine.session(for: tab, socksPort: 39_051)
            XCTAssertNotNil(session)
            engine.stopMeasuringTeardown(tabID: tab.id)
        }
    }
}

extension BrowserEngine {
    /// Synchronously drops a session between measurement iterations.
    ///
    /// The async teardown wipes the data store too, which is not what the
    /// measurement is about and would dominate the numbers.
    @MainActor
    fileprivate func stopMeasuringTeardown(tabID: UUID) {
        Task { await destroySession(for: tabID) }
    }
}
