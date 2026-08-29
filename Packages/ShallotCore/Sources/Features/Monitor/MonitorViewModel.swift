import Domain
import Foundation
import Observation

/// Drives the Monitor screen.
///
/// Reads only. Every value comes from `MonitorFeeding`, which measures it on
/// this device; nothing here fetches anything.
@MainActor
@Observable
public final class MonitorViewModel {
    @ObservationIgnored private let feed: any MonitorFeeding
    @ObservationIgnored private let onNewIdentity: () async -> Void

    public var isWorking = false

    public init(feed: any MonitorFeeding, onNewIdentity: @escaping () async -> Void) {
        self.feed = feed
        self.onNewIdentity = onNewIdentity
    }

    public var bootstrapProgress: Int { feed.bootstrapProgress }
    public var circuits: [Circuit] { feed.circuits }
    public var circuitCount: Int { feed.circuits.count(where: \.isUsable) }
    public var streamCount: Int { feed.streamCount }
    public var events: [SecurityEvent] { feed.events }
    public var destinationLabel: String? { feed.destinationLabel }

    /// The three-hop path shown in the chain view.
    public var path: [RelayNode] { feed.primaryCircuit?.path ?? [] }

    public var hasCircuit: Bool { !path.isEmpty }

    /// Normalised sparkline heights, scaled to the peak in the window.
    public var sparkline: [Double] {
        let samples = feed.bandwidthHistory
        guard !samples.isEmpty else { return [] }
        let peak = max(1, samples.map(\.downKilobytesPerSecond).max() ?? 1)
        return samples.map { min(1, $0.downKilobytesPerSecond / peak) }
    }

    public var downRateLabel: String {
        format(feed.latestBandwidth?.downKilobytesPerSecond ?? 0)
    }

    public var upRateLabel: String {
        format(feed.latestBandwidth?.upKilobytesPerSecond ?? 0)
    }

    /// The most recent events, newest first, for the terminal panel.
    public func recentEvents(limit: Int = 7) -> [SecurityEvent] {
        Array(events.prefix(limit))
    }

    public func refresh() async {
        await feed.refreshCircuits()
    }

    /// "New circuit" — rotate the path without clearing the session.
    public func requestNewCircuit() async {
        isWorking = true
        defer { isWorking = false }
        await feed.requestNewCircuit()
    }

    /// "New identity" — the full reset, owned by the browser view model.
    public func requestNewIdentity() async {
        isWorking = true
        defer { isWorking = false }
        await onNewIdentity()
        await feed.refreshCircuits()
    }

    private func format(_ rate: Double) -> String {
        rate >= 1000
            ? String(format: "%.1f MB/s", rate / 1024)
            : String(format: "%.0f", rate)
    }
}
