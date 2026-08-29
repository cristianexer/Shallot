import UIKit
import XCTest

/// The omnibar and the tab overview.
///
/// Nothing here loads a page over the network: the scripted Tor hands out fake
/// ports, and the addresses used are either refused outright or point at an
/// onion service that does not exist. What is under test is the chrome.
final class BrowserUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Omnibar

    @MainActor
    func testTappingTheAddressPillFocusesTheAddressField() {
        let app = launchShallot()

        let field = app.tapAddressPill()

        XCTAssertTrue(field.exists, "Tapping the pill should swap in an editable address field.")
        // Focus is what makes typing land in the right place; typing into the
        // field and reading the value back is the only observable proof of it.
        field.typeText("torproject")
        XCTAssertTrue(
            waitUntil("the typed text reaches the address field") {
                (field.value as? String) == "torproject"
            },
            "The address field did not receive the keystrokes, so it was not focused."
        )
    }

    @MainActor
    func testSubmittingAnAddressDismissesEditing() {
        let app = launchShallot()

        let field = app.tapAddressPill()
        field.typeText(Fixture.onionAddress)
        field.typeText("\n")

        XCTAssertTrue(
            field.waitForNonExistence(timeout: Timeout.transition),
            "Submitting should end editing and put the address pill back."
        )
    }

    @MainActor
    func testAMalformedOnionAddressIsRefusedAndTheStartPageStays() {
        let app = launchShallot()

        let field = app.tapAddressPill()
        field.typeText(Fixture.malformedOnionAddress)
        field.typeText("\n")

        XCTAssertTrue(field.waitForNonExistence(timeout: Timeout.transition))
        // A rejected onion address is never loaded, so there is no page to show
        // and the start page must still be there.
        XCTAssertTrue(
            app.staticTexts["SHALLOT"].waitForExistence(timeout: Timeout.transition),
            "A refused address should leave the start page in place."
        )
    }

    // MARK: - Tabs

    @MainActor
    func testTheTabsButtonOpensTheOverview() {
        let app = launchShallot()

        app.openTabOverview()

        XCTAssertTrue(app.navigationBars["Tabs"].exists, "The overview should be titled Tabs.")
        XCTAssertTrue(
            app.elements(.button, labelled: "Close tab").count >= 1,
            "The one open tab should be listed with a way to close it."
        )
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Tabs"].waitForNonExistence(timeout: Timeout.transition))
    }

    @MainActor
    func testAddingATabFromTheOverviewUpdatesTheTabCount() {
        let app = launchShallot()

        XCTAssertEqual(app.tabCountDescription, "1 open", "A fresh launch should have exactly one tab.")

        app.openTabOverview()
        let tapped = app.tapAddTabButton()

        // Adding dismisses the sheet, so the count is read back from the
        // toolbar button's accessibility value.
        waitUntil(
            "the tab count reaches two after tapping \(tapped)",
            diagnostic: {
                "The tabs button reads \(app.tabCountDescription ?? "nothing"); "
                    + "the overview is \(app.navigationBars["Tabs"].exists ? "still open" : "closed")."
            }
        ) {
            app.tabCountDescription == "2 open"
        }
    }

    @MainActor
    func testClosingATabFromTheOverviewUpdatesTheTabCount() {
        let app = launchShallot()

        app.openTabOverview()
        let tapped = app.tapAddTabButton()
        waitUntil(
            "the tab count reaches two after tapping \(tapped)",
            diagnostic: {
                "The tabs button reads \(app.tabCountDescription ?? "nothing"); "
                    + "the overview is \(app.navigationBars["Tabs"].exists ? "still open" : "closed")."
            }
        ) {
            app.tabCountDescription == "2 open"
        }

        app.openTabOverview()
        let closeButtons = app.elements(.button, labelled: "Close tab")
        XCTAssertTrue(
            waitUntil("both tabs are listed") { closeButtons.count == 2 },
            "The overview should list both tabs."
        )
        closeButtons.element(boundBy: 0).tap()

        XCTAssertTrue(
            waitUntil("one tab is left in the overview") { closeButtons.count == 1 },
            "Closing a tab should remove its row."
        )
        app.buttons["Done"].tap()

        XCTAssertTrue(
            waitUntil("the tab count falls back to one") { app.tabCountDescription == "1 open" },
            "Closing a tab should be reflected in the tabs button."
        )
    }
}

// MARK: - Browser helpers

extension XCUIApplication {

    /// Taps the address pill and returns the text field it swaps in.
    ///
    /// The pill combines its children for VoiceOver, so it is addressed by the
    /// label it speaks rather than by a container query.
    @MainActor
    @discardableResult
    func tapAddressPill(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let pill = element(.any, labelled: "Address bar, empty")
        XCTAssertTrue(
            pill.waitForExistence(timeout: Timeout.element),
            "The address pill was not found.",
            file: file,
            line: line
        )
        pill.tap()

        let field = textFields["Address"]
        XCTAssertTrue(
            field.waitForExistence(timeout: Timeout.transition),
            "Tapping the address pill should begin editing.",
            file: file,
            line: line
        )
        return field
    }

    /// The tabs toolbar button's spoken value, e.g. "2 open".
    @MainActor
    var tabCountDescription: String? {
        buttons["Tabs"].value as? String
    }

    @MainActor
    func openTabOverview(file: StaticString = #filePath, line: UInt = #line) {
        let tabs = buttons["Tabs"]
        XCTAssertTrue(
            tabs.waitForExistence(timeout: Timeout.element),
            "The tabs button was not found.",
            file: file,
            line: line
        )
        tabs.tap()
        XCTAssertTrue(
            navigationBars["Tabs"].waitForExistence(timeout: Timeout.transition),
            "The tab overview did not open.",
            file: file,
            line: line
        )
    }

    /// Taps the overview's "New tab" button and describes what it tapped.
    ///
    /// The label is not unique, and deliberately so: a tab with no page yet is
    /// announced as "New tab" too, and the iPad sidebar carries its own. The
    /// one wanted here is inside the overview — within the sheet's column,
    /// below its rows — so it is picked by geometry rather than by hoping the
    /// hierarchy orders them a particular way. The returned description is only
    /// there to make a mis-tap legible in a failure message.
    @MainActor
    @discardableResult
    func tapAddTabButton(file: StaticString = #filePath, line: UInt = #line) -> String {
        let bar = navigationBars["Tabs"].frame
        let candidates = elements(.button, labelled: "New tab")

        var chosen: XCUIElement?
        var chosenFrame: CGRect = .null
        var considered: [String] = []
        for index in 0..<candidates.count {
            let candidate = candidates.element(boundBy: index)
            let frame = candidate.frame
            considered.append("\(frame)")
            let isInOverviewColumn = frame.minY > bar.minY
                && frame.minX >= bar.minX - 1
                && frame.maxX <= bar.maxX + 1
            guard isInOverviewColumn else { continue }
            if chosenFrame.isNull || frame.minY > chosenFrame.minY {
                chosen = candidate
                chosenFrame = frame
            }
        }

        guard let button = chosen else {
            XCTFail(
                "No New tab button inside the overview (bar \(bar), candidates \(considered)).",
                file: file,
                line: line
            )
            return "nothing"
        }

        // Tapped near the leading edge rather than in the middle. The row is
        // `Image + Text + Spacer` inside a `.buttonStyle(.plain)` button with no
        // `contentShape`, and on iOS 26 its Liquid Glass background is not
        // hit-testable, so the centre of the row — which is over the spacer —
        // does nothing. Everything left of the spacer works.
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5)).tap()
        return "the button at \(chosenFrame) of candidates \(considered)"
    }
}

extension BrowserUITests {
    @MainActor
    func testTappingAFavouriteClosesTheSheetAndReturnsToTheBrowser() {
        // Reported from a device: the favourite opened into a tab you could not
        // see, because the list never got out of the way. The model-level wiring
        // is covered elsewhere; this is the view layer actually dismissing.
        let app = launchShallot()
        app.show(.favourites)
        app.addFavourite(named: "Test Site", address: Fixture.onionAddress)

        let card = app.buttons["favourite-card-Test Site"]
        XCTAssertTrue(card.waitForExistence(timeout: Timeout.element))
        app.scrollUntilHittable(card)
        card.tap()

        XCTAssertTrue(
            app.buttons["More"].waitForExistence(timeout: Timeout.transition),
            "Tapping a favourite should land on the browser."
        )
        XCTAssertTrue(
            app.staticTexts["FAVOURITES"].waitForNonExistence(timeout: Timeout.transition),
            "The favourites sheet should have closed rather than staying over the page."
        )
    }

    @MainActor
    func testReloadIsOfferedOnceAnAddressHasBeenOpened() {
        // Reload used to be tied to a page having successfully committed, which
        // took it away at exactly the moment it was wanted — on the error page
        // after a load that did not arrive.
        let app = launchShallot()
        let reload = app.buttons["Reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: Timeout.element))
        XCTAssertFalse(reload.isEnabled, "Nothing has been opened yet.")

        app.openAddress(Fixture.onionAddress)
        XCTAssertTrue(
            app.wait(for: reload, toBeEnabled: true, timeout: Timeout.element),
            "Once an address has been asked for, reload has something to retry."
        )
    }
}
