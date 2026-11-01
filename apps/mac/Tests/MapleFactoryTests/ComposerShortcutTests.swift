import Testing
@testable import MapleFactory

/// ⌘↩ while typing a task comment sends it, and the draft survives moving between the panel and full view.
@MainActor @Suite struct ComposerShortcutTests {
    @Test func focusedComposerSendsBeforeTogglingFullView() {
        let state = AppState()
        state.focusedTask = nil
        #expect(state.returnCommand(composerFocused: true, composerCanSend: true) == .sendComposer)
        state.focusedTask = state.selectedTask
        #expect(state.returnCommand(composerFocused: true, composerCanSend: true) == .sendComposer)
    }

    @Test func emptyFocusedComposerLeavesTheViewAlone() {
        let state = AppState()
        #expect(state.returnCommand(composerFocused: true, composerCanSend: false) == .nothing)
        state.focusedTask = state.selectedTask
        #expect(state.returnCommand(composerFocused: true, composerCanSend: false) == .nothing)
    }

    @Test func withoutAComposerItStillTogglesFullView() {
        let state = AppState()
        state.focusedTask = nil
        #expect(state.returnCommand(composerFocused: false, composerCanSend: false) == .openFocus)
        state.focusedTask = state.selectedTask
        #expect(state.returnCommand(composerFocused: false, composerCanSend: false) == .closeFocus)
        state.isComposing = true
        #expect(state.returnCommand(composerFocused: false, composerCanSend: false) == .sendToPlanning)
    }

    @Test func draftSurvivesOpeningAndClosingFullView() {
        let state = AppState()
        let id = state.selectedTask
        state.composerDrafts[id] = "Looks good, ship it"
        state.openFocus(id)
        #expect(state.composerDrafts[id] == "Looks good, ship it")
        state.closeFocus()
        #expect(state.composerDrafts[id] == "Looks good, ship it")
        #expect(state.composerDrafts["some-other-task"] == nil)
    }
}
