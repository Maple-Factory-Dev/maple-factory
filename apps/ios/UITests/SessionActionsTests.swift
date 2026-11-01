import XCTest

/// Start, share and end live sessions from Machines, in the demo. The Studio is the demo user's: New session
/// starts Claude in a folder and lands on its terminal; the ⋯ menu shares it with Sam (watch, then type);
/// End session asks first and the terminal says it ended. As a plain member (`-demoRole member`), Sam's
/// Build Mini offers none of New session, Share or End.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/SessionActionsTests …
final class SessionActionsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testStartShareAndEndAsOwner() {
        let app = launch()

        // New session: the sheet lists the Studio's agents and folders.
        let new = app.buttons["new-session-m-studio"]
        scroll(app, to: new)
        snap(app, "machines-new-session-row")
        new.tap()
        let start = app.buttons["new-session-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "New session should open the sheet")
        XCTAssertTrue(app.staticTexts["claude"].exists, "the Studio's agents are listed")
        XCTAssertTrue(app.staticTexts["codex"].exists)
        XCTAssertTrue(app.staticTexts["~"].exists, "home is the first folder")
        XCTAssertTrue(app.staticTexts["~/maple/worktrees/app-12"].exists, "and the folders its sessions are in")
        XCTAssertTrue(app.staticTexts["Other…"].exists)
        snap(app, "new-session-sheet")
        XCTAssertTrue(start.isEnabled)
        start.tap()

        // It lands on the new session's terminal.
        let menu = app.buttons["session-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Start should open the new session's terminal")
        XCTAssertTrue(app.staticTexts["~"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS '· ~'")).firstMatch.exists)
        snap(app, "new-session-terminal")

        // Share it with Sam, then let Sam type.
        menu.tap()
        let share = app.buttons["session-share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        XCTAssertTrue(app.staticTexts["Not shared with anyone."].waitForExistence(timeout: 5))
        app.buttons["share-add"].tap()
        let sam = app.buttons["Sam Rivera (@sam)"]
        XCTAssertTrue(sam.waitForExistence(timeout: 5), "Add a teammate lists the org's members")
        XCTAssertFalse(app.buttons["Andrea (@andrea)"].exists, "not the owner")
        sam.tap()
        let access = app.buttons["share-access-sam"]
        XCTAssertTrue(access.waitForExistence(timeout: 5), "Sam is added")
        XCTAssertTrue(access.label.contains("Can watch") || (access.value as? String ?? "").contains("Can watch"), access.label)
        XCTAssertFalse(app.descendants(matching: .any)["share-type-warning"].exists)
        access.tap()
        let canType = app.buttons["Can type"]
        XCTAssertTrue(canType.waitForExistence(timeout: 5))
        canType.tap()
        XCTAssertTrue(app.descendants(matching: .any)["share-type-warning"].waitForExistence(timeout: 5), "Can type warns it gives a shell")
        snap(app, "share-sheet-can-type")
        app.buttons["Done"].tap()

        // The menu now says who it's shared with; End session asks first.
        menu.tap()
        XCTAssertTrue(app.buttons["Shared with 1…"].waitForExistence(timeout: 5), "the menu counts the shares")
        app.buttons["session-end"].tap()
        XCTAssertTrue(app.staticTexts["Its terminal closes for everyone watching."].waitForExistence(timeout: 5), "End should ask first")
        snap(app, "end-session-confirm")
        app.buttons.matching(NSPredicate(format: "label == 'End session' AND identifier != 'session-end'")).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminalBanner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Session ended"].exists)
        XCTAssertFalse(menu.exists, "the menu hides once it ends")
        snap(app, "session-ended")
    }

    /// Swipes on the Machines tab: End on the trailing side with a confirm, Share on the leading side.
    func testSwipeShareAndEndOnMachines() {
        let app = launch()
        let row = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'APP-12'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.swipeRight()
        let share = app.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "the leading swipe offers Share")
        share.tap()
        XCTAssertTrue(app.buttons["share-add"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        row.swipeLeft()
        let end = app.buttons["End"]
        XCTAssertTrue(end.waitForExistence(timeout: 5), "the trailing swipe offers End")
        end.tap()
        XCTAssertTrue(app.staticTexts["End claude · APP-12?"].waitForExistence(timeout: 5), "End should name the session and ask first")
        app.buttons["End session"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "the session leaves the machine")
    }

    /// A member on Sam's Build Mini: no New session, no Share or End swipes, no ⋯ menu on its shared session.
    func testMemberSeesNoSessionControlsOnOthersMachines() {
        let app = launch("-demoRole", "member")
        XCTAssertTrue(app.descendants(matching: .any)["machine-m-mini"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["new-session-m-studio"].exists, "their own machine still offers New session")
        let row = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'BIL-7'")).firstMatch
        scroll(app, to: row)
        XCTAssertFalse(app.buttons["new-session-m-mini"].exists, "no New session on Sam's machine")
        XCTAssertFalse(app.buttons["new-session-m-air"].exists, "no New session on Kit's machine")
        row.swipeLeft()
        XCTAssertFalse(app.buttons["End"].waitForExistence(timeout: 2), "no End swipe on Sam's session")
        row.swipeRight()
        XCTAssertFalse(app.buttons["Share"].waitForExistence(timeout: 2), "no Share swipe on Sam's session")
        snap(app, "machines-as-member")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["typingPill"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["session-menu"].exists, "no ⋯ menu on a session shared with you")
    }

    private func launch(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "machines"] + extra
        app.launch()
        return app
    }

    private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        _ = element.waitForExistence(timeout: 20)
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
