import Foundation
import Testing
@testable import MapleFactory

/// Signed in, the app waits for the factory's first snapshot instead of showing the mock's goal, then lands somewhere real.
struct FactoryLoadingTests {
    @Test func loadingWhenSignedInWithoutSnapshot() {
        #expect(AppState.isLoading(signedIn: true, hasSnapshot: false))
    }

    @Test func notLoadingOnceSnapshotLands() {
        #expect(!AppState.isLoading(signedIn: true, hasSnapshot: true))
    }

    @Test func notLoadingSignedOut() {
        // Nothing to load: a fresh launch opens onboarding, and a demo launch (-mock YES, -snapshot…) the mock.
        #expect(!AppState.isLoading(signedIn: false, hasSnapshot: false))
    }

    @Test func emptyWorkspaceOpensInbox() {
        #expect(AppState.destinationAfterSnapshot(.goal("Auth overhaul"), goals: [], focusedGoal: nil) == .inbox)
    }

    @Test func focusedTasksGoalWins() {
        #expect(AppState.destinationAfterSnapshot(.goal("Auth overhaul"), goals: ["Billing", "Search"], focusedGoal: "Search") == .goal("Search"))
    }

    @Test func otherwiseFirstGoal() {
        #expect(AppState.destinationAfterSnapshot(.goal("Auth overhaul"), goals: ["Billing", "Search"], focusedGoal: nil) == .goal("Billing"))
        #expect(AppState.destinationAfterSnapshot(.goal("Auth overhaul"), goals: ["Billing"], focusedGoal: "Gone") == .goal("Billing"))
    }

    @Test func realGoalOrNonGoalStaysPut() {
        #expect(AppState.destinationAfterSnapshot(.goal("Search"), goals: ["Billing", "Search"], focusedGoal: nil) == nil)
        #expect(AppState.destinationAfterSnapshot(.myTasks, goals: [], focusedGoal: nil) == nil)
    }
}
