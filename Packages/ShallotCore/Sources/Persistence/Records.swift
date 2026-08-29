import Domain
import Foundation
import SwiftData

/// A saved site, on disk.
///
/// The only user content Shallot ever persists. There is no history model, no
/// tab model and no log model in this schema, and that is the point: they do
/// not exist to be recovered.
@Model
public final class FavouriteRecord {
    #Index<FavouriteRecord>([\.sortIndex])
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var urlString: String
    public var sortIndex: Int
    public var dateAdded: Date

    public init(id: UUID = UUID(), title: String, urlString: String, sortIndex: Int, dateAdded: Date = Date()) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.sortIndex = sortIndex
        self.dateAdded = dateAdded
    }

    public convenience init(_ favourite: Favourite) {
        self.init(
            id: favourite.id,
            title: favourite.title,
            urlString: favourite.url.absoluteString,
            sortIndex: favourite.sortIndex,
            dateAdded: favourite.dateAdded
        )
    }

    /// The domain value, or `nil` if the stored string is no longer a URL.
    ///
    /// Returning `nil` rather than force-unwrapping means one corrupt row hides
    /// itself instead of taking the whole favourites list down.
    public var favourite: Favourite? {
        guard let url = URL(string: urlString) else { return nil }
        return Favourite(id: id, title: title, url: url, sortIndex: sortIndex, dateAdded: dateAdded)
    }

    public func apply(_ favourite: Favourite) {
        title = favourite.title
        urlString = favourite.url.absoluteString
        sortIndex = favourite.sortIndex
    }
}

/// The single settings row.
///
/// Stored as an encoded `AppSettings` blob rather than a column per toggle: the
/// settings shape changes far more often than the storage needs to, and a blob
/// makes adding a preference a zero-migration change.
@Model
public final class SettingsRecord {
    @Attribute(.unique) public var identifier: String
    public var payload: Data
    /// The bridge configuration Tor was actually started with, so the app can
    /// tell whether a relaunch is pending.
    public var appliedBridgePayload: Data?
    public init(
        identifier: String = SettingsRecord.singletonIdentifier,
        payload: Data,
        appliedBridgePayload: Data? = nil
    ) {
        self.identifier = identifier
        self.payload = payload
        self.appliedBridgePayload = appliedBridgePayload
    }

    public static let singletonIdentifier = "shallot.settings"

    public func decoded() -> AppSettings {
        // A settings row we cannot decode is a settings row from a build that
        // no longer exists. Defaults are safe — every default is the private
        // choice — so this falls back rather than failing.
        (try? JSONDecoder().decode(AppSettings.self, from: payload)) ?? .default
    }

    public func decodedAppliedBridges() -> BridgeConfig? {
        guard let appliedBridgePayload else { return nil }
        return try? JSONDecoder().decode(BridgeConfig.self, from: appliedBridgePayload)
    }
}
