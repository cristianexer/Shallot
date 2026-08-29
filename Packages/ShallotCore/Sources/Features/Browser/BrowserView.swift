import Domain
import DesignSystem
import SwiftUI

/// The browser screen: sticky glass omnibar over either the start page or a
/// real, scrolling web page.
public struct BrowserView: View {
    @Bindable var model: BrowserViewModel
    var torState: TorRuntimeState
    var circuitSummary: String
    var favourites: [Favourite]
    var onNewIdentity: () async -> Void
    var onAddFavourite: () -> Void
    var onRetryConnection: () async -> Void

    @State private var isShowingTabs = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(
        model: BrowserViewModel,
        torState: TorRuntimeState,
        circuitSummary: String,
        favourites: [Favourite],
        onNewIdentity: @escaping () async -> Void,
        onAddFavourite: @escaping () -> Void,
        onRetryConnection: @escaping () async -> Void
    ) {
        self.model = model
        self.torState = torState
        self.circuitSummary = circuitSummary
        self.favourites = favourites
        self.onNewIdentity = onNewIdentity
        self.onAddFavourite = onAddFavourite
        self.onRetryConnection = onRetryConnection
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .sheet(isPresented: $isShowingTabs) {
            TabOverview(model: model)
        }
        .task { await model.onAppear() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TorStatusChip(label: torState.label, isLive: torState.canCarryTraffic)
                Spacer(minLength: 8)
                bookmarkButton
                tabsButton
            }

            OmniBar(model: model) {
                Task { await onNewIdentity() }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background {
            // A soft glass wash so page content refracts as it scrolls under
            // the bar, matching the prototype.
            LinearGradient(
                colors: [Palette.void.opacity(0.72), Palette.void.opacity(0.28), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(.ultraThinMaterial.opacity(0.6))
            .ignoresSafeArea(edges: .top)
        }
    }

    private var bookmarkButton: some View {
        Button {
            model.toggleFavourite()
        } label: {
            Image(systemName: model.isActivePageSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 13, weight: .medium))
                .frame(width: Metrics.minimumTouchTarget, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.isActivePageSaved ? Palette.arterialSoft : Palette.ash)
        .disabled(model.activeTab?.url == nil)
        .opacity(model.activeTab?.url == nil ? 0.35 : 1)
        .accessibilityLabel(model.isActivePageSaved ? "Remove from favourites" : "Save to favourites")
    }

    private var tabsButton: some View {
        Button {
            isShowingTabs = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 12, weight: .medium))
                Text("\(model.tabs.count)")
                    .font(Typography.dataSmall)
            }
            .frame(minWidth: Metrics.minimumTouchTarget, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ash)
        .accessibilityLabel("Tabs")
        .accessibilityValue("\(model.tabs.count) open")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch torState {
        case .failed(let reason):
            ConnectionFailedView(reason: reason) { await onRetryConnection() }
        case .off, .starting:
            BootstrapView(state: torState)
        case .running, .stopping:
            browsingContent
        }
    }

    @ViewBuilder
    private var browsingContent: some View {
        if let tab = model.activeTab, tab.url != nil, let webView = model.webView(for: tab) {
            WebCanvas(webView: webView)
                .id(tab.id)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    if case .failed = tab.loadState, tab.securityLevelOverride == nil,
                       model.settings.securityLevel == .safest {
                        javaScriptEscapeHatch
                    }
                }
        } else {
            ScrollView {
                StartPage(
                    circuitSummary: circuitSummary,
                    isConnected: torState.canCarryTraffic,
                    favourites: favourites,
                    onOpen: { model.open(url: $0.url) },
                    onAdd: onAddFavourite
                )
                .padding(.bottom, 120)
            }
            .scrollContentBackground(.hidden)
        }
    }

    /// Offered only when Safest is on and a page failed — the most likely cause
    /// is JavaScript being off, and the fix should be one tap and site-scoped.
    private var javaScriptEscapeHatch: some View {
        VStack(spacing: 8) {
            Text("This site may need JavaScript, which Safest turns off.")
                .font(Typography.detail)
                .foregroundStyle(Palette.ash)
                .multilineTextAlignment(.center)
            TerminalButton("ALLOW FOR THIS SITE") {
                model.allowJavaScriptForActiveTab()
            }
        }
        .padding(16)
        .glassPanel(cornerRadius: Metrics.cardRadius)
        .padding(Metrics.gutter)
        .padding(.bottom, 90)
    }
}

/// Shown while Tor is bootstrapping. The kill switch means nothing loads until
/// this finishes, so the wait has to be legible rather than a blank page.
struct BootstrapView: View {
    var state: TorRuntimeState

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("CONNECTING TO TOR")
                .font(Typography.kicker)
                .tracking(3)
                .foregroundStyle(Palette.arterialSoft)

            ProgressView(value: Double(state.progress), total: 100)
                .progressViewStyle(.linear)
                .tint(Palette.arterial)
                .frame(maxWidth: 260)

            Text("\(state.progress)%")
                .font(Typography.metric)
                .foregroundStyle(Palette.bone)
                .monospacedDigit()
                .contentTransition(.numericText())

            Text("Nothing will load until the circuit is up. That is deliberate — a request sent before Tor is ready would go out over your ordinary connection.")
                .font(Typography.detail)
                .foregroundStyle(Palette.ash)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.horizontal, Metrics.gutter)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connecting to Tor, \(state.progress) percent")
    }
}

/// Shown when bootstrap failed outright.
struct ConnectionFailedView: View {
    var reason: String
    var retry: () async -> Void

    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.arterialSoft)
            Text("Could not connect to Tor")
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.bone)
            Text("If Tor is blocked on this network, turn on bridges in Settings. Nothing has been sent outside Tor.")
                .font(Typography.detail)
                .foregroundStyle(Palette.ash)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Text(reason)
                .font(Typography.dataSmall)
                .foregroundStyle(Palette.ash.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, Metrics.gutter)

            TerminalButton(isRetrying ? "RETRYING…" : "TRY AGAIN", emphasis: .solid) {
                guard !isRetrying else { return }
                isRetrying = true
                Task {
                    await retry()
                    isRetrying = false
                }
            }
            .frame(maxWidth: 240)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
