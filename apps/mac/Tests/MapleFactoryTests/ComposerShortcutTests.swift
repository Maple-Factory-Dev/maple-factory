import Testing
import AppKit
import SwiftUI
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

/// Shift-Tab in the New task brief goes back to the title; plain Tab stays the editor's.
@MainActor @Suite struct MarkdownBacktabTests {
    private func coordinator(onBacktab: (() -> Void)?, onKey: ((MentionKey) -> Bool)? = nil) -> MarkdownTextView.Coordinator {
        MarkdownTextView(text: .constant(""), selection: .constant(NSRange(location: 0, length: 0)), upload: nil, onKey: onKey, onBacktab: onBacktab)
            .makeCoordinator()
    }

    @Test func backtabFiresOnBacktab() {
        var fired = 0
        let c = coordinator(onBacktab: { fired += 1 })
        #expect(c.textView(NSTextView(), doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(fired == 1)
    }

    @Test func tabIsNotIntercepted() {
        var fired = 0
        let c = coordinator(onBacktab: { fired += 1 })
        #expect(!c.textView(NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(fired == 0)
    }

    @Test func withoutOnBacktabTheTextViewKeepsTheKey() {
        let c = coordinator(onBacktab: nil)
        #expect(!c.textView(NSTextView(), doCommandBy: #selector(NSResponder.insertBacktab(_:))))
    }

    @Test func openPickerStillTakesTab() {
        var picked = false
        let c = coordinator(onBacktab: {}, onKey: { key in picked = key == .pick; return true })
        #expect(c.textView(NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(picked)
    }
}
