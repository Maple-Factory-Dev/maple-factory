import XCTest

/// Settings in the demo: the iOS-style menu opens Repositories, People, Secrets and Merging, and each
/// screen's admin action changes what it shows. As a member (`-demoRole member`) they're read-only.
/// With `TEST_RUNNER_SHOTS=<dir>` passed to xcodebuild, screenshots are also written there as PNGs.
final class SettingsMenuTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    func testAdminActionsChangeEachScreen() {
        let app = launch("-tab", "settings")
        XCTAssertTrue(element(app, "settings-repos").waitForExistence(timeout: 20), "Settings lists Repositories")
        snap(app, "settings-menu-light")

        // Repositories: hold acme/api, then release it.
        element(app, "settings-repos").tap()
        let api = element(app, "repo-acme/api")
        XCTAssertTrue(api.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "hold-badge-acme/docs").exists, "the demo's held repo shows its badge")
        XCTAssertFalse(element(app, "hold-badge-acme/api").exists)
        api.swipeLeft()
        app.buttons["Hold merges"].firstMatch.tap()
        let reason = app.alerts.textFields.firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        reason.typeText("Incident #7")
        app.alerts.buttons["Hold merges"].tap()
        XCTAssertTrue(element(app, "hold-badge-acme/api").waitForExistence(timeout: 5), "holding shows the badge")
        snap(app, "repos-held")
        element(app, "repo-acme/api").swipeLeft()
        app.buttons["Release merges"].firstMatch.tap()
        XCTAssertTrue(waitGone(element(app, "hold-badge-acme/api")), "releasing removes the badge")
        back(app)

        // People: make Sam an admin.
        element(app, "settings-people").tap()
        let samRole = element(app, "role-sam")
        XCTAssertTrue(samRole.waitForExistence(timeout: 10))
        XCTAssertEqual(samRole.label, "Member")
        XCTAssertFalse(element(app, "member-menu-andrea").exists, "no menu on your own row")
        element(app, "member-menu-sam").tap()
        app.buttons["Make admin"].tap()
        XCTAssertTrue(waitLabel(element(app, "role-sam"), "Admin"), "Sam is an admin now")
        snap(app, "people")
        back(app)

        // Secrets: add one to acme/web, then delete it.
        element(app, "settings-secrets").tap()
        XCTAssertTrue(element(app, "secret-acme/api-DATABASE_URL").waitForExistence(timeout: 10))
        element(app, "add-secret").tap()
        let name = app.textFields["secret-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("SENTRY_DSN")
        let value = app.secureTextFields["secret-value"]
        value.tap(); value.typeText("https://example")
        app.buttons["save-secret"].tap()
        let added = element(app, "secret-acme/app-SENTRY_DSN")
        XCTAssertTrue(added.waitForExistence(timeout: 5), "the new secret is listed under the first repo")
        XCTAssertFalse(added.label.contains("https://example"), "values are never shown")
        snap(app, "secrets")
        added.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        app.sheets.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(waitGone(element(app, "secret-acme/app-SENTRY_DSN")), "deleting removes it")
        back(app)

        // Merging: turn off automatic merges.
        element(app, "settings-merging").tap()
        let toggle = app.switches["toggle-autoMerges"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(waitValue(toggle, "0"), "the toggle saved off")
        snap(app, "merging")
        back(app)
        XCTAssertTrue(waitLabel(element(app, "settings-merging"), "Manual", contains: true), "the menu shows merges are manual")
    }

    func testMemberSeesReadOnlyScreens() {
        let app = launch("-tab", "settings", "-demoRole", "member")
        XCTAssertTrue(element(app, "settings-repos").waitForExistence(timeout: 20))
        element(app, "settings-repos").tap()
        XCTAssertTrue(element(app, "admin-only-note").waitForExistence(timeout: 10))
        element(app, "repo-acme/api").swipeLeft()
        XCTAssertFalse(app.buttons["Hold merges"].exists, "no hold action for members")
        back(app)

        element(app, "settings-people").tap()
        XCTAssertTrue(element(app, "admin-only-note").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "member-menu-sam").exists, "no grant or revoke for members")
        back(app)

        element(app, "settings-secrets").tap()
        XCTAssertTrue(element(app, "admin-only-note").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "add-secret").exists, "no add for members")
        back(app)

        element(app, "settings-merging").tap()
        let toggle = app.switches["toggle-autoMerges"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertFalse(toggle.isEnabled, "toggles are disabled for members")
        XCTAssertTrue(element(app, "admin-only-note").exists)
    }

    /// Each screen in light and dark, as an admin and as a member, for the review.
    func testScreenshots() throws {
        guard ProcessInfo.processInfo.environment["SHOTS"] != nil else { throw XCTSkip("set TEST_RUNNER_SHOTS to save screenshots") }
        for role in ["admin", "member"] {
            for appearance in [XCUIDevice.Appearance.light, .dark] {
                XCUIDevice.shared.appearance = appearance
                sleep(2) // Let the simulator switch before the app launches.
                let mode = appearance == .dark ? "dark" : "light"
                for pane in ["menu", "repos", "people", "secrets", "merging"] {
                    if role == "member" && pane == "menu" { continue }
                    let app = pane == "menu" ? launch("-tab", "settings", "-demoRole", role) : launch("-settings", pane, "-demoRole", role)
                    XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20))
                    XCUIDevice.shared.appearance = appearance
                    snap(app, "\(role)-\(pane)-\(mode)")
                    app.terminate()
                }
            }
        }
    }

    private func launch(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func waitGone(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    private func waitLabel(_ element: XCUIElement, _ label: String, contains: Bool = false) -> Bool {
        let format = contains ? "label CONTAINS %@" : "label == %@"
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    private func waitValue(_ element: XCUIElement, _ value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
