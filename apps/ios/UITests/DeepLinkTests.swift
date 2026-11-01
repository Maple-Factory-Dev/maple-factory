import XCTest

/// maplefactory:// links in the demo factory: a task link opens its detail on the Inbox tab, a
/// session link opens its terminal on Machines. Runs without a live factory.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/DeepLinkTests …
final class DeepLinkTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 60))
    }

    func testTaskLinkOpensTheTaskOnTheInbox() {
        app.tabBars.buttons["Goals"].tap()
        app.openLink("maplefactory://task/API-31")
        XCTAssertTrue(app.navigationBars["API-31"].waitForExistence(timeout: 20), "the task's detail didn't open")
        XCTAssertTrue(app.staticTexts["Rate limit API tokens per org"].exists)
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isSelected)
    }

    func testSessionLinkOpensMachines() {
        app.openLink("maplefactory://session/m-studio/s1")
        XCTAssertTrue(app.descendants(matching: .any)["sessionTerminal"].waitForExistence(timeout: 20), "the session's terminal didn't open")
        XCTAssertTrue(app.navigationBars["APP-12"].exists)
        XCTAssertTrue(app.tabBars.buttons["Machines"].isSelected)
    }

    func testOtherLinksAreIgnored() {
        app.openLink("maplefactory://goal/g-app")
        sleep(2)
        XCTAssertTrue(app.navigationBars["Inbox"].exists)
    }
}

extension XCUIApplication {
    /// Opens `link` as the system does, saying Open to its "Open in “Maple Factory”?" prompt.
    func openLink(_ link: String) {
        open(URL(string: link)!)
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if prompt.waitForExistence(timeout: 5) { prompt.tap() }
        _ = wait(for: .runningForeground, timeout: 20)
    }
}
