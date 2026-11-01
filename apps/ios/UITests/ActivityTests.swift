import XCTest

/// Activity in the demo factory: opened from the Inbox toolbar, newest first by day, filtered to agents,
/// and a row opens its task. Runs without a live factory.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/ActivityTests …
final class ActivityTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 60))
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private var rows: XCUIElementQuery {
        app.collectionViews.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'activity.row.'"))
    }

    private static let agents = ["Planner", "Builder", "Reviewer", "Factory"]

    func testOpensFromTheInboxFiltersAndOpensATask() {
        app.buttons["inbox.activity"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 10), "Activity didn't open")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "no activity rows")

        // Newest first: the planner's plan v2 on APP-14, 4 minutes ago, leads; Today sits above Yesterday.
        XCTAssertEqual(rows.firstMatch.identifier, "activity.row.APP-14")
        XCTAssertTrue(rows.firstMatch.label.hasPrefix("Planner wrote plan v2"), "first row is \(rows.firstMatch.label)")
        let today = app.staticTexts["Today"], yesterday = app.staticTexts["Yesterday"]
        XCTAssertTrue(today.exists, "no Today section")
        if yesterday.exists {
            XCTAssertLessThan(today.frame.minY, yesterday.frame.minY)
        } else {
            // Further down the list, under Today.
            app.collectionViews.firstMatch.swipeUp()
            XCTAssertTrue(yesterday.waitForExistence(timeout: 5), "no Yesterday section")
        }
        app.collectionViews.firstMatch.swipeDown()
        snapshot("activity everyone")

        let everyone = rows.count
        app.segmentedControls.buttons["Agents"].tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThan(rows.count, everyone, "the Agents filter left every row")
        for row in rows.allElementsBoundByIndex {
            XCTAssertTrue(Self.agents.contains { row.label.hasPrefix($0) }, "a person's row under Agents: \(row.label)")
        }
        snapshot("activity agents")

        rows.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["APP-14"].waitForExistence(timeout: 10), "the task's detail didn't open")
        snapshot("activity opened APP-14")
    }
}
