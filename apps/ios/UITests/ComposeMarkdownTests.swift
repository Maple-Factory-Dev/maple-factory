import XCTest

/// In the demo: the compose sheet's Markdown bar, Preview and attachments. `-composeAttachment 1` stands
/// in for the photo picker. A comment (or a steer) typed with Bold and a photo lands in the timeline
/// rendered: bold text, no asterisks, and the image's thumbnail.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/ComposeMarkdownTests …
@MainActor
final class ComposeMarkdownTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testCommentWithBoldAndPhoto() {
        run(action: "Comment", send: "Comment")
    }

    func testSteerWithBoldAndPhoto() {
        run(action: "Steer", send: "Send")
    }

    private func run(action: String, send: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-task", "APP-12", "-composeAttachment", "1"]
        app.launch()
        let button = app.buttons[action]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "APP-12 has no \(action) button")
        button.tap()

        let editor = app.textViews["compose.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the compose sheet didn't open")
        editor.tap()
        editor.typeText("Ship it ")
        app.buttons["format.bold"].tap()
        XCTAssertEqual(editor.value as? String, "Ship it **bold**")
        XCTAssertTrue(app.otherElements["compose.attachment.uploaded"].waitForExistence(timeout: 5), "the photo didn't upload")
        snap(app, "\(action.lowercased())-write")

        app.buttons["Preview"].tap()
        let preview = app.descendants(matching: .any)["compose.text.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "no preview")
        XCTAssertTrue(preview.staticTexts["Ship it bold"].exists, "the preview doesn't render the bold text")
        XCTAssertTrue(preview.buttons["markdown.image"].waitForExistence(timeout: 5), "the preview has no image")
        snap(app, "\(action.lowercased())-preview")

        app.buttons["compose.send"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "the sheet didn't close")
        app.buttons["Timeline"].tap()
        XCTAssertTrue(app.staticTexts["Ship it bold"].waitForExistence(timeout: 5), "the timeline doesn't show the rendered text")
        XCTAssertFalse(app.staticTexts["Ship it **bold**"].exists, "the timeline shows raw Markdown")
        // The timeline shows a note's own image lines in its attachment gallery
        // (attachment.image.<name>); an inline image keeps markdown.image.
        let thumb = app.buttons.matching(NSPredicate(format: "identifier == 'markdown.image' OR identifier BEGINSWITH 'attachment.image.'")).firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 5), "the timeline has no image thumbnail")
        snap(app, "\(action.lowercased())-timeline")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
