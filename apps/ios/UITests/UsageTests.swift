import XCTest

/// Settings → Usage in the demo: the Claude Code account Andrea's Mac Studio and Build Mini share, its
/// windows and run-out warning, the Mini's Codex account with its reset credits, and Kit's offline Air.
final class UsageTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    func testSharedAccountFromSettings() {
        let app = launch("-tab", "settings")
        let row = app.buttons["Usage"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Settings has a Usage row")
        snap(app, "settings-usage-row")
        row.tap()

        let window5h = element(app, "usage-window-claude-acct-team-5h")
        XCTAssertTrue(window5h.waitForExistence(timeout: 10))
        XCTAssertTrue(window5h.label.contains("Current session"), window5h.label)
        XCTAssertTrue(window5h.label.contains("82%"), window5h.label)
        XCTAssertTrue(window5h.label.contains("Resets in"), window5h.label)

        let week = element(app, "usage-window-claude-acct-team-7d")
        XCTAssertTrue(week.exists)
        XCTAssertTrue(week.label.contains("63%"), week.label)
        XCTAssertTrue(week.label.contains("Resets in 3d"), week.label)
        XCTAssertTrue(week.label.contains("at this pace"), "the week runs out early: \(week.label)")

        let fable = element(app, "usage-window-claude-acct-team-7d-Fable")
        XCTAssertTrue(fable.label.contains("5%"), fable.label)

        let machines = element(app, "usage-machines-claude-acct-team")
        XCTAssertTrue(machines.exists)
        XCTAssertTrue(machines.label.contains("Andrea's Mac Studio"), machines.label)
        XCTAssertTrue(machines.label.contains("Build Mini"), machines.label)
        XCTAssertTrue(app.staticTexts["Acme team · Andrea · on 2 machines"].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'on 2 machines'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'from Build Mini'")).firstMatch.exists, "the Mini's reading is the newer one")
        snap(app, "usage-light-1")

        let credits = app.staticTexts["2 reset credits"]
        for _ in 0..<5 where !(credits.exists && credits.isHittable) { app.swipeUp() }
        XCTAssertTrue(credits.exists, "the Codex account shows its credits")
        let codex = element(app, "usage-window-codex-acct-sam-codex-7d")
        XCTAssertTrue(codex.label.contains("8%"), codex.label)
        snap(app, "usage-light-2")

        let kit = element(app, "usage-machines-claude-acct-kit")
        for _ in 0..<5 where !(kit.exists && kit.isHittable) { app.swipeUp() }
        XCTAssertTrue(kit.label.contains("Kit's MacBook Air"), kit.label)
        XCTAssertTrue(kit.label.contains("Offline"), kit.label)
        snap(app, "usage-light-3")
    }

    func testLaunchArgumentInDarkMode() {
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        let app = launch("-usage", "YES")
        XCTAssertTrue(app.navigationBars["Usage"].waitForExistence(timeout: 20), "-usage YES opens Usage")
        XCTAssertTrue(element(app, "usage-window-claude-acct-team-5h").waitForExistence(timeout: 5))
        snap(app, "usage-dark-1")
        app.swipeUp()
        snap(app, "usage-dark-2")
    }

    func testEmptyState() {
        let app = launch("-usage", "YES", "-demoUsage", "none")
        XCTAssertTrue(app.staticTexts["No usage readings yet"].waitForExistence(timeout: 20))
        snap(app, "usage-empty")
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

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
