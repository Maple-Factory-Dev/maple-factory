import XCTest

/// MF-358: APP-14 has a Mermaid diagram. Its card renders inline; tapping it opens the full-screen viewer,
/// where the search field finds "runner" (three labels) and steps through them.
@MainActor
final class DiagramViewerTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-task", "APP-14"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Push notifications when a plan needs your approval"].waitForExistence(timeout: 20), "APP-14 didn't open")
    }

    private func screenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testOpenAndSearch() {
        let open = app.buttons["diagram.open.D1"]
        for _ in 0..<15 where !(open.exists && open.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(open.isHittable, "the diagram card never came on screen")
        app.swipeDown(velocity: .slow)
        sleep(2)
        XCTAssertTrue(app.webViews.staticTexts["Plan v2 ready"].waitForExistence(timeout: 10), "the inline diagram didn't render")
        screenshot("inline")
        for _ in 0..<4 where !open.isHittable { app.swipeUp(velocity: .slow) }
        open.tap()

        XCTAssertTrue(app.descendants(matching: .any)["diagram.viewer.D1"].waitForExistence(timeout: 10), "no viewer")
        let search = app.webViews.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "no search field in the viewer")
        search.tap()
        search.typeText("runner")
        XCTAssertTrue(app.webViews.staticTexts["1 of 3"].waitForExistence(timeout: 5), "searching runner didn't find 3 matches")
        search.typeText("\n")
        XCTAssertTrue(app.webViews.staticTexts["2 of 3"].waitForExistence(timeout: 5), "Enter didn't step to the next match")
        sleep(1)
        screenshot("viewer-search")

        app.buttons["diagram.close"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5), "closing didn't go back to the task")
    }
}
