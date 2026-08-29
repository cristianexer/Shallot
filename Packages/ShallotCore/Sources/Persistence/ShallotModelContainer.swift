import Domain
import Foundation
import SwiftData

/// Builds the SwiftData container, encrypted at rest and never synced.
public enum ShallotModelContainer {
    public static let schema = Schema([FavouriteRecord.self, SettingsRecord.self])

    public enum StoreError: Error, CustomStringConvertible {
        case unavailable(String)

        public var description: String {
            switch self {
            case .unavailable(let reason): "Shallot could not open its local store: \(reason)"
            }
        }
    }

    /// The on-disk container.
    ///
    /// - Note: `cloudKitDatabase: .none` is not a default we are relying on —
    ///   it is stated explicitly, because a bookmark list that syncs is a
    ///   bookmark list that links this device to an Apple ID.
    public static func make(url: URL? = nil) throws -> ModelContainer {
        let storeURL = url ?? defaultStoreURL()
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            throw StoreError.unavailable(String(describing: error))
        }
        applyFileProtection(at: storeURL)
        return container
    }

    /// An in-memory container for previews and tests.
    public static func inMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// The store lives in its own directory so the protection class can be set
    /// on the *directory*.
    ///
    /// SQLite creates `-wal` and `-shm` on the first write, which is after the
    /// container is built — protecting only the files that exist at that moment
    /// would leave recently-saved favourites in an unprotected write-ahead log.
    /// Files inherit the protection class of the directory they are created in,
    /// so this covers the sidecars before they exist.
    static func defaultStoreURL() -> URL {
        let directory = URL.applicationSupportDirectory.appending(
            path: "Store",
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )
        return directory.appending(path: "Shallot.store")
    }

    /// Marks the store files as unreadable while the device is locked.
    ///
    /// SwiftData has no API for this, so the protection class is applied to the
    /// store and its sidecar files directly. Shallot only ever writes here in
    /// response to a foreground tap, so `.complete` costs nothing and means a
    /// seized, locked device yields nothing — not even the list of onion
    /// services someone thought worth saving.
    public static func applyFileProtection(at storeURL: URL) {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        // The directory is the durable part — anything SQLite creates inside it
        // later inherits this. The explicit per-file pass covers a store that
        // was created before this code existed.
        try? manager.setAttributes(attributes, ofItemAtPath: storeURL.deletingLastPathComponent().path)
        for suffix in ["", "-wal", "-shm"] {
            let path = storeURL.path + suffix
            guard manager.fileExists(atPath: path) else { continue }
            try? manager.setAttributes(attributes, ofItemAtPath: path)
        }
    }
}
