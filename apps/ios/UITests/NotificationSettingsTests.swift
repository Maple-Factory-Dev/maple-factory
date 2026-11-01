import XCTest

/// Settings › Notifications in the demo factory (MF-272): this phone's sample registration, the
/// quiet-hours editor, and a tapped push opening its task. The demo sends nothing over the network.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/NotificationSettingsTests …
final class NotificationSettingsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments = ["-demo", "YES"] + extra
        app.launch()
    }

    func testRegistrationAndQuietHours() {
        launch()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 60))
        app.tabBars.buttons["Settings"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notifications'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("On"), "the Settings row should read On: \(row.label)")
        row.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 10))

        // This phone's sample registration, and another phone that can be swiped away.
        XCTAssertTrue(text("Allowed").exists, "permission should read Allowed")
        let registration = text("Registered · sandbox")
        XCTAssertTrue(registration.waitForExistence(timeout: 5), "this iPhone's registration isn't shown")
        let other = app.descendants(matching: .any)["pushDevice.0ldph0ne00000000"]
        XCTAssertTrue(other.exists)
        other.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertTrue(other.waitForNonExistence(timeout: 5), "the other phone wasn't removed")

        // Quiet hours: on gives one window; Add Window a second; swipe deletes it again.
        let toggle = app.switches["quietHoursToggle"]
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["quietWindow.0"].waitForExistence(timeout: 5))
        app.buttons["Add Window"].tap()
        let second = app.descendants(matching: .any)["quietWindow.1"]
        XCTAssertTrue(second.waitForExistence(timeout: 5), "Add Window didn't add one")
        second.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(second.waitForNonExistence(timeout: 5), "the window wasn't deleted")
        XCTAssertTrue(app.descendants(matching: .any)["quietWindow.0"].exists)

        // Off again clears the schedule.
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["quietWindow.0"].waitForNonExistence(timeout: 5))
    }

    /// Any element whose label holds `s` (LabeledContent merges its title and value into one).
    private func text(_ s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    /// `-pushRef` runs the same path as a tapped notification: pendingLink → TaskRoute on the Inbox.
    func testTappedNotificationOpensTheTask() {
        launch(["-pushRef", "API-31"])
        XCTAssertTrue(app.navigationBars["API-31"].waitForExistence(timeout: 60), "the task's detail didn't open")
        XCTAssertTrue(app.staticTexts["Rate limit API tokens per org"].exists)
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isSelected)
    }
}
