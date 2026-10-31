import XCTest

/// Against a live factory (scripts/dev-stack.sh): signs in, opens the goal MAPLE_GOAL (an id), and
/// creates a task there from the New task sheet: its second repo, P1, saved as a draft (or planned
/// now with MAPLE_PLAN=1). Then waits for it to show up in the goal.
///   TEST_RUNNER_MAPLE_FACTORY=localhost:8788 TEST_RUNNER_MAPLE_GOAL=<id> xcodebuild test … -only-testing:MapleFactoryUITests/LiveNewTaskTests
@MainActor
final class LiveNewTaskTests: XCTestCase {
    func testCreateTaskFromThePhone() throws {
        let env = ProcessInfo.processInfo.environment
        guard let factory = env["MAPLE_FACTORY"], let goal = env["MAPLE_GOAL"] else {
            throw XCTSkip("set MAPLE_FACTORY to a dev factory and MAPLE_GOAL to one of its goals")
        }
        let plan = env["MAPLE_PLAN"] == "1"
        let title = env["MAPLE_TITLE"] ?? "Made on the phone"
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingURL", factory, "-onboardingContinue", "YES", "-tab", "goals", "-goal", goal]
        app.launch()

        let button = app.buttons["newTask"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "the goal has no New task button")
        sleep(1)
        button.tap()

        let titleField = app.textFields["newTask.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        let brief = app.textViews["newTask.brief"].exists ? app.textViews["newTask.brief"] : app.textFields["newTask.brief"]
        brief.tap()
        brief.typeText("Started from the iPhone: pick the second repo, P1, and check the Mac shows it.")

        app.buttons["newTask.repo"].tap()
        app.buttons["acme/push"].tap()
        app.buttons["newTask.priority"].tap()
        app.buttons["P1 · Next"].tap()
        app.buttons[plan ? "Plan now" : "Save as draft"].tap()
        sleep(1)
        app.buttons["newTask.send"].tap()

        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 15), "the new task didn't show up in the goal")
        sleep(2)
    }
}
