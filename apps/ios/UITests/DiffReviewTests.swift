import XCTest

/// In the demo: long-press a line of API-31's diff → Add note, twice (an added line and a removed one),
/// then Submit review sends them as one review: the bar goes, and the Timeline shows the change request.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/DiffReviewTests …
@MainActor
final class DiffReviewTests: XCTestCase {
    func testNoteLinesAndSubmitReview() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", "g-api"]
        app.launch()
        open(app, "API-31")
        app.buttons["Diff"].tap()

        // A note on an added line of the new file.
        let added = app.descendants(matching: .any)["diff-line-server/src/ratelimit.ts-new7"]
        XCTAssertTrue(scrollTo(added, in: app), "the diff should show ratelimit.ts line 7")
        snap(app, "diff-before")
        addNote(app, on: added, title: "Note on server/src/ratelimit.ts:7", text: "Return the seconds left in the window, not a fixed 12.")
        let pending = app.buttons["pending-notes"]
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "the review bar should show")
        XCTAssertEqual(pending.label, "1 pending note")

        // A note on the removed line, numbered on the old side.
        let removed = app.descendants(matching: .any)["diff-line-server/src/api.ts-old42"]
        XCTAssertTrue(scrollTo(removed, in: app), "the diff should show api.ts's removed line 42")
        addNote(app, on: removed, title: "Note on server/src/api.ts:42", text: "Keep a comment on why the limit runs after auth.")
        XCTAssertTrue(app.descendants(matching: .any)["note-marker-server/src/api.ts-old42"].waitForExistence(timeout: 5), "the noted line should be marked")

        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        XCTAssertEqual(pending.label, "2 pending notes")
        XCTAssertTrue(app.descendants(matching: .any)["note-marker-server/src/ratelimit.ts-new7"].exists)
        pending.tap()
        snap(app, "diff-two-pending-notes")

        app.buttons["submit-review"].tap()
        XCTAssertTrue(app.staticTexts["Review sent: 2 comments"].waitForExistence(timeout: 10), "the toast should say the review went")
        XCTAssertFalse(pending.exists, "the bar goes once the review's sent")
        snap(app, "review-sent")

        // One change request listing both notes.
        app.buttons["Timeline"].tap()
        let change = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '1. server/src/ratelimit.ts:L7: Return the seconds left' AND label CONTAINS '2. server/src/api.ts:L42: Keep a comment'")).firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 10), "the Timeline should show the change request with both notes")
        snap(app, "timeline-review-change-request")
    }

    private func addNote(_ app: XCUIApplication, on line: XCUIElement, title: String, text: String) {
        line.press(forDuration: 1.2)
        let add = app.buttons["Add note"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "long-press should offer Add note")
        add.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "the compose sheet should open for the line")
        let send = app.navigationBars.buttons["Add"]
        XCTAssertFalse(send.isEnabled, "a note needs text")
        app.typeText(text)
        snap(app, "compose-note")
        send.tap()
    }

    private func open(_ app: XCUIApplication, _ id: String) {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", id)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the goal should list \(id)")
        row.tap()
        XCTAssertTrue(app.navigationBars[id].waitForExistence(timeout: 10))
    }

    /// Swipes the task up until `element` is on screen.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<8 {
            if element.exists && element.isHittable { return true }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
