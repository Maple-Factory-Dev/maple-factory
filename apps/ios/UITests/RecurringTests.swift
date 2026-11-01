import XCTest

/// A goal's recurring tasks in the demo factory. The demo user leads Mobile app, which has two (one
/// paused, its last run APP-9); Kit leads Public API, which has one. As the lead: pause, run now, add,
/// edit and delete, with GoalView's count following. As a plain member (`-demoRole member`) on Public
/// API: the list is read-only.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/RecurringTests …
final class RecurringTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func open(goal: String, title: String, _ extra: String...) {
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", goal] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 60), "the goal didn't open")
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private var count: XCUIElement { app.staticTexts["recurring-count"] }
    private func row(_ id: String) -> XCUIElement { app.descendants(matching: .any)["recurring-row-\(id)"] }
    private var rows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'recurring-row-'"))
    }

    private func openRecurring() {
        app.buttons["goal-recurring"].tap()
        XCTAssertTrue(app.navigationBars["Recurring"].waitForExistence(timeout: 10), "Recurring didn't open")
    }

    func testLeadPausesRunsAddsEditsAndDeletes() {
        open(goal: "g-app", title: "Mobile app", "-demoRole", "member")
        XCTAssertTrue(count.waitForExistence(timeout: 10), "no Recurring row")
        XCTAssertEqual(count.label, "2")
        snap("goal-recurring-row")

        openRecurring()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(app.descendants(matching: .any)["recurring-paused-rec-crash"].exists, "the crash triage starts paused")
        XCTAssertTrue(app.buttons["recurring-last-rec-crash"].exists, "the paused one links its last task")
        XCTAssertFalse(app.staticTexts["recurring-who"].exists, "the lead sees no who footer")
        XCTAssertTrue(app.buttons["recurring-add"].exists)
        snap("recurring-list-lead")

        // Pause.
        let deps = row("rec-deps")
        deps.swipeLeft()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5), "no Pause swipe action")
        XCTAssertTrue(app.buttons["Run Now"].exists, "no Run Now swipe action")
        snap("recurring-swipe-actions")
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recurring-paused-rec-deps"].waitForExistence(timeout: 5), "Pause didn't mark it Paused")

        // Run now: a toast, and a Last: link.
        row("rec-deps").swipeLeft()
        XCTAssertTrue(app.buttons["Run Now"].waitForExistence(timeout: 5))
        app.buttons["Run Now"].tap()
        XCTAssertTrue(app.staticTexts["Started a run of Check for dependency updates"].waitForExistence(timeout: 5), "no toast")
        XCTAssertTrue(app.buttons["recurring-last-rec-deps"].waitForExistence(timeout: 5), "no Last: link after running")
        XCTAssertTrue(app.buttons["recurring-last-rec-deps"].label.hasPrefix("Last: APP-"), app.buttons["recurring-last-rec-deps"].label)
        snap("recurring-ran-now")

        // Add one.
        app.buttons["recurring-add"].tap()
        let save = app.buttons["recurring-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the editor didn't open")
        XCTAssertFalse(save.isEnabled, "Add waits for a title and prompt")
        app.textFields["recurring-title"].tap()
        app.textFields["recurring-title"].typeText("Weekly flaky test sweep")
        app.textViews["recurring-prompt"].tap()
        app.textViews["recurring-prompt"].typeText("Find the flakiest UI tests and fix one.")
        XCTAssertTrue(save.isEnabled)
        snap("recurring-editor-add")
        save.tap()
        let added = app.staticTexts["Weekly flaky test sweep"]
        XCTAssertTrue(added.waitForExistence(timeout: 5), "the new one isn't listed")
        XCTAssertEqual(rows.count, 3)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "3", "GoalView's count didn't follow")
        openRecurring()

        // Edit it: rename.
        app.staticTexts["Weekly flaky test sweep"].tap()
        let title = app.textFields["recurring-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "tapping a row didn't open the editor")
        XCTAssertTrue(app.navigationBars["Edit Recurring Task"].exists)
        title.tap()
        title.typeText(" (UI)")
        snap("recurring-editor-edit")
        app.buttons["recurring-save"].tap()
        let renamed = app.staticTexts["Weekly flaky test sweep (UI)"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 5), "the rename didn't stick")
        XCTAssertEqual(rows.count, 3)

        // Delete it, confirming.
        let renamedRow = rows.containing(.staticText, identifier: "Weekly flaky test sweep (UI)").firstMatch
        renamedRow.swipeRight()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5), "no Delete swipe action")
        app.buttons["Delete"].tap()
        let confirm = app.buttons["recurring-delete-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no delete confirmation")
        confirm.tap()
        XCTAssertTrue(renamed.waitForNonExistence(timeout: 5), "Delete didn't remove it")
        XCTAssertEqual(rows.count, 2)
        snap("recurring-after-delete")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "2")
    }

    func testMemberSeesItReadOnly() {
        open(goal: "g-api", title: "Public API", "-demoRole", "member")
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertEqual(count.label, "1")
        openRecurring()
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(app.buttons["recurring-add"].exists, "a member has no + button")
        XCTAssertTrue(app.staticTexts["recurring-who"].exists, "no who footer")
        XCTAssertEqual(app.staticTexts["recurring-who"].label, "Only kit or an admin can change these.")

        row("rec-spec").swipeLeft()
        XCTAssertFalse(app.buttons["Run Now"].waitForExistence(timeout: 2), "a member got Run Now")
        XCTAssertFalse(app.buttons["Pause"].exists, "a member got Pause")
        XCTAssertFalse(app.buttons["Delete"].exists, "a member got Delete")
        // (No swipe right here: from the row's left edge it would go back. Leading actions share the lead check.)
        // Tapping doesn't open the editor either.
        app.staticTexts["Refresh the OpenAPI spec"].tap()
        XCTAssertFalse(app.textFields["recurring-title"].waitForExistence(timeout: 2), "a member opened the editor")
        snap("recurring-member-read-only")
    }
}
