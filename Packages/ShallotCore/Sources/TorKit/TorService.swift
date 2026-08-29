import Domain
import Foundation
import Tor

/// The embedded Tor engine.
///
/// Owns Tor's lifecycle, its control channel and the bank of SOCKS ports the
/// browser isolates tabs across. It is an `actor` because Tor's state is shared
/// mutable state, and it is the only type in the app that imports the Tor
/// library at all — everything above it talks to `Domain.TorServicing`.
///
/// ### One start per launch
///
/// The embedded Tor C library keeps process-global state and **cannot be
/// restarted inside the same process** once it has stopped. So:
///
/// * Tor starts exactly once, at launch.
/// * "New identity" is `SIGNAL NEWNYM`, never a restart.
/// * Configuration that Tor only reads at start-up — bridges, the SOCKS port
///   bank — is decided before `start()` and a change requires a relaunch.
///
/// Do not add a `stop()`-then-`start()` path. It will appear to work in the
/// simulator and wedge on device.
public actor TorService: TorServicing {
    /// Everything that must be known before Tor starts.
    public struct Configuration: Sendable {
        /// Bundled GeoIP databases. Country labels in the Monitor are resolved
        /// from these on-device; Shallot never asks anyone where a relay is.
        public var geoIPFile: URL?
        public var geoIPv6File: URL?

        /// Persistent consensus cache. Survives launches and cuts bootstrap
        /// from ~40 s to ~5–10 s. Contains no browsing data.
        public var cacheDirectory: URL

        /// How many isolated SOCKS ports to open — the ceiling on the number of
        /// tabs that can each have their own circuit.
        public var isolationPoolSize: Int

        /// Bridge configuration to apply at start-up.
        public var bridges: BridgeConfig

        /// Optional obfuscating-transport provider (see `PluggableTransportProviding`).
        public var transportProvider: (any PluggableTransportProviding)?

        /// How often Tor's traffic counters are sampled.
        public var bandwidthInterval: Duration

        /// How often circuit status is refreshed.
        public var circuitInterval: Duration

        /// How long to wait for bootstrap before giving up.
        public var bootstrapTimeout: Duration

        public init(
            geoIPFile: URL? = nil,
            geoIPv6File: URL? = nil,
            cacheDirectory: URL,
            isolationPoolSize: Int = 8,
            bridges: BridgeConfig = .disabled,
            transportProvider: (any PluggableTransportProviding)? = nil,
            bandwidthInterval: Duration = .seconds(1),
            circuitInterval: Duration = .seconds(4),
            bootstrapTimeout: Duration = .seconds(180)
        ) {
            self.geoIPFile = geoIPFile
            self.geoIPv6File = geoIPv6File
            self.cacheDirectory = cacheDirectory
            self.isolationPoolSize = isolationPoolSize
            self.bridges = bridges
            self.transportProvider = transportProvider
            self.bandwidthInterval = bandwidthInterval
            self.circuitInterval = circuitInterval
            self.bootstrapTimeout = bootstrapTimeout
        }
    }

    public enum ServiceError: Error, Sendable, Equatable, CustomStringConvertible {
        case notRunning
        case bootstrapTimedOut
        case controlUnavailable
        case startFailed(String)
        /// Tor was launched once already and did not come up. It cannot be
        /// launched again in this process.
        case requiresRelaunch

        public var description: String {
            switch self {
            case .notRunning: "Tor is not running."
            case .bootstrapTimedOut: "Tor could not finish connecting in time."
            case .controlUnavailable: "Tor's control channel is not available."
            case .startFailed(let reason): "Tor failed to start: \(reason)"
            case .requiresRelaunch:
                "Tor cannot be started again in this session. Quit Shallot and open it again."
            }
        }
    }

    private var configuration: Configuration

    private var client: TorClient?
    private var control: ControlChannel?
    private var pool: SocksPortPool?
    private var utilitySocksPort: UInt16?
    private var dataDirectory: String?

    private var currentState: TorRuntimeState = .off
    private var startTask: Task<Void, Error>?
    /// Whether `tor_run_main()` has already been handed a thread in this process.
    ///
    /// The Tor C library keeps process-global state, so launching it a second
    /// time is undefined behaviour — not a slower start, and not an error it
    /// reports. Once this is set, a retry has to be refused.
    private var hasLaunchedTorProcess = false
    private var eventTask: Task<Void, Never>?
    private var samplingTask: Task<Void, Never>?

    private var states = AsyncBroadcast<TorRuntimeState>()
    private var progressFeed = AsyncBroadcast<Int>()
    private var bandwidthFeed = AsyncBroadcast<BandwidthSample>()
    private var eventFeed = AsyncBroadcast<SecurityEvent>()

    private var lastTrafficRead: Int?
    private var lastTrafficWritten: Int?
    private var cachedCircuits: [Circuit] = []
    /// fingerprint → country code, resolved once from the bundled GeoIP data.
    private var countryCache: [String: String] = [:]
    /// Bridge configuration the *running* Tor was started with.
    private var appliedBridges: BridgeConfig
    private var cachedVersion: String?

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.appliedBridges = configuration.bridges
    }

    // MARK: - TorServicing

    public var state: TorRuntimeState { currentState }

    /// Whether a failed start can be retried, or whether only a relaunch will do.
    public var canRetryStart: Bool { !hasLaunchedTorProcess }

    public func stateUpdates() -> AsyncStream<TorRuntimeState> {
        states.stream(priming: currentState)
    }

    public func bootstrapProgress() -> AsyncStream<Int> {
        progressFeed.stream(priming: currentState.progress)
    }

    public func bandwidth() -> AsyncStream<BandwidthSample> {
        bandwidthFeed.stream()
    }

    public func securityEvents() -> AsyncStream<SecurityEvent> {
        eventFeed.stream()
    }

    public func start() async throws {
        // Idempotent: a second call joins the first rather than starting a
        // second Tor, which the C library would not survive.
        if let startTask { return try await startTask.value }
        if currentState.canCarryTraffic { return }
        // A failed attempt cannot be retried in-process. Saying so is the only
        // honest answer; trying anyway would appear to work in the simulator
        // and wedge on a device.
        if hasLaunchedTorProcess { throw ServiceError.requiresRelaunch }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.performStart()
        }
        startTask = task
        do {
            try await task.value
        } catch {
            startTask = nil
            throw error
        }
    }

    public func version() async -> String? {
        if let cachedVersion { return cachedVersion }
        guard let control else { return nil }
        guard let values = try? await control.getInfoValues(["version"]) else { return nil }
        cachedVersion = values["version"]
        return cachedVersion
    }

    public func newIdentity() async throws {
        guard let control else { throw ServiceError.controlUnavailable }
        try await control.perform("SIGNAL NEWNYM")
        // The ports themselves stay open — they are Tor listeners, not per
        // session state — but every isolation assignment is dropped so the next
        // tab starts from a clean slate.
        pool?.releaseAll()
        countryCache.removeAll()
        cachedCircuits.removeAll()
        eventFeed.yield(SecurityEvent(kind: .newIdentity, message: "new identity · all circuits rotated"))
        await refreshCircuits()
    }

    public func circuits() async throws -> [Circuit] {
        guard currentState.canCarryTraffic else { throw ServiceError.notRunning }
        await refreshCircuits()
        return cachedCircuits
    }

    public func streamCount() async throws -> Int {
        guard let control else { throw ServiceError.controlUnavailable }
        let raw = try await control.getInfoBlock("stream-status")
        return raw.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    public func socksPort(forIsolationKey key: IsolationKey) async throws -> UInt16 {
        guard currentState.canCarryTraffic else { throw ServiceError.notRunning }
        if key == .utility, let utilitySocksPort { return utilitySocksPort }
        guard var pool else { throw ServiceError.notRunning }
        let port = pool.port(for: key)
        self.pool = pool
        return port
    }

    public func releaseIsolation(_ key: IsolationKey) async {
        pool?.release(key)
    }

    @discardableResult
    public func setBridges(_ config: BridgeConfig?) async throws -> Bool {
        let newConfig = config ?? .disabled
        configuration.bridges = newConfig
        // Bridges are read by Tor only at start-up. If Tor is already up, the
        // honest answer is "this takes effect next launch" — not a silent no-op
        // and not a restart that would wedge the process.
        guard currentState != .off else {
            appliedBridges = newConfig
            return false
        }
        return newConfig != appliedBridges
    }

    // MARK: - Lifecycle

    private func performStart() async throws {
        transition(to: .starting(progress: 0))

        // One utility port for app-level requests, plus the isolation bank, plus
        // the control port — all reserved together so they cannot collide.
        let portCount = configuration.isolationPoolSize + 2
        let ports: [UInt16]
        do {
            ports = try PortReservation.reserve(count: portCount)
        } catch {
            let reason = String(describing: error)
            transition(to: .failed(reason: reason))
            throw ServiceError.startFailed(reason)
        }

        let controlPort = ports[0]
        let utilityPort = ports[1]
        let isolationPorts = Array(ports.dropFirst(2))
        utilitySocksPort = utilityPort
        pool = SocksPortPool(ports: isolationPorts)

        try? FileManager.default.createDirectory(
            at: configuration.cacheDirectory,
            withIntermediateDirectories: true
        )

        var torConfiguration = TorConfiguration.ephemeral(cacheDirectory: configuration.cacheDirectory.path)
        torConfiguration.socksPort = .fixed(Int(utilityPort))
        torConfiguration.cookieAuthentication = true
        torConfiguration.extraArgs = try await buildArguments(
            controlPort: controlPort,
            isolationPorts: isolationPorts
        )
        dataDirectory = torConfiguration.dataDirectory
        appliedBridges = configuration.bridges

        let client = TorClient(configuration: torConfiguration)
        self.client = client
        startConsumingEvents(of: client)
        hasLaunchedTorProcess = true

        do {
            try await client.start()
            try await client.waitUntilBootstrapped(timeout: configuration.bootstrapTimeout)
        } catch {
            let reason = String(describing: error)
            transition(to: .failed(reason: reason))
            eventFeed.yield(SecurityEvent(kind: .failure, message: "tor failed to start · \(reason)"))
            throw ServiceError.startFailed(reason)
        }

        guard let dataDirectory else { throw ServiceError.controlUnavailable }
        do {
            control = try await ControlChannel.connect(port: controlPort, dataDirectory: dataDirectory)
        } catch {
            // Tor is up and can carry traffic even if we cannot talk to it, but
            // the Monitor would be blind and New Identity would not work — so
            // this is a hard failure rather than a degraded mode.
            let reason = String(describing: error)
            transition(to: .failed(reason: reason))
            throw ServiceError.controlUnavailable
        }

        transition(to: .running)
        progressFeed.yield(100)
        eventFeed.yield(SecurityEvent(kind: .info, message: "tor bootstrapped · \(isolationPorts.count) isolated circuits ready"))
        startSampling()
        await refreshCircuits()
    }

    /// Builds the extra torrc arguments.
    ///
    /// Every one of these is a deliberate choice; see the inline notes.
    private func buildArguments(controlPort: UInt16, isolationPorts: [UInt16]) async throws -> [String] {
        var args: [String] = []

        // A control port we can dial, authenticated by the cookie file Tor
        // writes into its own data directory.
        args += ["--ControlPort", "\(controlPort)"]

        // The isolation bank. `IsolateDestAddr IsolateDestPort` means two
        // different destinations reached through the same port still get
        // different circuits, so isolation degrades gracefully once more tabs
        // are open than there are ports.
        for port in isolationPorts {
            args += ["--SocksPort", "\(port) IsolateDestAddr IsolateDestPort"]
        }

        // Refuse anything that is not this device talking to its own loopback.
        args += ["--SocksPolicy", "accept 127.0.0.1/32"]
        args += ["--SocksPolicy", "reject *"]

        // We are a client. Never relay, never serve a directory.
        args += ["--ClientOnly", "1"]

        // Keep as little as possible on disk, and never log an address.
        args += ["--AvoidDiskWrites", "1"]
        args += ["--SafeLogging", "1"]

        // Tor otherwise goes dormant after a long idle period and the first tap
        // after that would hang instead of loading.
        args += ["--DormantCanceledByStartup", "1"]
        args += ["--DormantOnFirstStartup", "0"]

        // GeoIP is used for two things only: country labels in the Monitor, and
        // Tor's own path selection. Both are local lookups against these files.
        if let geoIPFile = configuration.geoIPFile {
            args += ["--GeoIPFile", geoIPFile.path]
        }
        if let geoIPv6File = configuration.geoIPv6File {
            args += ["--GeoIPv6File", geoIPv6File.path]
        }

        args += try await bridgeArguments()
        return args
    }

    private func bridgeArguments() async throws -> [String] {
        let bridges = configuration.bridges
        guard bridges.isEffective else { return [] }

        var args: [String] = ["--UseBridges", "1"]

        if bridges.transport.requiresTransportProvider {
            // Without a transport binary an obfuscated bridge line would be
            // accepted by Tor and then silently fail to connect. Dropping back
            // to a direct connection is the honest behaviour; Settings says so.
            guard let provider = configuration.transportProvider,
                  provider.supports(bridges.transport),
                  let port = try? await provider.start(bridges.transport)
            else {
                eventFeed.yield(
                    SecurityEvent(
                        kind: .failure,
                        message: "\(bridges.transport.rawValue) unavailable · connecting without bridges"
                    )
                )
                return []
            }
            args += [
                "--ClientTransportPlugin",
                provider.clientTransportPluginValue(for: bridges.transport, port: port),
            ]
        }

        for line in bridges.lines {
            args += ["--Bridge", line.torrcValue]
        }
        return args
    }

    private func startConsumingEvents(of client: TorClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            let stream = await client.events
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: TorEvent) {
        switch event {
        case .bootstrap(let progress, _, let summary):
            progressFeed.yield(progress)
            if case .running = currentState {} else {
                transition(to: progress >= 100 ? .running : .starting(progress: progress))
            }
            if progress % 25 == 0 {
                eventFeed.yield(SecurityEvent(kind: .info, message: "bootstrap \(progress)% · \(summary)"))
            }
        case .circuit(_, let status) where status == "BUILT":
            eventFeed.yield(SecurityEvent(kind: .circuitBuilt, message: "circuit built · 3 hops"))
        case .circuit:
            break
        case .stream:
            break
        case .log(let level, let message):
            // Tor's own warnings are worth surfacing; notices and info are noise
            // in a five-line terminal view.
            if level >= .warn {
                eventFeed.yield(SecurityEvent(kind: .failure, message: message))
            }
        case .stateChanged:
            break
        }
    }

    private func startSampling() {
        samplingTask?.cancel()
        samplingTask = Task { [weak self] in
            guard let self else { return }
            let bandwidthInterval = await self.configuration.bandwidthInterval
            let circuitInterval = await self.configuration.circuitInterval
            var ticksUntilCircuitRefresh = 0
            let ticksPerCircuitRefresh = max(
                1,
                Int(circuitInterval / bandwidthInterval)
            )
            while !Task.isCancelled {
                try? await Task.sleep(for: bandwidthInterval)
                if Task.isCancelled { return }
                await self.sampleBandwidth(interval: bandwidthInterval)
                ticksUntilCircuitRefresh -= 1
                if ticksUntilCircuitRefresh <= 0 {
                    ticksUntilCircuitRefresh = ticksPerCircuitRefresh
                    await self.refreshCircuits()
                }
            }
        }
    }

    private func sampleBandwidth(interval: Duration) async {
        guard let control else { return }
        guard let values = try? await control.getInfoValues(["traffic/read", "traffic/written"]) else {
            return
        }
        guard
            let read = values["traffic/read"].flatMap(Int.init),
            let written = values["traffic/written"].flatMap(Int.init)
        else { return }

        defer {
            lastTrafficRead = read
            lastTrafficWritten = written
        }
        // The first sample has no previous reading to difference against, and
        // publishing the lifetime total as a one-second rate would spike the
        // sparkline to a meaningless number.
        guard let previousRead = lastTrafficRead, let previousWritten = lastTrafficWritten else { return }

        let seconds = Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1e18
        bandwidthFeed.yield(
            BandwidthSample(
                downBytes: max(0, read - previousRead),
                upBytes: max(0, written - previousWritten),
                interval: seconds
            )
        )
    }

    /// Pulls `circuit-status` and resolves each new relay's country locally.
    private func refreshCircuits() async {
        guard let control else { return }
        guard let raw = try? await control.getInfoBlock("circuit-status") else { return }
        let parsed = CircuitStatusParser.parse(raw)
        var resolved: [Circuit] = []
        resolved.reserveCapacity(parsed.count)
        for circuit in parsed {
            var path: [RelayNode] = []
            for relay in circuit.path {
                let code = await countryCode(for: relay.fingerprint)
                path.append(
                    RelayNode(
                        fingerprint: relay.fingerprint,
                        nickname: relay.nickname,
                        countryCode: code?.uppercased(),
                        countryName: code.flatMap(Self.countryName(for:)),
                        position: relay.position
                    )
                )
            }
            resolved.append(
                Circuit(id: circuit.id, status: circuit.status, path: path, purpose: circuit.purpose)
            )
        }
        cachedCircuits = resolved
    }

    /// Country for a relay, resolved from the bundled GeoIP database via Tor.
    ///
    /// Two control round-trips the first time we see a relay — one to learn its
    /// address, one to map that address to a country — then cached for the rest
    /// of the session. No network request is involved in either.
    private func countryCode(for fingerprint: String) async -> String? {
        if let cached = countryCache[fingerprint] { return cached.isEmpty ? nil : cached }
        guard let control, !fingerprint.isEmpty else { return nil }
        guard
            let router = try? await control.getInfoBlock("ns/id/$\(fingerprint)"),
            let address = RouterStatusParser.address(in: router),
            let values = try? await control.getInfoValues(["ip-to-country/\(address)"]),
            let code = values["ip-to-country/\(address)"]?.lowercased(),
            code != "??"
        else {
            // Cache the miss too, or every refresh re-asks for a relay Tor has
            // no answer for.
            countryCache[fingerprint] = ""
            return nil
        }
        countryCache[fingerprint] = code
        return code
    }

    static func countryName(for code: String) -> String? {
        Locale.current.localizedString(forRegionCode: code.uppercased())
    }

    private func transition(to state: TorRuntimeState) {
        guard state != currentState else { return }
        currentState = state
        states.yield(state)
    }
}
