import XCTest

/// A goal's Merging section in the demo factory, in Goal settings from the goal's … menu. The demo user leads Mobile app (five unfinished
/// tasks); Kit leads Public API, which Kit let auto-merge up to low. As the lead: set Auto-merge to
/// Medium and the caption says so; archive Mobile app, letting its tasks finish, and the app goes back
/// to Goals without it. As a plain member (`-demoRole member`) on Public API: both are read-only.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/GoalSettingsTests …
final class GoalSettingsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func open(goal: String, title: String, _ extra: String...) {
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", goal] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 60), "the goal didn't open")
        XCTAssertFalse(archive.exists, "Archive belongs in Goal settings, not on the goal's first screen")
        XCTAssertFalse(picker.exists, "Auto-merge belongs in Goal settings, not on the goal's first screen")
        app.buttons["goal-menu"].tap()
        let settings = app.buttons["goal-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "no Goal settings in the … menu")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Goal settings"].waitForExistence(timeout: 5), "Goal settings didn't open")
    }

    private var picker: XCUIElement { app.buttons["auto-merge-picker"] }
    private var archive: XCUIElement { app.buttons["archive-goal"] }
    private var caption: XCUIElement { app.staticTexts["auto-merge-caption"] }

    func testLeadSetsAutoMergeAndArchives() {
        open(goal: "g-app", title: "Mobile app", "-demoRole", "member")
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no Auto-merge picker")
        XCTAssertTrue(picker.isEnabled, "the lead can change auto-merge")
        XCTAssertTrue(archive.isEnabled, "the lead can archive")
        XCTAssertTrue(caption.label.hasPrefix("Off"), caption.label)
        XCTAssertFalse(app.staticTexts["goal-settings-who"].exists)
        snap("goal-settings-lead")

        // Auto-merge up to Medium.
        picker.tap()
        let medium = app.buttons["Medium"]
        XCTAssertTrue(medium.waitForExistence(timeout: 5), "the picker should list Medium")
        snap("goal-settings-picker-open")
        medium.tap()
        XCTAssertTrue(app.staticTexts["You accepted up to medium for Mobile app"].waitForExistence(timeout: 5), "the toast should confirm it")
        for _ in 0..<10 where !caption.label.hasPrefix("You accepted up to medium") { usleep(500_000) }
        XCTAssertTrue(caption.label.hasPrefix("You accepted up to medium"), caption.label)
        snap("goal-settings-medium")

        // Archive, letting the five unfinished tasks finish.
        archive.tap()
        let finish = app.buttons["Let them finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5), "the dialog should ask about the unfinished tasks")
        XCTAssertTrue(app.buttons["Cancel tasks and clean up"].exists)
        XCTAssertTrue(app.buttons["Cancel tasks, keep worktrees"].exists)
        XCTAssertTrue(app.staticTexts["Archive Mobile app?"].exists)
        snap("goal-settings-archive-dialog")
        finish.tap()

        XCTAssertTrue(app.navigationBars["Goals"].waitForExistence(timeout: 5), "archiving should go back to Goals")
        XCTAssertTrue(app.staticTexts["Public API"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Mobile app"].exists, "an archived goal isn't listed as active")
        snap("goal-settings-archived")
    }

    func testMemberSeesItReadOnly() {
        open(goal: "g-api", title: "Public API", "-demoRole", "member")
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no Auto-merge picker")
        XCTAssertFalse(picker.isEnabled, "only Kit or an admin can change auto-merge")
        XCTAssertFalse(archive.isEnabled, "only Kit or an admin can archive")
        XCTAssertTrue(caption.label.hasPrefix("Kit Okafor accepted up to low"), caption.label)
        XCTAssertEqual(app.staticTexts["goal-settings-who"].label, "Only kit or an admin can change this.")
        snap("goal-settings-member")
    }

    func testAdminCanChangeAGoalTheyDontLead() {
        open(goal: "g-api", title: "Public API")
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.isEnabled, "an admin can change any goal's auto-merge")
        XCTAssertTrue(archive.isEnabled, "an admin can archive any goal")
    }

    private func snap(_ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
