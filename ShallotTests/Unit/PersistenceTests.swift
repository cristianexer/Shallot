import Foundation
import SwiftData
import Testing

@testable import Domain
@testable import Persistence

@MainActor
@Suite("Favourites on SwiftData")
struct SwiftDataFavouritesRepositoryTests {
    static let securedrop = URL(string: "http://sdolvtfhatvsysc6l34d65ymdwxcujausv7k5jk4cy5ttzhjoi6fzvyd.onion")!
    static let propublica = URL(string: "http://p53lf57qovyuvwsc6xnrppyply3vtqm7l6pcobkmyqsiofyeznfu5uqd.onion")!
    static let duckDuckGo = URL(string: "https://duckduckgo.com")!
    static let bbc = URL(string: "https://www.bbc.co.uk/news")!

    /// Four saved sites in a known order, on a container the caller owns.
    private func seeded(_ container: ModelContainer) throws -> SwiftDataFavouritesRepository {
        let repository = SwiftDataFavouritesRepository(container: container)
        try repository.add(title: "SecureDrop", url: Self.securedrop)
        try repository.add(title: "ProPublica", url: Self.propublica)
        try repository.add(title: "DuckDuckGo", url: Self.duckDuckGo)
        try repository.add(title: "BBC News", url: Self.bbc)
        return repository
    }

    @Test("A newly added site is visible immediately and survives a reload")
    func addThenReload() throws {
        let container = try ShallotModelContainer.inMemory()
        let repository = SwiftDataFavouritesRepository(container: container)
        #expect(repository.favourites.isEmpty)

        try repository.add(title: "SecureDrop", url: Self.securedrop)
        #expect(repository.favourites.count == 1)
        #expect(repository.favourites[0].title == "SecureDrop")
        #expect(repository.favourites[0].url == Self.securedrop)
        #expect(repository.favourites[0].sortIndex == 0)

        try repository.reload()
        #expect(repository.favourites.count == 1)
        #expect(repository.favourites[0].url == Self.securedrop)
    }

    @Test("Saving the same URL twice leaves one entry")
    func duplicateURLIsIgnored() throws {
        let container = try ShallotModelContainer.inMemory()
        let repository = SwiftDataFavouritesRepository(container: container)
        try repository.add(title: "SecureDrop", url: Self.securedrop)
        try repository.add(title: "SecureDrop again", url: Self.securedrop)

        #expect(repository.favourites.count == 1)
        #expect(repository.favourites[0].title == "SecureDrop")
    }

    @Test("A blank title falls back to the host rather than saving a nameless tile")
    func emptyTitleFallsBackToHost() throws {
        let container = try ShallotModelContainer.inMemory()
        let repository = SwiftDataFavouritesRepository(container: container)
        try repository.add(title: "   \n ", url: URL(string: "https://www.bbc.co.uk/news")!)

        #expect(repository.favourites[0].title == "www.bbc.co.uk")
    }

    @Test("An edited favourite keeps its identity and shows the new title")
    func updateRewritesTheRow() throws {
        let container = try ShallotModelContainer.inMemory()
        let repository = SwiftDataFavouritesRepository(container: container)
        try repository.add(title: "SecureDrop", url: Self.securedrop)

        var edited = try #require(repository.favourites.first)
        edited.title = "Tip line"
        try repository.update(edited)

        #expect(repository.favourites.count == 1)
        #expect(repository.favourites[0].id == edited.id)
        #expect(repository.favourites[0].title == "Tip line")
    }

    @Test("Editing a favourite that is no longer saved changes nothing")
    func updateOfUnknownFavouriteIsIgnored() throws {
        let container = try ShallotModelContainer.inMemory()
        let repository = SwiftDataFavouritesRepository(container: container)
        try repository.add(title: "SecureDrop", url: Self.securedrop)

        try repository.update(Favourite(title: "Ghost", url: Self.bbc, sortIndex: 0))

        #expect(repository.favourites.count == 1)
        #expect(repository.favourites[0].title == "SecureDrop")
    }

    @Test("Deleting removes the row and forgets the URL")
    func deleteRemovesTheRow() throws {
        let container = try ShallotModelContainer.inMemory()
        let repository = SwiftDataFavouritesRepository(container: container)
        try repository.add(title: "SecureDrop", url: Self.securedrop)
        let saved = try #require(repository.favourites.first)

        try repository.delete(id: saved.id)

        #expect(repository.favourites.isEmpty)
        #expect(!repository.contains(url: Self.securedrop))
    }

    @Test("Deleting from the middle renumbers the rest into a dense sequence")
    func deletingFromTheMiddleReindexes() throws {
        let container = try ShallotModelContainer.inMemory()
        let repository = try seeded(container)
        #expect(repository.favourites.map(\.sortIndex) == [0, 1, 2, 3])

        try repository.delete(id: repository.favourites[1].id)

        // A gap here would make the next drag-to-reorder resolve inconsistently.
        #expect(repository.favourites.map(\.sortIndex) == [0, 1, 2])
        #expect(repository.favourites.map(\.title) == ["SecureDrop", "DuckDuckGo", "BBC News"])
    }

    @Test("contains(url:) answers for saved sites only")
    func containsTracksWhatIsSaved() throws {
        let container = try ShallotModelContainer.inMemory()
        let repository = SwiftDataFavouritesRepository(container: container)
        #expect(!repository.contains(url: Self.securedrop))

        try repository.add(title: "SecureDrop", url: Self.securedrop)

        #expect(repository.contains(url: Self.securedrop))
        #expect(!repository.contains(url: Self.bbc))
    }

    @Test("Dragging a site to the top reorders the list and renumbers it")
    func moveReordersAndReindexes() throws {
        let container = try ShallotModelContainer.inMemory()
        let repository = try seeded(container)

        try repository.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)

        #expect(repository.favourites.map(\.title) == ["BBC News", "SecureDrop", "ProPublica", "DuckDuckGo"])
        #expect(repository.favourites.map(\.sortIndex) == [0, 1, 2, 3])
    }

    @Test("A reorder is written to the store, not only to the in-memory list")
    func moveIsPersisted() throws {
        let container = try ShallotModelContainer.inMemory()
        let repository = try seeded(container)
        try repository.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)

        let reopened = SwiftDataFavouritesRepository(container: container)

        #expect(reopened.favourites.map(\.title) == ["ProPublica", "DuckDuckGo", "BBC News", "SecureDrop"])
        #expect(reopened.favourites.map(\.sortIndex) == [0, 1, 2, 3])
    }

    @Test("A second repository on the same store sees everything the first saved")
    func aSecondRepositorySeesSavedData() throws {
        let container = try ShallotModelContainer.inMemory()
        let repository = try seeded(container)
        try repository.delete(id: repository.favourites[0].id)

        let reopened = SwiftDataFavouritesRepository(container: container)

        #expect(reopened.favourites.map(\.title) == ["ProPublica", "DuckDuckGo", "BBC News"])
        #expect(reopened.contains(url: Self.propublica))
        #expect(!reopened.contains(url: Self.securedrop))
    }

    @Test("One corrupt row hides itself instead of taking the whole list down")
    func corruptRowIsSkipped() throws {
        let container = try ShallotModelContainer.inMemory()
        // Written straight to the store: no public API can produce this row, but
        // a schema change or a hand-edited store can leave one behind.
        let context = ModelContext(container)
        context.insert(FavouriteRecord(title: "Corrupt", urlString: "", sortIndex: 0))
        context.insert(FavouriteRecord(title: "ProPublica", urlString: Self.propublica.absoluteString, sortIndex: 1))
        try context.save()

        let repository = SwiftDataFavouritesRepository(container: container)

        #expect(repository.favourites.count == 1)
        #expect(repository.favourites[0].title == "ProPublica")
    }
}

@MainActor
@Suite("Settings on SwiftData")
struct SwiftDataSettingsStoreTests {
    static let snowflakeBridges = BridgeConfig(isEnabled: true, transport: .snowflake, lines: [])

    @Test("A first launch starts on the defaults with nothing pending")
    func firstLaunchDefaults() throws {
        let container = try ShallotModelContainer.inMemory()
        let store = SwiftDataSettingsStore(container: container)

        #expect(store.settings == .default)
        #expect(!store.needsRelaunchForBridges)
    }

    @Test("A changed preference is written out and read back by a fresh store")
    func updatePersists() throws {
        let container = try ShallotModelContainer.inMemory()
        let store = SwiftDataSettingsStore(container: container)
        store.update {
            $0.securityLevel = .safest
            $0.httpsOnly = false
            $0.searchEngine = .startpage
            $0.setException(.javaScript, on: "app.example", enabled: true)
        }

        let reopened = SwiftDataSettingsStore(container: container)

        #expect(reopened.settings.securityLevel == .safest)
        #expect(!reopened.settings.httpsOnly)
        #expect(reopened.settings.searchEngine == .startpage)
        #expect(reopened.settings.allows(.javaScript, on: "app.example"))
        #expect(reopened.settings == store.settings)
    }

    @Test("reload() discards an unsaved in-memory value in favour of the store")
    func reloadReadsFromTheStore() throws {
        let container = try ShallotModelContainer.inMemory()
        let store = SwiftDataSettingsStore(container: container)
        store.update { $0.securityLevel = .standard }

        store.reload()

        #expect(store.settings.securityLevel == .standard)
    }

    @Test("Turning bridges on flags a pending relaunch, and applying them clears it")
    func bridgeChangesFlagARelaunch() throws {
        let container = try ShallotModelContainer.inMemory()
        let store = SwiftDataSettingsStore(container: container)
        #expect(!store.needsRelaunchForBridges)

        store.update { $0.bridges = Self.snowflakeBridges }
        // The embedded Tor reads bridges at start-up only, so the flag is the
        // only thing telling the user their new setting is not live yet.
        #expect(store.needsRelaunchForBridges)

        store.markBridgesApplied()
        #expect(!store.needsRelaunchForBridges)
    }

    @Test("A preference that is not a bridge never asks for a relaunch")
    func nonBridgeChangeDoesNotFlagARelaunch() throws {
        let container = try ShallotModelContainer.inMemory()
        let store = SwiftDataSettingsStore(container: container)

        store.update { $0.securityLevel = .safest }

        #expect(!store.needsRelaunchForBridges)
    }

    @Test("A pending bridge change is still pending after the store is reopened")
    func pendingRelaunchSurvivesReopening() throws {
        let container = try ShallotModelContainer.inMemory()
        let store = SwiftDataSettingsStore(container: container)
        store.update { $0.bridges = Self.snowflakeBridges }

        let reopened = SwiftDataSettingsStore(container: container)

        #expect(reopened.settings.bridges == Self.snowflakeBridges)
        #expect(reopened.needsRelaunchForBridges)
    }

    @Test("Once bridges are applied a reopened store reports nothing pending")
    func appliedBridgesSurviveReopening() throws {
        let container = try ShallotModelContainer.inMemory()
        let store = SwiftDataSettingsStore(container: container)
        store.update { $0.bridges = Self.snowflakeBridges }
        store.markBridgesApplied()

        let reopened = SwiftDataSettingsStore(container: container)

        #expect(reopened.settings.bridges == Self.snowflakeBridges)
        #expect(!reopened.needsRelaunchForBridges)
    }
}

@Suite("Stored records")
struct RecordTests {
    @Test("A row whose URL no longer parses yields no favourite")
    func unparseableURLYieldsNil() {
        let record = FavouriteRecord(title: "Corrupt", urlString: "", sortIndex: 0)
        #expect(record.favourite == nil)
    }

    @Test("A well-formed row round-trips through the domain value")
    func recordRoundTrip() throws {
        let original = Favourite(
            title: "ProPublica",
            url: URL(string: "http://p53lf57qovyuvwsc6xnrppyply3vtqm7l6pcobkmyqsiofyeznfu5uqd.onion")!,
            sortIndex: 4
        )
        let record = FavouriteRecord(original)
        let restored = try #require(record.favourite)

        #expect(restored == original)
    }

    @Test("apply(_:) rewrites the stored fields in place")
    func applyRewritesFields() throws {
        let record = FavouriteRecord(title: "Old", urlString: "https://old.example", sortIndex: 9)
        let replacement = Favourite(
            id: record.id,
            title: "New",
            url: URL(string: "https://new.example")!,
            sortIndex: 2
        )
        record.apply(replacement)

        #expect(record.title == "New")
        #expect(record.urlString == "https://new.example")
        #expect(record.sortIndex == 2)
    }

    @Test("Settings that cannot be decoded fall back to the private defaults")
    func undecodableSettingsFallBack() {
        // Every default is the private choice, so falling back is safe where
        // failing — and leaving the user with no settings at all — is not.
        let record = SettingsRecord(payload: Data("not settings".utf8))
        #expect(record.decoded() == .default)
    }

    @Test("Settings written by this build decode back unchanged")
    func decodableSettingsRoundTrip() throws {
        var settings = AppSettings.default
        settings.securityLevel = .safest
        settings.hideInAppSwitcher = false
        let record = SettingsRecord(payload: try JSONEncoder().encode(settings))

        #expect(record.decoded() == settings)
    }

    @Test("Applied bridges are absent until something has been applied")
    func appliedBridgesDecoding() throws {
        let payload = try JSONEncoder().encode(AppSettings.default)
        #expect(SettingsRecord(payload: payload).decodedAppliedBridges() == nil)

        let bridges = BridgeConfig(isEnabled: true, transport: .snowflake, lines: [])
        let record = SettingsRecord(
            payload: payload,
            appliedBridgePayload: try JSONEncoder().encode(bridges)
        )
        #expect(record.decodedAppliedBridges() == bridges)

        let corrupt = SettingsRecord(payload: payload, appliedBridgePayload: Data("nonsense".utf8))
        #expect(corrupt.decodedAppliedBridges() == nil)
    }
}
