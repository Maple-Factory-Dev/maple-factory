import XCTest

/// The goal page's Overview (MF-324) on the demo Mobile app goal: the header, Needs you, Up next,
/// In motion and a folded Recently landed, with no Archive or Auto-merge on the first screen; those sit
/// in Goal settings behind the … menu, and every task is under All tasks. Snaps it light and dark.
///   xcodebuild test -scheme "Maple Factory" -only-testing:MapleFactoryUITests/GoalOverviewTests …
/// TEST_RUNNER_MAPLE_SHOTS=<dir> also writes the screenshots there.
final class GoalOverviewTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    /// Every section open (Recently landed folded) unless `folds` says otherwise, so a fold left over
    /// from another run doesn't leak in.
    private func open(_ folds: [String: Bool] = [:]) {
        var state = ["needsYou": true, "upNext": true, "drafts": true, "inMotion": true, "landed": false]
        state.merge(folds) { $1 }
        app.launchArguments = ["-demo", "YES", "-tab", "goals", "-goal", "g-app"]
            + state.sorted { $0.key < $1.key }.flatMap { ["-goalOverview.\($0.key)Open", $0.value ? "YES" : "NO"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Mobile app"].waitForExistence(timeout: 60), "the goal didn't open")
    }

    private func text(_ prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<5 where !(element.exists && element.isHittable) { app.collectionViews.firstMatch.swipeUp() }
    }

    func testOverviewShowsSectionsAndKeepsSettingsBehindTheMenu() {
        XCUIDevice.shared.appearance = .light
        open()
        XCTAssertTrue(app.staticTexts["APP"].exists, "no prefix chip")
        XCTAssertTrue(app.buttons["goal-follow"].exists, "no Following pill")
        XCTAssertTrue(text("Needs you · 2").exists, "no Needs you")
        XCTAssertTrue(app.staticTexts["needs-you-action-APP-12"].exists, "no Answer on the question")
        XCTAssertEqual(app.staticTexts["needs-you-action-APP-12"].label, "Answer")
        XCTAssertEqual(app.staticTexts["needs-you-action-APP-14"].label, "Approve plan")
        XCTAssertFalse(app.buttons["archive-goal"].exists, "Archive is on the goal's first screen")
        XCTAssertFalse(app.buttons["auto-merge-picker"].exists, "Auto-merge is on the goal's first screen")
        snap("goal-overview-light-1")

        reveal(text("Up next"))
        XCTAssertTrue(text("Up next").exists, "no Up next")
        reveal(text("In motion"))
        XCTAssertTrue(text("In motion").exists, "no In motion")
        let landed = app.buttons["recently-landed"]
        reveal(landed)
        XCTAssertTrue(landed.exists, "no Recently landed")
        XCTAssertFalse(app.staticTexts["Sign in with GitHub's device flow"].exists, "Recently landed starts folded")
        snap("goal-overview-light-2")
        landed.tap()
        XCTAssertTrue(app.staticTexts["Sign in with GitHub's device flow"].waitForExistence(timeout: 5), "Recently landed didn't open")
        landed.tap()

        // All tasks lists every stage, Backlog and Merged included.
        let all = app.buttons["goal-all-tasks"]
        reveal(all)
        all.tap()
        XCTAssertTrue(app.navigationBars["All tasks"].waitForExistence(timeout: 10))
        XCTAssertTrue(text("Merged · ").waitForExistence(timeout: 5) || { reveal(text("Merged · ")); return text("Merged · ").exists }(), "All tasks has no Merged")
        snap("goal-all-tasks")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Goal settings, from the … menu.
        app.buttons["goal-menu"].tap()
        XCTAssertTrue(app.buttons["editGoal"].waitForExistence(timeout: 5), "no Edit goal in the … menu")
        XCTAssertTrue(app.buttons["goal-recurring"].exists, "no Recurring in the … menu")
        snap("goal-menu")
        app.buttons["goal-settings"].tap()
        XCTAssertTrue(app.buttons["archive-goal"].waitForExistence(timeout: 5), "no Archive in Goal settings")
        XCTAssertTrue(app.buttons["auto-merge-picker"].exists, "no Auto-merge in Goal settings")
        snap("goal-settings")
    }

    func testOverviewInDark() {
        XCUIDevice.shared.appearance = .dark
        open()
        XCTAssertTrue(text("Needs you").exists)
        snap("goal-overview-dark-1")
        reveal(app.buttons["recently-landed"])
        snap("goal-overview-dark-2")
    }

    /// MF-340: tapping a section's header folds its rows away and keeps its title and count.
    func testSectionsFoldAndUnfold() {
        XCUIDevice.shared.appearance = .light
        open()
        let needsYou = app.buttons["section-needs-you"]
        XCTAssertTrue(needsYou.exists, "Needs you can't fold")
        XCTAssertEqual(needsYou.value as? String, "expanded")
        let card = app.buttons["needs-you-APP-12"]
        XCTAssertTrue(card.exists, "no APP-12 card")
        needsYou.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "Needs you didn't fold")
        XCTAssertTrue(text("Needs you · 2").exists, "folding hid the title and count")
        XCTAssertEqual(needsYou.value as? String, "collapsed")
        needsYou.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Needs you didn't unfold")

        let inMotion = app.buttons["section-in-motion"]
        reveal(inMotion)
        XCTAssertTrue(inMotion.exists, "In motion can't fold")
        let row = app.staticTexts["Crash reports with Sentry"]
        XCTAssertTrue(row.exists, "no APP-16 in In motion")
        inMotion.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "In motion didn't fold")
        XCTAssertEqual(inMotion.value as? String, "collapsed")
        XCTAssertTrue(text("In motion · ").exists, "folding hid In motion's title and count")
        inMotion.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "In motion didn't unfold")
        XCTAssertEqual(inMotion.value as? String, "expanded")

        // Drafts folds here too, and its Edit goes with the rows.
        let drafts = app.buttons["section-drafts"]
        reveal(drafts)
        XCTAssertTrue(drafts.exists, "Drafts can't fold")
        drafts.tap()
        XCTAssertEqual(drafts.value as? String, "collapsed")
        XCTAssertFalse(app.buttons["drafts-edit"].exists, "Edit shows on folded Drafts")
        drafts.tap()
    }

    /// A fold is kept across launches: started folded, Needs you shows its title and no cards.
    func testFoldedSectionsComeBackFolded() {
        XCUIDevice.shared.appearance = .light
        open(["needsYou": false, "inMotion": false, "drafts": false])
        XCTAssertEqual(app.buttons["section-needs-you"].value as? String, "collapsed")
        XCTAssertTrue(text("Needs you · 2").exists)
        XCTAssertFalse(app.buttons["needs-you-APP-12"].exists, "Needs you started open")
        XCTAssertEqual(app.buttons["section-up-next"].value as? String, "expanded")
        snap("goal-overview-folded-light")
        let drafts = app.buttons["section-drafts"]
        reveal(drafts)
        XCTAssertFalse(app.buttons["drafts-edit"].exists, "Edit shows on folded Drafts")
        snap("goal-overview-folded-drafts-light")

        app.terminate()
        XCUIDevice.shared.appearance = .dark
        open(["needsYou": false, "inMotion": false, "drafts": false])
        XCTAssertFalse(app.buttons["needs-you-APP-12"].exists, "Needs you started open")
        snap("goal-overview-folded-dark")

        // All tasks' Drafts doesn't fold.
        let all = app.buttons["goal-all-tasks"]
        reveal(all)
        all.tap()
        XCTAssertTrue(app.navigationBars["All tasks"].waitForExistence(timeout: 10))
        let edit = app.buttons["drafts-edit"]
        reveal(edit)
        XCTAssertTrue(edit.exists, "All tasks' Drafts lost Edit")
        XCTAssertFalse(app.buttons["section-drafts"].exists, "All tasks' Drafts folds")
        snap("goal-all-tasks-drafts-dark")
    }

    private func snap(_ name: String) {
        sleep(1)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["MAPLE_SHOTS"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }
}
