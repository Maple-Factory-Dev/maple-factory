import XCTest

/// Search on the Inbox and Goals tabs in the demo factory: every task and goal, ranked like the Mac's ⌘K palette,
/// and a result opens its task or goal. Runs without a live factory.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/SearchTests …
final class SearchTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 60))
    }

    private func search(_ text: String) {
        let field = app.searchFields.firstMatch
        if !field.exists { app.collectionViews.firstMatch.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field")
        field.tap()
        field.typeText(text)
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private var results: XCUIElement { app.collectionViews["searchResults"] }

    func testAnIdRanksItsTaskFirstAndOpensIt() {
        search("api-29")
        XCTAssertTrue(results.waitForExistence(timeout: 10), "search didn't show results")
        let first = results.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'search.task.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "no task results")
        XCTAssertEqual(first.identifier, "search.task.API-29", "API-29 isn't ranked first")
        XCTAssertTrue(first.staticTexts["Token scopes: read, write and admin"].exists || first.label.contains("Token scopes"))
        snapshot("search api-29")
        first.tap()
        XCTAssertTrue(app.navigationBars["API-29"].waitForExistence(timeout: 10), "the task's detail didn't open")
    }

    func testAGoalsNameListsItAndOpensIt() {
        search("billing")
        let goal = results.descendants(matching: .any)["search.goal.g-web"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10), "the Billing goal isn't listed")
        goal.tap()
        XCTAssertTrue(app.navigationBars["Billing"].waitForExistence(timeout: 10), "the goal didn't open")
    }

    func testGoalsTabFindsTasks() {
        app.tabBars.buttons["Goals"].tap()
        XCTAssertTrue(app.navigationBars["Goals"].waitForExistence(timeout: 10))
        search("rate")
        XCTAssertTrue(results.descendants(matching: .any)["search.task.API-31"].waitForExistence(timeout: 10), "API-31 isn't found")
    }

    func testTypingShowsRankedTasksAndGoals() {
        search("api")
        XCTAssertTrue(results.waitForExistence(timeout: 10))
        XCTAssertTrue(results.staticTexts["Tasks"].exists || results.staticTexts["TASKS"].exists, "no Tasks section")
        XCTAssertTrue(results.staticTexts["Goals"].exists || results.staticTexts["GOALS"].exists, "no Goals section")
        snapshot("search api")
    }
}
