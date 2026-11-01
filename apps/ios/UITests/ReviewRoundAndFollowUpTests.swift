import XCTest

/// In the demo: Request review… on API-29 opens a round with your focus and then reads Reviewing…;
/// Select on its findings turns the open one into a linked draft in Public API, which then reads
/// Follow-up: API-34 with no checkbox; a note makes a free-text follow-up; API-31's findings are all
/// fixed, so none can be picked.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/ReviewRoundAndFollowUpTests …
final class ReviewRoundAndFollowUpTests: XCTestCase {
    func testRequestReview() {
        let app = launch(goal: "g-api")
        open(app, "API-29")

        let request = app.buttons["request-review"]
        XCTAssertTrue(revealInBar(request, in: app), "a reviewing task should offer Request review…")
        XCTAssertTrue(request.isEnabled)
        XCTAssertTrue(request.label.contains("Request review"))
        snap(app, "request-review-bar")

        request.tap()
        XCTAssertTrue(app.navigationBars["Request a review of API-29"].waitForExistence(timeout: 10), "the compose sheet should open")
        let send = app.navigationBars.buttons["Send"]
        XCTAssertFalse(send.isEnabled, "a review request needs a focus")
        app.typeText("Check security: can a read token reach write endpoints?")
        snap(app, "request-review-compose")
        XCTAssertTrue(send.isEnabled)
        send.tap()

        app.buttons["Review"].tap()
        let round = app.descendants(matching: .any)["review-round"]
        XCTAssertTrue(round.waitForExistence(timeout: 10))
        XCTAssertTrue(round.label.contains("Round 2 of 3: reviewing…"), "a new running round: \(round.label)")
        let focus = app.descendants(matching: .any)["review-round-focus"]
        XCTAssertTrue(focus.exists)
        XCTAssertTrue(focus.label.contains("andrea asked it to look at: Check security"), focus.label)
        XCTAssertTrue(request.label.contains("Reviewing…"), "the button should say a round is running: \(request.label)")
        XCTAssertFalse(request.isEnabled, "no second request while a round runs")
        snap(app, "request-review-running")
        XCTAssertTrue(revealInBar(request, in: app))
        snap(app, "request-review-disabled")
    }

    func testFollowUpFromFindings() {
        let app = launch(goal: "g-api")
        open(app, "API-29")
        app.buttons["Review"].tap()

        let select = app.buttons["findings-select"]
        XCTAssertTrue(scrollTo(select, in: app), "API-29's open findings should be selectable")
        XCTAssertFalse(app.descendants(matching: .any)["finding-pick-f1"].exists, "no checkboxes until Select")
        select.tap()

        let open = app.descendants(matching: .any)["finding-pick-f1"]
        let disputed = app.descendants(matching: .any)["finding-pick-f2"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the open finding gets a checkbox")
        XCTAssertTrue(disputed.exists, "a disputed finding isn't fixed, so it gets one too")
        let make = app.buttons["make-follow-ups"]
        XCTAssertTrue(scrollTo(make, in: app))
        XCTAssertFalse(make.isEnabled, "nothing picked yet")
        open.tap()
        XCTAssertTrue(make.label.contains("Make 1 follow-up task"), make.label)
        XCTAssertTrue(make.isEnabled)
        snap(app, "follow-up-picked")

        make.tap()
        XCTAssertTrue(app.navigationBars["Follow-up of API-29"].waitForExistence(timeout: 10), "the follow-up sheet should open")
        let title = field(app, "follow-up-title-0")
        XCTAssertTrue((title.value as? String)?.hasPrefix("Scopes are compared as strings") ?? false, "the title starts from the finding")
        snap(app, "follow-up-sheet")
        app.navigationBars.buttons["Make"].tap()

        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Made 1 follow-up of API-29; it's in Public API's drafts.")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "the factory's toast should say where it went")
        let followed = app.descendants(matching: .any)["finding-followed-f1"]
        XCTAssertTrue(scrollTo(followed, in: app), "the finding should name its follow-up")
        XCTAssertEqual(followed.label, "Follow-up: API-34")
        XCTAssertFalse(app.descendants(matching: .any)["finding-pick-f1"].exists, "a followed-up finding can't be picked again")
        snap(app, "follow-up-made")

        // The draft is in the goal, linked back to the finding.
        back(app, from: "API-29")
        let draft = app.buttons.containing(NSPredicate(format: "label CONTAINS 'API-34'")).firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10), "the follow-up should be in Public API")
        snap(app, "follow-up-in-goal")
        draft.tap()
        XCTAssertTrue(app.navigationBars["API-34"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Follow-up from API-29'")).firstMatch.waitForExistence(timeout: 5),
                      "its brief quotes the finding and links back")
        snap(app, "follow-up-draft")
    }

    func testFollowUpFromNote() {
        let app = launch(goal: "g-api")
        open(app, "API-29")
        app.buttons["Review"].tap()

        let note = app.buttons["follow-up-note"]
        XCTAssertTrue(scrollTo(note, in: app))
        note.tap()
        XCTAssertTrue(app.navigationBars["Follow-up of API-29"].waitForExistence(timeout: 10))
        let make = app.navigationBars.buttons["Make"]
        XCTAssertFalse(make.isEnabled, "a note needs a title")
        let title = field(app, "follow-up-title-0")
        title.tap()
        title.typeText("Document token scopes")
        XCTAssertFalse(make.isEnabled, "a note-only follow-up needs a brief too")
        let brief = field(app, "follow-up-brief-0")
        brief.tap()
        brief.typeText("Add a scopes table to the API docs.")
        XCTAssertTrue(make.isEnabled)
        snap(app, "follow-up-note-sheet")
        make.tap()

        XCTAssertTrue(app.staticTexts["Made 1 follow-up of API-29; it's in Public API's drafts."].waitForExistence(timeout: 5))
        snap(app, "follow-up-note-made")
        back(app, from: "API-29")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Document token scopes'")).firstMatch.waitForExistence(timeout: 10),
                      "the note's draft should be in Public API")
        snap(app, "follow-up-note-in-goal")
    }

    func testFixedFindingsCantBePicked() {
        let app = launch(goal: "g-api")
        open(app, "API-31")
        app.buttons["Review"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["finding-f1"].waitForExistence(timeout: 10), "API-31's findings should show")
        XCTAssertFalse(app.buttons["findings-select"].exists, "with every finding fixed there's nothing to select")
        XCTAssertFalse(app.descendants(matching: .any)["finding-pick-f1"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["finding-pick-f2"].exists)
        snap(app, "fixed-findings")
    }

    /// Opens on the goal's task list: API-29 and API-31 are kit's, so they're not in andrea's Inbox.
    private func launch(goal: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", goal]
        app.launch()
        return app
    }

    private func open(_ app: XCUIApplication, _ id: String) {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", id)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the list should show \(id)")
        row.tap()
        XCTAssertTrue(app.navigationBars[id].waitForExistence(timeout: 10))
    }

    /// Back to the goal: the leading button of this task's own navigation bar, so a sheet's or
    /// another screen's bar can't be picked by mistake.
    private func back(_ app: XCUIApplication, from id: String) {
        let bar = app.navigationBars[id]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "\(id) should be on screen to go back from")
        let button = bar.buttons.element(boundBy: 0)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(id) should have a back button")
        button.tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "going back should leave \(id)")
    }

    /// A vertical TextField is a text view or a text field, depending on the OS.
    private func field(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let view = app.textViews[id]
        return view.waitForExistence(timeout: 5) ? view : app.textFields[id]
    }

    /// Swipes the action bar along until `element` is on screen.
    private func revealInBar(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        // Hittable counts a button that's only partly on screen, so swipe until all of it is.
        let screen = app.windows.firstMatch.frame
        // A swipe flings past it, so drag the bar a short way at a time, no further than it's off.
        for _ in 0..<6 where !(element.isHittable && screen.contains(element.frame)) {
            let off = element.frame.maxX - screen.maxX + 24
            let by = off > 0 ? -min(off, 150) : min(screen.minX - element.frame.minX + 24, 150)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: screen.midX, dy: element.frame.midY))
            from.press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: screen.midX + by, dy: element.frame.midY)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        return element.isHittable && screen.contains(element.frame)
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
