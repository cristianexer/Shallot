import Domain
import DesignSystem
import SwiftUI

/// The single-row address bar: back, forward, address pill, reload, mask.
public struct OmniBar: View {
    @Bindable var model: BrowserViewModel
    var onNewIdentity: () -> Void

    @FocusState private var isFieldFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(model: BrowserViewModel, onNewIdentity: @escaping () -> Void) {
        self.model = model
        self.onNewIdentity = onNewIdentity
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                control("chevron.left", label: "Back", enabled: model.canGoBack) { model.goBack() }
                control("chevron.right", label: "Forward", enabled: model.canGoForward) { model.goForward() }

                addressPill

                if model.isLoading {
                    control("xmark", label: "Stop loading") { model.stopLoading() }
                } else {
                    control("arrow.clockwise", label: "Reload", enabled: model.activeTab?.url != nil) {
                        model.reload()
                    }
                }

                control("theatermasks", label: "New identity", accent: true, action: onNewIdentity)
            }
            .padding(.horizontal, 2)

            progressLine
        }
    }

    // MARK: - Pieces

    private var addressPill: some View {
        HStack(spacing: 8) {
            shield
            if model.isEditingAddress {
                TextField("Search or enter .onion address", text: $model.addressText)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 36)
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

    @ViewBuilder
    private var addressText: some View {
        if let tab = model.activeTab, let url = tab.url {
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
            Text("Search or enter .onion address")
                .font(Typography.address)
                .foregroundStyle(Palette.ash)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shield: some View {
        Image(systemName: shieldSymbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(shieldColour)
            .frame(width: 24, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.arterial.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Palette.edgeRed, lineWidth: 1)
                    }
            }
            .accessibilityHidden(true)
    }

    private var shieldSymbol: String {
        switch model.activeTab?.security ?? .none {
        case .onion: "checkmark.shield"
        case .secure: "lock"
        case .insecure: "exclamationmark.shield"
        case .none: "shield"
        }
    }

    private var shieldColour: Color {
        switch model.activeTab?.security ?? .none {
        case .insecure: Palette.ash
        default: Palette.arterialSoft
        }
    }

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
        .padding(.top, 6)
        .accessibilityHidden(true)
    }

    private func control(
        _ symbol: String,
        label: String,
        accent: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent ? Palette.arterialSoft : Palette.ash)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        // The visual target is 30pt to match the prototype's slim bar; the
        // touch target is padded out to the 44pt minimum.
        .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
        .accessibilityLabel(label)
    }

    // MARK: - Address formatting

    private var accessibleAddress: String {
        guard let url = model.activeTab?.url else { return "Address bar, empty" }
        return url.host() ?? url.absoluteString
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
