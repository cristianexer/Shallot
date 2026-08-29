import Domain
import DesignSystem
import SwiftUI

/// The Settings screen — and the place the app tells the truth about what it
/// can and cannot do.
public struct SettingsView: View {
    @Bindable var model: SettingsViewModel
    var biometryName: String
    var isBiometryAvailable: Bool

    public init(model: SettingsViewModel, biometryName: String, isBiometryAvailable: Bool) {
        self.model = model
        self.biometryName = biometryName
        self.isBiometryAvailable = isBiometryAvailable
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(kicker: "Configuration", title: "SETTINGS")

                if model.needsRelaunchForBridges {
                    AdvisoryBox(
                        title: "Relaunch needed",
                        message: "Tor reads its bridge configuration only when it starts, and it cannot be restarted inside a running app. Quit and reopen Shallot to use the new bridges."
                    )
                    .padding(.bottom, 16)
                }

                securitySection
                connectionSection
                privacySection
                exceptionsSection
                lockSection
                honesty
                aboutSection
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 120)
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $model.isEditingBridges) { bridgeEditor }
    }

    // MARK: - Sections

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Security level").sectionLabelStyle()
            SecurityLevelPicker(
                selection: Binding(
                    get: { model.settings.securityLevel },
                    set: { model.setSecurityLevel($0) }
                )
            )
        }
        .padding(.bottom, 22)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection").sectionLabelStyle()
            SettingsGroup {
                SettingsRow("Use bridges", detail: "Connect even where Tor is blocked") {
                    Toggle("", isOn: Binding(
                        get: { model.settings.bridges.isEnabled },
                        set: { model.setBridgesEnabled($0) }
                    ))
                    .labelsHidden()
                    .tint(Palette.arterial)
                    .accessibilityLabel("Use bridges")
                }
                RowDivider()
                SettingsRow("Transport", detail: transportDetail) {
                    Menu {
                        ForEach(BridgeTransport.allCases) { transport in
                            Button {
                                model.setTransport(transport)
                            } label: {
                                if model.isAvailable(transport) {
                                    Text(transport.title)
                                } else {
                                    Text("\(transport.title) — unavailable")
                                }
                            }
                            .disabled(!model.isAvailable(transport))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.settings.bridges.transport.title)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .font(Typography.data)
                        .foregroundStyle(Palette.arterialSoft)
                        .frame(minHeight: Metrics.minimumTouchTarget)
                    }
                    .accessibilityLabel("Transport")
                    .accessibilityValue(model.settings.bridges.transport.title)
                }
                RowDivider()
                SettingsRow("Bridge lines", detail: bridgeCountDetail) {
                    Button("Edit") { model.isEditingBridges = true }
                        .font(Typography.data)
                        .foregroundStyle(Palette.arterialSoft)
                        .frame(minHeight: Metrics.minimumTouchTarget)
                }
                RowDivider()
                SettingsRow("Default search") {
                    Menu {
                        ForEach(SearchEngine.allCases) { engine in
                            Button(engine.title) { model.setSearchEngine(engine) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.settings.searchEngine.title)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .font(Typography.data)
                        .foregroundStyle(Palette.arterialSoft)
                        .frame(minHeight: Metrics.minimumTouchTarget)
                    }
                    .accessibilityLabel("Default search engine")
                    .accessibilityValue(model.settings.searchEngine.title)
                }
            }
        }
        .padding(.bottom, 22)
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Privacy").sectionLabelStyle()
            SettingsGroup {
                toggleRow(
                    "HTTPS-only mode",
                    detail: "Upgrades or blocks anything that is not encrypted",
                    isOn: model.settings.httpsOnly,
                    set: model.setHTTPSOnly
                )
                RowDivider()
                toggleRow(
                    "Block WebRTC",
                    detail: "Stops the classic real-IP leak",
                    isOn: model.settings.blockWebRTC,
                    set: model.setBlockWebRTC
                )
                RowDivider()
                toggleRow(
                    "Block WebAuthn",
                    detail: "Passkey requests can reach the network outside Tor with no interaction",
                    isOn: model.settings.blockWebAuthn,
                    set: model.setBlockWebAuthn
                )
                RowDivider()
                toggleRow(
                    "Block WebTransport",
                    detail: "Opens direct connections that ignore the proxy",
                    isOn: model.settings.blockWebTransport,
                    set: model.setBlockWebTransport
                )
                RowDivider()
                toggleRow(
                    "Block DNS prefetching",
                    detail: "Prefetch hints are resolved outside Tor",
                    isOn: model.settings.blockDNSPrefetch,
                    set: model.setBlockDNSPrefetch
                )
                RowDivider()
                toggleRow(
                    "Isolate circuit per tab",
                    detail: "Each tab uses its own Tor path",
                    isOn: model.settings.isolateCircuitPerTab,
                    set: model.setIsolateCircuitPerTab
                )
                RowDivider()
                toggleRow(
                    "Clear everything on exit",
                    detail: "Nothing is written to disk either way — this also wipes memory on quit",
                    isOn: model.settings.clearOnExit,
                    set: model.setClearOnExit
                )
            }
        }
        .padding(.bottom, 22)
    }

    @ViewBuilder
    private var exceptionsSection: some View {
        if !model.siteExceptions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Per-site exceptions").sectionLabelStyle()
                SettingsGroup {
                    ForEach(Array(model.siteExceptions.enumerated()), id: \.element.id) { index, exception in
                        if index > 0 { RowDivider() }
                        SettingsRow(exception.host, detail: "\(exception.feature.title) — \(exception.feature.risk)") {
                            Button("Revoke") { model.revokeException(exception) }
                                .font(Typography.data)
                                .foregroundStyle(Palette.arterialSoft)
                                .frame(minHeight: Metrics.minimumTouchTarget)
                                .accessibilityLabel("Revoke \(exception.feature.title) for \(exception.host)")
                        }
                    }
                }
            }
            .padding(.bottom, 22)
        }
    }

    private var lockSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lock").sectionLabelStyle()
            SettingsGroup {
                SettingsRow(
                    "\(biometryName) to open",
                    detail: isBiometryAvailable ? nil : "Set a device passcode to use the app lock"
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.settings.requireBiometricUnlock },
                        set: { model.setRequireBiometricUnlock($0) }
                    ))
                    .labelsHidden()
                    .tint(Palette.arterial)
                    .disabled(!isBiometryAvailable)
                    .accessibilityLabel("\(biometryName) to open")
                }
                RowDivider()
                toggleRow(
                    "Hide screen in App Switcher",
                    detail: "Covers the snapshot iOS takes when you leave the app",
                    isOn: model.settings.hideInAppSwitcher,
                    set: model.setHideInAppSwitcher
                )
            }
        }
        .padding(.bottom, 22)
    }

    private var honesty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What Shallot does")
                .font(Typography.dataSmall)
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(Palette.arterialSoft)
            Text(model.honestyStatement)
                .font(Typography.detail)
                .foregroundStyle(Color(red: 0.906, green: 0.788, blue: 0.808))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.arterial.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Palette.edgeRed, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About").sectionLabelStyle().padding(.top, 22)
            SettingsGroup {
                SettingsRow("Version") {
                    Text(model.appVersion)
                        .font(Typography.data)
                        .foregroundStyle(Palette.arterialSoft)
                }
                RowDivider()
                SettingsRow("Tor") {
                    Text(model.torVersion)
                        .font(Typography.data)
                        .foregroundStyle(Palette.arterialSoft)
                }
            }
        }
    }

    // MARK: - Pieces

    private func toggleRow(
        _ title: String,
        detail: String? = nil,
        isOn: Bool,
        set: @escaping (Bool) -> Void
    ) -> some View {
        SettingsRow(title, detail: detail) {
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .labelsHidden()
                .tint(Palette.arterial)
                .accessibilityLabel(title)
        }
    }

    private var transportDetail: String {
        let transport = model.settings.bridges.transport
        return model.isAvailable(transport) ? transport.detail : model.unavailableReason(for: transport)
    }

    private var bridgeCountDetail: String {
        let count = model.settings.bridges.lines.count
        return count == 0 ? "None saved" : "\(count) saved"
    }

    private var bridgeEditor: some View {
        NavigationStack {
            ZStack {
                ShallotBackdrop(isPaused: true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Paste the bridge lines you were given, one per line.")
                        .font(Typography.detail)
                        .foregroundStyle(Palette.ash)

                    TextEditor(text: $model.bridgeText)
                        .font(Typography.address)
                        .foregroundStyle(Palette.bone)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 180)
                        .glassPanel(cornerRadius: Metrics.pillRadius)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Bridge lines")

                    if !model.bridgeErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.bridgeErrors, id: \.self) { error in
                                Text(error)
                                    .font(Typography.dataSmall)
                                    .foregroundStyle(Palette.arterialSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(Metrics.gutter)
            }
            .navigationTitle("Bridges")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.isEditingBridges = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.commitBridgeLines() }
                }
            }
        }
    }
}
