import SwiftUI

/// The blood-red digital rain behind the glass.
///
/// Drawn as a pure function of the timeline's clock — no mutable state, no
/// per-frame allocation of positions — so it never drifts, never accumulates,
/// and stops dead when it is told to.
///
/// Two things keep it cheap enough to sit under a scrolling browser:
/// the glyph set is resolved once per frame rather than once per glyph, and
/// only the visible head and a short trail of each column are drawn instead of
/// a full character grid.
public struct RainView: View {
    /// Stops the animation entirely — used when the app is backgrounded, so a
    /// browser sitting in the app switcher is not animating a canvas.
    public var isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isPaused: Bool = false) {
        self.isPaused = isPaused
    }

    private static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾﾀﾁﾂﾃﾅﾆﾇﾊﾋﾌﾍﾎ0123456789ABCDEFxX#<>/█▓")
    private static let cell: CGFloat = 15
    private static let trailLength = 7

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 18.0, paused: isPaused || reduceMotion)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let seconds = reduceMotion
                    ? 0
                    : timeline.date.timeIntervalSinceReferenceDate
                draw(in: &context, size: size, seconds: seconds)
            }
        }
        // Reduce Motion still gets the texture, just frozen and quieter.
        .opacity(reduceMotion ? 0.28 : 0.55)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, seconds: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }
        let cell = Self.cell
        let columnCount = max(1, Int((size.width / cell).rounded(.up)))
        let font = Font.system(size: cell, weight: .semibold, design: .monospaced)

        // Resolve each glyph once per frame in each of the two tones, rather
        // than once per drawn character.
        let head = Self.glyphs.map { context.resolve(Text(String($0)).font(font).foregroundStyle(Palette.rain)) }
        let trail = Self.glyphs.map {
            context.resolve(Text(String($0)).font(font).foregroundStyle(Palette.blood.opacity(0.85)))
        }

        // Glyphs flicker on their own clock so a column is not a rigid ribbon.
        let flicker = Int(seconds * 11)
        let span = size.height + CGFloat(Self.trailLength) * cell

        for column in 0..<columnCount {
            let speed = 40 + Double(hash(column, 7) % 55)
            let offset = Double(hash(column, 13) % 1000) / 1000 * Double(span)
            let travelled = seconds * speed + offset
            let headY = CGFloat(travelled.truncatingRemainder(dividingBy: Double(span)))
                - CGFloat(Self.trailLength) * cell
            let x = CGFloat(column) * cell

            for step in 0..<Self.trailLength {
                let y = headY - CGFloat(step) * cell
                guard y > -cell, y < size.height else { continue }
                let row = Int((y / cell).rounded(.down))
                let index = hash(column &* 31 &+ row, flicker &+ step) % Self.glyphs.count
                let isHead = step == 0
                context.opacity = isHead ? 1.0 : max(0.06, 0.55 - Double(step) * 0.08)
                context.draw(isHead ? head[index] : trail[index], at: CGPoint(x: x, y: y), anchor: .topLeading)
            }
        }
        context.opacity = 1
    }

    /// A cheap deterministic hash, so the same cell always shows the same glyph
    /// for a given tick and the pattern does not shimmer randomly.
    private func hash(_ a: Int, _ b: Int) -> Int {
        var value = UInt64(bitPattern: Int64(a &* 0x9E3779B1 &+ b &* 0x85EBCA77))
        value ^= value >> 33
        value = value &* 0xFF51AFD7ED558CCD
        value ^= value >> 33
        return Int(value % UInt64(Int.max))
    }
}

/// The full backdrop: gradient, rain, vignette and scanlines.
public struct ShallotBackdrop: View {
    public var isPaused: Bool

    public init(isPaused: Bool = false) {
        self.isPaused = isPaused
    }

    public var body: some View {
        ZStack {
            Palette.backdrop
            RainView(isPaused: isPaused)
            // Darkens the edges so glass chrome reads against the rain.
            RadialGradient(
                colors: [.clear, Palette.void.opacity(0.55), Palette.void.opacity(0.92)],
                center: .top,
                startRadius: 0,
                endRadius: 900
            )
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}
