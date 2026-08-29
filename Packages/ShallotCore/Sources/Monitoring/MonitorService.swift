import Domain
import Foundation
import Observation

/// Aggregates everything the Monitor screen shows.
///
/// Every value here is measured on this device: circuit paths and traffic
/// counters come from Tor's own control channel over loopback, security events
/// come from the browser engine's own callbacks. There is no analytics SDK in
/// this app, no crash reporter, and no code path in this type that opens a
/// socket. The egress test in the security suite exists to keep it that way.
@MainActor
@Observable
public final class MonitorService: MonitorFeeding {
    public private(set) var bootstrapProgress: Int = 0
    public private(set) var circuits: [Circuit] = []
    public private(set) var streamCount: Int = 0
    public private(set) var events: [SecurityEvent] = []
    public private(set) var bandwidthHistory: [BandwidthSample] = []
    public var destinationLabel: String?

    @ObservationIgnored private let tor: any TorServicing
    @ObservationIgnored private var log = EventLog()
    @ObservationIgnored private var sampler = BandwidthSampler()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var isStarted = false

    public init(tor: any TorServicing) {
        self.tor = tor
    }

    deinit {
        for task in tasks { task.cancel() }
    }

    public var primaryCircuit: Circuit? {
        // Prefer the general-purpose built circuit with a full path; directory
        // fetches are also "circuits" and would otherwise win by being newest.
        circuits.last { $0.isUsable && ($0.purpose ?? "GENERAL") == "GENERAL" }
            ?? circuits.last(where: \.isUsable)
    }

    public var latestBandwidth: BandwidthSample? { sampler.latest }

    /// Normalised sparkline heights, 0...1.
    public var sparklineHeights: [Double] { sampler.normalisedHeights() }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        // `self` is re-acquired weakly *inside* each loop rather than once
        // before it. Hoisting the `guard let self` above the `for await` would
        // hold a strong reference for the whole life of the stream — and these
        // streams never finish — so the service could never be released and its
        // own `deinit` could never cancel these tasks.
        let tor = self.tor

        tasks.append(Task { [weak self, tor] in
            for await progress in await tor.bootstrapProgress() {
                guard let self else { return }
                self.bootstrapProgress = progress
            }
        })

        tasks.append(Task { [weak self, tor] in
            for await sample in await tor.bandwidth() {
                guard let self else { return }
                self.append(sample)
            }
        })

        tasks.append(Task { [weak self, tor] in
            for await event in await tor.securityEvents() {
                guard let self else { return }
                self.record(event)
            }
        })

        tasks.append(Task { [weak self, tor] in
            for await state in await tor.stateUpdates() {
                guard let self else { return }
                self.bootstrapProgress = state.progress
                if state.canCarryTraffic { await self.refreshCircuits() }
            }
        })

        // The circuit path is shown on the browser's start page as well as on
        // the Monitor, so it cannot only refresh when the Monitor appears —
        // otherwise the start page sits on "building circuit" forever. Tor
        // caches its own answers and resolves each relay's country only once,
        // so this is a control-channel read, not real work.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.refreshCircuits()
            }
        })
    }

    public func record(_ event: SecurityEvent) {
        log.append(event)
        events = log.events
    }

    public func refreshCircuits() async {
        // Both numbers describe the same instant, so a partial refresh — new
        // circuits alongside a stale stream count — is worse than no refresh.
        guard
            let latest = try? await tor.circuits(),
            let streams = try? await tor.streamCount()
        else { return }
        circuits = latest
        streamCount = streams
    }

    public func requestNewCircuit() async {
        do {
            try await tor.newIdentity()
            await refreshCircuits()
        } catch {
            record(SecurityEvent(kind: .failure, message: "could not rotate circuits · \(error)"))
        }
    }

    private func append(_ sample: BandwidthSample) {
        sampler.append(sample)
        bandwidthHistory = sampler.samples
    }
}
