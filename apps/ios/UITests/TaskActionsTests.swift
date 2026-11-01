import XCTest

/// The task's toolbar `…` in the demo: each action changes the task the way a factory would, and
/// what the Mac hides for a task's state or your role isn't offered.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/TaskActionsTests …
final class TaskActionsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// APP-15 is your draft: Send to backlog parks it.
    func testSendToBacklog() {
        let app = open("APP-15")
        XCTAssertTrue(app.staticTexts["Drafting"].exists)
        menu(app)
        XCTAssertTrue(app.buttons["Send to planning"].exists)
        XCTAssertTrue(app.buttons["Assign…"].exists)
        snap(app, "menu-drafting")
        app.buttons["Send to backlog"].tap()
        XCTAssertTrue(app.staticTexts["Backlog"].waitForExistence(timeout: 5), "the state chip should read Backlog")
        XCTAssertFalse(app.staticTexts["Drafting"].exists)
    }

    /// APP-12 is building: no Send to backlog or Send to planning, but it can still be cancelled.
    func testBuildingTaskHidesBacklog() {
        let app = open("APP-12")
        menu(app)
        XCTAssertTrue(app.buttons["Cancel task…"].exists)
        XCTAssertTrue(app.buttons["Edit title & brief…"].exists)
        XCTAssertFalse(app.buttons["Send to backlog"].exists)
        XCTAssertFalse(app.buttons["Send to planning"].exists)
        snap(app, "menu-building")
    }

    func testAssign() {
        let app = open("APP-15")
        XCTAssertTrue(app.staticTexts["andrea"].exists)
        menu(app)
        app.buttons["Assign…"].tap()
        let sam = app.buttons["assign-sam"]
        XCTAssertTrue(sam.waitForExistence(timeout: 5), "the member picker should open")
        snap(app, "assign-sheet")
        sam.tap()
        XCTAssertTrue(sam.waitForNonExistence(timeout: 5), "the sheet should close")
        XCTAssertTrue(app.staticTexts["sam"].waitForExistence(timeout: 5), "the owner should be sam")
        XCTAssertFalse(app.staticTexts["andrea"].exists)
        snap(app, "assigned")
    }

    func testEdit() {
        let app = open("APP-15")
        menu(app)
        app.buttons["Edit title & brief…"].tap()
        let title = app.textViews["edit-title"].exists ? app.textViews["edit-title"] : app.textFields["edit-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the edit sheet should open")
        XCTAssertFalse(app.buttons["edit-save"].isEnabled, "nothing changed yet")
        // At the end of the title, then delete all of it.
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85)).tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60))
        title.typeText("iPad layout with a split view")
        snap(app, "edit-sheet")
        app.buttons["edit-save"].tap()
        XCTAssertTrue(app.buttons["edit-save"].waitForNonExistence(timeout: 5), "the sheet should close")
        XCTAssertTrue(app.staticTexts["iPad layout with a split view"].waitForExistence(timeout: 5), "the header should show the new title")
    }

    func testMoveGoal() {
        let app = open("APP-15")
        XCTAssertTrue(app.staticTexts["Mobile app"].exists)
        menu(app)
        app.buttons["Move to goal…"].tap()
        let onboarding = app.buttons["move-g-onb"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 5), "the goal picker should open")
        XCTAssertFalse(app.buttons["move-g-api"].isEnabled, "Public API doesn't work in acme/app")
        XCTAssertTrue(app.staticTexts["Doesn't work in acme/app"].exists)
        snap(app, "move-goal-sheet")
        onboarding.tap()
        XCTAssertTrue(onboarding.waitForNonExistence(timeout: 5), "the sheet should close")
        XCTAssertTrue(app.staticTexts["Onboarding"].waitForExistence(timeout: 5), "the header should show the new goal")
        XCTAssertFalse(app.staticTexts["Mobile app"].exists)
    }

    /// APP-12's builder is running and asked a question: the confirmation says so, Keep Working leaves
    /// it building, and only Cancel Task cancels it.
    func testCancel() {
        let app = open("APP-12")
        menu(app)
        app.buttons["Cancel task…"].tap()
        let stops = app.staticTexts["This stops its running builder session and the open question to you. Its branch stays, and you can pick it back up with Retry."]
        XCTAssertTrue(stops.waitForExistence(timeout: 5), "the confirmation should say what it stops")
        snap(app, "cancel-confirmation")
        // On iOS 26+ the dialog is a popover off the toolbar with no Keep Working button: tapping outside it keeps working.
        if app.buttons["Keep Working"].exists { app.buttons["Keep Working"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).tap() }
        XCTAssertTrue(stops.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Building"].exists, "Keep Working shouldn't cancel it")

        menu(app)
        app.buttons["Cancel task…"].tap()
        XCTAssertTrue(app.buttons["Cancel Task"].waitForExistence(timeout: 5))
        app.buttons["Cancel Task"].tap()
        XCTAssertTrue(app.staticTexts["Cancelled"].waitForExistence(timeout: 5), "the task should be Cancelled")
        snap(app, "cancelled")
    }

    /// As a member, Sam's APP-14 can be taken over but not assigned to someone else.
    func testAssignHiddenForSomeoneElsesTaskWhenNotAdmin() {
        let app = open("APP-14", "-demoRole", "member")
        menu(app)
        XCTAssertTrue(app.buttons["Take it over"].exists)
        XCTAssertFalse(app.buttons["Assign…"].exists)
        snap(app, "menu-member-others-task")
    }

    /// Retry shows where the Mac's TaskActionButtons offers it: on a building task, not on a draft,
    /// and a draft without a plan has no Recheck GitHub or Split… either.
    func testRetryShowsWhenSomethingCanRun() {
        let building = open("BIL-8")
        menu(building)
        XCTAssertTrue(building.buttons["Retry"].exists)
        XCTAssertTrue(building.buttons["Recheck GitHub"].exists, "BIL-8 has a draft PR on GitHub")
        XCTAssertTrue(building.buttons["Split…"].exists, "BIL-8 has a four-step plan")
        snap(building, "menu-building-with-pr")
        building.buttons["Retry"].tap()
        XCTAssertTrue(building.staticTexts["Retrying BIL-8"].waitForExistence(timeout: 5), "the toast should say it's retrying")

        let draft = open("APP-15")
        menu(draft)
        XCTAssertFalse(draft.buttons["Retry"].exists)
        XCTAssertFalse(draft.buttons["Recheck GitHub"].exists)
        snap(draft, "menu-draft-no-retry")
    }

    /// BIL-8's draft PR has a running `test` and a queued `lint`: Recheck GitHub reads them again and they've passed.
    func testRecheckGitHub() {
        let app = open("BIL-8")
        app.buttons["Review"].tap()
        let test = app.buttons["check-test"], lint = app.buttons["check-lint"]
        reveal(app, lint)
        XCTAssertEqual(test.value as? String, "running")
        XCTAssertEqual(lint.value as? String, "queued")
        menu(app)
        app.buttons["Recheck GitHub"].tap()
        XCTAssertTrue(app.staticTexts["Checking GitHub…"].waitForExistence(timeout: 5), "the toast should say it's checking")
        for _ in 0..<20 where lint.value as? String != "passed" { usleep(500_000) }
        XCTAssertEqual(test.value as? String, "passed", "the running check should have passed")
        XCTAssertEqual(lint.value as? String, "passed", "the queued check should have passed")
        snap(app, "rechecked")
    }

    /// Split BIL-8 into 3: it keeps its first two steps, and two new tasks Split from BIL-8 go to planning.
    func testSplitIntoThree() {
        let app = open("BIL-8", "-tab", "goals")
        menu(app)
        app.buttons["Split…"].tap()
        let stepper = app.steppers["split-parts"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5), "the split sheet should open")
        XCTAssertTrue(app.staticTexts["New task 1"].exists || app.staticTexts["NEW TASK 1"].exists)
        // 44 files over a 20-file budget: it starts at 3.
        if !(app.staticTexts["NEW TASK 2"].exists || app.staticTexts["New task 2"].exists) { stepper.buttons.element(boundBy: 1).tap() }
        XCTAssertTrue(app.staticTexts["NEW TASK 2"].exists || app.staticTexts["New task 2"].exists, "three parts: two new tasks")
        XCTAssertTrue(app.staticTexts["3"].exists)
        snap(app, "split-sheet")
        app.buttons["split-confirm"].tap()
        XCTAssertTrue(app.staticTexts["Splitting BIL-8 into 3 tasks; the new ones go to planning"].waitForExistence(timeout: 5))

        // Back on Billing, the new tasks are there and planning.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Billing"].waitForExistence(timeout: 5))
        let first = app.staticTexts["Send it from the payment webhook"]
        let second = app.staticTexts["Let customers resend a receipt from Billing"]
        reveal(app, first)
        XCTAssertTrue(first.waitForExistence(timeout: 5), "BIL-9 should be on the board")
        reveal(app, second)
        XCTAssertTrue(second.exists, "BIL-10 should be on the board")
        snap(app, "split-board")

        first.tap()
        XCTAssertTrue(app.staticTexts["Planning"].waitForExistence(timeout: 5), "the new task should be planning")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Split from BIL-8'")).firstMatch.exists, "its brief should say where it came from")
        snap(app, "split-new-task")
    }

    /// APP-15 is a draft with no plan: nothing to split.
    func testSplitHiddenOnDraft() {
        let app = open("APP-15")
        menu(app)
        XCTAssertFalse(app.buttons["Split…"].exists)
        XCTAssertFalse(app.buttons["Retry"].exists)
        snap(app, "menu-draft-no-split")
    }

    // MARK: Helpers

    /// Scrolls until `element` is on screen.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        for _ in 0..<6 where !(element.exists && element.isHittable) { list.swipeUp() }
    }

    private func open(_ task: String, _ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-task", task] + extra
        app.launch()
        XCTAssertTrue(app.buttons["taskActions"].waitForExistence(timeout: 20), "\(task) should open with its … menu")
        return app
    }

    private func menu(_ app: XCUIApplication) {
        app.buttons["taskActions"].tap()
        XCTAssertTrue(app.buttons["Edit title & brief…"].waitForExistence(timeout: 5) || app.buttons["Take it over"].exists, "the menu should open")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
