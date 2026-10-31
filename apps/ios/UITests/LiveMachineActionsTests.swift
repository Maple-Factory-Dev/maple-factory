import XCTest

/// Against a live factory (scripts/dev-stack.sh) whose runner is behind the release feed's latest:
/// Update sends machine.update and the row moves into Updating…; long-press → Rename renames the
/// machine (MAPLE_MACHINE, default dev-mac) to MAPLE_RENAME, which the Mac app then shows too.
///   TEST_RUNNER_MAPLE_FACTORY=localhost:8788 TEST_RUNNER_MAPLE_MACHINE=dev-mac xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/LiveMachineActionsTests …
/// Skipped (XCTSkip) without MAPLE_FACTORY. MachineActionsTests needs no server.
final class LiveMachineActionsTests: XCTestCase {
    func testUpdateAndRename() throws {
        let env = ProcessInfo.processInfo.environment
        guard let factory = env["MAPLE_FACTORY"] else { throw XCTSkip("set MAPLE_FACTORY to a dev factory") }
        let machine = env["MAPLE_MACHINE"] ?? "dev-mac"
        let name = env["MAPLE_RENAME"] ?? "Renamed from iPhone"
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-onboardingURL", factory, "-onboardingContinue", "YES", "-tab", "machines"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 30), "didn't sign in")

        let update = app.buttons["update-runner-\(machine)"]
        XCTAssertTrue(update.waitForExistence(timeout: 20), "the outdated runner should offer Update")
        sleep(2)
        update.tap()
        let updating = app.descendants(matching: .any)["runner-updating-\(machine)"]
        XCTAssertTrue(updating.waitForExistence(timeout: 15), "Update should move the row into Updating…")
        XCTAssertTrue(updating.label.contains("Updating"), updating.label)
        sleep(3)

        app.descendants(matching: .any)["machine-\(machine)"].press(forDuration: 1.2)
        let rename = app.buttons["Rename…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        let field = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + name)
        sleep(1)
        app.alerts.firstMatch.buttons["Rename"].tap()
        let renamed = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "machine-\(machine)", name)).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 15), "the factory should send back the new name")
        sleep(3)
    }
}
