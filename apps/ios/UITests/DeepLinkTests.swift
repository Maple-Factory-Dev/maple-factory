import XCTest

/// maplefactory:// links in the demo factory: a task link opens its detail on the Inbox tab, a
/// session link switches to Machines. Runs without a live factory.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/DeepLinkTests …
final class DeepLinkTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 15))
    }

    func testTaskLinkOpensTheTaskOnTheInbox() {
        app.tabBars.buttons["Goals"].tap()
        app.open(URL(string: "maplefactory://task/API-31")!)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.navigationBars["API-31"].waitForExistence(timeout: 10), "the task's detail didn't open")
        XCTAssertTrue(app.staticTexts["Rate limit API tokens per org"].exists)
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isSelected)
    }

    func testSessionLinkOpensMachines() {
        app.open(URL(string: "maplefactory://session/m-studio/s-1")!)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 10), "Machines didn't open")
        XCTAssertTrue(app.tabBars.buttons["Machines"].isSelected)
    }

    func testOtherLinksAreIgnored() {
        app.open(URL(string: "maplefactory://goal/g-app")!)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(1)
        XCTAssertTrue(app.navigationBars["Inbox"].exists)
    }
}
