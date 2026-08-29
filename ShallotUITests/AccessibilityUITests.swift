import XCTest

/// An accessibility audit of each of the four screens.
///
/// Shallot's chrome is icon-only in places, so an unlabelled control here is
/// not a cosmetic problem — it is a control nobody using VoiceOver can find.
final class AccessibilityUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBrowseScreenPassesAnAccessibilityAudit() throws {
        let app = launchShallot()
        try audit(app, section: .browse)
    }

    @MainActor
    func testFavouritesScreenPassesAnAccessibilityAudit() throws {
        let app = launchShallot()
        try audit(app, section: .favourites)
    }

    @MainActor
    func testMonitorScreenPassesAnAccessibilityAudit() throws {
        let app = launchShallot()
        try audit(app, section: .monitor)
    }

    @MainActor
    func testSettingsScreenPassesAnAccessibilityAudit() throws {
        let app = launchShallot()
        try audit(app, section: .settings)
    }

    // MARK: - Running an audit

    /// Navigates to `section` and audits it, reporting every issue at once.
    ///
    /// The handler returns `true` for each issue so the audit does not raise a
    /// separate failure per issue; they are gathered into one legible report
    /// and failed on below. Nothing is suppressed by doing this.
    @MainActor
    private func audit(
        _ app: XCUIApplication,
        section: ShallotSection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        app.show(section, file: file, line: line)

        var issues: [String] = []
        try app.performAccessibilityAudit(for: Self.auditTypes) { issue in
            issues.append(
                """
                • \(issue.compactDescription)
                  element: \(issue.element?.debugDescription ?? "none")
                  detail: \(issue.detailedDescription)
                """
            )
            return true
        }

        if !issues.isEmpty {
            let report = issues.joined(separator: "\n")
            let attachment = XCTAttachment(string: report)
            attachment.name = "Accessibility audit — \(section.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail(
                "\(issues.count) accessibility issue(s) on \(section.rawValue):\n\(report)",
                file: file,
                line: line
            )
        }
    }

    /// The audit types run on every screen.
    private static let auditTypes: XCUIAccessibilityAuditType = .all
}
