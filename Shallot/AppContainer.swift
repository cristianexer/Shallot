import AppLock
import BrowserEngine
import Domain
import Features
import Foundation
import Monitoring
import Persistence
import SwiftData
import TorKit

/// The composition root.
///
/// Every concrete service is built exactly once, here, and handed to the layer
/// above as the protocol it implements. Nothing else in the app knows which
/// Tor library, which storage engine or which authentication framework is in
/// use — which is what makes any of them replaceable, and what lets every
/// screen be driven by a test double.
@MainActor
final class AppContainer {
    let tor: any TorServicing
    let session: BrowsingSession
    let favourites: SwiftDataFavouritesRepository
    let settings: SwiftDataSettingsStore
    let monitor: MonitorService
    let lock: AppLockService
    let engine: BrowserEngine
    let model: AppModel

    /// A description of why persistent storage is unavailable, when it is.
    ///
    /// Favourites and settings fall back to memory rather than the app
    /// refusing to launch: being unable to save a bookmark is a much smaller
    /// problem than being unable to browse.
    let storageWarning: String?

    /// True when the app is running as a test host rather than for a person.
    ///
    /// Tests drive the interface and the logic, not the network: with this on
    /// the app uses an in-memory store and a scripted Tor, so suites are
    /// hermetic, fast, and do not depend on a live Tor network being reachable
    /// from CI. It covers both cases:
    ///
    /// * unit tests, which load into this process and would otherwise have a
    ///   real Tor bootstrapping underneath them;
    /// * UI tests, which pass the launch argument.
    static var isTestHost: Bool {
        if ProcessInfo.processInfo.arguments.contains("--shallot-ui-testing") { return true }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        let container: ModelContainer
        var warning: String?
        do {
            container = Self.isTestHost
                ? try ShallotModelContainer.inMemory()
                : try ShallotModelContainer.make()
        } catch {
            warning = "Favourites and settings could not be opened and will not be saved this session."
            // `inMemory()` builds from the same schema and cannot realistically
            // fail; if it somehow does, there is no app to run.
            container = try! ShallotModelContainer.inMemory()
        }
        self.storageWarning = warning

        let settings = SwiftDataSettingsStore(container: container)
        let favourites = SwiftDataFavouritesRepository(container: container)

        let tor: any TorServicing = Self.isTestHost
            ? MockTorService(behaviour: .immediate)
            : TorService(
                configuration: Self.liveTorConfiguration(bridges: settings.settings.bridges)
            )

        let monitor = MonitorService(tor: tor)
        let engine = BrowserEngine(settings: settings.settings, monitor: monitor)
        let session = BrowsingSession()
        let lock = AppLockService()

        self.tor = tor
        self.settings = settings
        self.favourites = favourites
        self.monitor = monitor
        self.engine = engine
        self.session = session
        self.lock = lock

        self.model = AppModel(
            tor: tor,
            engine: engine,
            session: session,
            favouritesRepository: favourites,
            settingsStore: settings,
            monitorFeed: monitor,
            lock: lock,
            appVersion: Self.appVersion,
            transportAvailability: { transport in
                TransportAvailability.isAvailable(transport, provider: nil)
            }
        )

        if let warning {
            monitor.record(SecurityEvent(kind: .failure, message: warning))
        }

        seedFirstRunFavourites()
    }

    /// Offers a starting set of favourites, once.
    ///
    /// Guarded by a persisted flag rather than by "the list is empty", so a user
    /// who clears their favourites does not find them back at the next launch.
    private func seedFirstRunFavourites() {
        guard !settings.hasSeededDefaults else { return }
        settings.markDefaultsSeeded()
        guard favourites.favourites.isEmpty else { return }
        for favourite in Favourite.firstRunDefaults {
            try? favourites.add(title: favourite.title, url: favourite.url)
        }
    }

    private static func liveTorConfiguration(bridges: BridgeConfig) -> TorService.Configuration {
        TorService.Configuration(
            geoIPFile: Bundle.main.url(forResource: "geoip", withExtension: nil),
            geoIPv6File: Bundle.main.url(forResource: "geoip6", withExtension: nil),
            cacheDirectory: torCacheDirectory(),
            isolationPoolSize: 8,
            bridges: bridges,
            // Register a `PluggableTransportProviding` here to enable obfs4 and
            // Snowflake. Without one, plain bridges work and the obfuscating
            // transports are shown as unavailable in Settings rather than
            // offered and then failing to connect.
            transportProvider: nil
        )
    }

    /// Tor's consensus cache. Persistent on purpose — it turns a 40-second cold
    /// bootstrap into a 5–10 second warm one — and it holds no browsing data,
    /// only the public directory every Tor client downloads.
    static func torCacheDirectory() -> URL {
        let url = URL.cachesDirectory.appending(path: "TorConsensus", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}
