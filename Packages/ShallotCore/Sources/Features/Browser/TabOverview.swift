import Domain
import DesignSystem
import SwiftUI
import UIKit

/// The open tabs, as a grid of page cards.
///
/// Every card shows the tab's isolated circuit port. The port is not a
/// debugging detail — it is the visible evidence that this tab has its own
/// circuit, which is one of the app's actual promises, so it survives the move
/// from a list row to a card rather than being dropped for tidiness.
public struct TabOverview: View {
    @Bindable var model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    // Cards widen with the type they hold, so a long page title at a large
    // text size reflows the grid rather than being truncated to "Secur…".
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 152

    public init(model: BrowserViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                ShallotBackdrop(isPaused: true)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Metrics.tightGutter) {
                        ForEach(model.tabs) { tab in
                            card(for: tab)
                        }
                        newTabCard
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
            // The snapshots come from the live web views, which are still
            // mounted behind the sheet. Taking them here rather than on every
            // page load means the cost is only paid by someone who looks.
            .task { await model.captureTabThumbnails() }
        }
    }

    // MARK: - Layout

    private var columns: [GridItem] {
        // Two across on a phone, more on an iPad, and one at accessibility
        // sizes — the clamp is what lets the grid collapse instead of growing
        // a column minimum no screen can satisfy.
        let minimum = min(cardWidth, 190) * (sizeClass == .regular ? 1.3 : 1)
        return [GridItem(.adaptive(minimum: minimum), spacing: Metrics.tightGutter)]
    }

    /// Portrait previews normally, landscape once the grid is down to one
    /// column: a 3:4 card the full width of a phone is taller than the screen,
    /// and scrolling a single tab is not an overview.
    private var previewAspect: CGFloat {
        typeSize.isAccessibilitySize ? 4.0 / 3.0 : 3.0 / 4.0
    }

    // MARK: - Cards

    private func card(for tab: BrowserTab) -> some View {
        let isActive = tab.id == model.session.activeTabID
        return ZStack(alignment: .topTrailing) {
            Button {
                model.selectTab(tab.id)
                dismiss()
            } label: {
                VStack(spacing: 0) {
                    TabPreview(tab: tab, aspectRatio: previewAspect)
                    footer(for: tab)
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
                .contentShape(Rectangle())
                .glassPanel(cornerRadius: Metrics.panelRadius)
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                            .strokeBorder(Palette.arterial, lineWidth: 2)
                            .shadow(color: Palette.glow, radius: 10)
                    }
                }
            }
            .buttonStyle(TileButtonStyle())
            .accessibilityLabel(title(for: tab))
            .accessibilityValue(isActive ? "Current tab" : "Background tab")
            .accessibilityHint(switchHint(for: tab))

            closeButton(for: tab)
        }
    }

    private func footer(for tab: BrowserTab) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title(for: tab))
                .font(Typography.body)
                .foregroundStyle(Palette.bone)
                .lineLimit(1)
            Text(subtitle(for: tab))
                .font(Typography.dataSmall)
                .foregroundStyle(Palette.ash)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func closeButton(for tab: BrowserTab) -> some View {
        Button {
            model.closeTab(tab.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.bone)
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(Palette.void.opacity(0.72))
                        .overlay { Circle().strokeBorder(Palette.edgeRed, lineWidth: 1) }
                }
                // The glyph is 28pt so it does not eat the thumbnail, but the
                // target around it is the full minimum: a 28pt hit region is
                // an accessibility audit failure, not a style choice.
                .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close tab")
    }

    private var newTabCard: some View {
        Button {
            model.newTab()
            dismiss()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 46, height: 46)
                    .background {
                        Circle().strokeBorder(Palette.edgeRed, lineWidth: 1)
                    }
                Text("New tab")
                    .font(Typography.control)
                    .tracking(1.6)
                    .textCase(.uppercase)
            }
            .foregroundStyle(Palette.arterialSoft)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 34)
            // Without this the card is only tappable over the glyph and the
            // words: on iOS 26 the glass background is not hit-testable, so the
            // button's shape has to be declared before it is applied.
            .contentShape(Rectangle())
            .glassPanel(cornerRadius: Metrics.panelRadius)
        }
        .buttonStyle(TileButtonStyle())
        .accessibilityLabel("New tab")
        .accessibilityHint("Opens a tab on its own Tor circuit")
    }

    // MARK: - Wording

    /// A tab with nothing loaded is named for what it is showing. Calling it
    /// "New tab" would give it the same name as the button beside it.
    private func title(for tab: BrowserTab) -> String {
        if !tab.title.isEmpty { return tab.title }
        return tab.url?.host() ?? "Start page"
    }

    /// The second line never repeats the first: an empty tab is titled for the
    /// page it is showing, so its subtitle says what it is waiting for instead.
    private func subtitle(for tab: BrowserTab) -> String {
        guard let host = tab.url?.host() else { return "Nothing loaded yet" }
        return host
    }

    /// The hint carries the circuit port as well as the action: the chip that
    /// shows it on the card is inside the button, so VoiceOver never reads it.
    private func switchHint(for tab: BrowserTab) -> String {
        guard let port = tab.socksPort else { return "Switches to this tab" }
        return "Switches to this tab. Its own Tor circuit is on port \(port)."
    }
}

// MARK: - The picture on a card

/// A tab's last snapshot, or a placeholder built from the palette.
///
/// The decode is held in state and redone only when the bytes themselves
/// change, so scrolling the grid does not turn a JPEG back into pixels on every
/// pass of `body`.
private struct TabPreview: View {
    var tab: BrowserTab
    var aspectRatio: CGFloat

    @State private var image: Image?

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .background { ground }
            .overlay { content }
            .overlay(alignment: .bottomLeading) { circuitChip }
            .clipped()
            .task(id: tab.thumbnail) { image = Self.decode(tab.thumbnail) }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                // Pages are far taller than the card, so a centred crop lands
                // in the middle of an article. The top is the part someone
                // recognises a tab by.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Group {
            if let host = tab.url?.host() {
                Monogram(Self.monogram(for: host), size: 46)
            } else {
                // The app's own mark rather than a generic globe: a tab with
                // nothing loaded is showing Shallot's start page, so that is
                // what its card should look like.
                ShallotMark(layers: 3, tint: Palette.arterialSoft)
                    .frame(width: 44, height: 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ground: some View {
        LinearGradient(
            colors: [Palette.voidLift.opacity(0.85), Palette.void],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            RadialGradient(
                colors: [Palette.blood.opacity(0.20), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 150
            )
        }
    }

    @ViewBuilder
    private var circuitChip: some View {
        if let port = tab.socksPort {
            Text("circuit :\(String(port))")
                .font(Typography.dataSmall)
                .foregroundStyle(Palette.arterialSoft)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                // Its own scrim rather than a band across the card: the chip
                // has to stay legible over whatever the page happens to be.
                .background {
                    Capsule()
                        .fill(Palette.void.opacity(0.74))
                        .overlay { Capsule().strokeBorder(Palette.edgeRed, lineWidth: 1) }
                }
                .padding(8)
        }
    }

    private static func decode(_ data: Data?) -> Image? {
        guard let data, let decoded = UIImage(data: data) else { return nil }
        return Image(uiImage: decoded)
    }

    /// Two letters from the site's own name, skipping `www.` and the TLD.
    private static func monogram(for host: String) -> String {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let name = bare.split(separator: ".").first.map(String.init) ?? bare
        return String(name.prefix(2)).uppercased()
    }
}
