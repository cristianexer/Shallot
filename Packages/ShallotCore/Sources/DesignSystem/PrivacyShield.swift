import SwiftUI

/// Covers the app's content whenever it is not frontmost.
///
/// iOS takes the app-switcher snapshot while the scene is `.inactive`, so the
/// cover has to be in place before then — which is why the flag driving this is
/// set on `.inactive` rather than `.background`.
public struct PrivacyShield: ViewModifier {
    /// Whether the app is currently obscured.
    public var isObscured: Bool
    /// The user's preference. When off, the shield never appears.
    public var isEnabled: Bool

    public init(isObscured: Bool, isEnabled: Bool) {
        self.isObscured = isObscured
        self.isEnabled = isEnabled
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if isEnabled && isObscured {
                    ZStack {
                        Rectangle()
                            .fill(Palette.void)
                            .ignoresSafeArea()
                        VStack(spacing: 10) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(Palette.arterialSoft)
                            Text("SHALLOT")
                                .font(Typography.screenTitle)
                                .tracking(6)
                                .foregroundStyle(Palette.bone)
                        }
                    }
                    // No transition: a fade would be captured mid-way by the
                    // snapshot and show a ghost of the page underneath.
                    .transition(.identity)
                    .accessibilityHidden(true)
                }
            }
    }
}

/// The lock screen shown until the user authenticates.
public struct LockScreen: View {
    public var biometryName: String
    public var errorMessage: String?
    public var unlock: () async -> Void

    public init(biometryName: String, errorMessage: String?, unlock: @escaping () async -> Void) {
        self.biometryName = biometryName
        self.errorMessage = errorMessage
        self.unlock = unlock
    }

    public var body: some View {
        ZStack {
            ShallotBackdrop(isPaused: true)
            VStack(spacing: 18) {
                Image(systemName: "lock")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Palette.arterialSoft)
                Text("SHALLOT")
                    .font(Typography.wordmark)
                    .tracking(8)
                    .foregroundStyle(Palette.bone)
                Text("Locked")
                    .font(Typography.detail)
                    .foregroundStyle(Palette.ash)

                if let errorMessage {
                    Text(errorMessage)
                        .font(Typography.detail)
                        .foregroundStyle(Palette.arterialSoft)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                TerminalButton("UNLOCK WITH \(biometryName.uppercased())", emphasis: .solid) {
                    Task { await unlock() }
                }
                .frame(maxWidth: 280)
                .padding(.top, 8)
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shallot is locked")
    }
}

extension View {
    /// Applies the app-switcher privacy shield.
    public func privacyShield(isObscured: Bool, isEnabled: Bool) -> some View {
        modifier(PrivacyShield(isObscured: isObscured, isEnabled: isEnabled))
    }
}
