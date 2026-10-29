import Foundation
import Testing
@testable import MapleFactory

/// What a single click on a card or row does, per the "When you click a task" setting.
@Suite(.serialized) struct TaskOpeningTests {
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

    /// Runs `body` on a fresh AppState, then puts back the stored setting it changes.
    @MainActor private func withState(_ body: (AppState) -> Void) {
        let saved = AppDefaults.object(forKey: Opening.key)
        let savedPanel = AppDefaults.object(forKey: "taskPanelOpen")
        defer {
            AppDefaults.set(saved, forKey: Opening.key)
            AppDefaults.set(savedPanel, forKey: "taskPanelOpen")
        }
        body(AppState())
    }

    @MainActor @Test func taskPanelEnabledFollowsTheSetting() {
        withState { state in
            state.taskOpening = .panel
            #expect(state.taskPanelEnabled)
            state.taskOpening = .fullView
            #expect(!state.taskPanelEnabled)
        }
    }

    @MainActor @Test func toggleDoesNothingInFullView() {
        withState { state in
            state.taskOpening = .fullView
            state.toggleTaskPanel()
            #expect(!state.showInspector)
            state.taskOpening = .panel
            state.toggleTaskPanel()
            #expect(state.showInspector)
        }
    }

    @MainActor @Test func switchingToFullViewClosesTheOpenPanel() {
        withState { state in
            state.taskOpening = .panel
            state.openTask("MF-1")
            #expect(state.showInspector)
            state.taskOpening = .fullView
            #expect(!state.showInspector)
        }
    }

    @MainActor @Test func openTaskInFullViewOpensTheFullView() {
        withState { state in
            state.taskOpening = .fullView
            state.openTask("ATL-147")
            #expect(!state.showInspector)
            #expect(state.focusedTask == "ATL-147")
        }
    }
}
