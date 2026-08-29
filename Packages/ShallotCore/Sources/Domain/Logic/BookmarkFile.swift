import Foundation

/// Reads and writes the Netscape Bookmark File Format.
///
/// This is the lowest common denominator every browser speaks: Tor Browser,
/// Firefox, Chrome and Safari all import and export it, so a user arriving
/// from Tor Browser can bring their onion bookmarks with them and leave again
/// without being locked in.
///
/// The input is a file from outside the app — chosen in the document picker,
/// possibly hand-edited, possibly not a bookmark file at all. Nothing here
/// throws, recurses or backtracks: the scanner walks the bytes once, forward
/// only, and anything it cannot make sense of is skipped with a reason rather
/// than failing the whole import.
public enum BookmarkFile {
    /// One importable link. Folders are not represented — see `parse(_:now:)`.
    public struct Bookmark: Sendable, Hashable {
        public let title: String
        public let url: URL
        public let dateAdded: Date

        public init(title: String, url: URL, dateAdded: Date) {
            self.title = title
            self.url = url
            self.dateAdded = dateAdded
        }
    }

    /// Why an entry in the file cannot become a favourite.
    public enum SkipReason: Error, Sendable, Hashable, CustomStringConvertible {
        /// `about:`, `javascript:`, `data:`, `file:`, `place:` — anything the
        /// browser refuses to load.
        case unsupportedScheme(String)
        /// Claims to be an onion address but is not a valid v3 one.
        case invalidOnion(String)
        /// Not a URL at all, or one with no host.
        case malformedAddress

        public var description: String {
            switch self {
            case .unsupportedScheme(let scheme):
                "‘\(scheme):’ is not an address Shallot can open."
            case .invalidOnion(let host):
                "‘\(host)’ is not a valid v3 onion address."
            case .malformedAddress:
                "That is not a web address."
            }
        }
    }

    /// An entry that was read but will not be imported.
    public struct SkippedEntry: Sendable, Hashable {
        public let address: String
        public let reason: SkipReason

        public init(address: String, reason: SkipReason) {
            self.address = address
            self.reason = reason
        }
    }

    /// What a file yielded: the links we can open, and the ones we cannot.
    public struct ParseResult: Sendable, Hashable {
        public var bookmarks: [Bookmark]
        public var skipped: [SkippedEntry]

        public init(bookmarks: [Bookmark] = [], skipped: [SkippedEntry] = []) {
            self.bookmarks = bookmarks
            self.skipped = skipped
        }
    }

    // MARK: - Parsing

    /// Reads every link in a bookmark file, in document order.
    ///
    /// Folders are flattened away. `Favourite` has no notion of a folder, and
    /// inventing one so that an import can round-trip would be a data model
    /// change driven by a file format rather than by the app.
    ///
    /// - Parameter now: Substituted for a missing or nonsensical `ADD_DATE`.
    ///   Injected so the behaviour is testable without waiting for a clock.
    public static func parse(_ file: Data, now: Date = Date()) -> ParseResult {
        parse(decoded(file), now: now)
    }

    /// UTF-8 where the file is UTF-8, Latin-1 where it is not.
    ///
    /// This format is older than UTF-8 being universal, and an export from an
    /// elderly browser on Windows is frequently Latin-1. Falling back beats
    /// refusing the file: the markup is ASCII either way, so at worst an
    /// accented character in one title comes out wrong.
    static func decoded(_ file: Data) -> String {
        String(data: file, encoding: .utf8) ?? String(data: file, encoding: .isoLatin1) ?? ""
    }

    /// Reads every link in `text`, in document order.
    public static func parse(_ text: String, now: Date = Date()) -> ParseResult {
        let bytes = Array(text.utf8)
        var result = ParseResult()
        var index = 0

        while index < bytes.count {
            guard let opening = bytes[index...].firstIndex(of: openAngle) else { break }
            index = opening + 1

            if hasPrefix(commentOpen, in: bytes, at: index) {
                index = endOfComment(in: bytes, from: index + commentOpen.count)
                continue
            }

            let name = readTagName(bytes, &index)
            guard name == "a" else {
                // Every other tag — <DL>, <DT>, <H3> folder headings — is
                // consumed and dropped, but its attributes must still be
                // scanned so that a `>` inside a quoted value cannot be
                // mistaken for the end of the tag.
                _ = readAttributes(bytes, &index, capturing: [])
                continue
            }

            let attributes = readAttributes(bytes, &index, capturing: interestingAttributes)
            let title = decodingEntities(readText(bytes, &index))
            let href = decodingEntities(attributes["href"] ?? "")
            let dateAdded = date(from: attributes["add_date"], now: now)

            switch classify(href) {
            case .success(let url):
                let fallback = url.host() ?? url.absoluteString
                result.bookmarks.append(
                    Bookmark(
                        title: title.isEmpty ? fallback : title,
                        url: url,
                        dateAdded: dateAdded
                    )
                )
            case .failure(let reason):
                result.skipped.append(SkippedEntry(address: href, reason: reason))
            }
        }

        return result
    }

    /// Whether Shallot could open `href`, and why not when it could not.
    ///
    /// `URLNormalizer.isLoadable(_:)` is the authority on the answer; the
    /// checks either side of it exist only to say which rule was broken.
    static func classify(_ href: String) -> Result<URL, SkipReason> {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.malformedAddress) }
        // A space inside an address means the attribute was not closed and we
        // read past it — `URL` would silently percent-encode the remainder
        // into the path and hand back a plausible-looking URL for a page that
        // does not exist. `URLNormalizer.looksLikeHost(_:)` refuses a space
        // for the same reason.
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else {
            return .failure(.malformedAddress)
        }
        guard let scheme = url.scheme?.lowercased() else { return .failure(.malformedAddress) }
        guard URLNormalizer.allowedSchemes.contains(scheme) else {
            return .failure(.unsupportedScheme(scheme))
        }
        guard let host = url.host(), !host.isEmpty else { return .failure(.malformedAddress) }
        guard !OnionAddress.isRejectedOnion(host) else { return .failure(.invalidOnion(host)) }
        guard URLNormalizer.isLoadable(url) else { return .failure(.malformedAddress) }
        return .success(url)
    }

    /// `ADD_DATE` is Unix seconds, but exporters have been known to write
    /// microseconds, zero, or nothing at all. A value outside living memory is
    /// treated as absent rather than as a bookmark saved in 1970.
    static func date(from value: String?, now: Date) -> Date {
        guard let value, let seconds = Double(value.trimmingCharacters(in: .whitespaces)) else {
            return now
        }
        let date = Date(timeIntervalSince1970: seconds)
        guard date >= earliestPlausibleDate, date <= now.addingTimeInterval(oneDay) else {
            return now
        }
        return date
    }

    // MARK: - Serialising

    /// Writes `favourites` as a document Tor Browser and Firefox will import.
    ///
    /// A single flat list: the favourites have no folders to preserve, and a
    /// nested `<DL>` with one folder in it would only add a level for the
    /// receiving browser to unwrap.
    public static func serialise(_ favourites: [Favourite]) -> String {
        var out = """
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <!-- This is an automatically generated file.
                 It will be read and overwritten.
                 DO NOT EDIT! -->
            <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
            <TITLE>Bookmarks</TITLE>
            <H1>Bookmarks</H1>

            <DL><p>

            """
        for favourite in favourites {
            let address = escaped(favourite.url.absoluteString)
            let title = escaped(favourite.title)
            let added = Int(favourite.dateAdded.timeIntervalSince1970)
            out += "    <DT><A HREF=\"\(address)\" ADD_DATE=\"\(added)\">\(title)</A>\n"
        }
        out += "</DL><p>\n"
        return out
    }

    /// The five entities every reader of this format understands.
    ///
    /// `'` is written numerically because `&apos;` is XML, not HTML 4, and the
    /// older importers this format exists to satisfy do not all decode it.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: - Entity decoding

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    ]

    /// Longest entity we will look ahead for, so a lone `&` in a title costs a
    /// bounded scan rather than a walk to the end of the document.
    private static let maximumEntityLength = 12

    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "&" else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            let body = text.index(after: index)
            let limit = text.index(body, offsetBy: maximumEntityLength, limitedBy: text.endIndex) ?? text.endIndex
            guard let semicolon = text[body..<limit].firstIndex(of: ";"),
                  let replacement = entity(String(text[body..<semicolon]))
            else {
                out.append("&")
                index = body
                continue
            }
            out += replacement
            index = text.index(after: semicolon)
        }
        return out
    }

    private static func entity(_ body: String) -> String? {
        guard !body.isEmpty else { return nil }
        guard body.hasPrefix("#") else { return namedEntities[body.lowercased()] }

        let digits = body.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    // MARK: - Byte scanning
    //
    // Deliberately byte-level rather than regular expressions. The tag
    // delimiters are all ASCII, so multi-byte UTF-8 sequences pass through
    // untouched, and a single forward pass cannot be made to backtrack by a
    // hostile file the way a nested-quantifier pattern can.

    private static let openAngle = UInt8(ascii: "<")
    private static let closeAngle = UInt8(ascii: ">")
    private static let commentOpen = Array("!--".utf8)
    private static let commentClose = Array("-->".utf8)
    private static let interestingAttributes: Set<String> = ["href", "add_date"]
    private static let earliestPlausibleDate = Date(timeIntervalSince1970: 631_152_000)
    private static let oneDay: TimeInterval = 86_400

    private static func hasPrefix(_ prefix: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        guard index + prefix.count <= bytes.count else { return false }
        for (offset, byte) in prefix.enumerated() where bytes[index + offset] != byte {
            return false
        }
        return true
    }

    /// Index just past the closing `-->`, or the end of the file if the
    /// comment was never closed.
    private static func endOfComment(in bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            if hasPrefix(commentClose, in: bytes, at: index) { return index + commentClose.count }
            index += 1
        }
        return bytes.count
    }

    /// A slice of the file as text, decoded the same way the whole file is.
    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    /// Reads the lowercased tag name at `index`, leaving `index` on the first
    /// byte after it. A closing tag reads as `/a`, which never matches.
    private static func readTagName(_ bytes: [UInt8], _ index: inout Int) -> String {
        let start = index
        while index < bytes.count, !isSpace(bytes[index]), bytes[index] != closeAngle {
            index += 1
        }
        return text(bytes[start..<index]).lowercased()
    }

    /// Consumes the remainder of a tag, returning only the attributes named in
    /// `capturing`.
    ///
    /// The filter is not an optimisation of convenience: a Tor Browser export
    /// carries a base64 favicon in every `ICON=`, and materialising those as
    /// strings costs more than the rest of the parse put together.
    private static func readAttributes(
        _ bytes: [UInt8],
        _ index: inout Int,
        capturing wanted: Set<String>
    ) -> [String: String] {
        var attributes: [String: String] = [:]

        while index < bytes.count {
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count else { break }
            if bytes[index] == closeAngle {
                index += 1
                break
            }

            let nameStart = index
            while index < bytes.count,
                  !isSpace(bytes[index]),
                  bytes[index] != closeAngle,
                  bytes[index] != UInt8(ascii: "=") {
                index += 1
            }
            let name = text(bytes[nameStart..<index]).lowercased()

            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else {
                // A valueless attribute such as `PERSONAL_TOOLBAR_FOLDER`.
                // The step is what makes the loop provably terminate: every
                // iteration either consumes a byte or leaves through `break`.
                if index == nameStart { index += 1 }
                continue
            }
            index += 1

            let range = readAttributeValue(bytes, &index)
            if wanted.contains(name) {
                attributes[name] = text(bytes[range])
            }
        }
        return attributes
    }

    private static func readAttributeValue(_ bytes: [UInt8], _ index: inout Int) -> Range<Int> {
        while index < bytes.count, isSpace(bytes[index]) { index += 1 }
        guard index < bytes.count else { return index..<index }

        let quote = bytes[index]
        if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
            index += 1
            let start = index
            while index < bytes.count, bytes[index] != quote { index += 1 }
            let end = index
            // An unterminated quote runs to the end of the file; stopping
            // there is what every browser does with the same input.
            if index < bytes.count { index += 1 }
            return start..<end
        }

        let start = index
        while index < bytes.count, !isSpace(bytes[index]), bytes[index] != closeAngle {
            index += 1
        }
        return start..<index
    }

    /// The text between a tag and the next `<`, trimmed.
    private static func readText(_ bytes: [UInt8], _ index: inout Int) -> String {
        let start = index
        while index < bytes.count, bytes[index] != openAngle { index += 1 }
        return text(bytes[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
