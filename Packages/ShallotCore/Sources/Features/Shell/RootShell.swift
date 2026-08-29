
import Domain
import DesignSystem
import SwiftUI

/// The adaptive shell. Both layouts bind to the *same* view models, so
/// behaviour is identical on iPhone and iPad and only the chrome differs.
public struct RootShell: View {
    @Bindable var model: AppModel

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

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

    // MARK: - Compact (iPhone portrait)

    private var compactShell: some View {
        ZStack(alignment: .bottom) {
            ShallotBackdrop(isPaused: model.isObscured)

            screen
                // The bar floats over the content, so content has to end above
                // it rather than behind it.
                .safeAreaPadding(.bottom, isTabBarVisible ? 76 : 8)

            AppTabBar(selection: $model.section)
                .padding(.bottom, 12)
                // Slides away with the rest of the chrome while a page is being
                // scrolled, and comes straight back on the way up.
                .offset(y: isTabBarVisible ? 0 : 130)
                .opacity(isTabBarVisible ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.22), value: isTabBarVisible)
    }

    /// The tab bar only ever hides on the browser, and only while a page is
    /// being read — the list screens keep it, because there is nothing there
    /// worth surrendering the navigation for.
    private var isTabBarVisible: Bool {
        model.section != .browser || model.browser.isChromeVisible
    }

    // MARK: - Regular (iPad, iPhone landscape)

    private var regularShell: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // The backdrop belongs *inside* the detail pane on this shell.
            // `NavigationSplitView` paints its own opaque background, so a
            // backdrop behind the whole split view is simply covered up and
            // the rain never appears next to the page.
            ZStack {
                ShallotBackdrop(isPaused: model.isObscured)
                screen
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        // `List` wants an optional selection binding; the app always has a
        // section, so a nil write is simply ignored.
        List(
            selection: Binding<AppSection?>(
                get: { model.section },
                set: { if let new = $0 { model.section = new } }
            )
        ) {
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
        .navigationTitle("Shallot")
    }

    // MARK: - Screens

    @ViewBuilder
    private var screen: some View {
        switch model.section {
        case .browser:
            BrowserView(
                model: model.browser,
                torState: model.torState,
                circuitSummary: circuitSummary,
                favourites: model.favourites.favourites,
                onNewIdentity: { await model.newIdentity() },
                onAddFavourite: {
                    model.section = .favourites
                    model.favourites.beginAdding()
                },
                onRetryConnection: { await model.retryConnection() },
                canRetryConnection: model.canRetryConnection
            )
        case .favourites:
            FavouritesView(model: model.favourites)
        case .monitor:
            MonitorView(model: model.monitor)
        case .settings:
            SettingsView(
                model: model.settings,
                biometryName: model.lock.biometryName,
                isBiometryAvailable: model.lock.isAvailable
            )
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
