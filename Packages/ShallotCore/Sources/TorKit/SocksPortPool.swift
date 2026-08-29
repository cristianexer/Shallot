import Domain
import Foundation

/// Hands each isolation domain its own Tor SOCKS port, and therefore its own
/// circuit.
///
/// **Why ports and not SOCKS credentials.** Desktop Tor Browser isolates per
/// first-party domain using SOCKS username/password with `IsolateSOCKSAuth`.
/// That path does not work on `WKWebView`: credentials applied through
/// `ProxyConfiguration.applyCredential(username:password:)` are not reliably
/// used by WebKit. So Shallot opens a small bank of Tor `SOCKSPort` lines
/// instead — each one is a separate isolation domain as far as Tor is
/// concerned — and points each tab's data store at a different one. Every port
/// additionally carries `IsolateDestAddr IsolateDestPort`, so even two sites
/// visited in the same tab get separate circuits.
///
/// This is a correctness decision, not an accident. Do not "simplify" it back
/// to SOCKS auth.
public struct SocksPortPool: Sendable, Equatable {
    /// The ports Tor was told to listen on, in assignment order.
    public let ports: [UInt16]

    private var assignments: [IsolationKey: UInt16] = [:]
    private var useCounts: [UInt16: Int]

    public init(ports: [UInt16]) {
        precondition(!ports.isEmpty, "the pool needs at least one port")
        self.ports = ports
        self.useCounts = Dictionary(uniqueKeysWithValues: ports.map { ($0, 0) })
    }

    /// Ports with nothing assigned to them.
    public var freePortCount: Int { useCounts.values.count { $0 == 0 } }

    /// Isolation domains currently holding a port.
    public var assignmentCount: Int { assignments.count }

    /// The port serving `key`, assigning one if this is the first request.
    ///
    /// Assignment is stable: the same key always gets the same port until it is
    /// released, which is what keeps a tab on one circuit across navigations.
    /// Past the pool's capacity, keys start sharing the least-loaded port —
    /// degraded isolation is still better than refusing to open a tab.
    public mutating func port(for key: IsolationKey) -> UInt16 {
        if let existing = assignments[key] { return existing }
        let chosen = leastLoadedPort()
        assignments[key] = chosen
        useCounts[chosen, default: 0] += 1
        return chosen
    }

    /// Returns `key`'s port to the pool.
    ///
    /// Releasing a key that was never assigned is a no-op rather than an error:
    /// tab teardown races with tab creation and must not be able to corrupt the
    /// counts. A leak here would silently collapse isolation, so the counts are
    /// asserted in tests after rapid open/close churn.
    public mutating func release(_ key: IsolationKey) {
        guard let port = assignments.removeValue(forKey: key) else { return }
        useCounts[port] = max(0, (useCounts[port] ?? 1) - 1)
    }

    /// Drops every assignment — used by New Identity.
    public mutating func releaseAll() {
        assignments.removeAll()
        for port in ports { useCounts[port] = 0 }
    }

    /// Whether `key` currently holds a port.
    public func isAssigned(_ key: IsolationKey) -> Bool { assignments[key] != nil }

    private func leastLoadedPort() -> UInt16 {
        // Ties break towards the earliest port so assignment is deterministic
        // and tests do not depend on dictionary ordering.
        ports.min { lhs, rhs in
            let left = useCounts[lhs] ?? 0
            let right = useCounts[rhs] ?? 0
            if left != right { return left < right }
            return lhs < rhs
        } ?? ports[0]
    }
}
