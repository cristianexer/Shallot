import Domain
import SwiftUI

/// The three-way security segmented control, with its explanation underneath.
///
/// The explanation is part of the control, not decoration: a user choosing
/// "Safest" needs to know that sites will break before they choose it, not
/// after.
public struct SecurityLevelPicker: View {
    @Binding public var selection: SecurityLevel

    public init(selection: Binding<SecurityLevel>) {
        self._selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(SecurityLevel.allCases) { level in
                    Button {
                        withAnimation(.spring(duration: 0.28)) { selection = level }
                    } label: {
                        Text(level.title)
                            .font(Typography.control)
                            .tracking(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == level ? Color.white : Palette.ash)
                    .background {
                        if selection == level {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Palette.arterial, Color(red: 0.639, green: 0, blue: 0.125)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: Palette.glow, radius: 9, y: 5)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(level.title.capitalized)
                    .accessibilityHint(level.explanation)
                    .accessibilityAddTraits(selection == level ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(4)
            .glassPanel(cornerRadius: 16, density: .bar)

            Text(selection.explanation)
                .font(Typography.detail)
                .foregroundStyle(Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .animation(.easeInOut(duration: 0.2), value: selection)
        }
    }
}

/// The Tor status chip: a live dot and the state in wide-tracked mono.
public struct TorStatusChip: View {
    public var label: String
    public var isLive: Bool

    public init(label: String, isLive: Bool) {
        self.label = label
        self.isLive = isLive
    }

    public var body: some View {
        HStack(spacing: 6) {
            PulseDot(color: isLive ? Palette.arterial : Palette.ash, size: 7)
            Text(label)
                .font(Typography.dataSmall)
                .tracking(1.5)
                .foregroundStyle(isLive ? Palette.arterialSoft : Palette.ash)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLive ? "Connected to Tor" : label.lowercased())
    }
}
