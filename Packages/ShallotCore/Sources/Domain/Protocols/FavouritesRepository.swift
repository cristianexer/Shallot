import Foundation

/// On-device, encrypted-at-rest storage for saved sites.
///
/// There is deliberately no sync API. Syncing a Tor browser's bookmarks is a
/// way to be identified, so the capability does not exist rather than being
/// present and switched off.
@MainActor
public protocol FavouritesRepository: AnyObject {
    /// All favourites in user order.
    var favourites: [Favourite] { get }

    func reload() throws
    func add(title: String, url: URL) throws
    func update(_ favourite: Favourite) throws
    func delete(id: UUID) throws
    /// Reorders after a drag, rewriting `sortIndex` for the whole list.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws
    /// Whether `url` is already saved, so the UI can show a filled bookmark.
    func contains(url: URL) -> Bool
}
