import SwiftUI

/// The type system: SF Mono for chrome and data, SF Pro for prose.
///
/// Every style is built from a `Font.TextStyle`, so all of them scale with
/// Dynamic Type. Nothing here is a fixed point size — a fixed size on text that
/// carries meaning is an accessibility failure, and the terminal aesthetic
/// survives scaling perfectly well.
public enum Typography {
    /// Small, wide-tracked, uppercase label above a title.
    public static let kicker = Font.system(.caption2, design: .monospaced).weight(.medium)
    /// Screen titles.
    public static let screenTitle = Font.system(.title2, design: .monospaced).weight(.semibold)
    /// The SHALLOT wordmark on the start page.
    public static let wordmark = Font.system(.largeTitle, design: .monospaced).weight(.semibold)
    /// Section headers inside a screen.
    public static let sectionLabel = Font.system(.caption2, design: .monospaced).weight(.medium)
    /// Monospaced data: addresses, ports, relay names, counters.
    public static let data = Font.system(.footnote, design: .monospaced)
    /// Small monospaced data: URLs under a card, timestamps.
    public static let dataSmall = Font.system(.caption2, design: .monospaced)
    /// Large monospaced numerals in the metric tiles.
    public static let metric = Font.system(.title3, design: .monospaced).weight(.medium)
    /// The address in the omnibar.
    public static let address = Font.system(.footnote, design: .monospaced)
    /// Buttons and segmented controls.
    public static let control = Font.system(.caption, design: .monospaced).weight(.medium)
    /// Readable body copy.
    public static let body = Font.system(.subheadline)
    /// Secondary explanatory copy.
    public static let detail = Font.system(.footnote)
    /// A row's primary label.
    public static let rowTitle = Font.system(.callout)
}

extension View {
    /// Applies a kicker style: wide tracking, uppercase, soft accent.
    public func kickerStyle() -> some View {
        font(Typography.kicker)
            .tracking(2.6)
            .textCase(.uppercase)
            .foregroundStyle(Palette.arterialSoft)
    }

    /// Applies the section-label style used above grouped content.
    public func sectionLabelStyle() -> some View {
        font(Typography.sectionLabel)
            .tracking(2.2)
            .textCase(.uppercase)
            .foregroundStyle(Palette.ash)
    }
}
