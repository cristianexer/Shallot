import Foundation

/// A saved site. Stored on-device only, encrypted at rest, never synced —
/// cloud sync of a Tor browser's bookmarks is a deanonymisation surface.
public struct Favourite: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public var title: String
    public var url: URL
    public var sortIndex: Int
    public var dateAdded: Date

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        sortIndex: Int = 0,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.sortIndex = sortIndex
        self.dateAdded = dateAdded
    }

    /// Whether this points at an onion service.
    public var isOnion: Bool { url.host()?.hasSuffix(".onion") ?? false }

    /// Two-letter monogram for the tile, derived from the title.
    public var monogram: String {
        let words = title.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(title.prefix(2)).uppercased()
    }

    /// Host with the onion hash elided, so long v3 addresses stay readable.
    public var displayURL: String {
        guard let host = url.host() else { return url.absoluteString }
        guard isOnion, host.count > 24 else { return host }
        return host.prefix(16) + "…onion"
    }
}
