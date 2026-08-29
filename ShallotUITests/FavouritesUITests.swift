import XCTest

/// Favourites: adding one by hand, and removing it again.
///
/// Note on the starting state. The store is in memory in UI-testing mode, so
/// nothing survives a launch — but `AppContainer.seedFirstRunFavourites()` is
/// guarded by a *persisted* flag that is also in memory, so it reads as unset
/// on every launch and the seven first-run clearnet favourites are installed
/// again each time. These tests therefore assert about the favourite they add
/// themselves and never about the list being empty, which is both the honest
/// state of the app and the only stable one.
final class FavouritesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFavouritesShowsItsHeaderAndItsWarning() {
        let app = launchShallot()
        app.show(.favourites)

        XCTAssertTrue(app.staticTexts["FAVOURITES"].exists)
        XCTAssertTrue(
            app.buttons["Add a favourite"].waitForExistence(timeout: Timeout.element),
            "There should always be a way to add a favourite by hand."
        )
        // The screen leads with the reason a saved onion address is worth more
        // than a fresh link; losing that would be a substantive regression.
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH 'Onion addresses can change or be spoofed'")
            ).firstMatch.exists,
            "The verify-before-trusting advice should be on the screen."
        )
    }

    @MainActor
    func testTheAddButtonOpensTheNewFavouriteSheet() {
        let app = launchShallot()
        app.show(.favourites)

        app.buttons["Add a favourite"].tap()

        XCTAssertTrue(
            app.navigationBars["New favourite"].waitForExistence(timeout: Timeout.transition),
            "The add button should present the new-favourite sheet."
        )
        XCTAssertTrue(app.textFields["SecureDrop"].exists, "The sheet should offer a name field.")
        XCTAssertTrue(app.textFields["example.onion"].exists, "The sheet should offer an address field.")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["New favourite"].waitForNonExistence(timeout: Timeout.transition))
    }

    @MainActor
    func testSavingAValidOnionAddressAddsACard() {
        let app = launchShallot()
        app.show(.favourites)
        app.addFavourite(named: "Test Site", address: Fixture.onionAddress)

        XCTAssertTrue(
            app.buttons["Test Site"].waitForExistence(timeout: Timeout.element),
            "A saved favourite should appear as a card."
        )
        XCTAssertFalse(
            app.staticTexts["Nothing saved yet"].exists,
            "The empty state should give way once something is saved."
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Onion services'")).firstMatch.exists,
            "A .onion favourite belongs in the onion services group."
        )
        XCTAssertEqual(
            app.buttons["Test Site"].value as? String,
            "Onion service",
            "The card should announce what kind of address it holds."
        )
    }

    @MainActor
    func testAFavouriteCanBeDeletedFromItsContextMenu() {
        let app = launchShallot()
        app.show(.favourites)
        app.addFavourite(named: "Test Site", address: Fixture.onionAddress)

        let card = app.buttons["Test Site"]
        XCTAssertTrue(card.waitForExistence(timeout: Timeout.element))
        app.scrollUntilHittable(card)
        card.press(forDuration: 1.2)

        let delete = app.buttons["Delete"]
        XCTAssertTrue(
            delete.waitForExistence(timeout: Timeout.transition),
            "A long press should offer Rename and Delete."
        )
        delete.tap()

        XCTAssertTrue(
            card.waitForNonExistence(timeout: Timeout.transition),
            "Deleting should remove the card."
        )
        XCTAssertFalse(
            app.staticTexts["Test Site"].exists,
            "Nothing of the deleted favourite should be left on the screen."
        )
    }
}

// MARK: - Favourites helpers

extension XCUIApplication {

    /// Fills in and saves the new-favourite sheet.
    @MainActor
    func addFavourite(
        named name: String,
        address: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let add = buttons["Add a favourite"]
        XCTAssertTrue(
            add.waitForExistence(timeout: Timeout.element),
            "The add button was not found.",
            file: file,
            line: line
        )
        add.tap()

        // The fields carry no explicit accessibility label, so SwiftUI uses the
        // placeholder — which is what names them here.
        let nameField = textFields["SecureDrop"]
        XCTAssertTrue(
            nameField.waitForExistence(timeout: Timeout.transition),
            "The new-favourite sheet did not open.",
            file: file,
            line: line
        )
        nameField.tap()
        nameField.typeText(name)

        let addressField = textFields["example.onion"]
        addressField.tap()
        addressField.typeText(address)

        buttons["Save"].tap()
        XCTAssertTrue(
            navigationBars["New favourite"].waitForNonExistence(timeout: Timeout.transition),
            "Saving a valid address should dismiss the sheet.",
            file: file,
            line: line
        )
    }
}
