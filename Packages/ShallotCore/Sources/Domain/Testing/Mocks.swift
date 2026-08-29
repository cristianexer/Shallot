import Foundation
import Observation

// Preview and test doubles for every service protocol.
//
// They ship in the shipping module on purpose: SwiftUI previews, unit tests and
// UI tests all need them, and gating them behind `#if DEBUG` would mean the
// tested build and the shipped build are not the same build.

/// A `TorServicing` that never touches the network.
///
/// Bootstraps instantly or on a scripted schedule, hands out fake ports, and
/// can be forced into failure so the kill-switch and error paths get exercised.
public actor MockTorService: TorServicing {
    public enum Behaviour: Sendable, Equatable {
        /// Reaches `.running` as soon as `start()` is called.
        case immediate
        /// Steps through bootstrap percentages, then runs.
        case gradual(steps: [Int])
        /// Throws from `start()`.
        case failing(reason: String)
        /// Starts but never finishes bootstrapping.
        case stalled
    }

    public enum MockTorError: Error, Sendable, Equatable {
        case notRunning
        case startFailed(String)
    }

    private let behaviour: Behaviour
    private var currentState: TorRuntimeState = .off
    private var assignedPorts: [IsolationKey: UInt16] = [:]
    private var nextPort: UInt16 = 39_051
    private var storedBridges: BridgeConfig?

    private var states = AsyncBroadcast<TorRuntimeState>()
    private var progress = AsyncBroadcast<Int>()
    private var bandwidthFeed = AsyncBroadcast<BandwidthSample>()
    private var eventFeed = AsyncBroadcast<SecurityEvent>()

    /// Circuits handed back by `circuits()`. Settable so tests can script them.
    public var stubCircuits: [Circuit]

    public init(behaviour: Behaviour = .immediate, circuits: [Circuit] = [.sample]) {
        self.behaviour = behaviour
        self.stubCircuits = circuits
    }

    public var state: TorRuntimeState { currentState }

    public func start() async throws {
        switch behaviour {
        case .immediate:
            transition(to: .starting(progress: 0))
            transition(to: .running)
        case .gradual(let steps):
            for step in steps {
                transition(to: .starting(progress: step))
                progress.yield(step)
            }
            transition(to: .running)
            progress.yield(100)
        case .failing(let reason):
            transition(to: .failed(reason: reason))
            throw MockTorError.startFailed(reason)
        case .stalled:
            transition(to: .starting(progress: 15))
            progress.yield(15)
        }
    }

    public func stateUpdates() -> AsyncStream<TorRuntimeState> {
        states.stream(priming: currentState)
    }

    public func bootstrapProgress() -> AsyncStream<Int> {
        progress.stream(priming: currentState.progress)
    }

    public func bandwidth() -> AsyncStream<BandwidthSample> {
        bandwidthFeed.stream()
    }

    public func securityEvents() -> AsyncStream<SecurityEvent> {
        eventFeed.stream()
    }

    /// The mock can always be retried; nothing global is at stake.
    public var canRetryStart: Bool { true }

    public func version() async -> String? {
        currentState.canCarryTraffic ? "0.4.8.x (mock)" : nil
    }

    public func newIdentity() async throws {
        guard currentState == .running else { throw MockTorError.notRunning }
        eventFeed.yield(SecurityEvent(kind: .newIdentity, message: "new identity · circuits rotated"))
    }

    public func circuits() async throws -> [Circuit] {
        guard currentState == .running else { throw MockTorError.notRunning }
        return stubCircuits
    }

    public func streamCount() async throws -> Int {
        guard currentState == .running else { throw MockTorError.notRunning }
        return stubCircuits.count
    }

    public func socksPort(forIsolationKey key: IsolationKey) async throws -> UInt16 {
        guard currentState == .running else { throw MockTorError.notRunning }
        if let existing = assignedPorts[key] { return existing }
        let port = nextPort
        nextPort += 1
        assignedPorts[key] = port
        return port
    }

    public func releaseIsolation(_ key: IsolationKey) async {
        assignedPorts.removeValue(forKey: key)
    }

    @discardableResult
    public func setBridges(_ config: BridgeConfig?) async throws -> Bool {
        let changed = storedBridges != config
        storedBridges = config
        // A change only matters if Tor is already up: bridges are applied at
        // start-up, so an edit before start needs no relaunch.
        return changed && currentState != .off
    }

    // MARK: Test controls

    /// Forces the state, so kill-switch tests can drop Tor mid-session.
    public func forceState(_ state: TorRuntimeState) {
        transition(to: state)
    }

    public func setCircuits(_ circuits: [Circuit]) {
        stubCircuits = circuits
    }

    public func emit(bandwidth sample: BandwidthSample) {
        bandwidthFeed.yield(sample)
    }

    public func emit(event: SecurityEvent) {
        eventFeed.yield(event)
    }

    /// Ports currently checked out, for pool-leak assertions.
    public var checkedOutPortCount: Int { assignedPorts.count }

    public var bridges: BridgeConfig? { storedBridges }

    private func transition(to state: TorRuntimeState) {
        currentState = state
        states.yield(state)
    }
}

/// A `FavouritesRepository` backed by an array. No disk, no SwiftData.
@MainActor
@Observable
public final class InMemoryFavouritesRepository: FavouritesRepository {
    public private(set) var favourites: [Favourite]

    public init(favourites: [Favourite] = []) {
        self.favourites = favourites.sorted { $0.sortIndex < $1.sortIndex }
    }

    public func reload() throws {}

    public func add(title: String, url: URL) throws {
        guard !contains(url: url) else { return }
        favourites.append(
            Favourite(title: title, url: url, sortIndex: favourites.count)
        )
    }

    public func update(_ favourite: Favourite) throws {
        guard let index = favourites.firstIndex(where: { $0.id == favourite.id }) else { return }
        favourites[index] = favourite
    }

    public func delete(id: UUID) throws {
        favourites.removeAll { $0.id == id }
        reindex()
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        favourites.moveElements(fromOffsets: source, toOffset: destination)
        reindex()
    }

    public func contains(url: URL) -> Bool {
        favourites.contains { $0.url == url }
    }

    private func reindex() {
        for index in favourites.indices { favourites[index].sortIndex = index }
    }
}

/// A `SettingsStoring` that keeps everything in memory.
@MainActor
@Observable
public final class InMemorySettingsStore: SettingsStoring {
    public private(set) var settings: AppSettings
    public private(set) var needsRelaunchForBridges = false
    public private(set) var hasSeededDefaults = false

    private var appliedBridges: BridgeConfig

    public init(settings: AppSettings = .default) {
        self.settings = settings
        self.appliedBridges = settings.bridges
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        needsRelaunchForBridges = settings.bridges != appliedBridges
    }

    public func reload() {}

    public func markBridgesApplied() {
        appliedBridges = settings.bridges
        needsRelaunchForBridges = false
    }

    public func markDefaultsSeeded() {
        hasSeededDefaults = true
    }
}

/// An `AppLocking` that never talks to LocalAuthentication.
@MainActor
@Observable
public final class MockAppLock: AppLocking {
    public private(set) var isLocked: Bool
    public var isAvailable: Bool
    public var biometryName: String
    public private(set) var lastError: String?

    /// When false, `authenticate()` reports a failure instead of unlocking.
    public var shouldSucceed: Bool

    public init(
        isLocked: Bool = false,
        isAvailable: Bool = true,
        biometryName: String = "Face ID",
        shouldSucceed: Bool = true
    ) {
        self.isLocked = isLocked
        self.isAvailable = isAvailable
        self.biometryName = biometryName
        self.shouldSucceed = shouldSucceed
    }

    public func lock() {
        isLocked = true
    }

    public func authenticate() async {
        if shouldSucceed {
            isLocked = false
            lastError = nil
        } else {
            lastError = "Authentication failed."
        }
    }
}

/// A `MonitorFeeding` holding fixed sample data, for previews and snapshots.
@MainActor
@Observable
public final class MockMonitorFeed: MonitorFeeding {
    public var bootstrapProgress: Int
    public var circuits: [Circuit]
    public var streamCount: Int
    public var events: [SecurityEvent]
    public var bandwidthHistory: [BandwidthSample]
    public var destinationLabel: String?
    public private(set) var didRequestNewCircuit = false

    public init(
        bootstrapProgress: Int = 100,
        circuits: [Circuit] = [.sample],
        streamCount: Int = 7,
        events: [SecurityEvent] = SecurityEvent.samples,
        bandwidthHistory: [BandwidthSample] = BandwidthSample.sampleHistory,
        destinationLabel: String? = nil
    ) {
        self.bootstrapProgress = bootstrapProgress
        self.circuits = circuits
        self.streamCount = streamCount
        self.events = events
        self.bandwidthHistory = bandwidthHistory
        self.destinationLabel = destinationLabel
    }

    public var primaryCircuit: Circuit? { circuits.first(where: \.isUsable) }
    public var latestBandwidth: BandwidthSample? { bandwidthHistory.last }

    public func start() {}

    public func record(_ event: SecurityEvent) {
        events.insert(event, at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
    }

    public func refreshCircuits() async {}

    public func requestNewCircuit() async {
        didRequestNewCircuit = true
    }
}

// MARK: - Sample data

extension Circuit {
    /// A representative three-hop circuit for previews and tests.
    public static let sample = Circuit(
        id: "1",
        status: .built,
        path: [
            RelayNode(fingerprint: "AAAA1111", nickname: "frankfurtnode", countryCode: "DE", countryName: "Germany", position: .guardRelay),
            RelayNode(fingerprint: "BBBB2222", nickname: "amsix-mid", countryCode: "NL", countryName: "Netherlands", position: .middle),
            RelayNode(fingerprint: "CCCC3333", nickname: "parisexit9", countryCode: "FR", countryName: "France", position: .exit),
        ],
        purpose: "GENERAL"
    )
}

extension SecurityEvent {
    public static let samples: [SecurityEvent] = [
        SecurityEvent(kind: .dnsViaTor, message: "DNS resolved via Tor — no leak"),
        SecurityEvent(kind: .leakBlocked, message: "WebRTC probe blocked"),
        SecurityEvent(kind: .trackerBlocked, message: "tracker blocked · doubleclick.net"),
        SecurityEvent(kind: .circuitBuilt, message: "circuit built · 3 hops"),
        SecurityEvent(kind: .httpsUpgraded, message: "HTTPS upgraded · example.org"),
    ]
}

extension BandwidthSample {
    public static let sampleHistory: [BandwidthSample] = (0..<48).map { index in
        let phase = Double(index) / 6
        return BandwidthSample(
            downBytes: Int((160 + 70 * sin(phase)) * 1024),
            upBytes: Int((36 + 14 * cos(phase)) * 1024),
            interval: 1
        )
    }
}

extension Favourite {
    public static let samples: [Favourite] = [
        Favourite(title: "SecureDrop", url: URL(string: "http://sdolvtfhatvsysc6l34d65ymdwxcujausv7k5jk4cy5ttzhjoi6fzvyd.onion")!, sortIndex: 0),
        Favourite(title: "ProPublica", url: URL(string: "http://p53lf57qovyuvwsc6xnrppyply3vtqm7l6pcobkmyqsiofyeznfu5uqd.onion")!, sortIndex: 1),
        Favourite(title: "Tor Project", url: URL(string: "http://2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion")!, sortIndex: 2),
        Favourite(title: "DuckDuckGo", url: URL(string: "https://duckduckgo.com")!, sortIndex: 3),
        Favourite(title: "BBC News", url: URL(string: "https://www.bbc.co.uk/news")!, sortIndex: 4),
    ]
}
