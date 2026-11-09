import XCTest

/// In the demo (MF-278): the Inbox's Requests list, and a request's Ask, Attach, Decline and Start task,
/// each changing its status and thread the way the factory would.
@MainActor
final class IntakeTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Requests from the toolbar, filtered to Unanswered: the Slack and Jira ones, not the accepted one.
    func testListAndFilter() throws {
        let app = launch([])
        let requests = app.buttons["inbox.requests"]
        XCTAssertTrue(requests.waitForExistence(timeout: 10), "the Inbox has no Requests button")
        XCTAssertTrue(app.buttons["inbox.newRequests"].exists, "the Inbox has no new-requests row")
        requests.tap()
        XCTAssertTrue(app.buttons["intake.row.req-welcome-cropped"].waitForExistence(timeout: 5), "All doesn't show the accepted request")
        app.buttons["intake.filter.unanswered"].tap()
        XCTAssertTrue(app.buttons["intake.row.req-mobile-logout"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["intake.row.req-invoice-pdf"].exists)
        XCTAssertFalse(app.buttons["intake.row.req-welcome-cropped"].exists, "Unanswered shows an accepted request")
        XCTAssertFalse(app.buttons["intake.row.req-rate-limits"].exists, "Unanswered shows one waiting on the requester")
        app.buttons["intake.row.req-mobile-logout"].tap()
        XCTAssertTrue(app.staticTexts["Needs before planning"].waitForExistence(timeout: 3) || app.staticTexts["NEEDS BEFORE PLANNING"].exists)
        XCTAssertTrue(app.buttons["intake.start"].exists, "no action bar")
    }

    /// Ask posts the question as the bot; the requester answers a moment later and it's New again.
    func testAsk() throws {
        let app = launch(["-intake", "req-mobile-logout"])
        app.buttons["intake.ask"].waitAndTap()
        let field = app.textFields["intake.askText"].exists ? app.textFields["intake.askText"] : app.textViews["intake.askText"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Which app versions see it?")
        app.buttons["intake.askSend"].tap()
        XCTAssertTrue(status(app, "Waiting on requester").waitForExistence(timeout: 3), "the request isn't waiting on the requester")
        XCTAssertTrue(status(app, "New").waitForExistence(timeout: 6), "the requester didn't reply")
        app.collectionViews.firstMatch.swipeUp()
        XCTAssertTrue(app.staticTexts["Which app versions see it?"].waitForExistence(timeout: 3), "the question isn't in the thread")
        XCTAssertTrue(app.staticTexts["Good question. 2.31 and up, iOS only so far. Android looks fine."].exists, "the reply isn't in the thread")
    }

    /// Attach to the related task: the request became it, and the actions are gone.
    func testAttach() throws {
        let app = launch(["-intake", "req-mobile-logout"])
        app.buttons["intake.attach"].waitAndTap()
        app.buttons["intake.attachTo.APP-12"].waitAndTap()
        XCTAssertTrue(status(app, "Became APP-12").waitForExistence(timeout: 3), "the request didn't become APP-12")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Added to APP-12.")).firstMatch.exists, "no bot message in the thread")
        XCTAssertFalse(app.buttons["intake.ask"].exists, "the actions still show")
        XCTAssertTrue(app.buttons["intake.openTask"].exists)
    }

    /// Decline confirms first, then reads Declined.
    func testDecline() throws {
        let app = launch(["-intake", "req-invoice-pdf"])
        app.buttons["intake.decline"].waitAndTap()
        app.buttons.matching(identifier: "intake.confirmDecline").firstMatch.waitAndTap()
        XCTAssertTrue(status(app, "Declined").waitForExistence(timeout: 3))
        app.collectionViews.firstMatch.swipeUp()
        XCTAssertTrue(app.staticTexts["Passed on this for now. Reply here if it becomes urgent."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["intake.start"].exists)
    }

    /// Start task: New task has the request's title, brief and suggested goal; the goal changes, it's sent,
    /// and the request becomes the new task.
    func testStartTask() throws {
        let app = launch(["-intake", "req-invoice-pdf"])
        app.buttons["intake.start"].waitAndTap()
        let title = app.textFields["newTask.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Customers can't download invoice PDFs over 10 MB")
        let brief = app.textViews["newTask.brief"].exists ? app.textViews["newTask.brief"] : app.textFields["newTask.brief"]
        let value = brief.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("> Three enterprise customers"), value)
        XCTAssertTrue(value.contains("- SUP-1182: Invoice PDF download times out"), value)
        let goal = app.buttons["newTask.goal"]
        XCTAssertTrue(goal.label.contains("Billing"), "the goal isn't the suggested one: \(goal.label)")
        XCTAssertTrue(app.staticTexts["SUP-1190 · Open"].exists, "the request's tickets aren't shown")
        goal.tap()
        app.buttons["Public API"].waitAndTap()
        XCTAssertTrue(app.buttons["newTask.goal"].label.contains("Public API"))
        app.buttons["newTask.send"].tap()
        XCTAssertTrue(status(app, "Became API-35").waitForExistence(timeout: 5), "the request didn't become the new task")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Tracking this as API-35")).firstMatch.exists)
        app.buttons["intake.openTask"].tap()
        XCTAssertTrue(app.staticTexts["Customers can't download invoice PDFs over 10 MB"].waitForExistence(timeout: 5), "the new task doesn't open")
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "inbox"] + extra
        app.launch()
        return app
    }

    private func status(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "intake.status", title)).firstMatch
    }
}

private extension XCUIElement {
    func waitAndTap(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: 5), "\(self) never showed", file: file, line: line)
        tap()
    }
}
