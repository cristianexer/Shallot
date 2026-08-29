import Domain
import DesignSystem
import SwiftUI

/// The Monitor screen: live circuit, counters, bandwidth and the event log.
public struct MonitorView: View {
    @Bindable var model: MonitorViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(model: MonitorViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(
                    kicker: "● Live",
                    title: "MONITOR",
                    subtitle: "Everything here is measured on this device. Shallot never reports your activity anywhere."
                )

                CircuitChainView(path: model.path, destination: model.destinationLabel)

                metrics
                bandwidth
                eventLog
                actions
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 120)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metric(value: "\(model.bootstrapProgress)", unit: "%", label: "Bootstrap")
            metric(value: "\(model.circuitCount)", unit: "", label: "Circuits")
            metric(value: "\(model.streamCount)", unit: "", label: "Streams")
        }
    }

    private func metric(value: String, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value)
                    .font(Typography.metric)
                    .foregroundStyle(Palette.arterialSoft)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit)
                    .font(Typography.metric)
                    .foregroundStyle(Palette.bone)
            }
            Text(label)
                .font(Typography.dataSmall)
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Palette.ash)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .glassPanel(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)\(unit)")
    }

    private var bandwidth: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BANDWIDTH")
                    .font(Typography.dataSmall)
                    .tracking(1)
                    .foregroundStyle(Palette.ash)
                Spacer()
                Text("▼ \(model.downRateLabel) · ▲ \(model.upRateLabel) KB/S")
                    .font(Typography.dataSmall)
                    .foregroundStyle(Palette.arterialSoft)
                    .monospacedDigit()
            }
            Sparkline(values: model.sparkline)
        }
        .padding(14)
        .glassPanel(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bandwidth: \(model.downRateLabel) kilobytes per second down, \(model.upRateLabel) up")
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.recentEvents()) { event in
                HStack(spacing: 8) {
                    Text(Self.timestampFormatter.string(from: event.timestamp))
                        .foregroundStyle(Palette.ash)
                        .monospacedDigit()
                    Text(event.kind.glyph)
                        .foregroundStyle(event.kind.isAffirmative ? Palette.affirm : Palette.arterialSoft)
                    Text(event.message)
                        .foregroundStyle(Color(red: 0.906, green: 0.788, blue: 0.808))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(Typography.dataSmall)
                .accessibilityElement(children: .combine)
            }

            if model.events.isEmpty {
                Text("No events yet.")
                    .font(Typography.dataSmall)
                    .foregroundStyle(Palette.ash)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassPanel(cornerRadius: 16)
        .accessibilityLabel("Security event log")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            TerminalButton("NEW IDENTITY") {
                Task { await model.requestNewIdentity() }
            }
            .accessibilityHint("Closes every tab, clears the session and rotates all circuits")

            TerminalButton("NEW CIRCUIT", emphasis: .solid) {
                Task { await model.requestNewCircuit() }
            }
            .accessibilityHint("Builds a fresh path without clearing the session")
        }
        .disabled(model.isWorking)
        .opacity(model.isWorking ? 0.6 : 1)
    }

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
