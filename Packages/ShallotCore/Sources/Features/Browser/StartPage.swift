import Domain
import DesignSystem
import SwiftUI

/// The page a new tab shows: wordmark, live circuit, and quick access.
public struct StartPage: View {
    var circuitSummary: String
    var isConnected: Bool
    var favourites: [Favourite]
    var onOpen: (Favourite) -> Void
    var onAdd: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    // Scales with Dynamic Type, so at accessibility sizes the grid drops to
    // fewer, wider columns instead of truncating every name to "Secur…".
    @ScaledMetric(relativeTo: .caption2) private var tileWidth: CGFloat = 74

    public init(
        circuitSummary: String,
        isConnected: Bool,
        favourites: [Favourite],
        onOpen: @escaping (Favourite) -> Void,
        onAdd: @escaping () -> Void
    ) {
        self.circuitSummary = circuitSummary
        self.isConnected = isConnected
        self.favourites = favourites
        self.onOpen = onOpen
        self.onAdd = onAdd
    }

    public var body: some View {
        VStack(spacing: 0) {
            hero
            quickAccess
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Text("SHALLOT")
                .font(Typography.wordmark)
                .tracking(8)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 1, green: 0.427, blue: 0.51), Palette.blood],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Palette.arterial.opacity(0.35), radius: 18)
                .accessibilityAddTraits(.isHeader)

            Text("Onion routing, wrapped in glass.")
                .font(Typography.detail)
                .foregroundStyle(Palette.ash)

            HStack(spacing: 9) {
                HStack(spacing: 4) {
                    PulseDot(size: 6)
                    PulseDot(size: 6, delay: 0.3)
                    PulseDot(size: 6, delay: 0.6)
                }
                Text(circuitSummary)
                    .font(Typography.dataSmall)
                    .tracking(1)
                    .foregroundStyle(Palette.bone)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCapsule()
            .padding(.top, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isConnected ? "Circuit established. \(circuitSummary)" : circuitSummary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 6)
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick access")
                .sectionLabelStyle()
                .padding(.top, 26)

            LazyVGrid(columns: columns, spacing: Metrics.tightGutter) {
                ForEach(favourites.prefix(7)) { favourite in
                    Button {
                        onOpen(favourite)
                    } label: {
                        tile(monogram: favourite.monogram, name: favourite.title, isAdd: false)
                    }
                    .buttonStyle(TileButtonStyle())
                    .accessibilityLabel(favourite.title)
                    .accessibilityHint("Opens \(favourite.displayURL) over Tor")
                }

                Button(action: onAdd) {
                    tile(monogram: "+", name: "Add", isAdd: true)
                }
                .buttonStyle(TileButtonStyle())
                .accessibilityLabel("Add a favourite")
            }
        }
    }

    private var columns: [GridItem] {
        // Four across on a phone at the default text size, more on iPad, and
        // fewer as the text grows — the column width is what reflows, so the
        // names stay readable instead of being truncated.
        // Clamped so the largest accessibility sizes still get two columns
        // rather than collapsing to one and turning a seven-item grid into a
        // long scroll.
        let minimum = min(tileWidth, 168) * (sizeClass == .regular ? 1.3 : 1)
        return [GridItem(.adaptive(minimum: minimum), spacing: Metrics.tightGutter)]
    }

    private func tile(monogram: String, name: String, isAdd: Bool) -> some View {
        VStack(spacing: 8) {
            if isAdd {
                Text("+")
                    .font(.system(size: 22, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.arterialSoft)
                    .frame(width: 38, height: 38)
            } else {
                Monogram(monogram)
            }
            Text(name)
                .font(.system(.caption2))
                .foregroundStyle(Palette.ash)
                // A name with a space wraps onto a second line; a single word
                // shrinks instead, because SwiftUI's hyphenation would break
                // "DuckDuckGo" as "Duck-DuckGo", which reads as a different
                // name. Both paths still scale with Dynamic Type.
                .lineLimit(name.contains(" ") ? 2 : 1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .frame(minHeight: 88)
    }
}

/// Press feedback for the quick-access tiles.
struct TileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous))
    }
}
