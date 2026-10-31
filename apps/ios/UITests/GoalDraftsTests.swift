import XCTest

/// A goal's drafts and backlog in the demo factory: swipe a draft to Plan or Backlog, swipe a backlog
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
    }

    private func header(_ text: String) -> XCUIElement { app.staticTexts[text] }

    /// Swipes the row titled `title` left and taps `action`.
    private func swipe(_ title: String, _ action: String) {
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(title) isn't listed")
        row.swipeLeft()
        let button = app.buttons[action]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(action) swipe action")
        button.tap()
    }

    /// Whether `row` sits under the section `header`.
    private func assertRow(_ title: String, under header: String, file: StaticString = #filePath, line: UInt = #line) {
        let heading = self.header(header)
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "no \(header) section", file: file, line: line)
        let row = app.staticTexts[title]
        XCTAssertTrue(row.exists, "\(title) isn't listed", file: file, line: line)
        XCTAssertGreaterThan(row.frame.minY, heading.frame.minY, "\(title) isn't under \(header)", file: file, line: line)
    }

    func testPlanSwipeSendsADraftToPlanning() {
        open(goal: "g-app", title: "Mobile app")
        XCTAssertTrue(header("Drafting · 2").waitForExistence(timeout: 10))
        swipe(ipad, "Plan")
        assertRow(ipad, under: "Planning · 1")
        XCTAssertTrue(header("Drafting · 1").exists)
        XCTAssertGreaterThan(header("Drafting · 1").frame.minY, app.staticTexts[ipad].frame.minY, "still listed as a draft")
    }

    func testBacklogSwipeParksADraft() {
        open(goal: "g-app", title: "Mobile app")
        swipe(widget, "Backlog")
        assertRow(widget, under: "Backlog · 1")
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
        // The drafts start under the tab bar; scroll them up so a drag lands on the rows.
        app.collectionViews.firstMatch.swipeUp()
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
            .press(forDuration: 0.6, thenDragTo: ipadHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))

        edit.tap()
        XCTAssertEqual(edit.label, "Edit")
        XCTAssertFalse(handles.firstMatch.exists, "drag handles still showing after Done")
        sleep(1)
        XCTAssertLessThan(app.staticTexts[widget].frame.minY, app.staticTexts[ipad].frame.minY, "the new order didn't stick")

        // It stays put when you leave the goal and come back.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["Mobile app"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[widget].waitForExistence(timeout: 10))
        XCTAssertLessThan(app.staticTexts[widget].frame.minY, app.staticTexts[ipad].frame.minY, "the order didn't survive leaving the goal")
    }
}
