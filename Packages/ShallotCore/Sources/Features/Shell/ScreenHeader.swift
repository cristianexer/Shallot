import DesignSystem
import SwiftUI

/// The heading at the top of Favourites, Monitor and Settings.
///
/// One line of title, and a line of context only where the context is load
/// bearing. The three-line kicker-title-subtitle stack this replaces spent
/// most of a phone's first screenful restating the name of the tab you had
/// just tapped.
public struct ScreenHeader: View {
    var title: String
    var subtitle: String?
    /// Shown as a live dot before the title, for a screen that updates itself.
    var isLive: Bool

    public init(title: String, subtitle: String? = nil, isLive: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.isLive = isLive
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                SidebarToggleButton()
                    .padding(.trailing, -6)
                if isLive {
                    PulseDot(size: 6)
                }
                Text(title)
                    .font(Typography.screenTitle)
                    .tracking(2)
                    .foregroundStyle(Palette.bone)
                    .accessibilityAddTraits(.isHeader)
            }
            if let subtitle {
                Text(subtitle)
                    .font(Typography.detail)
                    .foregroundStyle(Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}
