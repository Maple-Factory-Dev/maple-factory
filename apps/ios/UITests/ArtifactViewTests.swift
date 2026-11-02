import XCTest

/// MF-273: a task's artifacts show in its task view, one chip each over one viewer. The demo's BIL-7 has
/// an HTML chart, an SVG, a Markdown note, a CSV, a PDF and a screenshot.
@MainActor
final class ArtifactViewTests: XCTestCase {
    private var app: XCUIApplication!
    private let ids = ["art-chart", "art-flow", "art-notes", "art-csv", "art-pdf", "art-shot"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-task", "BIL-7"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Invoice PDFs with line items"].waitForExistence(timeout: 20), "BIL-7 didn't open")
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func chip(_ id: String) -> XCUIElement { app.buttons["artifact.chip.\(id)"] }

    /// Scrolls the task until the chip row sits near the top, with the viewer under it on screen.
    private func revealArtifacts() {
        let row = app.scrollViews["artifact.chips"]
        for _ in 0..<12 where !(row.exists && row.isHittable && row.frame.minY < app.frame.height * 0.35) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5) && row.isHittable, "the Artifacts card never came on screen")
    }

    /// Taps a chip, scrolling the row sideways to it first.
    private func tapChip(_ id: String) {
        let row = app.scrollViews["artifact.chips"]
        for _ in 0..<4 where !chip(id).isHittable { row.swipeLeft() }
        XCTAssertTrue(chip(id).isHittable, "chip \(id) is out of reach")
        chip(id).tap()
    }

    private func screenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testChipsSwitchTheViewer() {
        revealArtifacts()
        for id in ids { XCTAssertTrue(chip(id).exists, "no chip for \(id)") }
        // It opens on the newest, the screenshot.
        XCTAssertTrue(app.buttons["artifact.image.art-shot"].waitForExistence(timeout: 5), "the image isn't showing")
        screenshot("image")

        tapChip("art-notes")
        XCTAssertTrue(element("artifact.viewer.art-notes").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Line items from our usage table"].waitForExistence(timeout: 5), "the Markdown didn't render")
        screenshot("markdown")

        tapChip("art-csv")
        let csv = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "date,org,metric")).firstMatch
        XCTAssertTrue(csv.waitForExistence(timeout: 5), "the CSV text isn't showing")
        screenshot("text")

        tapChip("art-pdf")
        XCTAssertTrue(element("artifact.viewer.art-pdf").waitForExistence(timeout: 5), "no PDF viewer")
        sleep(1)
        screenshot("pdf")

        tapChip("art-shot")
        XCTAssertTrue(app.buttons["artifact.image.art-shot"].waitForExistence(timeout: 5), "the image isn't showing")
    }

    /// The chart's script runs, but its fetch never gets out and its link goes nowhere.
    func testPageIsSandboxed() {
        revealArtifacts()
        app.scrollViews["artifact.chips"].swipeRight()
        tapChip("art-chart")
        XCTAssertTrue(element("artifact.viewer.art-chart").waitForExistence(timeout: 5))
        let blocked = app.webViews.staticTexts["Network: blocked (sandboxed)"]
        XCTAssertTrue(blocked.waitForExistence(timeout: 15), "the page's fetch wasn't reported blocked")
        XCTAssertFalse(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "reached")).firstMatch.exists)
        screenshot("sandboxed")

        let link = app.webViews.links["Open example.com"]
        XCTAssertTrue(link.exists && link.isHittable, "no link to tap in the page")
        link.tap()
        sleep(2)
        // Still the same page, in the same task, in the app.
        XCTAssertTrue(blocked.exists, "the link navigated away")
        XCTAssertTrue(chip("art-chart").exists, "left the task")
        XCTAssertEqual(app.state, .runningForeground)
        screenshot("after-link")
    }

    /// A task with no artifacts has no Artifacts card.
    func testNoArtifactsNoCard() {
        app.terminate()
        app.launchArguments = ["-demo", "YES", "-task", "APP-12"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Offline cache for the inbox"].waitForExistence(timeout: 20))
        for _ in 0..<6 { app.swipeUp() }
        XCTAssertFalse(app.staticTexts["Artifacts"].exists, "APP-12 shows an Artifacts card")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'artifact.chip.'")).count, 0)
        screenshot("no-artifacts")
    }
}
