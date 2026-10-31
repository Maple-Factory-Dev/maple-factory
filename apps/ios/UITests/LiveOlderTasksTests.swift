import XCTest

/// Against a live factory seeded by `node server/test/e2e-snapshot-window.mjs <url> keep` (MF-212): the
/// snapshot leaves out tasks finished over 14 days ago, the goal's done count still has them, and
/// Load older brings 50 of them into Merged.
///   TEST_RUNNER_MAPLE_FACTORY=localhost:8788 TEST_RUNNER_MAPLE_GOAL=<goal id> xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/LiveOlderTasksTests …
/// TEST_RUNNER_MAPLE_SHOTS=<dir> also writes the screenshots there. Skipped (XCTSkip) without MAPLE_FACTORY and MAPLE_GOAL.
final class LiveOlderTasksTests: XCTestCase {
    func testLoadOlderBringsInOldFinishedTasks() throws {
        let env = ProcessInfo.processInfo.environment
        guard let factory = env["MAPLE_FACTORY"], let goal = env["MAPLE_GOAL"] else { throw XCTSkip("set MAPLE_FACTORY and MAPLE_GOAL to a seeded dev factory") }
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingURL", factory, "-onboardingContinue", "YES", "-tab", "goals", "-goal", goal]
        app.launch()

        let older = app.buttons["load-older"]
        XCTAssertTrue(scrollTo(older, in: app), "the goal should offer Load older")
        snap(app, "ios-load-older-before")
        // Its label says how many are left: 50 fewer once the page lands.
        let before = older.label
        older.tap()
        // The page's 50 merged rows land above it, in Merged: on screen now, where Cancelled was.
        sleep(4)
        snap(app, "ios-load-older-after")
        XCTAssertTrue(scrollTo(older, in: app), "more are left, so Load older stays")
        XCTAssertNotEqual(older.label, before, "a page should load: \(before)")
        snap(app, "ios-load-older-left")
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        _ = element.waitForExistence(timeout: 20)
        for _ in 0..<25 {
            if element.exists && element.isHittable { return true }
            app.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["MAPLE_SHOTS"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }
}
