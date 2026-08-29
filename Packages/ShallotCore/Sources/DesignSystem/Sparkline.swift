import SwiftUI

/// The bandwidth sparkline: filled area plus a glowing stroke.
///
/// Takes pre-normalised 0...1 values so the scaling decision lives in
/// `BandwidthSampler`, where it is tested, rather than in a view.
public struct Sparkline: View {
    public var values: [Double]
    public var height: CGFloat

    public init(values: [Double], height: CGFloat = 46) {
        self.values = values
        self.height = height
    }

    public var body: some View {
        Canvas { context, size in
            guard values.count > 1, size.width > 0 else { return }
            let step = size.width / CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(min(max(value, 0), 1))))
            }

            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for point in points { area.addLine(to: point) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [Palette.arterial.opacity(0.5), Palette.arterial.opacity(0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            var line = Path()
            line.addLines(points)
            context.addFilter(.shadow(color: Palette.arterial.opacity(0.7), radius: 4))
            context.stroke(line, with: .color(Palette.rain), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
