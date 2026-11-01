import XCTest

/// Efforts in the demo factory: APP-12 (building) and APP-11 (merged) make up Offline; APP-15 and
/// APP-17 (drafts) make up Bigger screens. A row shows its effort chip, a task's Overview lists its
/// effort's tasks and opens them, and the task actions menu moves a task between efforts.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/EffortTests …
final class EffortTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testRowShowsEffortChip() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", "g-app"]
        app.launch()
        let chip = app.descendants(matching: .any).matching(identifier: "task.effort").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 30), "a task in an effort should show its chip")
        XCTAssertTrue(app.staticTexts["Effort Offline"].exists || app.otherElements["Effort Offline"].exists
                      || app.descendants(matching: .any)["Effort Offline"].exists, "the chip should name Offline")
        snap(app, "goal-rows")
    }

    func testCardListsSiblingsAndOpensThem() {
        let app = open("APP-12")
        let count = app.staticTexts["effort.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the Effort card should show")
        XCTAssertEqual(count.label, "1 of 2 merged")
        XCTAssertEqual(app.staticTexts["effort.name"].label, "Offline")
        XCTAssertTrue(app.descendants(matching: .any)["effort.current-APP-12"].exists, "the current task should be listed")
        let sibling = app.buttons["effort.sibling-APP-11"]
        XCTAssertTrue(sibling.exists, "APP-11 should be listed as a sibling")
        snap(app, "effort-card")
        sibling.tap()
        XCTAssertTrue(app.descendants(matching: .any)["effort.current-APP-11"].waitForExistence(timeout: 10), "APP-11 should open")
        XCTAssertTrue(app.buttons["effort.sibling-APP-12"].exists, "APP-11's card should link back to APP-12")
    }

    func testChangeAndClearEffort() {
        let app = open("APP-12")
        XCTAssertTrue(app.staticTexts["effort.count"].waitForExistence(timeout: 10))

        // Another effort: the card switches to its tasks.
        changeEffort(app)
        app.buttons["effort-Bigger screens"].tap()
        XCTAssertTrue(app.buttons["effort.sibling-APP-15"].waitForExistence(timeout: 5), "the card should list Bigger screens")
        XCTAssertEqual(app.staticTexts["effort.name"].label, "Bigger screens")
        XCTAssertFalse(app.buttons["effort.sibling-APP-11"].exists)
        XCTAssertEqual(app.staticTexts["effort.count"].label, "0 of 3 merged")

        // None: the card goes.
        changeEffort(app)
        app.buttons["effort-none"].tap()
        XCTAssertTrue(app.staticTexts["effort.count"].waitForNonExistence(timeout: 5), "the card should go")

        // A new one, named in the sheet.
        app.buttons["taskActions"].tap()
        XCTAssertTrue(app.buttons["Add to effort…"].waitForExistence(timeout: 5))
        app.buttons["Add to effort…"].tap()
        let field = app.textFields["effort-new"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Sync")
        app.buttons["effort-create"].tap()
        XCTAssertTrue(app.staticTexts["effort.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["effort.name"].label, "Sync")
        XCTAssertEqual(app.staticTexts["effort.count"].label, "0 of 1 merged")
        snap(app, "new-effort")
    }

    // MARK: Helpers

    private func open(_ task: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-task", task]
        app.launch()
        XCTAssertTrue(app.buttons["taskActions"].waitForExistence(timeout: 30), "\(task) should open")
        return app
    }

    private func changeEffort(_ app: XCUIApplication) {
        app.buttons["taskActions"].tap()
        XCTAssertTrue(app.buttons["Change effort…"].waitForExistence(timeout: 5), "the menu should offer Change effort…")
        app.buttons["Change effort…"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Effort for'")).firstMatch
            .waitForExistence(timeout: 5), "the effort sheet should open")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
