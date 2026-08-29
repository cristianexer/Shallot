import Domain
import DesignSystem
import SwiftUI

/// The browser screen: one row of chrome over the page, and nothing else.
///
/// The chrome gets out of the way while you read — scrolling down slides the
/// address bar and the tab bar off screen, scrolling up brings them back — so
/// a long article gets the whole display.
public struct BrowserView: View {
    @Bindable var model: BrowserViewModel
    var torState: TorRuntimeState
    var circuitSummary: String
    var favourites: [Favourite]
    var onNewIdentity: () async -> Void
    var onAddFavourite: () -> Void
    var onRetryConnection: () async -> Void
    var canRetryConnection: Bool

    @State private var isShowingTabs = false

    public init(
        model: BrowserViewModel,
        torState: TorRuntimeState,
        circuitSummary: String,
        favourites: [Favourite],
        onNewIdentity: @escaping () async -> Void,
        onAddFavourite: @escaping () -> Void,
        onRetryConnection: @escaping () async -> Void,
        canRetryConnection: Bool = true
    ) {
        self.model = model
        self.torState = torState
        self.circuitSummary = circuitSummary
        self.favourites = favourites
        self.onNewIdentity = onNewIdentity
        self.onAddFavourite = onAddFavourite
        self.onRetryConnection = onRetryConnection
        self.canRetryConnection = canRetryConnection
    }

    public var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .sheet(isPresented: $isShowingTabs) { TabOverview(model: model) }
            .task { await model.onAppear() }
    }

    // MARK: - Header

    private var header: some View {
        OmniBar(
            model: model,
            torState: torState,
            onNewIdentity: { Task { await onNewIdentity() } },
            onShowTabs: { isShowingTabs = true }
        )
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // No gradient wash and no material slab behind the bar: the pill is
        // already glass, and the rain reading through the gap is the whole
        // visual idea.
        .background(alignment: .bottom) {
            Rectangle()
                .fill(Palette.edge.opacity(model.isChromeVisible ? 0.35 : 0))
                .frame(height: Metrics.hairline)
        }
        .offset(y: model.isChromeVisible ? 0 : -120)
        .opacity(model.isChromeVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.22), value: model.isChromeVisible)
        // Tapping the sliver of screen the collapsed bar leaves brings it back,
        // so the chrome is never more than one tap away.
        .accessibilityElement(children: .contain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch torState {
        case .failed(let reason):
            ConnectionFailedView(reason: reason, canRetry: canRetryConnection) {
                await onRetryConnection()
            }
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
                .padding(.bottom, 110)
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
        VStack(spacing: 16) {
            Spacer()
            Text("CONNECTING TO TOR")
                .font(Typography.kicker)
                .tracking(3)
                .foregroundStyle(Palette.arterialSoft)

            ProgressView(value: Double(state.progress), total: 100)
                .progressViewStyle(.linear)
                .tint(Palette.arterial)
                .frame(maxWidth: 240)

            Text("\(state.progress)%")
                .font(Typography.metric)
                .foregroundStyle(Palette.bone)
                .monospacedDigit()
                .contentTransition(.numericText())

            Text("Nothing loads until the circuit is up. A request sent before Tor is ready would go out over your ordinary connection.")
                .font(Typography.detail)
                .foregroundStyle(Palette.ash)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
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
    /// The embedded Tor cannot be launched twice in one process, so a second
    /// attempt is offered only when one can actually be made.
    var canRetry: Bool
    var retry: () async -> Void

    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.arterialSoft)
            Text("Could not connect to Tor")
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.bone)
            Text("If Tor is blocked on this network, turn on bridges in Settings. Nothing has been sent outside Tor.")
                .font(Typography.detail)
                .foregroundStyle(Palette.ash)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Text(reason)
                .font(Typography.dataSmall)
                .foregroundStyle(Palette.ash.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, Metrics.gutter)

            if canRetry {
                TerminalButton(isRetrying ? "RETRYING…" : "TRY AGAIN", emphasis: .solid) {
                    guard !isRetrying else { return }
                    isRetrying = true
                    Task {
                        await retry()
                        isRetrying = false
                    }
                }
                .frame(maxWidth: 240)
            } else {
                Text("Quit Shallot and open it again to try once more.")
                    .font(Typography.detail)
                    .foregroundStyle(Palette.arterialSoft)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
