import Domain
import DesignSystem
import SwiftUI

/// The adaptive shell.
///
/// The browser is the root of the app. On a phone that is the whole shell: one
/// row of chrome above the page and one bar of browsing controls below it, with
/// Favourites, the Monitor and Settings presented from the overflow menu as the
/// occasional destinations they are. On an iPad the sidebar shows those
/// destinations permanently, because there is room for them.
///
/// Both shells bind to the *same* view models, so behaviour is identical and
/// only the chrome differs.
public struct RootShell: View {
    @Bindable var model: AppModel

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    /// Owned here rather than left to `NavigationSplitView`, so the sidebar can
    /// be toggled from our own chrome instead of from a navigation bar sitting
    /// above it.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isShowingTabs = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if sizeClass == .compact {
                compactShell
            } else {
                regularShell
            }
        }
        .tint(Palette.arterialSoft)
        .preferredColorScheme(.dark)
        .toast($model.toast)
        .sheet(isPresented: $isShowingTabs) {
            TabOverview(model: model.browser)
        }
        .sheet(item: $model.presentedSection) { section in
            destinationSheet(section)
        }
        .privacyShield(
            isObscured: model.isObscured,
            isEnabled: model.settings.settings.hideInAppSwitcher
        )
        .overlay {
            if model.lock.isLocked {
                LockScreen(
                    biometryName: model.lock.biometryName,
                    errorMessage: model.lock.lastError
                ) {
                    await model.lock.authenticate()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.lock.isLocked)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            model.handle(scenePhase: phase)
        }
    }

    // MARK: - Compact (iPhone)

    private var compactShell: some View {
        ZStack(alignment: .bottom) {
            ShallotBackdrop(isPaused: model.isObscured, isSubdued: isBackdropCovered)

            browser
                // The bar floats over the page, so the page has to end above it
                // rather than behind it.
                .safeAreaPadding(.bottom, isToolbarVisible ? 72 : 6)

            BrowserToolbar(model: model.browser) { isShowingTabs = true }
                .padding(.bottom, 10)
                // Slides away with the rest of the chrome while a page is being
                // read, and comes straight back on the way up.
                .offset(y: isToolbarVisible ? 0 : 130)
                .opacity(isToolbarVisible ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.22), value: isToolbarVisible)
    }

    /// The bar hides only while a page is being scrolled.
    private var isToolbarVisible: Bool { model.browser.isChromeVisible }

    /// Whether a web page is covering the backdrop.
    ///
    /// Only the browser can cover it — the other screens are translucent and
    /// the rain reads through them, which is the whole visual idea.
    private var isBackdropCovered: Bool {
        model.section == .browser
            && model.presentedSection == nil
            && model.browser.isShowingWebContent
    }

    // MARK: - Regular (iPad, iPhone landscape)

    private var regularShell: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            ZStack(alignment: .bottom) {
                ShallotBackdrop(isPaused: model.isObscured, isSubdued: isBackdropCovered)

                screen
                    .safeAreaPadding(.bottom, model.section == .browser && isToolbarVisible ? 72 : 6)

                if model.section == .browser {
                    BrowserToolbar(model: model.browser) { isShowingTabs = true }
                        .padding(.bottom, 10)
                        .offset(y: isToolbarVisible ? 0 : 130)
                        .opacity(isToolbarVisible ? 1 : 0)
                }
            }
            .animation(.easeOut(duration: 0.22), value: isToolbarVisible)
            // Hiding the detail's navigation bar is what keeps the iPad to a
            // single row of chrome; the toggle it would have held is published
            // below and drawn inline by whichever screen is on show.
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.sidebarControl, sidebarControl)
    }

    /// The sidebar control handed to whichever screen is on show.
    ///
    /// Always present on this shell, because hiding the split view's own
    /// navigation bar removed the only other way to collapse the sidebar and
    /// give a page the full width.
    private var sidebarControl: SidebarControl {
        SidebarControl(isVisible: columnVisibility == .all) {
            withAnimation(.easeInOut(duration: 0.22)) {
                columnVisibility = columnVisibility == .all ? .detailOnly : .all
            }
        }
    }

    private var sidebar: some View {
        List(
            selection: Binding<AppSection?>(
                get: { model.section },
                set: { if let new = $0 { model.section = new } }
            )
        ) {
            Text("SHALLOT")
                .font(Typography.data)
                .tracking(4)
                .foregroundStyle(Palette.arterialSoft)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityAddTraits(.isHeader)

            Section {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                        .accessibilityHint(section.accessibilityHint)
                }
            }

            Section("Open tabs") {
                ForEach(model.browser.tabs) { tab in
                    Button {
                        model.browser.selectTab(tab.id)
                        model.section = .browser
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tab.title.isEmpty ? (tab.url?.host() ?? "New tab") : tab.title)
                                .font(Typography.body)
                                .lineLimit(1)
                            if let port = tab.socksPort {
                                Text("circuit :\(String(port))")
                                    .font(Typography.dataSmall)
                                    .foregroundStyle(Palette.ash)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Switch to this tab")
                }

                Button {
                    model.browser.newTab()
                    model.section = .browser
                } label: {
                    Label("New tab", systemImage: "plus")
                }
                .accessibilityLabel("New tab")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Palette.void.opacity(0.4))
        // The sidebar's own navigation bar is hidden too. It held a second copy
        // of the sidebar toggle — two controls doing one job — and its title is
        // better said once, inside the list.
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Screens

    @ViewBuilder
    private var screen: some View {
        switch model.section {
        case .browser: browser
        case .favourites: FavouritesView(model: model.favourites)
        case .monitor: MonitorView(model: model.monitor)
        case .settings: settingsScreen
        }
    }

    private var browser: some View {
        BrowserView(
            model: model.browser,
            torState: model.torState,
            circuitSummary: circuitSummary,
            favourites: model.favourites.favourites,
            onNewIdentity: { await model.newIdentity() },
            onShowSection: { model.show($0, isCompact: sizeClass == .compact) },
            onRetryConnection: { await model.retryConnection() },
            canRetryConnection: model.canRetryConnection
        )
    }

    private var settingsScreen: some View {
        SettingsView(
            model: model.settings,
            biometryName: model.lock.biometryName,
            isBiometryAvailable: model.lock.isAvailable
        )
    }

    /// A destination presented over the browser on a phone.
    private func destinationSheet(_ section: AppSection) -> some View {
        NavigationStack {
            ZStack {
                ShallotBackdrop(isPaused: true)
                switch section {
                case .favourites: FavouritesView(model: model.favourites)
                case .monitor: MonitorView(model: model.monitor)
                case .settings: settingsScreen
                case .browser: EmptyView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.presentedSection = nil }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    /// The one-line circuit description on the start page.
    private var circuitSummary: String {
        let path = model.monitor.path
        guard !path.isEmpty else {
            return model.torState.canCarryTraffic ? "BUILDING CIRCUIT" : model.torState.label
        }
        let hops = path.map { $0.countryCode ?? "··" }.joined(separator: " → ")
        return "CIRCUIT · \(hops)"
    }
}
