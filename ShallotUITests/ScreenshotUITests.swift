import XCTest

/// A visual record of the four screens.
///
/// This asserts almost nothing on purpose — its value is the attachments, which
/// make a layout regression on either shell obvious in the test report without
/// anyone having to run the app.
final class ScreenshotUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCapturesEverySectionAsAScreenshot() {
        let app = launchShallot()

        for section in ShallotSection.allCases {
            app.show(section)
            attach(app.screenshot(), named: "\(shellName) — \(section.rawValue)")
        }
    }

    @MainActor
    func testCapturesTheTabOverviewAndTheNewFavouriteSheet() {
        let app = launchShallot()

        app.openTabOverview()
        attach(app.screenshot(), named: "\(shellName) — Tab overview")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Tabs"].waitForNonExistence(timeout: Timeout.transition))

        app.show(.favourites)
        app.buttons["Add a favourite"].tap()
        XCTAssertTrue(app.navigationBars["New favourite"].waitForExistence(timeout: Timeout.transition))
        attach(app.screenshot(), named: "\(shellName) — New favourite")
        app.buttons["Cancel"].tap()
    }

    // MARK: - Helpers

    @MainActor
    private var shellName: String {
        usesSplitViewShell ? "Split view" : "Tab bar"
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
