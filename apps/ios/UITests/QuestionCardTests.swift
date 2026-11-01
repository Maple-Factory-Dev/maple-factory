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
        app.openLink("maplefactory://task/BIL-7")
        XCTAssertTrue(app.navigationBars["BIL-7"].waitForExistence(timeout: 20), "the task's detail didn't open")
        let option = app.buttons.containing(NSPredicate(format: "label CONTAINS 'leave beta'")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10), "the raised hand should show its long option")
        if !option.isHittable { app.swipeUp() }
        let width = app.windows.firstMatch.frame.width
        XCTAssertLessThanOrEqual(option.frame.maxX, width, "the long hand option spills past the right edge")
        XCTAssertTrue(option.isHittable)
        snap("hand-card")
    }

    private func snap(_ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
