import XCTest

/// MF-370: a goal's docs on the iPhone. The demo's Mobile app goal has "Mobile docs plan" (demo-doc-1) with two
/// open threads, one from an agent, and a proposed decision. `TEST_RUNNER_SHOT_DIR` also writes the screenshots there.
@MainActor
final class DocScreenTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func screenshot(_ name: String) {
        let image = app.screenshot()
        let shot = XCTAttachment(screenshot: image)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testGoalDocsCommentsAndDecisions() {
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", "g-app"]
        app.launch()
        let docsRow = element("goal-docs")
        for _ in 0..<8 where !(docsRow.exists && docsRow.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(docsRow.waitForExistence(timeout: 15), "no Docs row on the goal")
        docsRow.tap()
        let row = element("doc-demo-doc-1")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the demo doc isn't listed")
        screenshot("ios-docs-list")
        row.tap()

        // Doc: the bundled embed renders the demo doc in the web view.
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "no web view")
        XCTAssertTrue(app.webViews.staticTexts["What ships"].waitForExistence(timeout: 15), "the doc didn't render")
        screenshot("ios-doc-tab")

        // Comments: type a reply, send it, then resolve the other thread.
        app.buttons["Comments 2"].tap()
        let reply = element("reply-th-1")
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        reply.typeText("Yes, greyed out under a toggle.")
        screenshot("ios-comments-reply-typed")
        app.buttons["Send"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Yes, greyed out under a toggle."].waitForExistence(timeout: 5), "the reply didn't land")
        element("resolve-th-2").tap()
        XCTAssertTrue(app.buttons["Comments 1"].waitForExistence(timeout: 5), "the thread didn't resolve")
        screenshot("ios-comments-resolved")

        // Decisions: accept with a different option and a why.
        app.buttons["Decisions 1"].tap()
        element("accept-dec-1").tap()
        app.buttons["Wait"].firstMatch.tap()
        let why = element("accept-why")
        why.tap()
        why.typeText("No Firebase project yet")
        screenshot("ios-decision-accepting")
        element("accept-confirm").tap()
        XCTAssertTrue(app.staticTexts["Accepted"].waitForExistence(timeout: 5), "the decision wasn't accepted")
        screenshot("ios-decision-accepted")
    }

    func testDecisionPushOpensDecisionsTab() {
        app.launchArguments = ["-demo", "YES", "-pushRef", "doc:demo-doc-1", "-pushReason", "decision"]
        app.launch()
        XCTAssertTrue(element("accept-dec-1").waitForExistence(timeout: 15), "didn't open on the Decisions tab")
        screenshot("ios-push-decision")
    }

    func testMentionPushOpensComments() {
        app.launchArguments = ["-demo", "YES", "-pushRef", "doc:demo-doc-1", "-pushReason", "mention"]
        app.launch()
        XCTAssertTrue(element("reply-th-1").waitForExistence(timeout: 15), "didn't open on the Comments tab")
        screenshot("ios-push-mention")
    }
}
