import Domain
import DesignSystem
import SwiftUI

/// The Monitor: what Tor is doing, measured here and reported nowhere.
///
/// Ordered by how often it is worth looking at. The two actions come first,
/// because they are the reason most people open this screen; then the numbers;
/// then the path; then the log. The path used to be a tall chain of cards at
/// the top, which cost most of a phone screen to say what the country codes say
/// on one line.
public struct MonitorView: View {
    @Bindable var model: MonitorViewModel

    public init(model: MonitorViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader(
                    title: "MONITOR",
                    subtitle: "Measured on this device. Shallot never reports your activity anywhere.",
                    isLive: true
                )

                actions
                metrics
                bandwidth
                CircuitPathView(path: model.path, destination: model.destinationLabel)
                eventLog
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 110)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
    }

    // MARK: - Actions

    /// The two things this screen can do, each saying what it does.
    ///
    /// "New circuit" and "New identity" sound like synonyms and are not: one
    /// keeps your session, the other ends it. Putting the difference on the
    /// control is cheaper than making someone find out by pressing it.
    private var actions: some View {
        HStack(alignment: .top, spacing: 10) {
            action(
                symbol: "arrow.triangle.2.circlepath",
                title: "New circuit",
                detail: "A fresh path. Your tabs stay open.",
                emphasis: true
            ) {
                await model.requestNewCircuit()
            }

            action(
                symbol: "theatermasks",
                title: "New identity",
                detail: "Also closes every tab and clears the session.",
                emphasis: false
            ) {
                await model.requestNewIdentity()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.isWorking)
        .opacity(model.isWorking ? 0.6 : 1)
    }

    private func action(
        symbol: String,
        title: String,
        detail: String,
        emphasis: Bool,
        perform: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await perform() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(emphasis ? Palette.arterial : Palette.arterialSoft)
                    .frame(height: 22)
                Text(title)
                    .font(Typography.control)
                    .tracking(0.8)
                    .foregroundStyle(Palette.bone)
                Text(detail)
                    .font(Typography.dataSmall)
                    .foregroundStyle(Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            // Both cards take the height of the taller one, so a longer
            // explanation does not leave the pair looking misaligned.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .frame(minHeight: Metrics.minimumTouchTarget)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassPanel(cornerRadius: 16)
        .overlay {
            if emphasis {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.edgeRed, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Numbers

    private var metrics: some View {
        HStack(spacing: 10) {
            metric(value: "\(model.bootstrapProgress)", unit: "%", label: "Bootstrap")
            metric(value: "\(model.circuitCount)", unit: "", label: "Circuits")
            metric(value: "\(model.streamCount)", unit: "", label: "Streams")
        }
    }

    private func metric(value: String, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Palette.ash)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .glassPanel(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)\(unit)")
    }

    private var bandwidth: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BANDWIDTH")
                    .font(Typography.dataSmall)
                    .tracking(1.2)
                    .foregroundStyle(Palette.ash)
                Spacer()
                Text("▼ \(model.downRateLabel) · ▲ \(model.upRateLabel) KB/S")
                    .font(Typography.dataSmall)
                    .foregroundStyle(Palette.arterialSoft)
                    .monospacedDigit()
            }
            Sparkline(values: model.sparkline, height: 40)
        }
        .padding(14)
        .glassPanel(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Bandwidth: \(model.downRateLabel) kilobytes per second down, \(model.upRateLabel) up"
        )
    }

    // MARK: - Log

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EVENTS")
                .font(Typography.dataSmall)
                .tracking(1.2)
                .foregroundStyle(Palette.ash)

            ForEach(model.recentEvents()) { event in
                HStack(spacing: 8) {
                    Text(Self.timestampFormatter.string(from: event.timestamp))
                        .foregroundStyle(Palette.ash)
                        .monospacedDigit()
                    Text(event.kind.glyph)
                        .foregroundStyle(event.kind.isAffirmative ? Palette.affirm : Palette.arterialSoft)
                    Text(event.message)
                        .foregroundStyle(Palette.bone.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(Typography.dataSmall)
                .accessibilityElement(children: .combine)
            }

            if model.events.isEmpty {
                Text("Nothing to report yet.")
                    .font(Typography.dataSmall)
                    .foregroundStyle(Palette.ash)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassPanel(cornerRadius: 16)
        .accessibilityLabel("Security event log")
    }

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
