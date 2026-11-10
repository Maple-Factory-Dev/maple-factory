import Foundation
import Testing
@testable import MapleFactory

/// MF-406: what each page says when it has nothing to show.
@MainActor
struct EmptyStateTests {
    @Test func inboxHeaderAtZeroSaysNothingIsWaiting() {
        #expect(InboxView.headerLine(count: 0, goals: 0, mine: true) == "Nothing is waiting on you.")
        #expect(InboxView.headerLine(count: 0, goals: 0, mine: false) == "Nothing is waiting on the team.")
    }

    @Test func inboxHeaderCountsOneAndMany() {
        #expect(InboxView.headerLine(count: 1, goals: 1, mine: true) == "1 thing across 1 goal is waiting on you.")
        #expect(InboxView.headerLine(count: 1, goals: 1, mine: false) == "1 thing across 1 goal is waiting on the team.")
        #expect(InboxView.headerLine(count: 5, goals: 3, mine: true) == "5 things across 3 goals are waiting on you.")
        #expect(InboxView.headerLine(count: 5, goals: 3, mine: false) == "5 things across 3 goals are waiting on the team.")
    }

    @Test func goalEmptyKindTellsNoTasksFromFiltered() {
        #expect(GoalView.emptyKind(all: 0, shown: 0, filter: .everyone) == GoalView.EmptyKind.none)
        #expect(GoalView.emptyKind(all: 0, shown: 0, filter: .mine) == GoalView.EmptyKind.none)
        #expect(GoalView.emptyKind(all: 4, shown: 0, filter: .mine) == .filtered(.mine))
        #expect(GoalView.emptyKind(all: 4, shown: 2, filter: .mine) == nil)
        #expect(GoalView.emptyKind(all: 4, shown: 4, filter: .everyone) == nil)
    }

    @Test func noGoalsLandsOnAllGoals() {
        #expect(AppState.landing(.goal("Auth overhaul"), noGoals: true) == .allGoals)
        #expect(AppState.landing(.goal("Auth overhaul"), noGoals: false) == .goal("Auth overhaul"))
        #expect(AppState.landing(.inbox, noGoals: true) == .inbox)
    }
}
