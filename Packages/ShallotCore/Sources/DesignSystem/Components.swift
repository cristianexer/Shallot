import Domain
import SwiftUI

/// A pulsing dot, used for "live" and for the Tor status light.
public struct PulseDot: View {
    public var color: Color
    public var size: CGFloat
    public var delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDim = false

    public init(color: Color = Palette.arterial, size: CGFloat = 7, delay: Double = 0) {
        self.color = color
        self.size = size
        self.delay = delay
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: Palette.glow, radius: 5)
            .opacity(isDim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true).delay(delay)) {
                    isDim = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// The square monogram used on favourites and quick-access tiles.
public struct Monogram: View {
    public var text: String
    public var size: CGFloat

    public init(_ text: String, size: CGFloat = 38) {
        self.text = text
        self.size = size
    }

    public var body: some View {
        Text(text)
            .font(.system(size: size * 0.39, weight: .bold, design: .monospaced))
            .foregroundStyle(Palette.bone)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Palette.arterial.opacity(0.22), Palette.blood.opacity(0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                            .strokeBorder(Palette.edgeRed, lineWidth: 1)
                    }
            }
            .accessibilityHidden(true)
    }
}

/// The ONION / HTTPS pill on a favourite card.
public struct SecurityTag: View {
    public var isOnion: Bool

    public init(isOnion: Bool) {
        self.isOnion = isOnion
    }

    public var body: some View {
        Text(isOnion ? "ONION" : "HTTPS")
            .font(.system(.caption2, design: .monospaced))
            .tracking(1)
            .foregroundStyle(isOnion ? Palette.arterialSoft : Palette.ash)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(isOnion ? Palette.arterial.opacity(0.08) : .clear)
            }
            .overlay {
                Capsule().strokeBorder(isOnion ? Palette.edgeRed : Palette.edge, lineWidth: 1)
            }
    }
}

/// The red-rimmed advisory box.
public struct AdvisoryBox: View {
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Typography.dataSmall)
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(Palette.arterialSoft)
            Text(message)
                .font(Typography.detail)
                .foregroundStyle(Color(red: 0.906, green: 0.788, blue: 0.808))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.arterial.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Palette.edgeRed, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A settings row: label, optional explanation, trailing control.
public struct SettingsRow<Trailing: View>: View {
    private let title: String
    private let detail: String?
    private let trailing: Trailing

    public init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.bone)
                if let detail {
                    Text(detail)
                        .font(Typography.detail)
                        .foregroundStyle(Palette.ash)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: Metrics.minimumTouchTarget)
    }
}

/// A section heading, optionally with one line of context for the whole group.
///
/// One explanation above four related rows beats four explanations inside
/// them: the rows stay scannable and the reason is stated once.
public struct SectionLabel: View {
    private let title: String
    private let note: String?

    public init(_ title: String, note: String? = nil) {
        self.title = title
        self.note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).sectionLabelStyle()
            if let note {
                Text(note)
                    .font(Typography.detail)
                    .foregroundStyle(Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }
}

/// Groups settings rows into one glass card with hairline separators.
public struct SettingsGroup<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .glassPanel(cornerRadius: Metrics.panelRadius)
    }
}

/// The hairline between two rows in a `SettingsGroup`.
public struct RowDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Palette.edge)
            .frame(height: Metrics.hairline)
            .padding(.leading, 16)
            .accessibilityHidden(true)
    }
}

/// The bordered terminal-style action button.
public struct TerminalButton: View {
    public enum Emphasis { case outline, solid }

    private let title: String
    private let emphasis: Emphasis
    private let action: () -> Void

    public init(_ title: String, emphasis: Emphasis = .outline, action: @escaping () -> Void) {
        self.title = title
        self.emphasis = emphasis
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.control)
                .tracking(1.5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(emphasis == .solid ? Color.white : Palette.bone)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            if emphasis == .solid {
                shape
                    .fill(
                        LinearGradient(
                            colors: [Palette.arterial, Color(red: 0.639, green: 0, blue: 0.125)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Palette.glow, radius: 12, y: 8)
            } else {
                shape.fill(Palette.glass)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.edgeRed, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
