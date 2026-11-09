import XCTest

/// Settings → Day report in the demo: today's four sections and their tasks, Copy for Slack and Copy as
/// Markdown (the server's text onto the pasteboard, confirmed by a label), Share, and stepping a day back
/// to the empty state and Today again.
final class DayReportTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
    }

    func testSectionsCopyAndDays() {
        let app = launch()
        let row = element(app, "settings-dayReport")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Settings has a Day report row")
        snap(app, "settings-day-report-row")
        row.tap()

        for key in ["merged", "reviewed", "pendingReview", "inProgress"] {
            XCTAssertTrue(element(app, "dayReport.section.\(key)").waitForExistence(timeout: 10), "the \(key) section shows")
        }
        for id in ["APP-9", "APP-11", "API-31", "APP-14", "API-29", "APP-12"] {
            let item = element(app, "dayReport.item.\(id)")
            for _ in 0..<4 where !item.exists { app.swipeUp() }
            XCTAssertTrue(item.exists, "\(id) is in the report")
        }
        app.swipeDown(); app.swipeDown()
        XCTAssertFalse(element(app, "dayReport.today").isEnabled, "Today is disabled on today")
        XCTAssertFalse(element(app, "dayReport.next").isEnabled, "the day after is disabled on today")
        snap(app, "day-report-light")

        element(app, "dayReport.menu").tap()
        app.buttons["Copy for Slack"].tap()
        let copied = element(app, "dayReport.copied")
        XCTAssertTrue(copied.waitForExistence(timeout: 5))
        XCTAssertTrue(copied.label.contains("Copied for Slack"), copied.label)
        snap(app, "day-report-copied-slack")

        sleep(5)
        element(app, "dayReport.menu").tap()
        app.buttons["Copy as Markdown"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Copied for Markdown'")).firstMatch.waitForExistence(timeout: 5))

        sleep(5)
        element(app, "dayReport.menu").tap()
        app.buttons["Share…"].tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10) || app.buttons["Copy"].waitForExistence(timeout: 5), "the share sheet opens")
        snap(app, "day-report-share-sheet")
        // On iOS 27 the share sheet is a popover: tap outside it to close.
        let dismiss = app.otherElements["PopoverDismissRegion"]
        if dismiss.exists { dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap() }
        else if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        else { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "the share sheet closes")

        let prev = element(app, "dayReport.prev")
        XCTAssertTrue(prev.waitForExistence(timeout: 5))
        prev.tap()
        XCTAssertTrue(element(app, "dayReport.empty").waitForExistence(timeout: 10), "the day before is empty")
        XCTAssertTrue(element(app, "dayReport.today").isEnabled)
        snap(app, "day-report-empty")

        element(app, "dayReport.today").tap()
        XCTAssertTrue(element(app, "dayReport.section.merged").waitForExistence(timeout: 10), "Today comes back")
    }

    func testDarkMode() {
        XCUIDevice.shared.appearance = .dark
        let app = launch()
        let row = element(app, "settings-dayReport")
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        snap(app, "settings-day-report-row-dark")
        row.tap()
        XCTAssertTrue(element(app, "dayReport.section.merged").waitForExistence(timeout: 10))
        snap(app, "day-report-dark")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "settings"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
