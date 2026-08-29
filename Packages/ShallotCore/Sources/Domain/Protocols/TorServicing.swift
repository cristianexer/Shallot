import Foundation

/// The Tor engine, as every other layer sees it.
///
/// Nothing above `TorKit` ever touches the underlying Tor library. That is what
/// makes the library swappable, and it is what keeps the UI testable without
/// bootstrapping a real Tor.
public protocol TorServicing: Sendable {
    /// Current lifecycle state.
    var state: TorRuntimeState { get async }

    /// Starts Tor. Idempotent — calling it twice is a no-op, not an error.
    ///
    /// - Important: The embedded Tor C library keeps process-global state and
    ///   cannot be restarted within the same process. Tor starts once per
    ///   launch; identity rotation is `newIdentity()`, and configuration that
    ///   only applies at start-up (bridges) requires a relaunch.
    func start() async throws

    /// Every state transition, from the moment of subscription.
    func stateUpdates() async -> AsyncStream<TorRuntimeState>

    /// Bootstrap progress, 0–100.
    func bootstrapProgress() async -> AsyncStream<Int>

    /// Requests fresh circuits for all new streams (`SIGNAL NEWNYM`).
    func newIdentity() async throws

    /// The circuits Tor currently holds.
    func circuits() async throws -> [Circuit]

    /// Number of application streams currently attached to circuits.
    func streamCount() async throws -> Int

    /// Read/write deltas, sampled on a fixed interval.
    func bandwidth() async -> AsyncStream<BandwidthSample>

    /// The loopback SOCKS port serving `key`.
    ///
    /// Each key gets its own port, and therefore its own circuit. Ports come
    /// from a bounded pool and are recycled when released.
    func socksPort(forIsolationKey key: IsolationKey) async throws -> UInt16

    /// Returns `key`'s port to the pool.
    func releaseIsolation(_ key: IsolationKey) async

    /// Stores bridge configuration for the *next* launch.
    ///
    /// - Returns: `true` if a relaunch is needed for the change to take effect.
    @discardableResult
    func setBridges(_ config: BridgeConfig?) async throws -> Bool

    /// Log lines and lifecycle notices worth showing in the Monitor.
    func securityEvents() async -> AsyncStream<SecurityEvent>

    /// The version of the Tor library actually running, once it is up.
    ///
    /// Read from Tor itself rather than hard-coded, so the About screen cannot
    /// drift out of date with the binary that is shipping.
    func version() async -> String?
}
