import Foundation

/// Parses the bridge lines a user pastes in from BridgeDB or a Telegram bot.
///
/// Bridge lines arrive from a hostile-ish place — a censored user copies them
/// out of an email or a QR code — so this never crashes and never guesses. A
/// line either parses into something we can hand Tor verbatim, or it is
/// rejected with a reason the user can act on.
public enum BridgeLineParser {
    public enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        case empty
        case missingAddress
        case malformedAddress(String)
        case invalidPort(String)
        case invalidFingerprint(String)
        case missingRequiredParameter(transport: String, parameter: String)

        public var description: String {
            switch self {
            case .empty:
                "That line is empty."
            case .missingAddress:
                "That bridge line has no address."
            case .malformedAddress(let value):
                "‘\(value)’ is not an address and port."
            case .invalidPort(let value):
                "‘\(value)’ is not a valid port number."
            case .invalidFingerprint(let value):
                "‘\(value)’ is not a 40-character relay fingerprint."
            case .missingRequiredParameter(let transport, let parameter):
                "An \(transport) bridge needs a ‘\(parameter)=’ value."
            }
        }
    }

    /// Parses a block of text into bridge lines, reporting per-line failures.
    ///
    /// - Returns: The lines that parsed, and the errors for the ones that did
    ///   not, so the UI can accept the good lines and explain the bad ones
    ///   rather than rejecting the whole paste.
    public static func parseAll(_ text: String) -> (lines: [BridgeLine], errors: [(line: String, error: ParseError)]) {
        var lines: [BridgeLine] = []
        var errors: [(String, ParseError)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let candidate = String(rawLine).trimmingCharacters(in: .whitespaces)
            if candidate.isEmpty || candidate.hasPrefix("#") { continue }
            do {
                lines.append(try parse(candidate))
            } catch let error as ParseError {
                errors.append((candidate, error))
            } catch {
                errors.append((candidate, .empty))
            }
        }
        return (lines, errors)
    }

    /// Parses one bridge line.
    public static func parse(_ line: String) throws -> BridgeLine {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }

        // Users often paste the whole torrc directive, keyword included.
        if text.lowercased().hasPrefix("bridge ") {
            text = String(text.dropFirst("bridge ".count)).trimmingCharacters(in: .whitespaces)
        }

        var tokens = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw ParseError.empty }

        // A leading token that is a known transport name selects the transport;
        // otherwise this is a plain bridge and the first token is the address.
        var transport = BridgeTransport.vanilla
        if let named = BridgeTransport(rawValue: tokens[0].lowercased()), named != .vanilla {
            transport = named
            tokens.removeFirst()
        } else if tokens[0].lowercased() == "obfs4proxy" || tokens[0].lowercased() == "lyrebird" {
            transport = .obfs4
            tokens.removeFirst()
        }

        guard !tokens.isEmpty else { throw ParseError.missingAddress }
        let (address, port) = try parseEndpoint(tokens.removeFirst())

        // An optional 40-hex fingerprint may follow the endpoint.
        var fingerprint: String?
        if let candidate = tokens.first, !candidate.contains("=") {
            guard isFingerprint(candidate) else { throw ParseError.invalidFingerprint(candidate) }
            fingerprint = candidate.uppercased()
            tokens.removeFirst()
        }

        var parameters: [String: String] = [:]
        for token in tokens {
            guard let separator = token.firstIndex(of: "=") else { continue }
            let key = String(token[token.startIndex..<separator])
            let value = String(token[token.index(after: separator)...])
            parameters[key] = value
        }

        // obfs4 is useless without its certificate — Tor would accept the line
        // and then fail to connect, which reads to the user as "Tor is broken".
        if transport == .obfs4, parameters["cert"] == nil {
            throw ParseError.missingRequiredParameter(transport: "obfs4", parameter: "cert")
        }

        return BridgeLine(
            transport: transport,
            address: address,
            port: port,
            fingerprint: fingerprint,
            parameters: parameters,
            rawValue: text
        )
    }

    /// Splits `host:port`, including the bracketed IPv6 form `[::1]:443`.
    static func parseEndpoint(_ token: String) throws -> (address: String, port: UInt16) {
        if token.hasPrefix("[") {
            guard let closing = token.firstIndex(of: "]") else {
                throw ParseError.malformedAddress(token)
            }
            let address = String(token[token.index(after: token.startIndex)..<closing])
            let remainder = String(token[token.index(after: closing)...])
            guard remainder.hasPrefix(":") else { throw ParseError.malformedAddress(token) }
            let portText = String(remainder.dropFirst())
            guard let port = UInt16(portText), port > 0 else { throw ParseError.invalidPort(portText) }
            return (address, port)
        }

        guard let separator = token.lastIndex(of: ":") else {
            throw ParseError.malformedAddress(token)
        }
        let address = String(token[token.startIndex..<separator])
        let portText = String(token[token.index(after: separator)...])
        guard !address.isEmpty else { throw ParseError.malformedAddress(token) }
        guard let port = UInt16(portText), port > 0 else { throw ParseError.invalidPort(portText) }
        return (address, port)
    }

    static func isFingerprint(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy(\.isHexDigit)
    }
}
