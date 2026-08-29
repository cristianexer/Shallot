import Domain
import Foundation
import Observation

/// Drives the Favourites screen.
@MainActor
@Observable
public final class FavouritesViewModel {
    @ObservationIgnored private let repository: any FavouritesRepository
    @ObservationIgnored private let open: (URL) -> Void

    /// Set when an edit fails, so the UI can say why instead of silently
    /// dropping the change.
    public var errorMessage: String?

    /// The favourite currently being renamed.
    public var editing: Favourite?
    public var editedTitle: String = ""

    /// Text for the add-favourite sheet.
    public var newTitle: String = ""
    public var newAddress: String = ""
    public var isAdding = false

    public init(repository: any FavouritesRepository, open: @escaping (URL) -> Void) {
        self.repository = repository
        self.open = open
    }

    public var favourites: [Favourite] { repository.favourites }
    public var onionFavourites: [Favourite] { favourites.filter(\.isOnion) }
    public var clearnetFavourites: [Favourite] { favourites.filter { !$0.isOnion } }
    public var isEmpty: Bool { favourites.isEmpty }

    public func openFavourite(_ favourite: Favourite) {
        open(favourite.url)
    }

    public func beginAdding() {
        newTitle = ""
        newAddress = ""
        isAdding = true
    }

    /// Adds whatever is in the add sheet, validating the address first.
    public func commitAdd() {
        let trimmed = newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        switch URLNormalizer.resolve(trimmed, httpsOnly: false) {
        case .url(let url):
            perform { try repository.add(title: newTitle, url: url) }
            isAdding = false
        case .invalidOnion(let host):
            errorMessage = "‘\(host)’ is not a valid v3 onion address."
        case .search, .empty:
            errorMessage = "That is not an address Shallot can open."
        }
    }

    public func beginRenaming(_ favourite: Favourite) {
        editing = favourite
        editedTitle = favourite.title
    }

    public func commitRename() {
        guard var favourite = editing else { return }
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editing = nil
            return
        }
        favourite.title = trimmed
        perform { try repository.update(favourite) }
        editing = nil
    }

    public func delete(_ favourite: Favourite) {
        perform { try repository.delete(id: favourite.id) }
    }

    public func delete(at offsets: IndexSet, in list: [Favourite]) {
        for index in offsets where list.indices.contains(index) {
            perform { try repository.delete(id: list[index].id) }
        }
    }

    public func move(from source: IndexSet, to destination: Int) {
        perform { try repository.move(fromOffsets: source, toOffset: destination) }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            errorMessage = nil
        } catch {
            errorMessage = "That change could not be saved."
        }
    }
}
