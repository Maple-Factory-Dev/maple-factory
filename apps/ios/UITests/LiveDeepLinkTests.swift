import XCTest

/// maplefactory:// links against a live dev factory (scripts/dev-stack.sh) holding a task MAPLE_TASK.
///   TEST_RUNNER_MAPLE_FACTORY=localhost:8788 TEST_RUNNER_MAPLE_TASK=LNK-1 xcodebuild test -scheme "Maple Factory" \
///     -only-testing:MapleFactoryUITests/LiveDeepLinkTests …
/// The signed-out test needs the app freshly installed (no saved factory). Skipped without MAPLE_FACTORY.
final class LiveDeepLinkTests: XCTestCase {
    private var factory = ""
    private var task = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let factory = env["MAPLE_FACTORY"], let task = env["MAPLE_TASK"] else {
            throw XCTSkip("set MAPLE_FACTORY to a dev factory and MAPLE_TASK to one of its tasks")
        }
        self.factory = factory
        self.task = task
    }

    /// Signed out, a task link waits on the sign-in screen; signing in lands on the task.
    func testTaskLinkOpenedSignedOutOpensAfterSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingURL", factory]
        app.launch()
        let signIn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sign in'")).firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 60), "the sign-in screen didn't show")
        sleep(2)
        app.openLink("maplefactory://task/\(task)")
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "the link skipped sign-in")
        sleep(2)
        signIn.tap()
        XCTAssertTrue(app.navigationBars[task].waitForExistence(timeout: 30), "signing in didn't open \(task)")
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isSelected)
        sleep(3)
    }

    /// Signed in: a task link opens its detail on the Inbox tab, then a session link switches to Machines.
    func testLinksWhileSignedIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingURL", factory, "-onboardingContinue", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Inbox"].waitForExistence(timeout: 60), "didn't sign in")
        app.tabBars.buttons["Settings"].tap()
        sleep(2)
        app.openLink("maplefactory://task/\(task)")
        XCTAssertTrue(app.navigationBars[task].waitForExistence(timeout: 30), "the link didn't open \(task)")
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isSelected)
        sleep(3)
        app.openLink("maplefactory://session/dev-mac/s-1")
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 30), "Machines didn't open")
        XCTAssertTrue(app.tabBars.buttons["Machines"].isSelected)
        sleep(5)
    }
}
