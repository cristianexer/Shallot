import Domain
import DesignSystem
import SwiftUI

/// The address bar. One row, and as little of it as the job allows.
///
/// The overflow menu on the left, the address in the middle, reload on the
/// right. Back, forward, saving a page and the tab list live in the bottom bar,
/// which is where a thumb is; the Tor status is the glyph on the pill's leading
/// edge rather than a banner of its own.
///
/// The result is that the address gets most of the width, which is the one
/// thing in this bar a person actually reads.
public struct OmniBar: View {
    @Bindable var model: BrowserViewModel
    var torState: TorRuntimeState
    var onNewIdentity: () -> Void
    var onShowSection: (AppSection) -> Void

    @FocusState private var isFieldFocused: Bool

    public init(
        model: BrowserViewModel,
        torState: TorRuntimeState,
        onNewIdentity: @escaping () -> Void,
        onShowSection: @escaping (AppSection) -> Void
    ) {
        self.model = model
        self.torState = torState
        self.onNewIdentity = onNewIdentity
        self.onShowSection = onShowSection
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                SidebarToggleButton()
                overflowMenu
                addressPill
                refreshButton
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
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
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

    // MARK: - Outer controls

    /// Reload, as its own control rather than a glyph tucked inside the pill.
    ///
    /// It doubles as stop while a page is loading, which is the one moment the
    /// two are never both wanted.
    @ViewBuilder
    private var refreshButton: some View {
        if model.isLoading {
            control("xmark", label: "Stop loading") { model.stopLoading() }
        } else {
            control("arrow.clockwise", label: "Reload", enabled: model.canReload) {
                model.reload()
            }
        }
    }

    private var overflowMenu: some View {
        Menu {
            // The three destinations. They live here rather than in a bottom
            // bar because they are places you visit occasionally, and the bar
            // is better spent on the controls a browser needs constantly.
            ForEach(AppSection.destinations) { section in
                Button {
                    onShowSection(section)
                } label: {
                    Label(section.title, systemImage: section.symbol)
                }
            }

            Divider()

            Button {
                model.newTab()
            } label: {
                Label("New Tab", systemImage: "plus.square")
            }

            Button(role: .destructive, action: onNewIdentity) {
                Label("New Identity", systemImage: "theatermasks")
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
        .accessibilityHint("Favourites, Monitor, Settings, a new tab and a new identity")
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
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ash)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
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
