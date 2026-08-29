import SwiftUI

/// A transient message shown above the tab bar.
public struct ToastMessage: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool { lhs.id == rhs.id }
}

/// Presents `message` as a floating capsule, dismissing itself after a moment.
public struct ToastOverlay: ViewModifier {
    @Binding var message: ToastMessage?
    var bottomInset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message.text)
                    .font(Typography.data)
                    .foregroundStyle(Palette.bone)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassCapsule()
                    .padding(.bottom, bottomInset)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                    // The toast narrates itself but must never steal focus from
                    // whatever the user just did.
                    .accessibilityAddTraits(.isStaticText)
                    .task(id: message.id) {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation(.easeOut(duration: 0.25)) { self.message = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.32), value: message)
    }
}

extension View {
    /// Shows a toast above the bottom chrome.
    public func toast(_ message: Binding<ToastMessage?>, bottomInset: CGFloat = 104) -> some View {
        modifier(ToastOverlay(message: message, bottomInset: bottomInset))
    }
}
