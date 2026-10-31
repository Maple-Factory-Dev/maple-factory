import XCTest

/// Against a live factory (scripts/dev-stack.sh): signs in with the onboarding flags, opens the first
/// plan awaiting approval from the inbox and approves it, then waits for the task to start building.
///   MAPLE_FACTORY=localhost:8788 xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests …
/// Skipped without MAPLE_FACTORY (set it with TEST_RUNNER_MAPLE_FACTORY when running through xcodebuild).
final class LiveApprovalTests: XCTestCase {
    func testApprovePlanFromTheInbox() throws {
        let factory = try XCTUnwrap(ProcessInfo.processInfo.environment["MAPLE_FACTORY"], "set MAPLE_FACTORY to a dev factory")
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingURL", factory, "-onboardingContinue", "YES"]
        app.launch()

        let section = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Plans awaiting approval'")).firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 20), "the inbox has no plans awaiting approval")
        sleep(2)

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Plan v'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let approve = app.buttons["Approve plan"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        sleep(2)
        approve.tap()

        let started = app.staticTexts.matching(NSPredicate(format: "label == 'Building' OR label == 'Reviewing'")).firstMatch
        XCTAssertTrue(started.waitForExistence(timeout: 20), "the task didn't move to building")
        sleep(3)
    }
}
