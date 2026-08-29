import DesignSystem
import SwiftUI

/// The floating, icon-only tab bar from the prototype.
///
/// Icon-only chrome means the VoiceOver labels are not a nicety — they are the
/// only thing that names these controls, so every one carries a label and a
/// hint, and each meets the 44pt touch minimum.
public struct AppTabBar: View {
    @Binding var selection: AppSection

    public init(selection: Binding<AppSection>) {
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(AppSection.allCases) { section in
                Button {
                    withAnimation(.spring(duration: 0.25)) { selection = section }
                } label: {
                    Image(systemName: section.symbol)
                        .font(.system(size: 18, weight: .regular))
                        .frame(maxWidth: .infinity, minHeight: Metrics.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == section ? Palette.arterialSoft : Palette.ash)
                .shadow(
                    color: selection == section ? Palette.glow : .clear,
                    radius: selection == section ? 8 : 0
                )
                .accessibilityLabel(section.title)
                .accessibilityHint(section.accessibilityHint)
                .accessibilityAddTraits(selection == section ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .glassPanel(cornerRadius: Metrics.barRadius, density: .bar)
        .padding(.horizontal, 16)
    }
}
