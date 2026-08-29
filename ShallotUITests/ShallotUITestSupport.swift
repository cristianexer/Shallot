import UIKit
import XCTest

// Shared plumbing for the Shallot UI suite.
//
// Two things every test here needs. First, a hermetic launch: the app looks for
// `--shallot-ui-testing` and swaps in an in-memory store and a scripted Tor, so
// no test waits on a real circuit or inherits a previous run's favourites.
// Second, a way to reach the four sections in *both* shells — the phone's
// floating tab bar and the iPad's `NavigationSplitView` sidebar are different
// controls with the same accessibility labels, which is the only handle a test
// has because the phone chrome is icon-only.

// MARK: - Timeouts

/// Generous enough for a cold launch on a loaded machine, bounded so a broken
/// build fails rather than hangs. Nothing in this suite ever sleeps blindly.
enum Timeout {
    static let launch: TimeInterval = 60
    static let element: TimeInterval = 15
    static let transition: TimeInterval = 10
    static let brief: TimeInterval = 5
}

// MARK: - Sections

/// The four top-level destinations, named by the label the app exposes.
///
/// `AppSection.title` supplies the VoiceOver label on the icon-only tab bar and
/// the row text in the iPad sidebar, so one string addresses both shells.
enum ShallotSection: String, CaseIterable {
    case browse = "Browse"
    case favourites = "Favourites"
    case monitor = "Monitor"
    case settings = "Settings"

    /// A landmark that is present on this screen and nowhere else, used to
    /// prove a navigation actually landed.
    ///
    /// Browse is the odd one out: its wordmark only shows while the start page
    /// is up, so the always-present omnibar control is the reliable landmark
    /// and the wordmark is asserted separately.
    var landmark: (type: XCUIElement.ElementType, label: String) {
        switch self {
        case .browse: (.button, "New identity")
        case .favourites: (.staticText, "FAVOURITES")
        case .monitor: (.staticText, "MONITOR")
        case .settings: (.staticText, "SETTINGS")
        }
    }
}

// MARK: - Launching

/// True when the running simulator uses the regular-width iPad shell.
@MainActor
var usesSplitViewShell: Bool {
    UIDevice.current.userInterfaceIdiom == .pad
}

/// Launches Shallot in its hermetic UI-testing mode and waits for the shell.
@MainActor
func launchShallot(file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
    // Orientation is set *before* the launch on purpose. A
    // `NavigationSplitView(.balanced)` decides its column visibility when the
    // scene first lays out: a scene born in portrait keeps its sidebar hidden
    // behind the Show Sidebar button even after the device is turned. Starting
    // the iPad in landscape gives the permanent sidebar column that the regular
    // shell is designed around, which is the arrangement worth testing.
    XCUIDevice.shared.orientation = usesSplitViewShell ? .landscapeLeft : .portrait

    let app = XCUIApplication()
    // The one argument that matters: in-memory storage and a scripted Tor.
    app.launchArguments += ["--shallot-ui-testing"]
    app.launch()

    XCTAssertTrue(
        app.wait(for: .runningForeground, timeout: Timeout.launch),
        "Shallot never reached the foreground.",
        file: file,
        line: line
    )

    XCTAssertTrue(
        app.waitForShell(),
        "The app shell never appeared — no section control could be found.",
        file: file,
        line: line
    )
    return app
}

// MARK: - Navigation

extension XCUIApplication {
    /// The tab-bar button (compact) or sidebar row (regular) for `section`.
    ///
    /// The compact bar exposes buttons; the sidebar exposes list cells. Both
    /// carry the same label, so the type is whatever is on screen.
    @MainActor
    func sectionControl(_ section: ShallotSection) -> XCUIElement {
        let title = section.rawValue
        for candidate in [buttons[title], cells[title], staticTexts[title]] where candidate.exists {
            return candidate
        }
        // Nothing has resolved yet. Hand back whichever this shell will use, so
        // the caller can wait on it.
        return usesSplitViewShell ? cells[title] : buttons[title]
    }

    /// Waits for either shell's section controls to be on screen.
    @MainActor
    func waitForShell(timeout: TimeInterval = Timeout.element) -> Bool {
        if sectionControl(.browse).waitForExistence(timeout: Timeout.brief) { return true }
        // The split view can still start collapsed — a narrower window, or a
        // different iPadOS default — so ask for the sidebar before giving up.
        revealSidebarIfNeeded()
        return sectionControl(.browse).waitForExistence(timeout: timeout)
    }

    /// Taps the split view's sidebar toggle, if one is on screen.
    @discardableResult
    @MainActor
    func revealSidebarIfNeeded() -> Bool {
        let toggle = buttons
            .matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'"))
            .firstMatch
        guard toggle.waitForExistence(timeout: Timeout.brief), toggle.isHittable else { return false }
        toggle.tap()
        return true
    }

    /// Moves to `section` and waits for its landmark.
    @MainActor
    func show(
        _ section: ShallotSection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var control = sectionControl(section)
        if !control.waitForExistence(timeout: Timeout.brief) {
            // The sidebar may have collapsed itself — for instance after a
            // rotation, or on a narrower split-view window.
            revealSidebarIfNeeded()
            control = sectionControl(section)
        }
        guard control.waitForExistence(timeout: Timeout.element) else {
            XCTFail("No control for the \(section.rawValue) section.", file: file, line: line)
            return
        }
        control.tap()

        let landmark = element(section.landmark.type, labelled: section.landmark.label)
        XCTAssertTrue(
            landmark.waitForExistence(timeout: Timeout.transition),
            "The \(section.rawValue) screen never appeared.",
            file: file,
            line: line
        )
    }

    /// The first element of `type` whose accessibility label is exactly `label`.
    ///
    /// Several controls here are addressed by label rather than identifier
    /// because the app is deliberately icon-only in places — the VoiceOver
    /// label *is* the name of the control.
    @MainActor
    func element(_ type: XCUIElement.ElementType, labelled label: String) -> XCUIElement {
        descendants(matching: type)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    /// Every element of `type` carrying `label`, in hierarchy order.
    @MainActor
    func elements(_ type: XCUIElement.ElementType, labelled label: String) -> XCUIElementQuery {
        descendants(matching: type).matching(NSPredicate(format: "label == %@", label))
    }
}

// MARK: - Waiting and scrolling

/// Polls `condition` until it holds or `timeout` elapses.
///
/// Bounded by construction, so a test can fail but never hang.
@MainActor
@discardableResult
func waitUntil(
    _ description: String,
    timeout: TimeInterval = Timeout.element,
    diagnostic: () -> String = { "" },
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }
    if condition() { return true }
    let extra = diagnostic()
    XCTFail(
        "Timed out after \(timeout)s waiting until \(description)."
            + (extra.isEmpty ? "" : " \(extra)"),
        file: file,
        line: line
    )
    return false
}

/// Taps `element` and waits for `condition`, trying twice before failing.
///
/// A tap that lands while a screen is still settling — the iPad's detail column
/// swapping in, a scroll view still decelerating — is occasionally dropped
/// before SwiftUI has installed the gesture. The second attempt separates that
/// from a control that genuinely does nothing, which fails both times.
@MainActor
@discardableResult
func tap(
    _ element: XCUIElement,
    attempts: Int = 2,
    timeout: TimeInterval = Timeout.brief,
    file: StaticString = #filePath,
    line: UInt = #line,
    until condition: () -> Bool
) -> Bool {
    for _ in 0..<attempts {
        element.tap()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
    }
    XCTFail("The control did not respond to \(attempts) taps.", file: file, line: line)
    return false
}

extension XCUIApplication {
    /// Scrolls the frontmost scroll view until `element` can be tapped.
    ///
    /// Settings and Favourites are long scrolling screens; on a phone the row a
    /// test wants is often below the fold.
    @MainActor
    @discardableResult
    func scrollUntilHittable(
        _ element: XCUIElement,
        maxSwipes: Int = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        if element.exists, element.isHittable { return true }
        let scroller: XCUIElement = scrollViews.firstMatch.exists ? scrollViews.firstMatch : self
        for _ in 0..<maxSwipes {
            scroller.swipeUp()
            if element.exists, element.isHittable { return true }
        }
        XCTFail("Could not bring the element into view after \(maxSwipes) swipes.", file: file, line: line)
        return false
    }
}

// MARK: - Fixtures

enum Fixture {
    /// A syntactically valid v3 onion address: 56 base32 characters plus the
    /// suffix. Nothing ever connects to it — the app only has to accept it.
    static let onionAddress = "shallottestonionaddressforuitestsuiteexampleaddress23456.onion"

    /// Refused by `OnionAddress.isValidV3`, so the app declines to load it.
    static let malformedOnionAddress = "definitely-not-valid.onion"
}
