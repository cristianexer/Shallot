import Domain
import Foundation
import LocalAuthentication
import Observation

/// Gates app entry behind Face ID, Touch ID or the device passcode.
@MainActor
@Observable
public final class AppLockService: AppLocking {
    public private(set) var isLocked: Bool = false
    public private(set) var lastError: String?

    @ObservationIgnored private var context = LAContext()
    @ObservationIgnored private var isAuthenticating = false

    public init() {}

    public var isAvailable: Bool {
        // `.deviceOwnerAuthentication` includes the passcode fallback, so this
        // is true on any device with a passcode set — not just one with
        // biometrics enrolled.
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    public var biometryName: String {
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    public func lock() {
        isLocked = true
        lastError = nil
        // A fresh context each time, or iOS reuses the previous successful
        // evaluation and the prompt never appears.
        context = LAContext()
    }

    public func authenticate() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        self.context = context

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set means the lock cannot be enforced. Staying locked
            // forever would brick the app, so it opens — and Settings says the
            // lock is unavailable.
            lastError = nil
            isLocked = false
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Shallot"
            )
            isLocked = !success
            lastError = success ? nil : "Authentication was not successful."
        } catch let authError as LAError {
            lastError = Self.message(for: authError)
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func message(for error: LAError) -> String? {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:
            // The user chose not to unlock. That is not an error worth shouting
            // about — the lock screen simply stays.
            return nil
        case .userFallback:
            return nil
        case .biometryLockout:
            return "Too many attempts. Use your device passcode to unlock."
        case .biometryNotEnrolled, .biometryNotAvailable:
            return "Biometrics are not set up on this device. Use your passcode."
        case .passcodeNotSet:
            return "Set a device passcode to use the app lock."
        default:
            return error.localizedDescription
        }
    }
}
