import SwiftUI

/// The palette from the signed-off prototype.
///
/// Blood red on near-black. The red is reserved for accents, large type and
/// glyphs — small red text on black fails contrast, so body copy is bone or
/// ash, never arterial.
public enum Palette {
    /// Page background.
    public static let void = Color(red: 0.039, green: 0.008, blue: 0.024)
    /// Slightly lifted background for the top of the gradient.
    public static let voidLift = Color(red: 0.165, green: 0.016, blue: 0.063)
    /// Deep, saturated red for gradients.
    public static let blood = Color(red: 0.545, green: 0.0, blue: 0.0)
    /// The signature accent.
    public static let arterial = Color(red: 1.0, green: 0.071, blue: 0.239)
    /// A lighter accent that passes contrast at small sizes.
    public static let arterialSoft = Color(red: 1.0, green: 0.314, blue: 0.412)
    /// The digital rain.
    public static let rain = Color(red: 1.0, green: 0.169, blue: 0.271)
    /// Primary text.
    public static let bone = Color(red: 0.957, green: 0.914, blue: 0.925)
    /// Secondary text.
    public static let ash = Color(red: 0.639, green: 0.467, blue: 0.498)
    /// Affirmative state in the event log.
    public static let affirm = Color(red: 0.341, green: 0.851, blue: 0.541)

    /// Glass fill.
    public static let glass = Color(red: 0.094, green: 0.024, blue: 0.047).opacity(0.46)
    /// Slightly denser glass, for grouped rows.
    public static let glassDense = Color(red: 0.133, green: 0.035, blue: 0.067).opacity(0.58)
    /// Hairline highlight.
    public static let edge = Color.white.opacity(0.14)
    /// Warm hairline that gives the glass its red rim.
    public static let edgeRed = Color(red: 1.0, green: 0.471, blue: 0.549).opacity(0.30)
    /// Glow behind accents.
    public static let glow = Color(red: 1.0, green: 0.071, blue: 0.239).opacity(0.45)

    /// The full-bleed background gradient the rain sits on.
    public static var backdrop: some View {
        LinearGradient(
            colors: [voidLift.opacity(0.55), void, Color(red: 0.02, green: 0.004, blue: 0.012)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Corner radii, spacing and stroke widths, so components agree with each other.
public enum Metrics {
    public static let cardRadius: CGFloat = 20
    public static let panelRadius: CGFloat = 18
    public static let barRadius: CGFloat = 19
    public static let pillRadius: CGFloat = 14
    public static let tileRadius: CGFloat = 20

    public static let gutter: CGFloat = 18
    public static let tightGutter: CGFloat = 11
    public static let hairline: CGFloat = 1

    /// The minimum comfortable hit target. Every control meets it.
    public static let minimumTouchTarget: CGFloat = 44
}
