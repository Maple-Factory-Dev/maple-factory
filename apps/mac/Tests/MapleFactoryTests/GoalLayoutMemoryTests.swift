import Foundation
import Testing
@testable import MapleFactory

/// MF-310: the goal layout (Overview/Board/List/Timeline) is remembered across relaunches.
@MainActor
struct GoalLayoutMemoryTests {
    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "GoalLayoutMemoryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func savedOverviewComesBackOnANewState() throws {
        try withSuite { defaults in
            let saved = AppDefaults.string(forKey: "goalLayout")
            let state = AppState(boardDefaults: defaults)
            state.layout = .overview
            #expect(defaults.string(forKey: "goalLayout") == "Overview")
            #expect(AppState(boardDefaults: defaults).layout == .overview)
            state.layout = .timeline
            #expect(AppState(boardDefaults: defaults).layout == .timeline)
            // The throwaway suite holds it; the app's own defaults are untouched.
            #expect(AppDefaults.string(forKey: "goalLayout") == saved)
        }
    }

    @Test func emptySuiteStartsOnBoard() throws {
        try withSuite { defaults in
            #expect(AppState(boardDefaults: defaults).layout == .board)
        }
    }

    @Test func unknownStoredValueFallsBackToBoard() throws {
        try withSuite { defaults in
            defaults.set("Kanban", forKey: "goalLayout")
            #expect(AppState(boardDefaults: defaults).layout == .board)
        }
    }

    @Test func creatingAStateDoesNotOverwriteTheSavedLayout() throws {
        try withSuite { defaults in
            defaults.set("List", forKey: "goalLayout")
            _ = AppState(boardDefaults: defaults)
            #expect(defaults.string(forKey: "goalLayout") == "List")
        }
    }
}
