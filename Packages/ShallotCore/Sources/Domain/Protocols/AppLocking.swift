import Foundation

/// Face ID / Touch ID / passcode gate on app entry.
@MainActor
public protocol AppLocking: AnyObject {
    /// True while the app contents must stay hidden behind the lock screen.
    var isLocked: Bool { get }

    /// Whether this device can actually perform biometric or passcode auth.
    var isAvailable: Bool { get }

    /// Human name for the enrolled biometry, e.g. "Face ID".
    var biometryName: String { get }

    /// Locks the app. Called at launch when the setting is on.
    func lock()

    /// Presents the authentication prompt and unlocks on success.
    func authenticate() async

    /// The last authentication failure, for the retry screen.
    var lastError: String? { get }
}
