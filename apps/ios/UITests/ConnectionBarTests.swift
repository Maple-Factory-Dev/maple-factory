import XCTest

/// The Inbox's connection pill (MF-349): with `-demoConnection` the demo acts as if its socket had
/// dropped. The pill reads a short headline instead of the raw socket error, and tapping it shows the
/// detail in a popover.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/ConnectionBarTests …
/// With `TEST_RUNNER_SHOTS=<dir>` passed to xcodebuild, screenshots are also written there as PNGs.
final class ConnectionBarTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ connection: String) {
        app.launchArguments = ["-demo", "YES", "-demoConnection", connection]
        app.launch()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 60))
    }

    private var bar: XCUIElement { app.descendants(matching: .any)["connection.bar"].firstMatch }

    func testOfflinePillAndPopover() {
        launch("offline")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the connection pill isn't shown")
        XCTAssertEqual(bar.label, "Offline, reconnecting", "the pill should read Offline · Reconnecting…")
        XCTAssertEqual(bar.value as? String, "The operation couldn’t be completed. Socket is not connected",
                       "VoiceOver still gets the raw reason")
        let socketText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Socket is not connected'"))
        XCTAssertEqual(socketText.count, 0, "the raw socket error shouldn't be on screen")
        snap("inbox-offline")

        bar.tap()
        let reason = app.staticTexts["connection.reason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "the popover didn't open")
        XCTAssertTrue(reason.label.contains("Socket is not connected"), "the popover should hold the reason: \(reason.label)")
        XCTAssertEqual(app.staticTexts["connection.attempt"].label, "Attempt 1")
        let tryNow = app.buttons["connection.tryNow"]
        XCTAssertTrue(tryNow.exists, "Try now is missing")
        snap("popover-offline")

        tryNow.tap()
        XCTAssertTrue(reason.waitForNonExistence(timeout: 5), "Try now should close the popover")
        bar.tap()
        XCTAssertTrue(app.staticTexts["connection.attempt"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["connection.attempt"].label, "Attempt 2", "Try now should count an attempt")
    }

    func testUnreachablePill() {
        launch("unreachable")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the connection pill isn't shown")
        XCTAssertEqual(bar.label, "Can't reach factory, reconnecting")
        snap("inbox-unreachable")
    }

    private func snap(_ name: String) {
        sleep(1)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
