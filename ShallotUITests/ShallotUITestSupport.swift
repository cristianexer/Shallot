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
    /// and the wordmark is asserted separately. That control is the overflow
    /// menu — new identity, favourites and the security level moved inside it
    /// when the chrome was reduced to a single row.
    var landmark: (type: XCUIElement.ElementType, label: String) {
        switch self {
        case .browse: (.button, "More")
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
    /// The sidebar row for `section`, on the shell that has a sidebar.
    ///
    /// The phone has no permanent section control at all any more: the browser
    /// is the root of the app and the other three are reached from the
    /// overflow menu, so `show(_:)` opens that menu instead.
    @MainActor
    func sectionControl(_ section: ShallotSection) -> XCUIElement {
        let title = section.rawValue
        for candidate in [cells[title], buttons[title], staticTexts[title]] where candidate.exists {
            return candidate
        }
        return usesSplitViewShell ? cells[title] : buttons[title]
    }

    /// Waits for the shell to be up.
    ///
    /// The overflow menu is the one control present on every shell and every
    /// screen, so it is the landmark for "the app has launched".
    @MainActor
    func waitForShell(timeout: TimeInterval = Timeout.element) -> Bool {
        if buttons["More"].waitForExistence(timeout: Timeout.brief) { return true }
        // The split view can still start collapsed — a narrower window, or a
        // different iPadOS default — so ask for the sidebar before giving up.
        revealSidebarIfNeeded()
        return buttons["More"].waitForExistence(timeout: timeout)
    }

    /// Taps the sidebar control, but only when it would *reveal* the sidebar.
    ///
    /// The control is inline in the app's own chrome and toggles both ways, so
    /// matching on "sidebar" alone would cheerfully hide a sidebar that was
    /// already there.
    @discardableResult
    @MainActor
    func revealSidebarIfNeeded() -> Bool {
        let toggle = buttons["Show Sidebar"]
        guard toggle.waitForExistence(timeout: Timeout.brief), toggle.isHittable else { return false }
        toggle.tap()
        return true
    }

    /// Moves to `section` and waits for its landmark.
    ///
    /// Two different journeys, because the shells are different apps in this
    /// respect: the iPad selects a sidebar row, the phone opens the overflow
    /// menu and presents the destination over the browser.
    @MainActor
    func show(
        _ section: ShallotSection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if section == .browse {
            dismissDestinationIfPresented()
        } else if usesSplitViewShell {
            var control = sectionControl(section)
            if !control.waitForExistence(timeout: Timeout.brief) {
                // The sidebar may have collapsed itself — after a rotation, or
                // on a narrower split-view window.
                revealSidebarIfNeeded()
                control = sectionControl(section)
            }
            guard control.waitForExistence(timeout: Timeout.element) else {
                XCTFail("No sidebar row for \(section.rawValue).", file: file, line: line)
                return
            }
            control.tap()
        } else {
            dismissDestinationIfPresented()
            let menu = buttons["More"]
            guard menu.waitForExistence(timeout: Timeout.element) else {
                XCTFail("The overflow menu never appeared.", file: file, line: line)
                return
            }
            menu.tap()
            let item = buttons[section.rawValue]
            guard item.waitForExistence(timeout: Timeout.transition) else {
                XCTFail("No menu item for \(section.rawValue).", file: file, line: line)
                return
            }
            item.tap()
        }

        let landmark = element(section.landmark.type, labelled: section.landmark.label)
        XCTAssertTrue(
            landmark.waitForExistence(timeout: Timeout.transition),
            "The \(section.rawValue) screen never appeared.",
            file: file,
            line: line
        )
    }

    /// Closes a destination presented over the browser, if one is up.
    @MainActor
    func dismissDestinationIfPresented() {
        let done = buttons["Done"]
        guard done.exists, done.isHittable else { return }
        done.tap()
        _ = buttons["More"].waitForExistence(timeout: Timeout.transition)
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
