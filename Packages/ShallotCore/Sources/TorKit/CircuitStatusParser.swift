import Domain
import Foundation

/// Turns Tor's `GETINFO circuit-status` output into `Circuit` values.
///
/// Pure and synchronous so the whole format — including the shapes Tor only
/// emits under load, like pathless `LAUNCHED` circuits and `$fingerprint`
/// entries with no nickname — is covered by unit tests against captured
/// fixtures rather than by hoping on a live network.
///
/// One line looks like:
///
///     1 BUILT $AAAA~guardnick,$BBBB~midnick,$CCCC~exitnick BUILD_FLAGS=NEED_CAPACITY PURPOSE=GENERAL
///
/// See control-spec.txt §4.1.1 for the grammar.
public enum CircuitStatusParser {
    /// Parses the whole data block Tor returns for `circuit-status`.
    public static func parse(_ raw: String) -> [Circuit] {
        raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseLine(String($0)) }
    }

    /// Parses a single circuit-status line, or the payload of a `CIRC` event.
    public static func parseLine(_ line: String) -> Circuit? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var fields = trimmed.split(separator: " ").map(String.init)
        guard fields.count >= 2 else { return nil }

        let id = fields.removeFirst()
        let statusToken = fields.removeFirst()
        let status = Circuit.Status(rawValue: statusToken) ?? .unknown

        // The path is the next field, if there is one — `LAUNCHED` circuits
        // have none at all and go straight to their attributes.
        var path: [RelayNode] = []
        if let candidate = fields.first, !isAttribute(candidate) {
            path = parsePath(candidate)
            fields.removeFirst()
        }

        var attributes: [String: String] = [:]
        for field in fields {
            guard let separator = field.firstIndex(of: "=") else { continue }
            let key = String(field[field.startIndex..<separator])
            let value = String(field[field.index(after: separator)...])
            attributes[key] = value
        }

        return Circuit(id: id, status: status, path: path, purpose: attributes["PURPOSE"])
    }

    /// Splits `$FP~nick,$FP=nick,$FP` into positioned relays.
    public static func parsePath(_ path: String) -> [RelayNode] {
        let entries = path.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return entries.enumerated().map { index, entry in
            let (fingerprint, nickname) = splitLongName(entry)
            return RelayNode(
                fingerprint: fingerprint,
                nickname: nickname,
                position: position(at: index, of: entries.count)
            )
        }
    }

    /// Whether a field is a `KEY=VALUE` attribute rather than the path.
    ///
    /// "Contains an `=`" is not good enough: Tor writes a *Named* relay as
    /// `$fingerprint=nickname`, so a path can contain `=` too. Attribute keys
    /// are always uppercase words (`BUILD_FLAGS`, `PURPOSE`, `TIME_CREATED`,
    /// `REASON`, `SOCKS_USERNAME`…), which is what distinguishes them.
    static func isAttribute(_ field: String) -> Bool {
        // A path always begins with a `$`-prefixed fingerprint, so that alone
        // settles it before the key test has a chance to be fooled by an
        // all-uppercase hex fingerprint.
        guard !field.hasPrefix("$") else { return false }
        guard let separator = field.firstIndex(of: "=") else { return false }
        let key = field[field.startIndex..<separator]
        guard !key.isEmpty else { return false }
        return key.allSatisfy { character in
            (character.isLetter && character.isUppercase) || character.isNumber || character == "_"
        }
    }

    /// `$ABC123~nickname` → (`ABC123`, `nickname`).
    ///
    /// Tor uses `~` when the nickname is unverified and `=` when it is named in
    /// the consensus; both are separators, and either may be absent entirely.
    static func splitLongName(_ entry: String) -> (fingerprint: String, nickname: String) {
        var value = entry
        if value.hasPrefix("$") { value.removeFirst() }
        if let separator = value.firstIndex(where: { $0 == "~" || $0 == "=" }) {
            let fingerprint = String(value[value.startIndex..<separator])
            let nickname = String(value[value.index(after: separator)...])
            return (fingerprint, nickname)
        }
        return (value, "")
    }

    /// First hop is the guard, last is the exit, everything between is middle.
    ///
    /// A one-hop circuit is a directory fetch, not a browsing path; calling its
    /// single relay the guard is the accurate description.
    static func position(at index: Int, of count: Int) -> RelayNode.Position {
        if index == 0 { return .guardRelay }
        if index == count - 1 { return .exit }
        return .middle
    }
}

/// Parses the `r` lines of `GETINFO ns/id/<fingerprint>`.
///
/// The only field we want is the relay's IP address, which is then fed to
/// `GETINFO ip-to-country/<ip>` so the Monitor can label a hop with a country
/// resolved from the *bundled* GeoIP database — never from a network lookup.
public enum RouterStatusParser {
    /// `r nickname identity digest publication IP ORPort DirPort`
    public static func address(in raw: String) -> String? {
        for line in raw.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.first == "r", fields.count >= 7 else { continue }
            return fields[6]
        }
        return nil
    }
}
