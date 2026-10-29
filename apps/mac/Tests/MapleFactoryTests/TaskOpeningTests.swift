import Foundation
import Testing
@testable import MapleFactory

/// What a single click on a card or row does, per the "When you click a task" setting.
struct TaskOpeningTests {
    private typealias Opening = AppState.TaskOpening

    @Test func defaultsToFullView() throws {
        let defaults = try #require(UserDefaults(suiteName: "TaskOpeningTests.\(UUID())"))
        #expect(Opening.stored(defaults) == .fullView)
        defaults.set("panel", forKey: Opening.key)
        #expect(Opening.stored(defaults) == .panel)
        defaults.set("bogus", forKey: Opening.key)
        #expect(Opening.stored(defaults) == .fullView)
    }

    @Test func fullViewAlwaysFocuses() {
        for panelOpen in [false, true] {
            for id in ["MF-1", "MF-2"] {
                #expect(AppState.clickAction(opening: .fullView, panelOpen: panelOpen, selected: "MF-1", id: id) == .focus)
            }
        }
    }

    @Test func panelOpensAnotherTask() {
        #expect(AppState.clickAction(opening: .panel, panelOpen: false, selected: "MF-1", id: "MF-1") == .openPanel)
        #expect(AppState.clickAction(opening: .panel, panelOpen: false, selected: "MF-1", id: "MF-2") == .openPanel)
        #expect(AppState.clickAction(opening: .panel, panelOpen: true, selected: "MF-1", id: "MF-2") == .openPanel)
    }

    @Test func panelClosesOnTheOpenTask() {
        #expect(AppState.clickAction(opening: .panel, panelOpen: true, selected: "MF-1", id: "MF-1") == .closePanel)
    }
}
