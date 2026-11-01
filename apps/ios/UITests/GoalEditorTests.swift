import XCTest

/// New goal and Edit goal in the demo factory, which answers `goal.save` the way the server does: a new
/// goal gets an id, and a prefix another goal uses is refused. The demo user leads Mobile app (APP); Kit
/// leads Public API (API). Snapshots go to ~/.cache/maple-proof/agent/mf-285/ when it's there.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/GoalEditorTests …
final class GoalEditorTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ arguments: String...) {
        app.launchArguments = ["-demo", "YES", "-tab", "goals"] + arguments
        app.launch()
    }

    private var nameField: XCUIElement { app.textFields["goalEditor.name"] }
    private var prefix: XCUIElement { app.textFields["goalEditor.prefix"] }
    private var save: XCUIElement { app.buttons["goalEditor.save"] }

    private func snapshot(_ label: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = label
        attachment.lifetime = .keepAlways
        add(attachment)
        let dir = URL(fileURLWithPath: NSHomeDirectory().components(separatedBy: "/Library/Developer").first ?? NSHomeDirectory())
            .appending(path: ".cache/maple-proof/agent/mf-285")
        if FileManager.default.fileExists(atPath: dir.path) {
            try? shot.pngRepresentation.write(to: dir.appending(path: "\(label).png"))
        }
    }

    /// Anything by its identifier, scrolled to (a Form only makes the rows on screen).
    private func element(_ id: String, up: Bool = false) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        // The sheet's Form, not the list behind it: swipe the middle of the screen.
        // Dragged above where the keyboard sits, so it scrolls the Form.
        let (from, to) = up ? (0.15, 0.4) : (0.4, 0.15)
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
        }
        return element
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + text)
    }

    private func tick(_ repo: String) {
        let row = app.buttons["goalEditor.repo.\(repo)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(repo) isn't offered")
        if !row.isHittable { app.swipeUp() }
        row.tap()
    }

    func testCreateAGoalFromTheGoalsTab() {
        launch()
        let newGoal = app.buttons["newGoal"]
        XCTAssertTrue(newGoal.waitForExistence(timeout: 60), "no New goal button on Goals")
        snapshot("goals-tab-new-goal-button")
        newGoal.tap()

        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "Create is on with nothing filled in")
        nameField.tap()
        nameField.typeText("Desktop app")
        XCTAssertEqual(prefix.value as? String, "DA", "the prefix isn't filled in from the name")
        XCTAssertTrue(app.staticTexts["Its tasks are numbered DA-1, DA-2…"].exists)
        tick("acme/docs")
        XCTAssertEqual(app.buttons["goalEditor.repo.acme/docs"].value as? String, "default")
        tick("acme/web")
        XCTAssertEqual(app.buttons["goalEditor.repo.acme/web"].value as? String, "ticked")
        app.swipeDown(velocity: .slow)
        snapshot("new-goal-sheet-filled-in")
        save.tap()

        XCTAssertTrue(app.navigationBars["Desktop app"].waitForExistence(timeout: 5), "the new goal's page didn't open")
        XCTAssertFalse(nameField.exists, "the sheet stayed open")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Desktop app"].waitForExistence(timeout: 5), "the new goal isn't listed")
        XCTAssertTrue(app.staticTexts["DA"].exists)
    }

    func testLeadEditsNameAndPlannerInstructions() {
        launch("-goal", "g-app")
        XCTAssertTrue(app.navigationBars["Mobile app"].waitForExistence(timeout: 60))
        let edit = app.buttons["editGoal"]
        XCTAssertTrue(edit.exists, "the lead has no Edit button")
        edit.tap()

        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertEqual(prefix.value as? String, "APP")
        replace(nameField, with: "Mobile apps")
        XCTAssertEqual(prefix.value as? String, "APP", "editing the name changed a goal's prefix")
        let planner = element("goalEditor.prompt.planner")
        XCTAssertTrue(planner.isEnabled, "the lead can't edit the instructions")
        planner.tap()
        planner.typeText("Plan for iPhone and iPad.")
        snapshot("edit-goal-sheet-agent-instructions")
        save.tap()

        XCTAssertTrue(app.navigationBars["Mobile apps"].waitForExistence(timeout: 5), "the title didn't update")
        XCTAssertFalse(nameField.exists, "the sheet stayed open")
        app.buttons["editGoal"].tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertEqual(nameField.value as? String, "Mobile apps")
        let saved = element("goalEditor.prompt.planner")
        XCTAssertEqual(saved.value as? String, "Plan for iPhone and iPad.", "the planner instructions weren't kept")
    }

    func testATakenPrefixIsRefusedInline() {
        launch()
        let newGoal = app.buttons["newGoal"]
        XCTAssertTrue(newGoal.waitForExistence(timeout: 60))
        newGoal.tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        // The prefix first, while it's empty; an edited prefix isn't filled in from the name.
        prefix.tap()
        prefix.typeText("API")
        nameField.tap()
        nameField.typeText("Platform")
        XCTAssertEqual(prefix.value as? String, "API")
        tick("acme/api")
        save.tap()

        let failure = element("goalEditor.failure", up: true)
        XCTAssertTrue(failure.waitForExistence(timeout: 5), "the refusal didn't show in the sheet: \(app.debugDescription)")
        XCTAssertTrue(failure.label.contains("Another goal already uses API."), failure.label)
        XCTAssertTrue(nameField.exists, "the sheet closed on a refusal")
        XCTAssertTrue(save.isEnabled, "Create stays off after a refusal")
        snapshot("new-goal-prefix-refused")
    }

    func testMemberHasNoEditOnAGoalTheyDontLead() {
        launch("-goal", "g-api", "-demoRole", "member")
        XCTAssertTrue(app.navigationBars["Public API"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["newTask"].exists)
        XCTAssertFalse(app.buttons["editGoal"].exists, "a member who doesn't lead it can edit the goal")
    }
}
