import XCTest

/// In the demo, API-29's pull request has a failed `test` and a passed `lint`: tapping a check opens
/// its log sheet; Re-run from a row's context menu runs it again until it passes; Rerun failed checks
/// does the same for every failed one and then goes away.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/CheckLogTests …
final class CheckLogTests: XCTestCase {
    func testTapCheckOpensLog() {
        let app = openReview()
        let test = app.buttons["check-test"]
        XCTAssertTrue(scrollTo(test, in: app), "API-29's failed test check should show")
        XCTAssertTrue(app.buttons["rerun-failed-checks"].exists, "a failed check offers Rerun failed checks")
        snap(app, "check-rows")

        test.tap()
        XCTAssertTrue(app.navigationBars["test"].waitForExistence(timeout: 10), "the log sheet should open")
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Process completed with exit code 1.")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10), "the log should load and show its error")
        XCTAssertTrue(app.descendants(matching: .any)["check-log-failed-step"].exists, "a failed log shows the failed-step banner")
        let subtitle = app.staticTexts["check-log-subtitle"]
        XCTAssertTrue(subtitle.label.contains("#405 · Failed after 58s"), subtitle.label)
        snap(app, "check-log-sheet")

        app.navigationBars["test"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["test"].waitForNonExistence(timeout: 10))
    }

    func testRerunOneFromContextMenu() {
        let app = openReview()
        let test = app.buttons["check-test"]
        XCTAssertTrue(scrollTo(test, in: app))
        XCTAssertEqual(test.value as? String, "failed")

        test.press(forDuration: 1.2)
        let rerun = app.buttons["Re-run"]
        XCTAssertTrue(rerun.waitForExistence(timeout: 5), "the context menu should offer Re-run")
        XCTAssertTrue(app.descendants(matching: .any)["View log"].exists, "and View log")
        XCTAssertTrue(app.descendants(matching: .any)["Open on GitHub"].exists, "and Open on GitHub")
        snap(app, "check-context-menu")
        rerun.tap()

        XCTAssertTrue(wait(test, value: "running", timeout: 5), "the check should be running: \(String(describing: test.value))")
        XCTAssertTrue(wait(test, value: "passed", timeout: 10), "then pass: \(String(describing: test.value))")
        XCTAssertFalse(app.buttons["rerun-failed-checks"].exists, "nothing failing, nothing to rerun")
    }

    func testRerunFailedChecks() {
        let app = openReview()
        let rerun = app.buttons["rerun-failed-checks"]
        XCTAssertTrue(scrollTo(rerun, in: app))
        rerun.tap()

        let test = app.buttons["check-test"]
        XCTAssertTrue(wait(test, value: "running", timeout: 5), "the failed check should run again")
        XCTAssertEqual(app.buttons["check-lint"].value as? String, "passed", "a passed check is left alone")
        XCTAssertTrue(wait(test, value: "passed", timeout: 10))
        XCTAssertTrue(rerun.waitForNonExistence(timeout: 5), "with none failing, the button goes away")
        snap(app, "checks-rerun")
    }

    private func openReview() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", "g-api"]
        app.launch()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "API-29")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the list should show API-29")
        row.tap()
        XCTAssertTrue(app.navigationBars["API-29"].waitForExistence(timeout: 10))
        app.buttons["Review"].tap()
        return app
    }

    private func wait(_ element: XCUIElement, value: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// Swipes the task up until `element` is on screen.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<8 {
            if element.exists && element.isHittable { return true }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
