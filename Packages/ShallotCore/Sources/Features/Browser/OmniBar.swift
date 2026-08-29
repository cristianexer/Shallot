import Domain
import DesignSystem
import SwiftUI

/// The address bar. One row, and as little of it as the job allows.
///
/// The controls that used to sit around it have been folded inward: reload
/// lives inside the pill, the Tor status is the dot on its leading edge, and
/// everything that is not needed on every page — new identity, saving a
/// favourite, the security level — is behind the overflow menu. Back appears
/// only when there is somewhere to go back to.
///
/// The result is that the address gets most of the width, which is the one
/// thing in this bar a person actually reads.
public struct OmniBar: View {
    @Bindable var model: BrowserViewModel
    var torState: TorRuntimeState
    var onNewIdentity: () -> Void
    var onShowTabs: () -> Void

    @FocusState private var isFieldFocused: Bool

    public init(
        model: BrowserViewModel,
        torState: TorRuntimeState,
        onNewIdentity: @escaping () -> Void,
        onShowTabs: @escaping () -> Void
    ) {
        self.model = model
        self.torState = torState
        self.onNewIdentity = onNewIdentity
        self.onShowTabs = onShowTabs
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if model.canGoBack {
                    control("chevron.left", label: "Back") { model.goBack() }
                }

                addressPill

                tabsButton
                overflowMenu
            }

            progressLine
        }
    }

    // MARK: - The pill

    private var addressPill: some View {
        HStack(spacing: 8) {
            leadingIndicator

            if model.isEditingAddress {
                TextField("Search or .onion address", text: $model.addressText)
                    .font(Typography.address)
                    .foregroundStyle(Palette.bone)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($isFieldFocused)
                    .onSubmit { model.submitAddress() }
                    .accessibilityLabel("Address")
            } else {
                addressText
            }

            trailingAction
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 38)
        .glassPanel(cornerRadius: Metrics.pillRadius, density: .bar)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.pillRadius, style: .continuous))
        .onTapGesture {
            guard !model.isEditingAddress else { return }
            model.syncAddressField()
            model.isEditingAddress = true
            isFieldFocused = true
        }
        .onChange(of: model.isEditingAddress) { _, editing in
            isFieldFocused = editing
        }
        .accessibilityElement(children: model.isEditingAddress ? .contain : .combine)
        .accessibilityLabel(model.isEditingAddress ? "Address" : accessibleAddress)
        .accessibilityHint(model.isEditingAddress ? "" : "Tap to edit the address")
    }

    /// The leading glyph: Tor's state when it matters, the connection's
    /// security when it does not.
    ///
    /// A permanent "TOR · ANONYMOUS" banner is reassurance you stop reading
    /// after the first day. The state that needs saying is the state where the
    /// browser will not load anything — so that is the only one that takes
    /// space.
    @ViewBuilder
    private var leadingIndicator: some View {
        if torState.canCarryTraffic {
            Image(systemName: shieldSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(shieldColour)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        } else {
            PulseDot(color: Palette.arterialSoft, size: 7)
                .frame(width: 20, height: 20)
        }
    }

    @ViewBuilder
    private var addressText: some View {
        if !torState.canCarryTraffic {
            Text(connectingLabel)
                .font(Typography.address)
                .foregroundStyle(Palette.arterialSoft)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let url = model.activeTab?.url {
            HStack(spacing: 0) {
                Text(hostBase(of: url))
                    .foregroundStyle(Palette.bone)
                Text(hostSuffix(of: url))
                    .foregroundStyle(Palette.arterialSoft)
            }
            .font(Typography.address)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Search or .onion address")
                .font(Typography.address)
                .foregroundStyle(Palette.ash)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Reload and stop live inside the pill, where they cost no extra width.
    @ViewBuilder
    private var trailingAction: some View {
        if model.isLoading {
            pillButton("xmark", label: "Stop loading") { model.stopLoading() }
        } else if model.activeTab?.url != nil {
            pillButton("arrow.clockwise", label: "Reload") { model.reload() }
        }
    }

    // MARK: - Outer controls

    private var tabsButton: some View {
        Button(action: onShowTabs) {
            ZStack {
                Image(systemName: "square.on.square")
                    .font(.system(size: 15, weight: .light))
                Text("\(model.tabs.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .offset(x: 1, y: 1)
            }
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ash)
        .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
        .accessibilityLabel("Tabs")
        .accessibilityValue("\(model.tabs.count) open")
    }

    private var overflowMenu: some View {
        Menu {
            Button(role: .destructive, action: onNewIdentity) {
                Label("New Identity", systemImage: "theatermasks")
            }

            if model.activeTab?.url != nil {
                Button {
                    model.toggleFavourite()
                } label: {
                    Label(
                        model.isActivePageSaved ? "Remove from Favourites" : "Save to Favourites",
                        systemImage: model.isActivePageSaved ? "bookmark.fill" : "bookmark"
                    )
                }
            }

            Button {
                model.newTab()
            } label: {
                Label("New Tab", systemImage: "plus.square")
            }

            // The level a person most wants to change is the one that just
            // broke the page in front of them, so it belongs here rather than
            // three taps away in Settings.
            Picker("Security level", selection: securityLevelBinding) {
                ForEach(SecurityLevel.allCases) { level in
                    Text(level.title.capitalized).tag(level)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .foregroundStyle(Palette.arterialSoft)
        .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
        .accessibilityLabel("More")
        .accessibilityHint("New identity, favourites, tabs and security level")
    }

    private var securityLevelBinding: Binding<SecurityLevel> {
        Binding(
            get: { model.securityLevel },
            set: { model.setSecurityLevel($0) }
        )
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressLine: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Palette.blood, Palette.arterial],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: proxy.size.width * model.loadProgress)
                .shadow(color: Palette.glow, radius: 4)
                .animation(.easeOut(duration: 0.25), value: model.loadProgress)
        }
        .frame(height: 2)
        .opacity(model.isLoading ? 1 : 0)
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    // MARK: - Pieces

    private func control(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ash)
        .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
        .accessibilityLabel(label)
    }

    /// A control sized to sit inside the pill without stretching it.
    private func pillButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ash)
        .accessibilityLabel(label)
    }

    private var shieldSymbol: String {
        switch model.activeTab?.security ?? .none {
        case .onion: "checkmark.shield.fill"
        case .secure: "lock.fill"
        case .insecure: "exclamationmark.shield.fill"
        case .none: "shield"
        }
    }

    private var shieldColour: Color {
        switch model.activeTab?.security ?? .none {
        case .insecure: Palette.ash
        case .none: Palette.ash
        default: Palette.arterialSoft
        }
    }

    private var connectingLabel: String {
        switch torState {
        case .failed: "Not connected to Tor"
        case .off: "Starting Tor…"
        case .stopping: "Disconnecting…"
        case .starting(let progress): "Connecting to Tor · \(progress)%"
        case .running: ""
        }
    }

    // MARK: - Address formatting

    private var accessibleAddress: String {
        guard torState.canCarryTraffic else { return connectingLabel }
        guard let url = model.activeTab?.url else { return "Address bar, empty" }
        let security = model.activeTab?.security ?? .none
        let host = url.host() ?? url.absoluteString
        return security == .none ? host : "\(host), \(security.label)"
    }

    /// The host with its final label removed, so `.onion` can be tinted.
    private func hostBase(of url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        guard let dot = host.lastIndex(of: ".") else { return host }
        return String(host[host.startIndex..<dot])
    }

    private func hostSuffix(of url: URL) -> String {
        guard let host = url.host(), let dot = host.lastIndex(of: ".") else { return "" }
        return String(host[dot...])
    }
}
