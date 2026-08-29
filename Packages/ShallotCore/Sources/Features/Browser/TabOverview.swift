import Domain
import DesignSystem
import SwiftUI

/// The open-tabs list, with each tab's isolated circuit port shown.
///
/// The port is not a debugging detail — it is the visible evidence that this
/// tab has its own circuit, which is one of the app's actual promises.
public struct TabOverview: View {
    @Bindable var model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    public init(model: BrowserViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                ShallotBackdrop(isPaused: true)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.tabs) { tab in
                            row(for: tab)
                        }

                        Button {
                            model.newTab()
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(width: 36, height: 36)
                                Text("New tab")
                                    .font(Typography.rowTitle)
                                Spacer()
                            }
                            .padding(14)
                            .foregroundStyle(Palette.arterialSoft)
                            // Without this the row is only tappable over the
                            // icon and the words: on iOS 26 the glass
                            // background is not hit-testable, so the button's
                            // shape has to be declared before it is applied.
                            .contentShape(Rectangle())
                            .glassPanel(cornerRadius: Metrics.panelRadius)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New tab")
                    }
                    .padding(Metrics.gutter)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(for tab: BrowserTab) -> some View {
        HStack(spacing: 12) {
            Button {
                model.selectTab(tab.id)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tab.title.isEmpty ? (tab.url?.host() ?? "New tab") : tab.title)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.bone)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(tab.url?.host() ?? "Start page")
                            .font(Typography.dataSmall)
                            .foregroundStyle(Palette.ash)
                            .lineLimit(1)
                        if let port = tab.socksPort {
                            Text("· circuit :\(String(port))")
                                .font(Typography.dataSmall)
                                .foregroundStyle(Palette.arterialSoft)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title.isEmpty ? "New tab" : tab.title)
            .accessibilityHint(tab.socksPort.map { "Using its own Tor circuit on port \($0)" } ?? "")

            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ash)
            .accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassPanel(cornerRadius: Metrics.panelRadius)
        .overlay(alignment: .leading) {
            if tab.id == model.session.activeTabID {
                Capsule()
                    .fill(Palette.arterial)
                    .frame(width: 3, height: 26)
                    .padding(.leading, 4)
                    .accessibilityHidden(true)
            }
        }
    }
}
