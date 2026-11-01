import Foundation
import Testing
@testable import MapleFactory

/// The Slack-style factory rail: shown on its own from two factories, the View menu's choice
/// overriding that; ⌘N picks the Nth saved factory; and its 60pt comes out of the content's width.
@MainActor
struct FactoryRailTests {
    private func factories(_ count: Int) -> [SavedFactory] {
        (1...max(count, 1)).prefix(count).map {
            SavedFactory(server: URL(string: "https://f\($0).example.com")!, org: "org\($0)", name: "Factory \($0)", lastUsed: .now)
        }
    }

    @Test func oneFactoryHidesTheRail() {
        #expect(!SavedFactories.railShown(count: 0, preference: nil))
        #expect(!SavedFactories.railShown(count: 1, preference: nil))
    }

    @Test func twoFactoriesShowTheRail() {
        #expect(SavedFactories.railShown(count: 2, preference: nil))
        #expect(SavedFactories.railShown(count: 5, preference: nil))
    }

    @Test func thePreferenceOverridesTheCount() {
        #expect(SavedFactories.railShown(count: 1, preference: true))
        #expect(!SavedFactories.railShown(count: 3, preference: false))
    }

    @Test func shortcutPicksTheNthFactory() {
        let list = factories(3)
        #expect(SavedFactories.factory(forShortcut: 1, in: list)?.name == "Factory 1")
        #expect(SavedFactories.factory(forShortcut: 3, in: list)?.name == "Factory 3")
    }

    @Test func shortcutPastTheEndIsNil() {
        #expect(SavedFactories.factory(forShortcut: 4, in: factories(3)) == nil)
        #expect(SavedFactories.factory(forShortcut: 0, in: factories(3)) == nil)
        #expect(SavedFactories.factory(forShortcut: 1, in: []) == nil)
    }

    @Test func theRailTakesItsWidthFromTheContent() {
        let state = AppState()
        let saved = state.factoryRailPreference
        defer { state.factoryRailPreference = saved }
        state.windowResized(to: 1600)
        if state.sidebarCollapsed { state.toggleSidebar() }
        state.showInspector = false

        state.factoryRailPreference = false
        #expect(state.railSpace == 0)
        #expect(state.sidebarSpace == 250)
        #expect(state.contentWidth == 1350)

        state.factoryRailPreference = true
        #expect(state.railSpace == 60)
        #expect(state.sidebarSpace == 310)
        #expect(state.contentWidth == 1290)

        state.toggleSidebar()
        #expect(state.sidebarSpace == 128)
        #expect(state.contentWidth == 1472)
        state.toggleSidebar()
    }
}
