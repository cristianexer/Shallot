import Domain
import Foundation
import Observation

/// Drives the Favourites screen.
@MainActor
@Observable
public final class FavouritesViewModel {
    @ObservationIgnored private let repository: any FavouritesRepository

    /// What to do with a favourite the user tapped.
    ///
    /// Settable rather than injected, because the coordinator that knows how to
    /// *navigate* to the browser does not exist yet when this is built.
    @ObservationIgnored public var open: (URL) -> Void

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

    /// Drives the document picker and the export panel.
    public var isImporting = false
    public var isExporting = false

    /// What an import did, reported back to the user. Set for a successful
    /// import as well as a failed one: a file that yielded nothing looks
    /// exactly like a file that was never read, and the two need telling apart.
    public var importSummary: String?

    /// Serialised when the export panel opens rather than on every redraw,
    /// because `body` is evaluated far more often than a user exports.
    public private(set) var exportText = ""

    public init(repository: any FavouritesRepository, open: @escaping (URL) -> Void = { _ in }) {
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

    // MARK: - Import and export

    /// A file larger than this is not a bookmark file, whatever it claims.
    ///
    /// A Tor Browser export of a thousand bookmarks, favicons and all, is
    /// under three megabytes; the ceiling exists so that picking a disk image
    /// by mistake fails immediately instead of reading it into memory.
    private static let maximumImportBytes = 16 * 1024 * 1024

    public var canExport: Bool { !favourites.isEmpty }

    public func beginImport() {
        isImporting = true
    }

    public func beginExport() {
        exportText = BookmarkFile.serialise(favourites)
        isExporting = true
    }

    /// Handles what the document picker returned.
    public func finishImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let file = urls.first else { return }
            importBookmarks(from: file)
        case .failure:
            importSummary = "That file could not be opened."
        }
    }

    public func finishExport(_ result: Result<URL, any Error>) {
        if case .failure = result {
            errorMessage = "Those bookmarks could not be written to a file."
        }
    }

    /// Reads a bookmark file the user picked and saves what it holds.
    public func importBookmarks(from file: URL) {
        // The picked file lives outside the app's container, so the sandbox
        // only opens it while the scoped resource is held.
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: file) else {
            importSummary = "That file could not be read."
            return
        }
        guard data.count <= Self.maximumImportBytes else {
            importSummary = "That file is too large to be a bookmark file."
            return
        }
        // Lossy by design: a bookmark file written in some other encoding
        // still has usable ASCII markup, and a mangled character in a title is
        // a better outcome than refusing the whole import.
        let parsed = BookmarkFile.parse(String(decoding: data, as: UTF8.self))
        importSummary = saveImported(parsed).summary
    }

    /// Saves everything in `parsed` that is not already a favourite.
    public func saveImported(_ parsed: BookmarkFile.ParseResult) -> ImportOutcome {
        var outcome = ImportOutcome(skipped: parsed.skipped)
        for bookmark in parsed.bookmarks {
            guard !repository.contains(url: bookmark.url) else {
                outcome.alreadySaved += 1
                continue
            }
            do {
                try repository.add(title: bookmark.title, url: bookmark.url)
                outcome.added += 1
            } catch {
                outcome.notSaved += 1
            }
        }
        return outcome
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

/// What one import did, in the terms the user is told about it.
public struct ImportOutcome: Sendable, Hashable {
    public var added = 0
    public var alreadySaved = 0
    public var notSaved = 0
    public var skipped: [BookmarkFile.SkippedEntry] = []

    public init(
        added: Int = 0,
        alreadySaved: Int = 0,
        notSaved: Int = 0,
        skipped: [BookmarkFile.SkippedEntry] = []
    ) {
        self.added = added
        self.alreadySaved = alreadySaved
        self.notSaved = notSaved
        self.skipped = skipped
    }

    /// Plain sentences, no jargon, and never silent about a link that was
    /// dropped — an import that quietly loses a bookmark is how someone
    /// discovers months later that an onion address is gone.
    public var summary: String {
        guard added > 0 || alreadySaved > 0 || notSaved > 0 || !skipped.isEmpty else {
            return "That file has no bookmarks Shallot can open."
        }

        var sentences: [String] = []
        switch added {
        case 0: sentences.append("No new bookmarks were added.")
        case 1: sentences.append("Added 1 bookmark.")
        default: sentences.append("Added \(added) bookmarks.")
        }
        if alreadySaved > 0 {
            sentences.append(alreadySaved == 1 ? "1 was already saved." : "\(alreadySaved) were already saved.")
        }
        if notSaved > 0 {
            sentences.append(notSaved == 1 ? "1 could not be saved." : "\(notSaved) could not be saved.")
        }
        if let skippedSentence {
            sentences.append(skippedSentence)
        }
        return sentences.joined(separator: " ")
    }

    /// The count, then the first couple of distinct reasons. Listing every
    /// reason for a file full of `place:` entries would fill the alert.
    private var skippedSentence: String? {
        guard !skipped.isEmpty else { return nil }
        var reasons: [String] = []
        for entry in skipped where !reasons.contains(entry.reason.description) {
            reasons.append(entry.reason.description)
        }
        let lead = skipped.count == 1
            ? "1 was skipped."
            : "\(skipped.count) were skipped."
        return ([lead] + reasons.prefix(2)).joined(separator: " ")
    }
}
