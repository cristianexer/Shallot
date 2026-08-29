import XCTest

/// Settings: the switches people rely on, and the security level's explanation.
final class SettingsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Privacy toggles

    @MainActor
    func testFlippingAPrivacyToggleChangesItsValue() {
        let app = launchShallot()
        app.show(.settings)

        let toggle = app.privacyToggle("Block WebRTC")
        let before = toggle.value as? String
        XCTAssertEqual(before, "1", "Block WebRTC ships on; the rest of this test assumes it.")

        tap(toggle) { (toggle.value as? String) == "0" }

        XCTAssertEqual(
            toggle.value as? String,
            "0",
            "Tapping the switch should change its value."
        )
    }

    @MainActor
    func testAFlippedPrivacyToggleSurvivesLeavingAndReturningToSettings() {
        let app = launchShallot()
        app.show(.settings)

        let toggle = app.privacyToggle("Block DNS prefetching")
        XCTAssertEqual(toggle.value as? String, "1")
        tap(toggle) { (toggle.value as? String) == "0" }

        app.show(.monitor)
        app.show(.settings)

        let returned = app.privacyToggle("Block DNS prefetching")
        XCTAssertEqual(
            returned.value as? String,
            "0",
            "The change should still be there after navigating away and back."
        )
    }

    // MARK: - Security level

    @MainActor
    func testChangingTheSecurityLevelChangesTheExplanationUnderneath() {
        let app = launchShallot()
        app.show(.settings)

        // Shallot ships on Safer, so that explanation is the one on screen.
        XCTAssertTrue(
            app.explanation(startingWith: "Safer:").waitForExistence(timeout: Timeout.element),
            "The default level's explanation should be shown."
        )

        let safest = app.buttons["Safest"]
        XCTAssertTrue(safest.waitForExistence(timeout: Timeout.element))
        app.scrollUntilHittable(safest)
        tap(safest) { app.explanation(startingWith: "Safest:").exists }

        XCTAssertTrue(
            app.explanation(startingWith: "Safest:").exists,
            "Choosing Safest should replace the explanation with the Safest one."
        )
        XCTAssertTrue(
            waitUntil("the Safer explanation is gone") {
                !app.explanation(startingWith: "Safer:").exists
            },
            "Only the selected level's explanation should remain."
        )

        // And back again, so the control is shown to work in both directions.
        let standard = app.buttons["Standard"]
        app.scrollUntilHittable(standard)
        tap(standard) { app.explanation(startingWith: "Standard:").exists }
        XCTAssertTrue(
            app.explanation(startingWith: "Standard:").exists,
            "Choosing Standard should update the explanation again."
        )
    }

    @MainActor
    func testTheSecurityLevelSurvivesLeavingAndReturningToSettings() {
        let app = launchShallot()
        app.show(.settings)

        let safest = app.buttons["Safest"]
        XCTAssertTrue(safest.waitForExistence(timeout: Timeout.element))
        app.scrollUntilHittable(safest)
        tap(safest) { app.explanation(startingWith: "Safest:").exists }

        app.show(.browse)
        app.show(.settings)

        XCTAssertTrue(
            app.explanation(startingWith: "Safest:").waitForExistence(timeout: Timeout.transition),
            "The chosen security level should still be in force."
        )
    }
}

// MARK: - Settings helpers

extension XCUIApplication {

    /// The switch in the Privacy group with `label`, scrolled into view.
    ///
    /// The toggles hide their SwiftUI labels and carry an accessibility label
    /// instead, so the spoken name is the selector. Settings is a long scroll
    /// view, and on a phone most of the Privacy group starts below the fold.
    @MainActor
    func privacyToggle(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let toggle = switches[label]
        XCTAssertTrue(
            toggle.waitForExistence(timeout: Timeout.element),
            "No switch labelled ‘\(label)’ in Settings.",
            file: file,
            line: line
        )
        scrollUntilHittable(toggle, file: file, line: line)
        return toggle
    }

    /// The security level explanation currently under the picker.
    ///
    /// Matched on its opening word rather than the whole sentence so a wording
    /// change does not break the test for the wrong reason.
    @MainActor
    func explanation(startingWith prefix: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }
}
