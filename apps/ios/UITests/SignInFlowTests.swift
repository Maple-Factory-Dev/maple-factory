import XCTest

/// The sign-in flow (SignInView.swift) step by step, using `-onboardingStep` sample data so no server is needed:
/// the Recent list and the bad-address hint, the connection checks (and a failed one), what GitHub shares,
/// and the device code's Copy → Copied. With `TEST_RUNNER_SHOTS=<dir>` passed to xcodebuild, testScreenshots
/// writes every step in light and dark, at the default and an accessibility text size, there as PNGs.
final class SignInFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    func testAddressStepShowsRecentAndHint() {
        let app = launch("address")
        let field = app.textFields["signin-address"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the address field shows")
        XCTAssertTrue(element(app, "signin-steps").exists, "step dots show")
        XCTAssertEqual(element(app, "signin-steps").label, "Step 1 of 3: Connect")
        XCTAssertTrue(element(app, "signin-setup").exists, "the maplefactory.dev footer shows")
        XCTAssertTrue(element(app, "signin-demo").exists, "the demo is a quiet button")

        // Recent sits above the field; tapping one fills its address in (the sample can't switch for real).
        let recent = element(app, "signin-recent-maple.atlas.dev")
        XCTAssertTrue(recent.exists, "Recent lists saved factories")
        XCTAssertLessThan(recent.frame.minY, field.frame.minY, "Recent is above the address field")
        recent.tap()
        XCTAssertEqual(field.value as? String, "maple.atlas.dev")

        // Something that isn't an address: Continue says why instead of being greyed out.
        app.terminate()
        let fresh = launch("address")
        let empty = fresh.textFields["signin-address"]
        XCTAssertTrue(empty.waitForExistence(timeout: 20))
        empty.tap()
        empty.typeText("not an address")
        let go = fresh.buttons["signin-continue"]
        XCTAssertTrue(go.isEnabled, "Continue isn't greyed out")
        go.tap()
        let hint = element(fresh, "signin-hint")
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "an inline hint explains")
        XCTAssertTrue(hint.label.contains("maple.yourteam.dev"), hint.label)
    }

    func testConnectionChecks() {
        let app = launch("connecting")
        for key in ["reach", "secure", "factory"] {
            XCTAssertTrue(element(app, "signin-check-\(key)").waitForExistence(timeout: 20), "the \(key) check shows")
        }
        XCTAssertTrue(element(app, "signin-check-reach").label.contains("Reaching maple.atlas.dev"))
        XCTAssertTrue(element(app, "signin-check-secure").label.contains("Secure connection"))
        XCTAssertTrue(element(app, "signin-check-factory").label.contains("Found the atlas factory"))
        XCTAssertFalse(app.buttons["signin-continue"].isEnabled, "nothing to press while it checks")
    }

    func testFailedCheckKeepsAddressForRetry() {
        let app = launch("failed")
        let error = element(app, "signin-check-error")
        XCTAssertTrue(error.waitForExistence(timeout: 20), "the failing check says why")
        XCTAssertTrue(error.label.contains("Update Maple Factory"), "a protocol mismatch says which side to update: \(error.label)")
        XCTAssertEqual(app.textFields["signin-address"].value as? String, "maple.atlas.dev", "what was typed stays")
        XCTAssertEqual(app.buttons["signin-continue"].label, "Try again")
    }

    func testSignInPermissionsThenCode() {
        let app = launch("signin")
        let github = app.buttons["signin-github"]
        XCTAssertTrue(github.waitForExistence(timeout: 20))
        XCTAssertEqual(element(app, "signin-steps").label, "Step 2 of 3: Sign in")
        XCTAssertTrue(app.staticTexts["Sign in to join"].exists)
        XCTAssertTrue(element(app, "signin-factory").label.contains("Connected"), "the factory header shows it's connected")
        XCTAssertTrue(app.staticTexts["Your name and avatar"].exists)
        XCTAssertTrue(app.staticTexts["Membership in atlas, to match your team"].exists)
        XCTAssertTrue(app.staticTexts["Nothing else. Agents use the factory's own GitHub App for PRs."].exists)
        XCTAssertTrue(app.buttons["signin-change"].exists, "Wrong factory? Change address")

        github.tap()
        let code = element(app, "signin-code")
        XCTAssertTrue(code.waitForExistence(timeout: 5), "the GitHub code shows")
        XCTAssertEqual(code.label, "WDJB-MJHT")
        XCTAssertTrue(app.buttons["signin-open-github"].exists, "Copy code and open GitHub")
        XCTAssertTrue(element(app, "signin-waiting").exists, "Waiting for GitHub…")
        let copy = app.buttons["signin-copy"]
        XCTAssertEqual(copy.label, "Copy code")
        copy.tap()
        XCTAssertTrue(waitLabel(copy, "Copied"), "Copy turns into Copied")
        XCTAssertTrue(waitLabel(copy, "Copy code", timeout: 4), "and back after a moment")

        app.buttons["signin-change"].tap()
        XCTAssertTrue(app.textFields["signin-address"].waitForExistence(timeout: 5), "Change address goes back")
    }

    func testAuthorizingAndDevServer() {
        let app = launch("authorizing")
        XCTAssertTrue(element(app, "signin-code").waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["signin-open-again"].exists, "Open again once GitHub was opened")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Code expires in 14:'")).firstMatch.exists)
        app.terminate()

        let dev = launch("dev")
        let button = dev.buttons["signin-github"]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        XCTAssertEqual(button.label, "Continue as @dev")
    }

    /// Every step in light and dark, at the default text size and at Accessibility XL, for the review.
    func testScreenshots() throws {
        guard ProcessInfo.processInfo.environment["SHOTS"] != nil else { throw XCTSkip("set TEST_RUNNER_SHOTS to save screenshots") }
        let sizes = [("default", nil), ("ax-xl", "UICTContentSizeCategoryAccessibilityXL")] as [(String, String?)]
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            sleep(2)
            let mode = appearance == .dark ? "dark" : "light"
            for (sizeName, size) in sizes {
                for step in ["address", "connecting", "failed", "signin", "authorizing"] {
                    let extra = size.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []
                    let app = launch(step, extra: extra)
                    XCTAssertTrue(element(app, "signin-steps").waitForExistence(timeout: 20))
                    snap(app, "signin-\(step)-\(mode)-\(sizeName)")
                    // At big sizes the bottom of the screen scrolls; capture it too so nothing's hidden.
                    if size != nil {
                        app.swipeUp()
                        snap(app, "signin-\(step)-\(mode)-\(sizeName)-bottom")
                    }
                    app.terminate()
                }
            }
        }
    }

    private func launch(_ step: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingStep", step] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 3) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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
