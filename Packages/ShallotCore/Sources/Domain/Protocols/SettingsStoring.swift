import Foundation

/// Persisted user preferences.
@MainActor
public protocol SettingsStoring: AnyObject {
    var settings: AppSettings { get }

    /// Applies a mutation and persists it immediately.
    func update(_ mutate: (inout AppSettings) -> Void)

    /// Reloads from disk, discarding anything in memory.
    func reload()

    /// Bridge changes only take effect at the next launch, because the embedded
    /// Tor cannot be reconfigured in-process. `true` once a change is pending.
    var needsRelaunchForBridges: Bool { get }
    func markBridgesApplied()

}
