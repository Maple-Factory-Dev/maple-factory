import XCTest

/// A goal's drafts and backlog in the demo factory, on its All tasks screen: swipe a draft to Plan or Backlog, swipe a backlog
/// task to Plan, and drag drafts into order in Edit mode. Runs without a live factory.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/GoalDraftsTests …
final class GoalDraftsTests: XCTestCase {
    private var app: XCUIApplication!

    private let ipad = "iPad layout with a sidebar"
    private let widget = "Home screen widget for the inbox"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func open(goal: String, title: String) {
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", goal]
        app.launch()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 60), "the goal didn't open")
        openAllTasks()
    }

    /// The stage-by-stage list, from the bottom of the goal's Overview.
    private func openAllTasks() {
        let all = app.buttons["goal-all-tasks"]
        for _ in 0..<5 where !(all.exists && all.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        all.tap()
        XCTAssertTrue(app.navigationBars["All tasks"].waitForExistence(timeout: 10), "All tasks didn't open")
    }

    private func header(_ text: String) -> XCUIElement { app.staticTexts[text] }

    /// Scrolls the goal until `element` is on screen: the list only builds rows near the viewport.
    private func reveal(_ element: XCUIElement) {
        let list = app.collectionViews.firstMatch
        for _ in 0..<3 where !(element.exists && element.isHittable) { list.swipeUp() }
        for _ in 0..<4 where !(element.exists && element.isHittable) { list.swipeDown() }
    }

    /// Scrolls to the end of the goal, where the drafts sit clear of the tab bar.
    private func scrollToBottom() {
        for _ in 0..<2 { app.collectionViews.firstMatch.swipeUp() }
    }

    /// Swipes the row titled `title` left and taps `action`.
    private func swipe(_ title: String, _ action: String) {
        let row = app.staticTexts[title]
        // Lift the row clear of the tab bar so its swipe buttons are on screen.
        scrollToBottom()
        reveal(row)
        XCTAssertTrue(row.exists, "\(title) isn't listed")
        row.swipeLeft()
        let button = app.buttons[action]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(action) swipe action")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "swipe \(title)"
        shot.lifetime = .keepAlways
        add(shot)
        button.tap()
    }

    /// Whether `row` sits under the section `header`.
    private func assertRow(_ title: String, under header: String, file: StaticString = #filePath, line: UInt = #line) {
        let heading = self.header(header)
        reveal(heading)
        XCTAssertTrue(heading.exists, "no \(header) section", file: file, line: line)
        let row = app.staticTexts[title]
        reveal(row)
        XCTAssertTrue(row.exists, "\(title) isn't listed", file: file, line: line)
        XCTAssertGreaterThan(row.frame.minY, heading.frame.minY, "\(title) isn't under \(header)", file: file, line: line)
    }

    func testPlanSwipeSendsADraftToPlanning() {
        open(goal: "g-app", title: "Mobile app")
        reveal(header("Drafting · 2"))
        XCTAssertTrue(header("Drafting · 2").exists)
        swipe(ipad, "Plan")
        assertRow(ipad, under: "Planning · 1")
        reveal(header("Drafting · 1"))
        XCTAssertTrue(header("Drafting · 1").exists)
        XCTAssertGreaterThan(header("Drafting · 1").frame.minY, app.staticTexts[ipad].frame.minY, "still listed as a draft")
    }

    func testBacklogSwipeParksADraft() {
        open(goal: "g-app", title: "Mobile app")
        swipe(widget, "Backlog")
        assertRow(widget, under: "Backlog · 1")
        reveal(header("Drafting · 1"))
        XCTAssertTrue(header("Drafting · 1").exists)
    }

    func testPlanSwipePicksUpABacklogTask() {
        open(goal: "g-api", title: "Public API")
        let webhooks = "Webhooks for task events"
        XCTAssertTrue(header("Backlog · 1").waitForExistence(timeout: 10))
        swipe(webhooks, "Plan")
        assertRow(webhooks, under: "Planning · 1")
        XCTAssertFalse(header("Backlog · 1").exists)
    }

    func testEditModeDragsDraftsIntoOrder() {
        open(goal: "g-app", title: "Mobile app")
        // The drafts start below the fold; scroll them up so a drag lands on the rows.
        scrollToBottom()
        XCTAssertLessThan(app.staticTexts[ipad].frame.minY, app.staticTexts[widget].frame.minY, "the demo's drafts start iPad first")

        let edit = app.buttons["drafts-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertEqual(edit.label, "Edit")
        edit.tap()
        XCTAssertEqual(edit.label, "Done")

        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
        XCTAssertTrue(handles.firstMatch.waitForExistence(timeout: 5), "no drag handles in Edit mode")
        XCTAssertEqual(handles.count, 2)
        let widgetHandle = handles.matching(NSPredicate(format: "label CONTAINS %@", widget)).firstMatch
        let ipadHandle = handles.matching(NSPredicate(format: "label CONTAINS %@", ipad)).firstMatch
        let center = CGVector(dx: 0.5, dy: 0.5)
        widgetHandle.coordinate(withNormalizedOffset: center)
            .press(forDuration: 0.8,
                   thenDragTo: ipadHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.2)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)

        edit.tap()
        XCTAssertEqual(edit.label, "Edit")
        XCTAssertFalse(handles.firstMatch.exists, "drag handles still showing after Done")
        sleep(1)
        XCTAssertLessThan(app.staticTexts[widget].frame.minY, app.staticTexts[ipad].frame.minY, "the new order didn't stick")

        // It stays put when you leave the goal and come back.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Mobile app"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["Mobile app"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Mobile app"].waitForExistence(timeout: 10))
        openAllTasks()
        scrollToBottom()
        XCTAssertTrue(app.staticTexts[widget].waitForExistence(timeout: 10))
        XCTAssertLessThan(app.staticTexts[widget].frame.minY, app.staticTexts[ipad].frame.minY, "the order didn't survive leaving the goal")
    }
}
