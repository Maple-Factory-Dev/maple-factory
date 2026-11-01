import XCTest

/// MF-326: a task's attached images, videos and files show in its task view. The demo's ONB-3 has two
/// images in its brief (from the phone), a Slack-style `## Attachments` file, and a comment with an image.
@MainActor
final class AttachmentViewTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-task", "ONB-3"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["task.brief"].waitForExistence(timeout: 20), "ONB-3 didn't open")
    }

    /// The brief's images are thumbnails, its Slack file a chip, and no link text is left showing.
    func testBriefShowsThumbnailsAndChip() {
        XCTAssertTrue(app.buttons["attachment.image.welcome-se.png"].waitForExistence(timeout: 5), "no thumbnail for welcome-se.png")
        XCTAssertTrue(app.buttons["attachment.image.welcome-15.png"].exists, "no thumbnail for welcome-15.png")
        XCTAssertTrue(app.buttons["attachment.file.crash-log.txt"].exists, "no chip for crash-log.txt")
        let brief = app.staticTexts["task.brief"]
        XCTAssertTrue(brief.label.hasPrefix("The welcome screen's header is cut off"), brief.label)
        let raw = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "/attachments/"))
        XCTAssertEqual(raw.count, 0, "raw attachment links are showing")
        XCTAssertFalse(app.staticTexts["Attachments"].exists, "Slack's Attachments heading is left with nothing under it")
    }

    /// Tapping a thumbnail opens the full-screen viewer on that image; Done comes back to the task.
    func testThumbnailOpensViewer() {
        let thumb = app.buttons["attachment.image.welcome-15.png"]
        XCTAssertTrue(thumb.waitForExistence(timeout: 5))
        thumb.tap()
        XCTAssertTrue(app.navigationBars["welcome-15.png"].waitForExistence(timeout: 5), "the viewer didn't open on the tapped image")
        XCTAssertTrue(app.descendants(matching: .any)["attachmentViewer.image.welcome-15.png"].waitForExistence(timeout: 5), "the image didn't load")
        XCTAssertTrue(app.descendants(matching: .any)["attachmentViewer.share"].exists, "no Share")
        app.swipeRight()
        XCTAssertTrue(app.navigationBars["welcome-se.png"].waitForExistence(timeout: 5), "swiping doesn't page to the other image")
        app.buttons["attachmentViewer.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["task.brief"].waitForExistence(timeout: 5), "Done didn't return to the task")
        XCTAssertFalse(app.buttons["attachmentViewer.done"].exists)
    }

    /// A comment's image shows inline in the Timeline.
    func testCommentShowsImage() {
        app.buttons["Timeline"].tap()
        XCTAssertTrue(app.buttons["attachment.image.mini.png"].waitForExistence(timeout: 5), "the comment's image isn't inline")
        XCTAssertTrue(app.staticTexts["Same on my mini:"].exists, "the comment's text is gone")
    }
}
