import XCTest

/// Against a live factory (scripts/dev-stack.sh): Settings → Statistics for an admin, stepping through
/// every range; a member (MAPLE_DEV_AS=<login>) sees no Statistics row.
///   TEST_RUNNER_MAPLE_FACTORY=localhost:8788 xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/LiveStatisticsTests …
/// Skipped (XCTSkip) without MAPLE_FACTORY. DemoStatisticsTests needs no server.
final class LiveStatisticsTests: XCTestCase {
    private func launch() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let factory = env["MAPLE_FACTORY"] else { throw XCTSkip("set MAPLE_FACTORY to a dev factory") }
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingURL", factory, "-onboardingContinue", "YES", "-tab", "settings"]
        if let login = env["MAPLE_DEV_AS"] { app.launchArguments += ["-devAs", login] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "didn't sign in")
        sleep(2)
        return app
    }

    func testAdminStepsThroughEveryRange() throws {
        guard ProcessInfo.processInfo.environment["MAPLE_DEV_AS"] == nil else { throw XCTSkip("a member run") }
        let app = try launch()
        let row = app.buttons["Statistics"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "an admin should see Statistics")
        row.tap()
        for range in ["24h", "3d", "7d", "30d", "90d"] {
            let segment = app.buttons[range]
            XCTAssertTrue(segment.waitForExistence(timeout: 5))
            segment.tap()
            XCTAssertTrue(app.staticTexts["Merged"].waitForExistence(timeout: 10), "no stats for \(range)")
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Only admins'")).firstMatch.exists)
            sleep(3)
            add(shot(app, "live-admin-\(range)"))
        }
    }

    func testMemberSeesNoStatistics() throws {
        guard ProcessInfo.processInfo.environment["MAPLE_DEV_AS"] != nil else { throw XCTSkip("an admin run") }
        let app = try launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '· member'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Statistics"].exists)
        add(shot(app, "live-member-settings"))
    }
}

/// The demo's Statistics, top to bottom: headline, finding outcomes, top areas and top findings.
final class DemoStatisticsTests: XCTestCase {
    func testDemoStatistics() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "settings", "-statsDays", "30"]
        app.launch()
        let row = app.buttons["Statistics"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        add(shot(app, "demo-settings"))
        row.tap()
        XCTAssertTrue(app.staticTexts["Merged"].waitForExistence(timeout: 10))
        add(shot(app, "demo-stats-1"))
        for page in 2...4 {
            app.swipeUp()
            sleep(1)
            add(shot(app, "demo-stats-\(page)"))
        }
    }
}

private func shot(_ app: XCUIApplication, _ name: String) -> XCTAttachment {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    return attachment
}
