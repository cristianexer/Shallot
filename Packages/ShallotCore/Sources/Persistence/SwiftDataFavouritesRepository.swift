import Domain
import Foundation
import Observation
import SwiftData

/// `FavouritesRepository` over SwiftData.
@MainActor
@Observable
public final class SwiftDataFavouritesRepository: FavouritesRepository {
    public private(set) var favourites: [Favourite] = []

    @ObservationIgnored private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
        try? reload()
    }

    public func reload() throws {
        let descriptor = FetchDescriptor<FavouriteRecord>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.dateAdded)]
        )
        favourites = try context.fetch(descriptor).compactMap(\.favourite)
    }

    public func add(title: String, url: URL) throws {
        // Both checks go to the store rather than to the in-memory list: a row
        // that failed to parse is absent from `favourites` but still present on
        // disk, and using the list's count would hand the new row an index that
        // is already taken.
        guard try !storeContains(url: url) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? (url.host() ?? url.absoluteString) : trimmed
        context.insert(
            FavouriteRecord(
                title: name,
                urlString: url.absoluteString,
                sortIndex: try nextSortIndex()
            )
        )
        try context.save()
        try reload()
    }

    public func update(_ favourite: Favourite) throws {
        guard let record = try record(for: favourite.id) else { return }
        record.apply(favourite)
        try context.save()
        try reload()
    }

    public func delete(id: UUID) throws {
        guard let record = try record(for: id) else { return }
        context.delete(record)
        try context.save()
        try reindex()
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        favourites.moveElements(fromOffsets: source, toOffset: destination)
        try reindex(using: favourites)
    }

    public func contains(url: URL) -> Bool {
        favourites.contains { $0.url == url }
    }

    // MARK: - Internals

    /// One past the highest `sortIndex` on disk, including unparseable rows.
    private func nextSortIndex() throws -> Int {
        let records = try context.fetch(FetchDescriptor<FavouriteRecord>())
        return (records.map(\.sortIndex).max() ?? -1) + 1
    }

    private func storeContains(url: URL) throws -> Bool {
        let target = url.absoluteString
        var descriptor = FetchDescriptor<FavouriteRecord>(
            predicate: #Predicate { $0.urlString == target }
        )
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    private func record(for id: UUID) throws -> FavouriteRecord? {
        var descriptor = FetchDescriptor<FavouriteRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Rewrites `sortIndex` so it is always a dense 0..<n sequence.
    ///
    /// Without this, deleting from the middle leaves gaps that a later reorder
    /// would resolve inconsistently.
    private func reindex(using order: [Favourite]? = nil) throws {
        let descriptor = FetchDescriptor<FavouriteRecord>()
        let records = try context.fetch(descriptor)
        let ordering: [UUID: Int]
        if let order {
            ordering = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element.id, $0.offset) })
        } else {
            let sorted = records.sorted { $0.sortIndex < $1.sortIndex }
            ordering = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.id, $0.offset) })
        }
        for record in records {
            record.sortIndex = ordering[record.id] ?? record.sortIndex
        }
        try context.save()
        try reload()
    }
}
