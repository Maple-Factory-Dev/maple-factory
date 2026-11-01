import XCTest

/// In the demo: opens the Mobile app goal, starts a task from its New task button, and checks it lands
/// in the right section: Drafting for Save as draft, Planning for Plan now.
@MainActor
final class NewTaskTests: XCTestCase {
    func testSaveAsDraft() throws {
        try create(title: "Haptics when a plan is approved", plan: false, section: "Drafting · 3")
    }

    func testPlanNow() throws {
        try create(title: "Widget for the inbox count", plan: true, section: "Planning · 1")
    }

    /// Codex and a new effort ride along in task.create: the new row carries the effort's tag.
    func testAgentAndNewEffort() throws {
        let app = open([])
        fill(app, title: "Haptics on approve")
        app.buttons["newTask.agent"].tap()
        app.buttons["Codex"].tap()
        app.buttons["newTask.effort"].tap()
        app.buttons["New effort…"].tap()
        let name = app.textFields["newTask.newEffort"]
        XCTAssertTrue(name.waitForExistence(timeout: 3), "New effort… shows no name field")
        name.tap()
        name.typeText("Haptics")
        app.buttons["newTask.send"].tap()

        let row = app.staticTexts["Haptics on approve"]
        for _ in 0..<3 where !row.waitForExistence(timeout: 2) { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(row.exists, "the new task isn't in the goal")
        let tag = app.staticTexts.matching(identifier: "task.effort").matching(NSPredicate(format: "label == %@", "Haptics")).firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 3), "the new task's row has no Haptics effort tag")
        row.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "· codex")).firstMatch.waitForExistence(timeout: 5),
                      "the task doesn't run on Codex")
    }

    /// `-newTaskAttachment` stands in for the photo picker: the thumbnail uploads, Send waits for it,
    /// and the brief that goes out ends with the attachment's link.
    func testAttachment() throws {
        let app = open(["-newTaskAttachment", "1"])
        fill(app, title: "Fix the cropped header")
        XCTAssertTrue(app.otherElements["newTask.attachment.uploaded"].waitForExistence(timeout: 5), "the attachment didn't upload")
        app.buttons["newTask.send"].tap()

        let row = app.staticTexts["Fix the cropped header"]
        for _ in 0..<3 where !row.waitForExistence(timeout: 2) { app.collectionViews.firstMatch.swipeUp() }
        row.tap()
        let brief = app.descendants(matching: .any)["task.brief"]
        XCTAssertTrue(brief.waitForExistence(timeout: 5))
        let value = brief.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("Made on the phone by the UI test."), value)
        XCTAssertNotNil(value.range(of: #"\n!\[screenshot-[0-9-]+\.png\]\(/attachments/demo/screenshot-[0-9-]+\.png\)$"#, options: .regularExpression),
                        "the brief doesn't end with the attachment link: \(value)")
    }

    /// While an upload runs, Send waits.
    func testSendWaitsForUploads() throws {
        let app = open(["-newTaskAttachment", "2", "-demoUploadHang", "IMG-"])
        fill(app, title: "Waits for the upload")
        XCTAssertTrue(app.otherElements["newTask.attachment.uploaded"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["newTask.attachment.uploading"].exists, "the hung upload shows no spinner")
        XCTAssertFalse(app.buttons["newTask.send"].isEnabled, "Send is on while a photo is still uploading")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove IMG-")).firstMatch.tap()
        XCTAssertTrue(app.buttons["newTask.send"].isEnabled, "Send stays off after the uploading photo is removed")
    }

    private func open(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", "g-app"] + extra
        app.launch()
        let button = app.buttons["newTask"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the goal has no New task button")
        button.tap()
        return app
    }

    private func fill(_ app: XCUIApplication, title: String) {
        let titleField = app.textFields["newTask.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        let brief = app.textViews["newTask.brief"].exists ? app.textViews["newTask.brief"] : app.textFields["newTask.brief"]
        brief.tap()
        brief.typeText("Made on the phone by the UI test.")
    }

    private func create(title: String, plan: Bool, section: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", "g-app"]
        app.launch()

        let button = app.buttons["newTask"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the goal has no New task button")
        button.tap()

        let titleField = app.textFields["newTask.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        let brief = app.textViews["newTask.brief"].exists ? app.textViews["newTask.brief"] : app.textFields["newTask.brief"]
        brief.tap()
        brief.typeText("Made on the phone by the UI test.")
        app.buttons[plan ? "Plan now" : "Save as draft"].tap()
        app.buttons["newTask.send"].tap()

        let row = app.staticTexts[title]
        // The goal runs past the screen; the list only builds rows near the viewport.
        for _ in 0..<3 where !row.waitForExistence(timeout: 2) { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the new task isn't in the goal")
        XCTAssertTrue(app.staticTexts["APP-18"].exists, "the new task isn't APP-18")
        XCTAssertTrue(app.staticTexts[section].exists, "no \(section) section")
        // The section a row is in is the nearest header above it.
        let headers = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[A-Za-z ]+ · [0-9]+$")).allElementsBoundByIndex
        let above = headers.filter { $0.frame.maxY <= row.frame.minY }.max { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(above?.label, section, "the task isn't under \(section)")
    }
}
