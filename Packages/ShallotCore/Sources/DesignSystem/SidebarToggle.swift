import SwiftUI

/// Lets a screen show the split view's sidebar control without knowing that a
/// split view exists.
///
/// `NavigationSplitView` puts its own toggle in a navigation bar, which on the
/// detail side lands *above* our chrome and gives the iPad a second row of bar
/// for a single button — exactly the crowding the one-row omnibar removed. So
/// the shell hides that navigation bar, owns the column visibility itself, and
/// publishes the control here for whichever screen is on show to place inline.
@MainActor
public struct SidebarControl {
    /// Whether the sidebar is currently on screen.
    public var isVisible: Bool
    /// Shows it if it is hidden, hides it if it is not.
    public var toggle: @MainActor () -> Void

    public init(isVisible: Bool, toggle: @escaping @MainActor () -> Void) {
        self.isVisible = isVisible
        self.toggle = toggle
    }
}

public struct SidebarControlKey: EnvironmentKey {
    /// `nil` on a phone, where there is no sidebar and no space to waste on a
    /// control for one.
    public static let defaultValue: SidebarControl? = nil

    // The value is only ever read and written on the main actor — it is a
    // SwiftUI environment value — so the isolation is stated rather than
    // worked around with an unchecked conformance.
    public typealias Value = SidebarControl?
}

extension EnvironmentValues {
    public var sidebarControl: SidebarControl? {
        get { self[SidebarControlKey.self] }
        set { self[SidebarControlKey.self] = newValue }
    }
}

/// The inline sidebar control. Nothing at all where there is no sidebar.
public struct SidebarToggleButton: View {
    @Environment(\.sidebarControl) private var control

    public init() {}

    public var body: some View {
        if let control {
            Button(action: control.toggle) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(control.isVisible ? Palette.arterialSoft : Palette.ash)
            .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
            .accessibilityLabel(control.isVisible ? "Hide Sidebar" : "Show Sidebar")
        }
    }
}
