import Foundation

/// How much of the web platform Shallot is willing to expose to a page.
///
/// On iOS every browser renders with WebKit, so we cannot patch the engine the
/// way desktop Tor Browser patches Firefox. Turning JavaScript off is therefore
/// the single strongest realistic anti-fingerprinting lever available to us,
/// and it is what `.safest` does.
public enum SecurityLevel: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    /// Everything on. The §9 leak mitigations still apply — they always do.
    case standard
    /// JavaScript still runs, but the strict blocking rule list is applied.
    case safer
    /// JavaScript off everywhere. Some sites will break; that is expected.
    case safest

    public var id: String { rawValue }

    /// Short uppercase label for the segmented picker.
    public var title: String {
        switch self {
        case .standard: "STANDARD"
        case .safer: "SAFER"
        case .safest: "SAFEST"
        }
    }

    /// Plain-language explanation shown under the picker. No overstatement.
    public var explanation: String {
        switch self {
        case .standard:
            "Standard: all features on. Every site works normally — the least protection."
        case .safer:
            "Safer: risky scripts and remote fonts are blocked. A balance of usability and protection."
        case .safest:
            "Safest: JavaScript is disabled on every site. Maximum protection, some sites will break."
        }
    }

    /// Whether page-authored JavaScript is allowed to run at this level.
    public var allowsJavaScript: Bool { self != .safest }

    /// Whether the strict blocking rule list is applied on top of the base list.
    public var usesStrictBlocking: Bool { self != .standard }
}
