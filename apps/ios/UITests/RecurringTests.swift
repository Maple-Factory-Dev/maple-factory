import XCTest

/// A goal's recurring and scheduled tasks in the demo factory. The demo user leads Mobile app, which has
/// three (one paused, its last run APP-9; one a one-off, rec-release); Kit leads Public API, which has one. As the lead: pause, run now, add,
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

    /// The count on the … menu's Scheduled item: "Scheduled (3)" reads "3". Closes the menu again.
    private func recurringCount() -> String {
        openMenu()
        let item = app.buttons["goal-recurring"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Recurring in the … menu")
        let label = item.label
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.95)).tap()
        _ = item.waitForNonExistence(timeout: 3)
        guard let open = label.firstIndex(of: "("), let close = label.firstIndex(of: ")") else { return label }
        return String(label[label.index(after: open)..<close])
    }

    private func openMenu() {
        let menu = app.buttons["goal-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no … menu")
        menu.tap()
    }
    private func row(_ id: String) -> XCUIElement { app.descendants(matching: .any)["recurring-row-\(id)"] }
    private var rows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'recurring-row-'"))
    }

    private func openRecurring() {
        openMenu()
        XCTAssertTrue(app.buttons["goal-recurring"].waitForExistence(timeout: 5))
        app.buttons["goal-recurring"].tap()
        XCTAssertTrue(app.navigationBars["Recurring / Scheduled"].waitForExistence(timeout: 10), "Recurring / Scheduled didn't open")
    }

    func testLeadPausesRunsAddsEditsAndDeletes() {
        open(goal: "g-app", title: "Mobile app", "-demoRole", "member")
        XCTAssertEqual(recurringCount(), "3")
        snap("goal-recurring-row")

        openRecurring()
        XCTAssertEqual(rows.count, 3)
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
        XCTAssertEqual(rows.count, 4)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(recurringCount(), "4", "GoalView's count didn't follow")
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
        XCTAssertEqual(rows.count, 4)

        // Delete it, confirming.
        let renamedRow = rows.containing(.staticText, identifier: "Weekly flaky test sweep (UI)").firstMatch
        renamedRow.swipeRight()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5), "no Delete swipe action")
        app.buttons["Delete"].tap()
        let confirm = app.buttons["recurring-delete-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no delete confirmation")
        confirm.tap()
        XCTAssertTrue(renamed.waitForNonExistence(timeout: 5), "Delete didn't remove it")
        XCTAssertEqual(rows.count, 3)
        snap("recurring-after-delete")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(recurringCount(), "3")
    }

    /// One-offs: the demo's rec-release reads "Once · …" with a calendar icon and no Next: line; Add with
    /// Repeats = Once at a time hides Every and saves a one-off; Run Now on a one-off removes it.
    func testOneOffScheduledTasks() {
        open(goal: "g-app", title: "Mobile app")
        openRecurring()
        let release = row("rec-release")
        XCTAssertTrue(release.waitForExistence(timeout: 5), "no one-off row")
        XCTAssertTrue(app.descendants(matching: .any)["recurring-once-rec-release"].exists, "the one-off has no calendar icon")
        XCTAssertTrue(release.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Once · '")).firstMatch.exists, "the one-off doesn't read Once ·")
        XCTAssertFalse(release.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Next: '")).firstMatch.exists, "a one-off shows Next:")
        XCTAssertTrue(app.descendants(matching: .any)["recurring-repeats-rec-deps"].exists, "a repeating row has no clock icon")
        snap("scheduled-list")

        // Add a one-off.
        app.buttons["recurring-add"].tap()
        let save = app.buttons["recurring-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the editor didn't open")
        XCTAssertTrue(app.navigationBars["New Recurring Task"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["recurring-every"].exists)
        app.buttons["Once at a time"].tap()
        XCTAssertTrue(app.navigationBars["New Scheduled Task"].waitForExistence(timeout: 5), "the title didn't follow Repeats")
        XCTAssertFalse(app.descendants(matching: .any)["recurring-every"].exists, "Once still shows Every")
        XCTAssertTrue(app.staticTexts["Runs at"].exists, "no Runs at date")
        XCTAssertTrue(app.staticTexts["It starts one task then, and is removed; the task is the record."].exists)
        app.textFields["recurring-title"].tap()
        app.textFields["recurring-title"].typeText("Ship the beta")
        app.textViews["recurring-prompt"].tap()
        app.textViews["recurring-prompt"].typeText("Send the build to TestFlight.")
        snap("scheduled-editor-once")
        save.tap()
        let added = rows.containing(.staticText, identifier: "Ship the beta").firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 5), "the one-off isn't listed")
        XCTAssertTrue(added.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Once · '")).firstMatch.exists, "the new one-off doesn't read Once ·")
        XCTAssertEqual(rows.count, 4)
        snap("scheduled-list-added")

        // Run Now on the one-off: it starts its task and is removed.
        row("rec-release").swipeLeft()
        XCTAssertTrue(app.buttons["Run Now"].waitForExistence(timeout: 5))
        app.buttons["Run Now"].tap()
        XCTAssertTrue(row("rec-release").waitForNonExistence(timeout: 5), "Run Now didn't remove the one-off")
        XCTAssertEqual(rows.count, 3)
        snap("scheduled-after-run-now")
    }

    func testMemberSeesItReadOnly() {
        open(goal: "g-api", title: "Public API", "-demoRole", "member")
        XCTAssertEqual(recurringCount(), "1")
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
