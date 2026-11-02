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
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// Scrolls the task down until the element is on screen.
    private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<12 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5) && element.isHittable, "\(element) never came on screen", file: file, line: line)
    }

    private func chip(_ id: String) -> XCUIElement { app.buttons["artifact.chip.\(id)"] }

    func testChipsSwitchTheViewer() {
        reveal(chip("art-shot"))
        for id in ids { XCTAssertTrue(chip(id).exists, "no chip for \(id)") }
        // It opens on the newest, the screenshot.
        XCTAssertTrue(app.buttons["artifact.image.art-shot"].waitForExistence(timeout: 5), "the image isn't showing")

        chip("art-notes").tap()
        XCTAssertTrue(element("artifact.viewer.art-notes").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Line items from our usage table"].waitForExistence(timeout: 5), "the Markdown didn't render")

        chip("art-csv").tap()
        let csv = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "date,org,metric")).firstMatch
        XCTAssertTrue(csv.waitForExistence(timeout: 5), "the CSV text isn't showing")

        chip("art-pdf").tap()
        XCTAssertTrue(element("artifact.viewer.art-pdf").waitForExistence(timeout: 5), "no PDF viewer")

        chip("art-shot").tap()
        XCTAssertTrue(app.buttons["artifact.image.art-shot"].waitForExistence(timeout: 5), "the image isn't showing")
    }

    /// The chart's script runs, but its fetch never gets out and its link goes nowhere.
    func testPageIsSandboxed() {
        reveal(chip("art-chart"))
        chip("art-chart").tap()
        let viewer = element("artifact.viewer.art-chart")
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        let blocked = app.webViews.staticTexts["Network: blocked (sandboxed)"]
        XCTAssertTrue(blocked.waitForExistence(timeout: 15), "the page's fetch wasn't reported blocked")
        XCTAssertFalse(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "reached")).firstMatch.exists)

        let link = app.webViews.links["Open example.com"]
        XCTAssertTrue(link.exists, "no link in the page")
        link.tap()
        // Still the same page, still in the app.
        XCTAssertTrue(blocked.waitForExistence(timeout: 3), "the link navigated away")
        XCTAssertEqual(app.state, .runningForeground)
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
    }
}
