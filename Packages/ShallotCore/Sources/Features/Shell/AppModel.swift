import BrowserEngine
import Domain
import DesignSystem
import Foundation
import Observation
import SwiftUI

/// The coordinator: owns the four screens' view models and the app-wide state
/// they share.
///
/// This is where the launch sequence lives, and where a Tor state change is
/// turned into an effect on the browser engine's kill switch.
@MainActor
@Observable
public final class AppModel {
    public let browser: BrowserViewModel
    public let favourites: FavouritesViewModel
    public let monitor: MonitorViewModel
    public let settings: SettingsViewModel
    public let lock: any AppLocking

    public var section: AppSection = .browser
    public var torState: TorRuntimeState = .off
    public var toast: ToastMessage?

    /// Reported by Tor once it is running; blank until then.
    public var torVersion: String = "—"

    /// False once a start attempt has failed and only a relaunch can help.
    ///
    /// The embedded Tor cannot be launched twice in one process, so the
    /// connection screen must stop offering a retry rather than show a button
    /// that is guaranteed not to work.
    public private(set) var canRetryConnection = true

    /// True while the app is not frontmost. Freezes the rain canvas and, when
    /// the setting is on, hides the content from the app switcher.
    public var isObscured = false

    /// A relaunch is needed for a bridge change to take effect.
    public var showsRelaunchNotice: Bool { settings.needsRelaunchForBridges }

    @ObservationIgnored private let tor: any TorServicing
    @ObservationIgnored private let engine: BrowserEngine
    @ObservationIgnored private let feed: any MonitorFeeding
    @ObservationIgnored private let settingsStore: any SettingsStoring
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private let versionBox: VersionBox

    public init(
        tor: any TorServicing,
        engine: BrowserEngine,
        session: any BrowsingSessioning,
        favouritesRepository: any FavouritesRepository,
        settingsStore: any SettingsStoring,
        monitorFeed: any MonitorFeeding,
        lock: any AppLocking,
        appVersion: String,
        transportAvailability: @escaping (BridgeTransport) -> Bool = { !$0.requiresTransportProvider }
    ) {
        self.tor = tor
        self.engine = engine
        self.feed = monitorFeed
        self.settingsStore = settingsStore
        self.lock = lock

        // The About row needs a value that is not known until Tor answers, and
        // the view models are built before that happens. A tiny observable box
        // bridges the two without any of them reaching back into this type.
        let versionBox = VersionBox()
        self.versionBox = versionBox

        let browser = BrowserViewModel(
            session: session,
            tor: tor,
            engine: engine,
            settingsStore: settingsStore,
            monitor: monitorFeed,
            favourites: favouritesRepository
        )
        self.browser = browser

        // Each view model is handed exactly the capability it needs, as a
        // closure over an already-built collaborator. No view model reaches
        // back into this coordinator, so none of them can reach each other.
        self.favourites = FavouritesViewModel(
            repository: favouritesRepository,
            open: { url in browser.open(url: url) }
        )

        self.monitor = MonitorViewModel(
            feed: monitorFeed,
            onNewIdentity: { await browser.newIdentity() }
        )

        self.settings = SettingsViewModel(
            store: settingsStore,
            appVersion: appVersion,
            torVersion: { [weak versionBox] in versionBox?.value ?? "—" },
            transportAvailability: transportAvailability,
            onSettingsChanged: { [engine] updated in
                engine.settings = updated
                await engine.prepareRuleLists()
            }
        )

        engine.settings = settingsStore.settings
        engine.monitor = monitorFeed
    }

    deinit {
        for task in tasks { task.cancel() }
    }

    // MARK: - Launch

    /// The launch sequence: lock, then Tor, then the first tab.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        if settingsStore.settings.requireBiometricUnlock, lock.isAvailable {
            lock.lock()
        }

        feed.start()
        observeTorState()

        await engine.prepareRuleLists()

        do {
            try await tor.start()
            if let version = await tor.version() {
                versionBox.value = version
                torVersion = version
            }
        } catch {
            torState = .failed(reason: describe(error))
            canRetryConnection = await tor.canRetryStart
            feed.record(SecurityEvent(kind: .failure, message: "tor failed to start"))
        }
    }

    /// Retries a failed bootstrap.
    public func retryConnection() async {
        guard canRetryConnection else { return }
        torState = .starting(progress: 0)
        do {
            try await tor.start()
        } catch {
            torState = .failed(reason: describe(error))
            canRetryConnection = await tor.canRetryStart
        }
    }

    /// A failure reason worth showing someone, rather than a Swift dump.
    private func describe(_ error: any Error) -> String {
        (error as? any CustomStringConvertible)?.description ?? error.localizedDescription
    }

    private func observeTorState() {
        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await state in await self.tor.stateUpdates() {
                self.apply(state)
            }
        })
    }

    private func apply(_ state: TorRuntimeState) {
        let wasCarrying = torState.canCarryTraffic
        torState = state
        // The kill switch. The engine refuses every load while this is false.
        engine.canCarryTraffic = state.canCarryTraffic
        guard state.canCarryTraffic, !wasCarrying else { return }
        Task { await browser.torBecameReady() }
    }

    // MARK: - Scene

    /// Reacts to the app moving between foreground and background.
    public func handle(scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            isObscured = false
            if lock.isLocked {
                Task { await lock.authenticate() }
            }
        case .inactive:
            // `.inactive` is when the app-switcher snapshot is taken, so the
            // shield has to be up before the phase reaches `.background`.
            isObscured = true
        case .background:
            isObscured = true
            if settingsStore.settings.requireBiometricUnlock, lock.isAvailable {
                lock.lock()
            }
        @unknown default:
            isObscured = true
        }
    }

    /// Wipes everything the session held. Called on clear-on-exit.
    public func clearSession() async {
        await engine.destroyAllSessions()
    }

    /// Sheds background tabs under memory pressure, keeping Tor up.
    public func handleMemoryWarning() async {
        await browser.shedMemory()
    }

    // MARK: - Actions shared across screens

    public func show(_ section: AppSection) {
        self.section = section
    }

    public func newIdentity() async {
        await browser.newIdentity()
        section = .browser
        toast = ToastMessage("New identity · session cleared")
    }

    public func post(_ text: String) {
        toast = ToastMessage(text)
    }
}


/// Holds the Tor version once it is known.
///
/// `@Observable` so the About row updates the moment Tor reports it, without
/// `SettingsViewModel` needing a reference to anything that owns Tor.
@MainActor
@Observable
final class VersionBox {
    var value: String = "—"
}
