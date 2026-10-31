import XCTest

/// Machines in the demo: Build Mini's runner is behind, Kit's MacBook Air is offline with BIL-8 (the demo
/// user's) and API-34 (Kit's) stranded on it. As an admin: Update shows progress and then the new version,
/// long-press → Rename changes the name shown, and Move takes the session off the Air with a toast. As a
/// plain member (`-demoRole member`): no Update or Rename on others' machines, and Move only on your own task.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/MachineActionsTests …
final class MachineActionsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testUpdateRenameAndMoveAsAdmin() {
        let app = launch()

        // Update: the outdated label has its button; a tap shows progress, then the new version.
        let update = app.buttons["update-runner-m-mini"]
        XCTAssertTrue(update.waitForExistence(timeout: 20), "Build Mini's outdated runner should offer Update")
        XCTAssertTrue(app.staticTexts["Runner 0.65.0 is out"].exists)
        snap(app, "machines-update-button")
        update.tap()
        let updating = app.descendants(matching: .any)["runner-updating-m-mini"]
        XCTAssertTrue(updating.waitForExistence(timeout: 5), "Update should show the progress row")
        XCTAssertTrue(updating.label.contains("Updating to runner 0.65.0"), updating.label)
        XCTAssertFalse(update.exists, "no second Update while it runs")
        snap(app, "machines-updating")
        XCTAssertTrue(app.descendants(matching: .any)["runner-updated-m-mini"].waitForExistence(timeout: 10), "it should finish on the new runner")

        // Rename: long-press the header, Rename…, type, and the new name shows.
        app.descendants(matching: .any)["machine-m-mini"].press(forDuration: 1.2)
        let rename = app.buttons["Rename…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "the long-press menu should offer Rename…")
        rename.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["A nickname everyone sees in place of m-mini. Leave it empty to go back to that."].exists)
        let field = alert.textFields.firstMatch
        XCTAssertEqual(field.value as? String, "Build Mini", "the field should start with the current name")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Build Mini".count) + "Release Mini")
        snap(app, "machines-rename-alert")
        alert.buttons["Rename"].tap()
        XCTAssertTrue(named(app, "Release Mini").waitForExistence(timeout: 5), "the new name should show")
        XCTAssertFalse(named(app, "Build Mini").exists)

        // Move: the offline Air's sessions offer it; confirming re-queues BIL-8 and toasts.
        let move = app.buttons["move-BIL-8"]
        scroll(app, to: move)
        XCTAssertTrue(app.buttons["move-API-34"].exists, "an admin can move anyone's task off a stuck machine")
        snap(app, "machines-move-button")
        move.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Move to another machine' AND NOT (identifier BEGINSWITH 'move-')")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Move should ask first")
        XCTAssertTrue(app.staticTexts["It re-queues first and carries on from its last push."].exists)
        snap(app, "machines-move-confirm")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["BIL-8 moves to the next free machine"].waitForExistence(timeout: 5), "the toast should say where it goes")
        snap(app, "machines-moved")
        XCTAssertTrue(move.waitForNonExistence(timeout: 5), "BIL-8's session should leave the Air")
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'BIL-8'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["move-API-34"].exists, "the other stranded session stays")
    }

    /// A member who neither owns the machine nor is an admin: none of the three, except Move on their own task.
    func testMemberSeesNoControlsOnOthersMachines() {
        let app = launch("-demoRole", "member")

        XCTAssertTrue(app.staticTexts["Runner 0.65.0 is out"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["update-runner-m-mini"].exists, "no Update on Sam's machine")

        app.descendants(matching: .any)["machine-m-mini"].press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["Rename…"].waitForExistence(timeout: 2), "no Rename on Sam's machine")
        dismissMenu(app)

        scroll(app, to: app.buttons["move-BIL-8"])
        XCTAssertFalse(app.buttons["move-API-34"].exists, "no Move on Kit's task")
        snap(app, "machines-as-member")
        app.descendants(matching: .any)["machine-m-air"].press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["Rename…"].waitForExistence(timeout: 2), "no Rename on Kit's machine")
        dismissMenu(app)

        // Their own machine is still theirs to rename.
        app.swipeDown()
        app.descendants(matching: .any)["machine-m-studio"].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Rename…"].waitForExistence(timeout: 5), "Rename on your own machine")
    }

    private func launch(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "machines", "-demoUpdateSeconds", "3"] + extra
        app.launch()
        return app
    }

    /// The header row combines its texts into one element, so match on its label.
    private func named(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'machine-m-' AND label BEGINSWITH %@", name)).firstMatch
    }

    private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    private func dismissMenu(_ app: XCUIApplication) {
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
