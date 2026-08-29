import Domain
import Foundation
import Observation

/// Drives the Settings screen, and is the one place a preference change is
/// turned into an effect on the running app.
@MainActor
@Observable
public final class SettingsViewModel {
    @ObservationIgnored private let store: any SettingsStoring
    @ObservationIgnored private let onSettingsChanged: (AppSettings) async -> Void
    @ObservationIgnored private let transportAvailability: (BridgeTransport) -> Bool

    /// Free text for the bridge-lines editor.
    public var bridgeText: String = ""
    /// Per-line parse failures, shown under the editor.
    public var bridgeErrors: [String] = []
    public var isEditingBridges = false

    public let appVersion: String
    @ObservationIgnored private let torVersionProvider: () -> String

    /// Read live so the About row reflects the Tor that is actually running.
    public var torVersion: String { torVersionProvider() }

    public init(
        store: any SettingsStoring,
        appVersion: String,
        torVersion: @escaping () -> String,
        transportAvailability: @escaping (BridgeTransport) -> Bool = { _ in false },
        onSettingsChanged: @escaping (AppSettings) async -> Void
    ) {
        self.store = store
        self.appVersion = appVersion
        self.torVersionProvider = torVersion
        self.transportAvailability = transportAvailability
        self.onSettingsChanged = onSettingsChanged
        self.bridgeText = store.settings.bridges.lines.map(\.rawValue).joined(separator: "\n")
    }

    public var settings: AppSettings { store.settings }
    public var needsRelaunchForBridges: Bool { store.needsRelaunchForBridges }

    /// The honesty statement. Non-negotiable, and shown without a disclosure
    /// triangle — a user must not have to go looking for it.
    public let honestyStatement = """
        Shallot hides your IP address and location and reaches .onion sites. \
        Because iOS requires every browser to use Apple's web engine, it cannot \
        fully match desktop Tor Browser's anti-fingerprinting — raise the \
        security level for more protection.
        """

    // MARK: - Mutations

    public func setSecurityLevel(_ level: SecurityLevel) {
        apply { $0.securityLevel = level }
    }

    public func setSearchEngine(_ engine: SearchEngine) {
        apply { $0.searchEngine = engine }
    }

    public func setBridgesEnabled(_ enabled: Bool) {
        apply { $0.bridges.isEnabled = enabled }
    }

    public func setTransport(_ transport: BridgeTransport) {
        apply { $0.bridges.transport = transport }
    }

    public func setHTTPSOnly(_ value: Bool) { apply { $0.httpsOnly = value } }
    public func setBlockWebRTC(_ value: Bool) { apply { $0.blockWebRTC = value } }
    public func setBlockWebAuthn(_ value: Bool) { apply { $0.blockWebAuthn = value } }
    public func setBlockWebTransport(_ value: Bool) { apply { $0.blockWebTransport = value } }
    public func setBlockDNSPrefetch(_ value: Bool) { apply { $0.blockDNSPrefetch = value } }
    public func setIsolateCircuitPerTab(_ value: Bool) { apply { $0.isolateCircuitPerTab = value } }
    public func setClearOnExit(_ value: Bool) { apply { $0.clearOnExit = value } }
    public func setRequireBiometricUnlock(_ value: Bool) { apply { $0.requireBiometricUnlock = value } }
    public func setHideInAppSwitcher(_ value: Bool) { apply { $0.hideInAppSwitcher = value } }

    /// Whether `transport` can actually be used in this build.
    public func isAvailable(_ transport: BridgeTransport) -> Bool {
        transportAvailability(transport)
    }

    public func unavailableReason(for transport: BridgeTransport) -> String {
        "\(transport.title) needs a pluggable-transport binary, which this build does not include. Plain bridges work without one."
    }

    /// Parses the bridge editor and stores whatever was valid.
    public func commitBridgeLines() {
        let result = BridgeLineParser.parseAll(bridgeText)
        bridgeErrors = result.errors.map { "\($0.line) — \($0.error.description)" }
        apply { $0.bridges.lines = result.lines }
        isEditingBridges = false
    }

    /// Removes a per-site exception the user granted earlier.
    public func revokeException(_ exception: SiteException) {
        apply { $0.setException(exception.feature, on: exception.host, enabled: false) }
    }

    public var siteExceptions: [SiteException] {
        settings.siteExceptions.sorted { $0.id < $1.id }
    }

    private func apply(_ mutate: @escaping (inout AppSettings) -> Void) {
        store.update(mutate)
        let updated = store.settings
        Task { await onSettingsChanged(updated) }
    }
}
