import Domain
import DesignSystem
import SwiftUI

/// The floating bottom bar: the four controls you reach for while reading.
///
/// This used to be a four-way section switcher, which meant the controls a
/// browser needs constantly — back, forward, saving the page — were either
/// crowded into the top row or two taps away. Favourites, the Monitor and
/// Settings are destinations you visit occasionally, so they moved into the
/// overflow menu and the bar went to the browsing controls instead.
public struct BrowserToolbar: View {
    @Bindable var model: BrowserViewModel
    var onShowTabs: () -> Void

    public init(model: BrowserViewModel, onShowTabs: @escaping () -> Void) {
        self.model = model
        self.onShowTabs = onShowTabs
    }

    public var body: some View {
        HStack(spacing: 0) {
            control("chevron.left", label: "Back", enabled: model.canGoBack) {
                model.goBack()
            }
            control("chevron.right", label: "Forward", enabled: model.canGoForward) {
                model.goForward()
            }
            control(
                model.isActivePageSaved ? "bookmark.fill" : "bookmark",
                label: model.isActivePageSaved ? "Remove from favourites" : "Save to favourites",
                enabled: model.activeTab?.url != nil,
                accent: model.isActivePageSaved
            ) {
                model.toggleFavourite()
            }
            tabsControl
        }
        .padding(4)
        .glassPanel(cornerRadius: Metrics.barRadius, density: .bar)
        .padding(.horizontal, 16)
    }

    private var tabsControl: some View {
        Button(action: onShowTabs) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(lineWidth: 1.6)
                    .frame(width: 19, height: 19)
                Text("\(model.tabs.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ash)
        .accessibilityLabel("Tabs")
        .accessibilityValue("\(model.tabs.count) open")
    }

    private func control(
        _ symbol: String,
        label: String,
        enabled: Bool = true,
        accent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .frame(maxWidth: .infinity, minHeight: Metrics.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent ? Palette.arterialSoft : Palette.ash)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }
}
