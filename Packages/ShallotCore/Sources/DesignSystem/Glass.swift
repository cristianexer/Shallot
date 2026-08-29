import SwiftUI

/// The translucent chrome the digital rain refracts through.
///
/// On iOS 26 this is real Liquid Glass. Below it, the prototype's material and
/// border treatment. The split lives here and nowhere else, so no feature ever
/// branches on OS version.
///
/// Glass belongs to the navigation and control layer only — never behind page
/// content. Glass also cannot sample glass, so overlapping glass elements are
/// grouped in a `GlassEffectContainer` rather than nested.
/// How dense the frosting is behind a piece of chrome.
public enum GlassDensity {
    /// Bars and floating chrome.
    case bar
    /// Cards and grouped rows.
    case panel

    var fill: Color {
        switch self {
        case .bar: Palette.glass
        case .panel: Palette.glassDense
        }
    }
}

public struct GlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    let density: GlassDensity

    public func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay { shape.strokeBorder(Palette.edgeRed, lineWidth: 0.5) }
        } else {
            content
                .background {
                    shape
                        .fill(density.fill)
                        .background(.ultraThinMaterial, in: shape)
                }
                .overlay {
                    shape.strokeBorder(Palette.edge, lineWidth: Metrics.hairline)
                }
                .overlay {
                    shape.strokeBorder(Palette.edgeRed, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.5), radius: 17, y: 12)
        }
    }
}

extension View {
    /// Puts this view on glass with the given corner radius.
    public func glassPanel(
        cornerRadius: CGFloat = Metrics.panelRadius,
        density: GlassDensity = .panel
    ) -> some View {
        modifier(
            GlassBackground(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                density: density
            )
        )
    }

    /// Puts this view on glass with a capsule outline.
    public func glassCapsule(density: GlassDensity = .bar) -> some View {
        modifier(GlassBackground(shape: Capsule(), density: density))
    }
}

/// Groups several glass elements so they blend rather than stack.
///
/// On iOS 26 this is `GlassEffectContainer`; below it, a plain passthrough.
public struct GlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A card on glass.
public struct GlassPanel<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content

    public init(cornerRadius: CGFloat = Metrics.cardRadius, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content.glassPanel(cornerRadius: cornerRadius)
    }
}
