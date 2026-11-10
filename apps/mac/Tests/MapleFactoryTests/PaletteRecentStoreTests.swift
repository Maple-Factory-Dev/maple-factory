import Foundation
import Testing
@testable import MapleFactory

/// MF-408 review: Recent is read from disk before the first write, and the palette's "This task"
/// is only a task whose ⋯ menu is on screen.
@MainActor
struct PaletteRecentStoreTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "PaletteRecentStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func firstOpenAfterLaunchAddsToTheSavedHistory() throws {
        try withDefaults { defaults in
            let before = AppState(boardDefaults: defaults)
            before.rememberRecent(.task("MF-1"))
            before.rememberRecent(.doc("d-1"))
            // A relaunch: one task opened before ⌘K must not wipe the rest.
            let after = AppState(boardDefaults: defaults)
            after.rememberRecent(.task("MF-2"))
            #expect(after.recentPaletteItems == [.task("MF-2"), .doc("d-1"), .task("MF-1")])
            after.loadRecent()
            #expect(after.recentPaletteItems == [.task("MF-2"), .doc("d-1"), .task("MF-1")])
        }
    }

    @Test func switchingFactoriesReloadsItsList() throws {
        try withDefaults { defaults in
            let state = AppState(boardDefaults: defaults)
            state.rememberRecent(.task("MF-1"))
            state.recentPaletteItems = [.task("OTHER-9")]  // what another factory had in memory
            state.didSwitchFactory()
            #expect(state.recentPaletteItems == [.task("MF-1")])
        }
    }

    @Test func paletteTaskIsOnlyAPanelThatIsShown() throws {
        try withDefaults { defaults in
            let state = AppState(boardDefaults: defaults)
            let id = try #require(state.tasks.first?.id)
            state.selectedTask = id
            state.showInspector = true
            state.destination = .inbox
            #expect(state.paletteTask == id)
            // Usage has no task panel, so no ⋯ menu to show Assign… or Cancel… from.
            state.destination = .usage
            #expect(state.paletteTask == nil)
            state.showInspector = false
            state.destination = .inbox
            #expect(state.paletteTask == nil)
        }
    }
}
