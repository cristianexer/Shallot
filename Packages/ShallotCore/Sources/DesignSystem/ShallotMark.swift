import SwiftUI

/// The onion in cross-section — the app's icon, as a shape rather than a bitmap.
///
/// The same tear-drop curve `Tools/make-app-icon.py` renders. Drawn rather than
/// imported so it stays crisp at any size, takes whatever tint the surrounding
/// view gives it, and needs no asset plumbing across the package boundary.
public struct OnionOutline: Shape {
    /// How far in from the outer skin this layer sits. `1` is the skin itself.
    public var layer: CGFloat

    public init(layer: CGFloat = 1) {
        self.layer = layer
    }

    /// Lets a layer be animated between depths.
    public var animatableData: CGFloat {
        get { layer }
        set { layer = newValue }
    }

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return Path() }

        // Every layer is normalised against the *outer* curve's bounds, so the
        // rings stay concentric instead of each one re-centring itself.
        let bounds = OnionGeometry.bounds
        let span = max(bounds.width, bounds.height)
        let scale = side / span
        let centre = CGPoint(x: rect.midX, y: rect.midY)

        var path = Path()
        for (index, point) in OnionGeometry.points.enumerated() {
            let x = centre.x + (point.x - bounds.midX) * scale * layer
            // Flipped, because the curve is described with y upward and a
            // `CGRect` counts it downward.
            let y = centre.y - (point.y - bounds.midY) * scale * layer
            let placed = CGPoint(x: x, y: y)
            if index == 0 { path.move(to: placed) } else { path.addLine(to: placed) }
        }
        path.closeSubpath()
        return path
    }
}

/// The curve, sampled once.
enum OnionGeometry {
    static let points: [CGPoint] = {
        let samples = 720
        return (0..<samples).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(samples)
            return CGPoint(
                x: -sin(angle) * pow(sin(angle / 2), 2) * 1.30,
                y: cos(angle) * 0.95
            )
        }
    }()

    static let bounds: CGRect = {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }()
}

/// The app's mark: nested onion layers around a core.
///
/// Used wherever Shallot needs to identify itself without a page behind it —
/// the lock screen, the app-switcher shield, the connecting state, and a tab
/// that has not loaded anything yet.
public struct ShallotMark: View {
    /// How many layers to draw. Fewer reads better at small sizes.
    public var layers: Int
    /// The colour of the outermost skin. Inner layers fade from it.
    public var tint: Color

    public init(layers: Int = 4, tint: Color = Palette.arterial) {
        self.layers = layers
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                ForEach(0..<layers, id: \.self) { index in
                    OnionOutline(layer: pow(0.70, CGFloat(index)))
                        .stroke(
                            tint.opacity(index == 0 ? 1 : 0.75 - Double(index) * 0.17),
                            lineWidth: max(1, side * (index == 0 ? 0.035 : 0.024))
                        )
                }
                Circle()
                    .fill(tint)
                    .frame(width: side * 0.085, height: side * 0.085)
                    .offset(y: side * 0.06)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
