import Foundation

/// Lifecycle of the embedded Tor engine, as the rest of the app sees it.
///
/// Deliberately independent of the underlying Tor library's own state type so
/// that swapping the library never ripples past `TorKit`.
public enum TorRuntimeState: Sendable, Hashable {
    /// Not started yet.
    case off
    /// Tor is running but has not finished bootstrapping. Carries progress 0–100.
    case starting(progress: Int)
    /// Bootstrapped, circuits established, safe to carry user traffic.
    case running
    /// Shutting down.
    case stopping
    /// Terminal failure. Carries a human-readable reason.
    case failed(reason: String)

    /// The kill-switch predicate: the *only* state in which a page may load.
    ///
    /// `BrowserEngine` refuses every navigation unless this is `true`. That is a
    /// security control, not UX polish — it is what stops a clearnet leak when
    /// Tor drops mid-session.
    public var canCarryTraffic: Bool { self == .running }

    /// Bootstrap percentage for the progress UI.
    public var progress: Int {
        switch self {
        case .off, .failed: 0
        case .starting(let progress): progress
        case .running, .stopping: 100
        }
    }

    /// Terminal-style label for the status bar.
    public var label: String {
        switch self {
        case .off: "OFFLINE"
        case .starting: "CONNECTING"
        case .running: "TOR · ANONYMOUS"
        case .stopping: "DISCONNECTING"
        case .failed: "FAILED"
        }
    }
}

/// One relay in a Tor circuit.
public struct RelayNode: Sendable, Hashable, Identifiable, Codable {
    /// Position of this relay in the path.
    public enum Position: String, Sendable, Codable, Hashable {
        case guardRelay, middle, exit

        public var title: String {
            switch self {
            case .guardRelay: "Guard"
            case .middle: "Relay"
            case .exit: "Exit"
            }
        }
    }

    /// Relay identity fingerprint, without the leading `$`.
    public let fingerprint: String
    /// Relay nickname as published in the consensus, when known.
    public let nickname: String
    /// Two-letter country code resolved locally from the bundled GeoIP database.
    public let countryCode: String?
    /// Human-readable country name, when we can resolve one.
    public let countryName: String?
    /// Where this relay sits in the path.
    public let position: Position

    public var id: String { fingerprint }

    public init(
        fingerprint: String,
        nickname: String,
        countryCode: String? = nil,
        countryName: String? = nil,
        position: Position
    ) {
        self.fingerprint = fingerprint
        self.nickname = nickname
        self.countryCode = countryCode
        self.countryName = countryName
        self.position = position
    }

    /// What the circuit view shows in the relay badge.
    public var badge: String { countryCode ?? "··" }
}

/// A built Tor circuit, as reported by `GETINFO circuit-status`.
public struct Circuit: Sendable, Hashable, Identifiable, Codable {
    public enum Status: String, Sendable, Codable, Hashable {
        case launched = "LAUNCHED"
        case built = "BUILT"
        case guardWait = "GUARD_WAIT"
        case extended = "EXTENDED"
        case failed = "FAILED"
        case closed = "CLOSED"
        case unknown
    }

    public let id: String
    public let status: Status
    public let path: [RelayNode]
    /// The `SOCKS_USERNAME`/target purpose Tor attributes to this circuit, if any.
    public let purpose: String?

    public init(id: String, status: Status, path: [RelayNode], purpose: String? = nil) {
        self.id = id
        self.status = status
        self.path = path
        self.purpose = purpose
    }

    /// Only fully built three-hop circuits are worth showing as "the" circuit.
    public var isUsable: Bool { status == .built && path.count >= 3 }
}

/// One sample of Tor's read/write counters, already differenced into a rate.
public struct BandwidthSample: Sendable, Hashable, Codable {
    /// Bytes read since the previous sample.
    public let downBytes: Int
    /// Bytes written since the previous sample.
    public let upBytes: Int
    /// Seconds covered by this sample.
    public let interval: TimeInterval

    public init(downBytes: Int, upBytes: Int, interval: TimeInterval) {
        self.downBytes = downBytes
        self.upBytes = upBytes
        self.interval = interval
    }

    public var downKilobytesPerSecond: Double {
        interval > 0 ? Double(downBytes) / 1024 / interval : 0
    }

    public var upKilobytesPerSecond: Double {
        interval > 0 ? Double(upBytes) / 1024 / interval : 0
    }
}

/// Identifies the isolation domain a tab's traffic belongs to.
///
/// Every distinct key is handed a distinct Tor SOCKS port, and therefore a
/// distinct circuit. See `TorKit.SocksPortPool` for why we isolate by port
/// rather than by SOCKS username/password.
public struct IsolationKey: Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// One isolation domain per tab.
    public static func tab(_ id: UUID) -> IsolationKey {
        IsolationKey(rawValue: "tab:\(id.uuidString)")
    }

    /// The shared domain used for app-level requests that are not page loads.
    public static let utility = IsolationKey(rawValue: "utility")
}
