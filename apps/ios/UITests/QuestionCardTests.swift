import XCTest

/// The demo's APP-12 builder asks a question with long, sentence-length options, like a planner's ask:
/// each option is a full-width button that wraps inside the card instead of spilling past its edge,
/// and every one can be tapped. BIL-7's raised hand has a long option title that wraps the same way.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/QuestionCardTests …
final class QuestionCardTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 60))
    }

    func testLongQuestionOptionsWrapInsideTheCard() {
        app.openLink("maplefactory://task/APP-12")
        XCTAssertTrue(app.navigationBars["APP-12"].waitForExistence(timeout: 20), "the task's detail didn't open")

        let first = app.buttons["question-option-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the question card should show its options")
        let width = app.windows.firstMatch.frame.width
        let options = (0..<3).map { app.buttons["question-option-\($0)"] }
        for (index, option) in options.enumerated() {
            if !option.isHittable { app.swipeUp() }
            XCTAssertTrue(option.exists, "option \(index) is missing")
            XCTAssertGreaterThanOrEqual(option.frame.minX, 0, "option \(index) starts off the left edge")
            XCTAssertLessThanOrEqual(option.frame.maxX, width, "option \(index) spills past the right edge")
            XCTAssertTrue(option.isHittable, "option \(index) can't be tapped")
        }
        // The long options wrap, so they're taller than the one-line option.
        XCTAssertGreaterThan(options[0].frame.height, options[2].frame.height, "the long option should wrap over several lines")
        XCTAssertTrue(options[0].label.contains("Recommended"), "the recommended option should say so")
        snap("question-card")

        options[1].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 10), "answering should clear the question")
        snap("question-answered")
    }

    func testLongHandOptionWrapsInsideTheCard() {
        openHandTask()
        checkHandOptions()
        snap("hand-card")
    }

    /// BIL-7 is building with a raised hand: Reply to hand, Steer and Comment all sit in the bar,
    /// fully on screen, tappable without scrolling it sideways (MF-353's "Comment" was cut off).
    func testActionBarFitsTheScreen() {
        openHandTask()
        checkActionBar()
        snap("action-bar")
    }

    /// At a large text size the hand's options still wrap inside the card, and the bar's secondary
    /// actions collapse to icons instead of running off the edge.
    func testLargeTextHandAndActionBarFit() {
        app.terminate()
        app.launchArguments = ["-demo", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 60))
        openHandTask()
        checkHandOptions()
        snap("hand-card-large-text")
        checkActionBar()
        snap("action-bar-large-text")
    }

    private func openHandTask() {
        app.openLink("maplefactory://task/BIL-7")
        XCTAssertTrue(app.navigationBars["BIL-7"].waitForExistence(timeout: 20), "the task's detail didn't open")
    }

    private func checkHandOptions() {
        let width = app.windows.firstMatch.frame.width
        for index in 0..<2 {
            let option = app.buttons["hand-option-\(index)"]
            XCTAssertTrue(option.waitForExistence(timeout: 10), "hand option \(index) is missing")
            var swipes = 0
            while !option.isHittable, swipes < 6 { app.swipeUp(); swipes += 1 }
            XCTAssertGreaterThanOrEqual(option.frame.minX, 0, "hand option \(index) starts off the left edge")
            XCTAssertLessThanOrEqual(option.frame.maxX, width, "hand option \(index) spills past the right edge")
            XCTAssertTrue(option.isHittable, "hand option \(index) can't be tapped")
        }
        XCTAssertTrue(app.buttons["hand-option-1"].label.contains("leave beta"))
        XCTAssertTrue(app.buttons["hand-option-0"].label.contains("Recommended"))
    }

    private func checkActionBar() {
        let width = app.windows.firstMatch.frame.width
        let bar = app.descendants(matching: .any)["action-bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the action bar is missing")
        for title in ["Reply to hand", "Steer", "Comment"] {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(button.exists, "\(title) is missing from the action bar")
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0, "\(title) starts off the left edge")
            XCTAssertLessThanOrEqual(button.frame.maxX, width, "\(title) is cut off at the right edge")
            XCTAssertTrue(button.isHittable, "\(title) can't be tapped without scrolling")
        }
    }

    private func snap(_ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
