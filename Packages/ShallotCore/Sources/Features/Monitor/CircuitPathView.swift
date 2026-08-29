import Domain
import DesignSystem
import SwiftUI

/// The Tor path, as one line.
///
/// This used to be a tall vertical chain with a card per relay, which took most
/// of the screen to say something the country codes say on their own. The
/// detail that matters — which countries the traffic crosses, in order, and
/// where it comes out — fits on a row; the relay names go underneath for anyone
/// who wants them.
public struct CircuitPathView: View {
    var path: [RelayNode]
    var destination: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(path: [RelayNode], destination: String?) {
        self.path = path
        self.destination = destination
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("PATH")
                    .font(Typography.dataSmall)
                    .tracking(1.4)
                    .foregroundStyle(Palette.ash)
                Spacer()
                if let destination {
                    Text(destination)
                        .font(Typography.dataSmall)
                        .foregroundStyle(Palette.arterialSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if path.isEmpty {
                Text("Building a path through the network…")
                    .font(Typography.detail)
                    .foregroundStyle(Palette.ash)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                hops
                names
            }
        }
        .padding(14)
        .glassPanel(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenPath)
    }

    private var hops: some View {
        HStack(spacing: 4) {
            endpoint("iphone")
            ForEach(Array(path.enumerated()), id: \.element.id) { _, relay in
                connector
                badge(relay)
            }
            connector
            endpoint("globe")
        }
    }

    private var names: some View {
        Text(path.map(displayName).joined(separator: "  ·  "))
            .font(Typography.dataSmall)
            .foregroundStyle(Palette.ash)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badge(_ relay: RelayNode) -> some View {
        Text(relay.badge)
            .font(.system(.caption2, design: .monospaced).weight(.bold))
            .foregroundStyle(Palette.bone)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Palette.arterial.opacity(0.24), Palette.blood.opacity(0.30)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Palette.edgeRed, lineWidth: 1)
                    }
            }
    }

    private func endpoint(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.ash)
            .frame(width: 26, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Palette.edge, lineWidth: 1)
                    }
            }
    }

    /// The line between two hops, with a pulse travelling along it.
    ///
    /// A `Canvas` in a `TimelineView` per connector meant four timelines
    /// redrawing on the main thread at 24fps, on a screen that already has the
    /// rain behind it. This is the same effect handed to Core Animation, which
    /// runs it off the main thread for nothing.
    private var connector: some View {
        ConnectorLine(isAnimated: !reduceMotion)
            .frame(height: 1.5)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private func displayName(_ relay: RelayNode) -> String {
        relay.nickname.isEmpty ? String(relay.fingerprint.prefix(8)) : relay.nickname
    }

    private var spokenPath: String {
        guard !path.isEmpty else { return "No circuit yet. Building a path through the network." }
        let hops = path.map { relay in
            "\(relay.position.title) in \(relay.countryName ?? "an unknown country"), \(displayName(relay))"
        }
        let tail = destination.map { ", out to \($0)" } ?? ""
        return "Path: this device, then " + hops.joined(separator: ", then ") + tail
    }
}

/// A hairline with a pulse sliding along it.
private struct ConnectorLine: View {
    var isAnimated: Bool

    @State private var isTravelling = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let pulse = max(12, width * 0.5)
            Rectangle()
                .fill(Palette.edgeRed)
                .overlay(alignment: .leading) {
                    if isAnimated {
                        LinearGradient(
                            colors: [.clear, Palette.arterial, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: pulse)
                        .offset(x: isTravelling ? width : -pulse)
                    }
                }
                .clipped()
                .onAppear {
                    guard isAnimated else { return }
                    withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                        isTravelling = true
                    }
                }
        }
    }
}
