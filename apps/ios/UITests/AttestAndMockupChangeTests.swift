import XCTest

/// In the demo: Request change under APP-14's mockup marks it changes requested and queues the change
/// for the planner; I checked it on APP-12's pending Done when item, with no note, proves it as attested.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/AttestAndMockupChangeTests …
final class AttestAndMockupChangeTests: XCTestCase {
    func testRequestMockupChange() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        open(app, "APP-14")

        let request = app.buttons["mockup-change-m1"]
        XCTAssertTrue(scrollTo(request, in: app), "the mockup should offer Request change")
        snap(app, "mockup-request-change")

        request.tap()
        XCTAssertTrue(app.navigationBars["Change \"The notification\""].waitForExistence(timeout: 10), "the compose sheet should open for the mockup")
        let send = app.navigationBars.buttons["Request"]
        XCTAssertFalse(send.isEnabled, "a mockup change needs text")
        app.typeText("Put the task title first, then the goal.")
        snap(app, "mockup-compose")
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let requested = app.descendants(matching: .any)["mockup-changes-requested-m1"]
        XCTAssertTrue(scrollTo(requested, in: app), "the mockup should show changes requested")
        XCTAssertTrue(requested.label.contains("v2 coming"))
        XCTAssertFalse(request.exists, "Request change goes once it's asked for")
        snap(app, "mockup-changes-requested")

        // The change is queued for the planner, anchored on the mockup.
        app.buttons["Timeline"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Put the task title first'")).firstMatch.waitForExistence(timeout: 10))
        snap(app, "timeline-change-queued")
    }

    func testAttestDoneItemWithNoNote() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        open(app, "APP-12")

        // Only unproven items offer it: item 0 is proven by tests already.
        let attest = app.buttons["attest-1"]
        XCTAssertTrue(scrollTo(attest, in: app), "a pending Done when item should offer I checked it")
        XCTAssertFalse(app.buttons["attest-0"].exists, "a proven item shouldn't offer I checked it")
        XCTAssertTrue(app.buttons["attest-2"].exists)
        snap(app, "done-when-before")

        attest.tap()
        XCTAssertTrue(app.navigationBars["I checked it"].waitForExistence(timeout: 10), "the compose sheet should open")
        let send = app.navigationBars.buttons["Mark checked"]
        XCTAssertTrue(send.isEnabled, "the note is optional")
        snap(app, "attest-compose")
        send.tap()

        let attested = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Attested by'")).firstMatch
        XCTAssertTrue(scrollTo(attested, in: app), "the item should show who attested it")
        XCTAssertFalse(app.buttons["attest-1"].exists, "the proven item shouldn't offer I checked it any more")
        XCTAssertTrue(app.buttons["attest-2"].exists)
        snap(app, "done-when-attested")

        // With a note, the summary carries it.
        app.buttons["attest-2"].tap()
        XCTAssertTrue(app.navigationBars["I checked it"].waitForExistence(timeout: 10))
        app.typeText("Signed out on my phone and checked the container.")
        app.navigationBars.buttons["Mark checked"].tap()
        let withNote = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ': Signed out on my phone'")).firstMatch
        XCTAssertTrue(scrollTo(withNote, in: app), "the summary should carry the note")
        snap(app, "done-when-attested-with-note")
    }

    private func open(_ app: XCUIApplication, _ id: String) {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", id)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the inbox should list \(id)")
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
