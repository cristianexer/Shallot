import XCTest

/// The shell: reaching all four sections and coming back.
///
/// The same tests run against both shells — the phone's floating tab bar and
/// the iPad's split-view sidebar — because `sectionControl(_:)` resolves
/// whichever is on screen. That is the point: the two layouts are supposed to
/// be interchangeable, and a test that assumed the phone would never notice if
/// the iPad sidebar stopped switching sections.
final class NavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBrowseIsTheSectionShownOnLaunch() {
        let app = launchShallot()

        XCTAssertTrue(
            app.staticTexts["SHALLOT"].waitForExistence(timeout: Timeout.element),
            "The start page wordmark should be the first thing on screen."
        )
        XCTAssertTrue(app.buttons["New identity"].exists, "The omnibar should be present on Browse.")
    }

    @MainActor
    func testEverySectionCanBeReachedAndShowsItsOwnScreen() {
        let app = launchShallot()

        app.show(.favourites)
        XCTAssertTrue(app.staticTexts["FAVOURITES"].exists)

        app.show(.monitor)
        XCTAssertTrue(app.staticTexts["MONITOR"].exists)
        XCTAssertFalse(app.staticTexts["FAVOURITES"].exists, "Leaving a section should leave its screen behind.")

        app.show(.settings)
        XCTAssertTrue(app.staticTexts["SETTINGS"].exists)

        app.show(.browse)
        XCTAssertTrue(
            app.staticTexts["SHALLOT"].waitForExistence(timeout: Timeout.transition),
            "Returning to Browse should show the start page again."
        )
    }

    @MainActor
    func testSectionsCanBeVisitedRepeatedlyInAnyOrder() {
        let app = launchShallot()

        for section in [ShallotSection.settings, .browse, .monitor, .favourites, .settings] {
            app.show(section)
        }

        XCTAssertTrue(app.staticTexts["SETTINGS"].exists)
    }

    @MainActor
    func testTheStartPageOffersQuickAccessAndACircuitSummary() {
        let app = launchShallot()

        XCTAssertTrue(app.staticTexts["SHALLOT"].waitForExistence(timeout: Timeout.element))
        XCTAssertTrue(
            app.buttons["Add a favourite"].waitForExistence(timeout: Timeout.transition),
            "Quick access should offer the add tile even with nothing saved."
        )
        // The scripted Tor reports itself as connected immediately, so the
        // status chip should say so rather than sitting in a bootstrap state.
        // The chip combines its children, so it is not a static text.
        XCTAssertTrue(
            app.element(.any, labelled: "Connected to Tor").waitForExistence(timeout: Timeout.transition),
            "The scripted Tor should be reported as connected."
        )
    }
}
