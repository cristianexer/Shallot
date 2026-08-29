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
        app.tapAddTabButton()

        // Adding dismisses the sheet, so the count is read back from the
        // toolbar button's accessibility value.
        XCTAssertTrue(
            waitUntil("the tab count reaches two") { app.tabCountDescription == "2 open" },
            "Adding a tab should be reflected in the tabs button. Was \(app.tabCountDescription ?? "nil")."
        )
    }

    @MainActor
    func testClosingATabFromTheOverviewUpdatesTheTabCount() {
        let app = launchShallot()

        app.openTabOverview()
        app.tapAddTabButton()
        XCTAssertTrue(waitUntil("the tab count reaches two") { app.tabCountDescription == "2 open" })

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
            "Closing a tab should be reflected in the tabs button. Was \(app.tabCountDescription ?? "nil")."
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

    /// Taps the overview's "New tab" button.
    ///
    /// The label is not unique: a tab with no page yet is also announced as
    /// "New tab", and the iPad sidebar carries one too. The overview's add
    /// button is the last of them in the hierarchy — it sits below the rows,
    /// inside the most recently presented view — and if that ever stopped
    /// holding, the tab-count assertion in the caller would catch the mis-tap.
    @MainActor
    func tapAddTabButton(file: StaticString = #filePath, line: UInt = #line) {
        let candidates = elements(.button, labelled: "New tab")
        guard candidates.count > 0 else {
            XCTFail("No New tab button in the overview.", file: file, line: line)
            return
        }
        candidates.element(boundBy: candidates.count - 1).tap()
    }
}
