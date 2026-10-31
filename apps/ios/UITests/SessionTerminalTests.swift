import XCTest

/// A live session's terminal in the demo factory: session rows on Machines and maplefactory://session links
/// open it, your own machine's session takes the keyboard, and one shared with you to watch doesn't.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/SessionTerminalTests …
final class SessionTerminalTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "machines"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 60))
    }

    private var terminal: XCUIElement { app.descendants(matching: .any)["sessionTerminal"] }
    private var pill: XCUIElement { app.staticTexts["typingPill"] }

    private func openSession(_ task: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", task)).firstMatch
        // Further machines' rows are below the fold (and the list loads them lazily).
        for _ in 0..<5 where !(row.waitForExistence(timeout: 3) && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no session row for \(task)")
        row.tap()
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "\(task)'s terminal didn't open")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Your own machine's session: its output in the terminal, Typing, a keyboard on tap, and back to Machines.
    func testSessionRowOpensItsTerminal() {
        openSession("APP-12")
        XCTAssertTrue(app.navigationBars["APP-12"].exists)
        XCTAssertEqual(pill.label, "Typing")
        let output = (terminal.value as? String) ?? ""
        XCTAssertTrue(output.contains("Update(apps/web/src/limits.ts)"), "the demo's output isn't in the terminal: \(output)")
        XCTAssertTrue(app.staticTexts["terminalStatus"].label.hasPrefix("Live"))
        terminal.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "no keyboard for the machine's owner")
        shot("typing")
        app.navigationBars.buttons["Machines"].tap()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 10))
    }

    /// A session someone shared with you to watch: Watching, and no keyboard.
    func testSharedSessionOnlyWatches() {
        app.terminate()
        app.launchArguments += ["-demoRole", "member"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 60))
        openSession("BIL-7")
        XCTAssertEqual(pill.label, "Watching")
        XCTAssertTrue(((terminal.value as? String) ?? "").contains("Raised a hand"))
        let status = app.staticTexts["terminalStatus"]
        XCTAssertTrue(status.label.contains("shared by @sam to watch"), status.label)
        terminal.tap()
        sleep(2)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a watch-only share got a keyboard")
        shot("watching")
    }

    /// The task is a tap away from its session.
    func testOpenTaskFromTheSession() {
        openSession("APP-12")
        app.buttons["openTask"].tap()
        XCTAssertTrue(app.staticTexts["Rate limit API tokens per org"].waitForExistence(timeout: 10) || app.navigationBars["APP-12"].exists)
        XCTAssertFalse(terminal.exists)
    }

    /// maplefactory://session/<machine>/<id> lands on that session's terminal, from any tab.
    func testSessionLinkOpensItsTerminal() {
        app.tabBars.buttons["Goals"].tap()
        app.openLink("maplefactory://session/m-studio/s1")
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "the link didn't open the terminal")
        XCTAssertTrue(app.tabBars.buttons["Machines"].isSelected)
        XCTAssertTrue(app.navigationBars["APP-12"].exists)
        XCTAssertTrue(((terminal.value as? String) ?? "").contains("Thinking"))
    }
}

/// The terminal against a live dev factory (scripts/dev-stack.sh) with a running session MAPLE_SESSION on MAPLE_MACHINE.
/// MAPLE_AS signs in as another member (a teammate the session is shared with); MAPLE_EXPECT is "Watching",
/// "Typing", or "refused" (no share: the server's 403 shows and nothing retries). MAPLE_VIA=row taps the session's
/// row on Machines instead of opening its link; MAPLE_TYPE is text to type when it can.
///   TEST_RUNNER_MAPLE_FACTORY=localhost:8788 TEST_RUNNER_MAPLE_MACHINE=… TEST_RUNNER_MAPLE_SESSION=… \
///     xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/LiveSessionTerminalTests …
final class LiveSessionTerminalTests: XCTestCase {
    func testAttachSeeOutputAndLeave() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let factory = env["MAPLE_FACTORY"], let machine = env["MAPLE_MACHINE"], let session = env["MAPLE_SESSION"] else {
            throw XCTSkip("set MAPLE_FACTORY, MAPLE_MACHINE and MAPLE_SESSION to a dev factory's running session")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingURL", factory, "-onboardingContinue", "YES", "-tab", "machines"]
        if let login = env["MAPLE_AS"] { app.launchArguments += ["-devAs", login] }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Machines"].waitForExistence(timeout: 60), "didn't sign in")
        sleep(3)
        if env["MAPLE_VIA"] == "row" {
            // Tapping the session's row on Machines (a shell session's row reads "shell").
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'shell'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 30), "no session row")
            sleep(2)
            row.tap()
        } else {
            app.openLink("maplefactory://session/\(machine)/\(session)")
        }
        let terminal = app.descendants(matching: .any)["sessionTerminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the terminal didn't open")
        let status = app.staticTexts["terminalStatus"]
        let expect = env["MAPLE_EXPECT"] ?? "Typing"
        if expect == "refused" {
            XCTAssertTrue(poll { status.label.contains("or an admin can open terminals") }, "no refusal: \(status.label)")
            let first = status.label
            sleep(20)
            XCTAssertEqual(status.label, first, "it retried after a refusal")
        } else {
            XCTAssertTrue(poll { status.label.hasPrefix("Live") }, "never went live: \(status.label)")
            XCTAssertEqual(app.staticTexts["typingPill"].label, expect)
            XCTAssertTrue(poll { !((terminal.value as? String) ?? "").isEmpty }, "no output arrived")
            if let text = env["MAPLE_TYPE"], expect == "Typing" {
                terminal.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
                app.typeText(text)
                sleep(3)
            } else if expect == "Watching" {
                terminal.tap()
                sleep(2)
                XCTAssertFalse(app.keyboards.firstMatch.exists, "a watch-only share got a keyboard")
            }
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "live-\(expect)"
        attachment.lifetime = .keepAlways
        add(attachment)
        sleep(2)
        app.navigationBars.buttons.firstMatch.tap()
        sleep(3)
    }

    /// Checks `condition` twice a second for up to `timeout` seconds.
    private func poll(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(500_000)
        }
        return condition()
    }
}
