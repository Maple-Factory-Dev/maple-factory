import XCTest

/// In the demo: opens the Mobile app goal, starts a task from its New task button, and checks it lands
/// in the right section: Drafting for Save as draft, Planning for Plan now.
final class NewTaskTests: XCTestCase {
    func testSaveAsDraft() throws {
        try create(title: "Haptics when a plan is approved", plan: false, section: "Drafting · 2")
    }

    func testPlanNow() throws {
        try create(title: "Widget for the inbox count", plan: true, section: "Planning · 1")
    }

    private func create(title: String, plan: Bool, section: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", "g-app"]
        app.launch()

        let button = app.buttons["newTask"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the goal has no New task button")
        button.tap()

        let titleField = app.textFields["newTask.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        let brief = app.textViews["newTask.brief"].exists ? app.textViews["newTask.brief"] : app.textFields["newTask.brief"]
        brief.tap()
        brief.typeText("Made on the phone by the UI test.")
        app.buttons[plan ? "Plan now" : "Save as draft"].tap()
        app.buttons["newTask.send"].tap()

        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the new task isn't in the goal")
        XCTAssertTrue(app.staticTexts["APP-16"].exists, "the new task isn't APP-16")
        XCTAssertTrue(app.staticTexts[section].exists, "no \(section) section")
        // The section a row is in is the nearest header above it.
        let headers = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[A-Za-z ]+ · [0-9]+$")).allElementsBoundByIndex
        let above = headers.filter { $0.frame.maxY <= row.frame.minY }.max { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(above?.label, section, "the task isn't under \(section)")
    }
}
