import Foundation
import Testing

@testable import Domain

// MARK: - Fixtures

/// A cut-down Tor Browser export.
///
/// Trimmed from a real 47 KB one: same nesting, same attribute order, same
/// casing, but with the base64 `ICON=` payloads reduced to a few characters.
/// The originals are 30 KB of the file and none of its meaning.
private let torBrowserExport = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <!-- This is an automatically generated file.
         It will be read and overwritten.
         DO NOT EDIT! -->
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks Menu</H1>

    <DL><p>
        <DT><H3 ADD_DATE="1784733487" LAST_MODIFIED="1784733487">Tor Project Bookmarks</H3>
        <DL><p>
            <DT><A HREF="http://2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion/" ADD_DATE="1784733487" ICON="AAABAAEAEBA=">Learn more about Tor</A>
            <DT><A HREF="about:manual" ADD_DATE="1784733487" ICON_URI="fake-favicon-uri:about:manual">Tor Browser Manual</A>
            <DT><A HREF="https://donate.torproject.org/" ADD_DATE="1784733487">Donate &amp; Keep Tor Strong</A>
        </DL><p>
        <DT><H3 ADD_DATE="1784733487" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Toolbar</H3>
        <DL><p>
            <DT><A HREF="http://ofinde3b67voi7xiq3qflof2mwriwngicd7glwvf3bclgdgcjfozlzqd.onion/" ADD_DATE="1784733557" LAST_MODIFIED="1784733567">OnionFind </A>
            <DT><A HREF="http://expyuzz4wqqyqhjn.onion/" ADD_DATE="1784733746">Old Tor Project site</A>
        </DL><p>
    </DL><p>
    """

/// The address of the one link in `torBrowserExport` with no folder above it
/// in Tor Browser's own ordering — used to assert document order is kept.
private let firstOnion = "http://2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion/"

private let validOnion = "http://\(String(repeating: "a", count: 56)).onion/"

private func fixedNow() -> Date { Date(timeIntervalSince1970: 1_790_000_000) }

@Suite("Bookmark files")
struct BookmarkFileTests {
    // MARK: - Parsing

    @Test("Every openable link in a Tor Browser export is imported, in document order")
    func flattensFoldersInOrder() {
        let result = BookmarkFile.parse(torBrowserExport, now: fixedNow())
        #expect(
            result.bookmarks.map(\.title) == [
                "Learn more about Tor",
                "Donate & Keep Tor Strong",
                "OnionFind",
            ]
        )
        #expect(result.bookmarks.first?.url.absoluteString == firstOnion)
    }

    @Test("Folder names are never imported as bookmarks")
    func ignoresFolders() {
        let result = BookmarkFile.parse(torBrowserExport, now: fixedNow())
        #expect(!result.bookmarks.contains { $0.title == "Tor Project Bookmarks" })
        #expect(!result.bookmarks.contains { $0.title == "Bookmarks Toolbar" })
    }

    @Test("Titles are unescaped, because exporters escape them")
    func decodesEntitiesInTitles() {
        let document = """
            <DL><p>
            <DT><A HREF="\(validOnion)">Tom &amp; Jerry &lt;3 &quot;quotes&quot; &#39;and&#39; &#x263A;</A>
            </DL><p>
            """
        let result = BookmarkFile.parse(document, now: fixedNow())
        #expect(result.bookmarks.first?.title == "Tom & Jerry <3 \"quotes\" 'and' ☺")
    }

    @Test("An ampersand that is not an entity survives unchanged")
    func leavesBareAmpersandAlone() {
        let document = "<DT><A HREF=\"\(validOnion)\">Rock & Roll & &notanentity;</A>"
        let result = BookmarkFile.parse(document, now: fixedNow())
        #expect(result.bookmarks.first?.title == "Rock & Roll & &notanentity;")
    }

    @Test("Escaped characters in the address are decoded before it is loaded")
    func decodesEntitiesInAddresses() throws {
        let document = "<DT><A HREF=\"https://example.org/search?a=1&amp;b=2\">Search</A>"
        let bookmark = try #require(BookmarkFile.parse(document, now: fixedNow()).bookmarks.first)
        #expect(bookmark.url.absoluteString == "https://example.org/search?a=1&b=2")
    }

    @Test("ADD_DATE is read as Unix seconds")
    func readsAddDate() throws {
        let bookmark = try #require(BookmarkFile.parse(torBrowserExport, now: fixedNow()).bookmarks.first)
        #expect(bookmark.dateAdded == Date(timeIntervalSince1970: 1_784_733_487))
    }

    @Test("A missing, empty or implausible ADD_DATE becomes the time of the import", arguments: [
        "",
        "ADD_DATE=\"\"",
        "ADD_DATE=\"0\"",
        "ADD_DATE=\"not-a-number\"",
        // Microseconds, which some exporters write where seconds belong. Taken
        // literally this is the year 58,500.
        "ADD_DATE=\"1784733487000000\"",
    ])
    func fallsBackToNowForNonsenseDates(attribute: String) throws {
        let document = "<DT><A HREF=\"\(validOnion)\" \(attribute)>Somewhere</A>"
        let bookmark = try #require(BookmarkFile.parse(document, now: fixedNow()).bookmarks.first)
        #expect(bookmark.dateAdded == fixedNow())
    }

    @Test("A link with no title is saved under its host rather than under nothing")
    func fallsBackToHostForEmptyTitle() throws {
        let document = "<DT><A HREF=\"https://example.org/deep/page\"></A>"
        let bookmark = try #require(BookmarkFile.parse(document, now: fixedNow()).bookmarks.first)
        #expect(bookmark.title == "example.org")
    }

    @Test("Lowercase markup parses exactly as uppercase does")
    func acceptsLowercaseMarkup() {
        let document = """
            <dl><p>
            <dt><h3>Folder</h3>
            <dt><a href="\(validOnion)" add_date="1784733487">Lowercase</a>
            </dl><p>
            """
        let result = BookmarkFile.parse(document, now: fixedNow())
        #expect(result.bookmarks.count == 1)
        #expect(result.bookmarks.first?.title == "Lowercase")
        #expect(result.bookmarks.first?.dateAdded == Date(timeIntervalSince1970: 1_784_733_487))
    }

    // MARK: - Entries Shallot cannot open

    @Test("The sample's about: entry is skipped and reported, not imported")
    func skipsAboutManual() throws {
        let result = BookmarkFile.parse(torBrowserExport, now: fixedNow())
        #expect(!result.bookmarks.contains { $0.url.absoluteString.hasPrefix("about:") })
        let skipped = try #require(result.skipped.first { $0.address == "about:manual" })
        #expect(skipped.reason == .unsupportedScheme("about"))
    }

    @Test("Schemes the browser refuses are skipped with the scheme named", arguments: [
        "javascript:alert(1)",
        "data:text/html;base64,PHNjcmlwdD4=",
        "file:///etc/passwd",
        "place:type=6&sort=14",
        "ftp://example.org/pub",
    ])
    func skipsUnloadableSchemes(address: String) throws {
        let document = "<DT><A HREF=\"\(address)\">Do not open this</A>"
        let result = BookmarkFile.parse(document, now: fixedNow())
        #expect(result.bookmarks.isEmpty)
        let skipped = try #require(result.skipped.first)
        #expect(skipped.address == address)
        guard case .unsupportedScheme = skipped.reason else {
            Issue.record("expected an unsupported scheme, got \(skipped.reason)")
            return
        }
    }

    @Test("A v2-length onion address is skipped, because it can only be a dead or spoofed service")
    func skipsMalformedOnion() throws {
        let result = BookmarkFile.parse(torBrowserExport, now: fixedNow())
        #expect(!result.bookmarks.contains { $0.title == "Old Tor Project site" })
        let skipped = try #require(result.skipped.first { $0.address.contains("expyuzz4wqqyqhjn") })
        #expect(skipped.reason == .invalidOnion("expyuzz4wqqyqhjn.onion"))
    }

    @Test("An onion address with characters outside base32 is skipped")
    func skipsBadOnionAlphabet() throws {
        let host = String(repeating: "a", count: 55) + "1.onion"
        let document = "<DT><A HREF=\"http://\(host)/\">Typo-squat</A>"
        let result = BookmarkFile.parse(document, now: fixedNow())
        #expect(result.bookmarks.isEmpty)
        #expect(result.skipped.first?.reason == .invalidOnion(host))
    }

    @Test("An anchor with no address at all is skipped rather than saved empty", arguments: [
        "<DT><A>No address</A>",
        "<DT><A HREF=\"\">Empty address</A>",
        "<DT><A HREF=\"not a url\">Not an address</A>",
        "<DT><A HREF=\"https://\">No host</A>",
    ])
    func skipsAddresslessAnchors(document: String) {
        let result = BookmarkFile.parse(document, now: fixedNow())
        #expect(result.bookmarks.isEmpty)
        #expect(result.skipped.count == 1)
    }

    @Test("The sample yields three links and two refusals, and the counts add up")
    func countsAreComplete() {
        let result = BookmarkFile.parse(torBrowserExport, now: fixedNow())
        #expect(result.bookmarks.count == 3)
        #expect(result.skipped.count == 2)
    }

    // MARK: - Export

    private func favourite(_ title: String, _ address: String, seconds: TimeInterval) -> Favourite {
        Favourite(
            title: title,
            url: URL(string: address)!,
            dateAdded: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("The exported file declares itself as the format other browsers import")
    func writesNetscapeHeader() {
        let document = BookmarkFile.serialise([favourite("Tor", validOnion, seconds: 1_784_733_487)])
        #expect(document.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        #expect(document.contains("<TITLE>Bookmarks</TITLE>"))
        #expect(document.contains("<H1>Bookmarks</H1>"))
        #expect(document.contains("<DL><p>"))
        #expect(document.contains("</DL><p>"))
        #expect(document.contains("ADD_DATE=\"1784733487\""))
    }

    @Test("Markup characters in a title cannot escape their tag")
    func escapesTitles() {
        let document = BookmarkFile.serialise([
            favourite("</A><script>alert(\"x\")</script> & 'more'", validOnion, seconds: 1_784_733_487)
        ])
        #expect(!document.contains("<script>"))
        #expect(document.contains("&lt;/A&gt;&lt;script&gt;alert(&quot;x&quot;)"))
        #expect(document.contains("&amp;"))
        #expect(document.contains("&#39;more&#39;"))
    }

    @Test("An address with an ampersand is escaped in the attribute")
    func escapesAddresses() {
        let document = BookmarkFile.serialise([
            favourite("Search", "https://example.org/?a=1&b=2", seconds: 1_784_733_487)
        ])
        #expect(document.contains("HREF=\"https://example.org/?a=1&amp;b=2\""))
    }

    @Test("Exporting nothing still produces a valid, empty document")
    func writesEmptyDocument() {
        let document = BookmarkFile.serialise([])
        #expect(document.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        #expect(BookmarkFile.parse(document, now: fixedNow()).bookmarks.isEmpty)
    }

    @Test("Exporting then importing returns the same bookmarks, in the same order")
    func roundTrips() {
        let favourites = [
            favourite("Learn more about Tor", firstOnion, seconds: 1_784_733_487),
            favourite("Tom & Jerry <3 \"quotes\"", validOnion, seconds: 1_784_733_557),
            favourite("Donate", "https://donate.torproject.org/?a=1&b=2", seconds: 1_700_000_000),
        ]
        let parsed = BookmarkFile.parse(BookmarkFile.serialise(favourites), now: fixedNow())

        #expect(parsed.skipped.isEmpty)
        #expect(parsed.bookmarks.map(\.title) == favourites.map(\.title))
        #expect(parsed.bookmarks.map(\.url) == favourites.map(\.url))
        #expect(parsed.bookmarks.map(\.dateAdded) == favourites.map(\.dateAdded))
    }

    // MARK: - Robustness
    //
    // A bookmark file comes from outside the app and may not be a bookmark
    // file at all. None of these may crash, hang, or take the rest of the
    // import with them.

    @Test("An empty file imports nothing and reports nothing wrong")
    func handlesEmptyFile() {
        let result = BookmarkFile.parse("", now: fixedNow())
        #expect(result.bookmarks.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    @Test("A file with no links at all imports nothing")
    func handlesLinklessFile() {
        let document = """
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <TITLE>Bookmarks</TITLE>
            <H1>Bookmarks Menu</H1>
            <DL><p>
                <DT><H3>An empty folder</H3>
                <DL><p>
                </DL><p>
            </DL><p>
            """
        #expect(BookmarkFile.parse(document, now: fixedNow()).bookmarks.isEmpty)
    }

    @Test("A file truncated part way through keeps everything before the break")
    func handlesTruncatedFile() throws {
        // Cut inside the second anchor's attributes, where a file that stopped
        // uploading half way would end.
        let cut = try #require(torBrowserExport.range(of: "about:manual")).lowerBound
        let result = BookmarkFile.parse(String(torBrowserExport[..<cut]), now: fixedNow())
        #expect(result.bookmarks.map(\.title) == ["Learn more about Tor"])
    }

    @Test("An unterminated quote runs to the end of the file instead of forever")
    func handlesUnterminatedQuote() {
        let document = "<DL><p>\n<DT><A HREF=\"\(validOnion) ADD_DATE=\"1784733487\">Never closed</A>"
        let result = BookmarkFile.parse(document, now: fixedNow())
        #expect(result.bookmarks.isEmpty)
        #expect(result.skipped.count == 1)
    }

    @Test("An unterminated comment swallows the rest of the file and nothing more")
    func handlesUnterminatedComment() {
        let document = "<DT><A HREF=\"\(validOnion)\">Before</A>\n<!-- and then nothing closes this"
        let result = BookmarkFile.parse(document, now: fixedNow())
        #expect(result.bookmarks.map(\.title) == ["Before"])
    }

    @Test("An unclosed tag does not swallow the link after it")
    func handlesUnclosedTag() {
        let document = "<DT><H3>Folder</H3>\n<DT><A HREF=\"\(validOnion)\">After a stray tag</A>"
        #expect(BookmarkFile.parse(document, now: fixedNow()).bookmarks.count == 1)
    }

    @Test("Text that is not markup at all imports nothing")
    func handlesJunk() {
        let junk = String(repeating: "\u{FFFD}\u{0000}not html at all 12345 <<<>>> ", count: 500)
        let result = BookmarkFile.parse(junk, now: fixedNow())
        #expect(result.bookmarks.isEmpty)
    }

    @Test("Bytes that are not valid UTF-8 do not stop the rest of the file being read")
    func handlesInvalidUTF8() {
        var bytes = Array("<DT><A HREF=\"\(validOnion)\">Caf".utf8)
        bytes += [0xC3, 0x28, 0xFF]
        bytes += Array("</A>".utf8)
        let result = BookmarkFile.parse(String(decoding: bytes, as: UTF8.self), now: fixedNow())
        #expect(result.bookmarks.count == 1)
        #expect(result.bookmarks.first?.url.absoluteString == validOnion)
    }

    @Test("A multi-megabyte file parses in one pass, without backtracking")
    func handlesLargeFile() {
        let entry = "    <DT><A HREF=\"\(validOnion)?q=x\" ADD_DATE=\"1784733487\" ICON=\"AAABAAEAEBA=\">A saved site</A>\n"
        let document = "<DL><p>\n" + String(repeating: entry, count: 40_000) + "</DL><p>\n"
        #expect(document.utf8.count > 5_000_000)

        let started = ContinuousClock.now
        let result = BookmarkFile.parse(document, now: fixedNow())
        #expect(result.bookmarks.count == 40_000)
        // Generous by two orders of magnitude: this is a guard against a
        // pathological parse, not a performance benchmark.
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test("Deeply nested folders do not recurse")
    func handlesDeepNesting() {
        let opening = String(repeating: "<DL><p><DT><H3>Folder</H3>\n", count: 5_000)
        let closing = String(repeating: "</DL><p>\n", count: 5_000)
        let document = opening + "<DT><A HREF=\"\(validOnion)\">Deep</A>\n" + closing
        #expect(BookmarkFile.parse(document, now: fixedNow()).bookmarks.map(\.title) == ["Deep"])
    }
}
