import Domain
import DesignSystem
import SwiftUI

/// The vertical relay chain: this device → guard → relay → exit → destination.
public struct CircuitChainView: View {
    var path: [RelayNode]
    var destination: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(path: [RelayNode], destination: String?) {
        self.path = path
        self.destination = destination
    }

    public var body: some View {
        VStack(spacing: 0) {
            node(
                badge: "YOU",
                title: "This device",
                detail: "entry into the network",
                isEndpoint: true,
                showsWire: true
            )

            if path.isEmpty {
                node(
                    badge: "··",
                    title: "No circuit yet",
                    detail: "waiting for Tor to build a path",
                    isEndpoint: true,
                    showsWire: true
                )
            } else {
                ForEach(Array(path.enumerated()), id: \.element.id) { index, relay in
                    node(
                        badge: relay.badge,
                        title: "\(relay.position.title) · \(relay.nickname.isEmpty ? shortFingerprint(relay) : relay.nickname)",
                        detail: relay.countryName ?? "location unknown",
                        isEndpoint: false,
                        showsWire: true
                    )
                    .accessibilityLabel("\(relay.position.title) relay \(relay.nickname), \(relay.countryName ?? "location unknown")")
                }
            }

            node(
                badge: "◈",
                title: "Destination",
                detail: destination ?? "nothing open",
                isEndpoint: true,
                showsWire: false
            )
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .glassPanel(cornerRadius: Metrics.cardRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Circuit path")
    }

    private func node(
        badge: String,
        title: String,
        detail: String,
        isEndpoint: Bool,
        showsWire: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 0) {
                Text(badge)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isEndpoint ? Palette.ash : Palette.bone)
                    .frame(width: 34, height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                isEndpoint
                                    ? AnyShapeStyle(Color.white.opacity(0.05))
                                    : AnyShapeStyle(
                                        LinearGradient(
                                            colors: [Palette.arterial.opacity(0.2), Palette.blood.opacity(0.24)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isEndpoint ? Palette.edge : Palette.edgeRed, lineWidth: 1)
                            }
                    }

                if showsWire {
                    WireSegment(isAnimated: !reduceMotion)
                        .frame(width: 2, height: 26)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Typography.data)
                    .foregroundStyle(Palette.bone)
                    .lineLimit(1)
                Text(detail)
                    .font(Typography.dataSmall)
                    .foregroundStyle(Palette.ash)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortFingerprint(_ relay: RelayNode) -> String {
        String(relay.fingerprint.prefix(8))
    }
}

/// The vertical wire between two nodes, with a pulse travelling down it.
struct WireSegment: View {
    var isAnimated: Bool

    var body: some View {
        if isAnimated {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.edgeRed))
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    let pulseHeight = size.height * 0.35
                    let y = phase * (size.height + pulseHeight) - pulseHeight
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: pulseHeight)),
                        with: .linearGradient(
                            Gradient(colors: [.clear, Palette.arterial, .clear]),
                            startPoint: CGPoint(x: 0, y: y),
                            endPoint: CGPoint(x: 0, y: y + pulseHeight)
                        )
                    )
                }
            }
            .accessibilityHidden(true)
        } else {
            Rectangle()
                .fill(Palette.edgeRed)
                .accessibilityHidden(true)
        }
    }
}
