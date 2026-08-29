import Domain
import DesignSystem
import SwiftUI

/// Saved sites, grouped into onion services and clearnet.
public struct FavouritesView: View {
    @Bindable var model: FavouritesViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 150

    public init(model: FavouritesViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(
                    kicker: "Local · Encrypted",
                    title: "FAVOURITES",
                    subtitle: "Stored on this device only. No cloud sync — sync is a way to be identified."
                )

                AdvisoryBox(
                    title: "Verify before trusting",
                    message: "Onion addresses can change or be spoofed. A saved favourite is one you checked; a fresh link is not."
                )
                .padding(.bottom, 16)

                if model.isEmpty {
                    emptyState
                } else {
                    if !model.onionFavourites.isEmpty {
                        section("Onion services", items: model.onionFavourites)
                    }
                    if !model.clearnetFavourites.isEmpty {
                        section("Clearnet", items: model.clearnetFavourites)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 120)
        }
        .scrollContentBackground(.hidden)
        .overlay(alignment: .bottomTrailing) { addButton }
        .sheet(isPresented: $model.isAdding) { addSheet }
        .alert(
            "Rename favourite",
            isPresented: Binding(get: { model.editing != nil }, set: { if !$0 { model.editing = nil } })
        ) {
            TextField("Name", text: $model.editedTitle)
            Button("Save") { model.commitRename() }
            Button("Cancel", role: .cancel) { model.editing = nil }
        }
        .alert(
            "Could not save",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func section(_ title: String, items: [Favourite]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .sectionLabelStyle()
                .padding(.top, 10)

            LazyVGrid(columns: columns, spacing: Metrics.tightGutter) {
                ForEach(items) { favourite in
                    card(for: favourite)
                }
            }
        }
        .padding(.bottom, 10)
    }

    private var columns: [GridItem] {
        // Cards widen with the text they hold, so a long onion address is
        // still elided rather than crushed at accessibility sizes.
        let minimum = cardWidth * (sizeClass == .regular ? 1.45 : 1)
        return [GridItem(.adaptive(minimum: minimum), spacing: Metrics.tightGutter)]
    }

    private func card(for favourite: Favourite) -> some View {
        Button {
            model.openFavourite(favourite)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Monogram(favourite.monogram, size: 36)
                    Spacer()
                    SecurityTag(isOnion: favourite.isOnion)
                }
                Text(favourite.title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.bone)
                    .lineLimit(1)
                    .padding(.top, 12)
                Text(favourite.displayURL)
                    .font(Typography.dataSmall)
                    .foregroundStyle(Palette.ash)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .buttonStyle(TileButtonStyle())
        .glassPanel(cornerRadius: Metrics.panelRadius)
        .contextMenu {
            Button("Rename") { model.beginRenaming(favourite) }
            Button("Delete", role: .destructive) { model.delete(favourite) }
        }
        .accessibilityLabel(favourite.title)
        .accessibilityValue(favourite.isOnion ? "Onion service" : "Standard website")
        .accessibilityHint("Opens over Tor. Long press to rename or delete.")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bookmark")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.arterialSoft)
            Text("Nothing saved yet")
                .font(Typography.body)
                .foregroundStyle(Palette.bone)
            Text("Save a page from the browser, or add an address by hand.")
                .font(Typography.detail)
                .foregroundStyle(Palette.ash)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var addButton: some View {
        Button {
            model.beginAdding()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.bone)
        .background {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Palette.arterial, Color(red: 0.639, green: 0, blue: 0.125)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Palette.glow, radius: 14, y: 6)
        }
        .padding(.trailing, Metrics.gutter)
        .padding(.bottom, 96)
        .accessibilityLabel("Add a favourite")
    }

    private var addSheet: some View {
        NavigationStack {
            ZStack {
                ShallotBackdrop(isPaused: true)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name").sectionLabelStyle()
                        TextField("SecureDrop", text: $model.newTitle)
                            .textFieldStyle(.plain)
                            .font(Typography.body)
                            .foregroundStyle(Palette.bone)
                            .padding(12)
                            .glassPanel(cornerRadius: Metrics.pillRadius)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Address").sectionLabelStyle()
                        TextField("example.onion", text: $model.newAddress)
                            .textFieldStyle(.plain)
                            .font(Typography.address)
                            .foregroundStyle(Palette.bone)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .padding(12)
                            .glassPanel(cornerRadius: Metrics.pillRadius)
                    }
                    Text("Onion addresses are checked for the v3 format before they are saved.")
                        .font(Typography.detail)
                        .foregroundStyle(Palette.ash)
                    Spacer()
                }
                .padding(Metrics.gutter)
            }
            .navigationTitle("New favourite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.isAdding = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.commitAdd() }
                        .disabled(model.newAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// The sticky glass header used at the top of Favourites, Monitor and Settings.
public struct ScreenHeader: View {
    var kicker: String
    var title: String
    var subtitle: String?

    public init(kicker: String, title: String, subtitle: String? = nil) {
        self.kicker = kicker
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kicker).kickerStyle()
            Text(title)
                .font(Typography.screenTitle)
                .tracking(2)
                .foregroundStyle(Palette.bone)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(Typography.detail)
                    .foregroundStyle(Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}
