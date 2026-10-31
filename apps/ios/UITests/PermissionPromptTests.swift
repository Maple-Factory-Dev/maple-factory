import XCTest

/// The demo's APP-16 builder is stopped at a Bash permission prompt: the Machines row says so, the
/// task shows the card, and Yes answers it, so the card goes and the session is working again.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/PermissionPromptTests …
final class PermissionPromptTests: XCTestCase {
    func testAnswerYesInTheDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "machines"]
        app.launch()

        let badge = app.descendants(matching: .any)["session-needs-permission"]
        XCTAssertTrue(badge.waitForExistence(timeout: 20), "the Machines row should say needs permission")
        XCTAssertTrue(app.staticTexts["Bash: npm install @sentry/react-native"].exists)
        snap(app, "machines-needs-permission")

        app.buttons.containing(NSPredicate(format: "label CONTAINS 'APP-16'")).firstMatch.tap()
        let card = app.descendants(matching: .any)["permission-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the task should show the permission card")
        XCTAssertTrue(app.staticTexts["cd app && npm install @sentry/react-native --save"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'install scripts'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["permission-no"].exists)
        snap(app, "task-permission-card")

        app.buttons["permission-yes"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "answering should clear the card")
        snap(app, "task-answered")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Allowed"].waitForExistence(timeout: 10), "the session should be working again")
        XCTAssertFalse(badge.exists, "the row shouldn't say needs permission any more")
        XCTAssertTrue(app.staticTexts["working"].exists)
        snap(app, "machines-working")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
