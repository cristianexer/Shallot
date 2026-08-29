import Foundation

/// Validation for `.onion` hostnames.
///
/// Only v3 addresses are accepted. Tor removed v2 onion support in 0.4.6 and
/// v2 addresses are cryptographically weak, so treating them as valid would be
/// actively misleading to a user who is trusting the "ONION · VERIFIED" badge.
public enum OnionAddress {
    /// A v3 onion address is 56 base32 characters followed by `.onion`.
    public static let v3Length = 56

    private static let base32Alphabet = Set("abcdefghijklmnopqrstuvwxyz234567")

    /// Whether `host` is a syntactically valid v3 onion hostname.
    ///
    /// Subdomains are permitted (`www.<56>.onion`) because onion services can
    /// and do serve virtual hosts.
    public static func isValidV3(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host.hasSuffix(".onion") else { return false }
        let withoutSuffix = String(host.dropLast(".onion".count))
        guard let label = withoutSuffix.split(separator: ".").last else { return false }
        guard label.count == v3Length else { return false }
        return label.allSatisfy { base32Alphabet.contains($0) }
    }

    /// Whether `host` claims to be an onion address at all, valid or not.
    public static func isOnion(_ host: String) -> Bool {
        host.lowercased().hasSuffix(".onion")
    }

    /// Whether `host` is an onion address we must refuse.
    ///
    /// A v2-length address, or a malformed one, resolves to nothing useful and
    /// may be a typo-squat of a real service.
    public static func isRejectedOnion(_ host: String) -> Bool {
        isOnion(host) && !isValidV3(host)
    }
}
