import Foundation

/// Something security-relevant that Shallot observed and handled locally.
///
/// These are the lines in the Monitor's terminal view. They are computed on
/// device, held in memory, and never written to disk or sent anywhere.
public struct SecurityEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// A hostname was handed to Tor for remote resolution rather than
        /// resolved on this device.
        case dnsViaTor
        /// A request was blocked because it would have bypassed the proxy.
        case leakBlocked
        /// A third-party tracker request was blocked by the rule list.
        case trackerBlocked
        /// An `http://` URL was upgraded to `https://`.
        case httpsUpgraded
        /// A load was refused because Tor was not carrying traffic.
        case killSwitch
        /// A new circuit was built.
        case circuitBuilt
        /// The user asked for a brand-new identity.
        case newIdentity
        /// Informational.
        case info
        /// Something went wrong.
        case failure

        /// Glyph used in the Monitor terminal, matching the prototype.
        public var glyph: String {
            switch self {
            case .dnsViaTor, .httpsUpgraded, .info: "✓"
            case .leakBlocked, .trackerBlocked, .killSwitch: "⛌"
            case .circuitBuilt, .newIdentity: "↻"
            case .failure: "✕"
            }
        }

        /// Whether this reads as a good outcome (green) or an intervention (red).
        public var isAffirmative: Bool {
            switch self {
            case .dnsViaTor, .httpsUpgraded, .circuitBuilt, .newIdentity, .info: true
            case .leakBlocked, .trackerBlocked, .killSwitch, .failure: false
            }
        }
    }

    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), kind: Kind, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
    }
}
