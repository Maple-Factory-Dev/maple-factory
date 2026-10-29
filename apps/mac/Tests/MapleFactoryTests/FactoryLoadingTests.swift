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

/// Relaunching reopens the page this factory was last on, while it's still there.
struct LastPageTests {
    @Test func encodingRoundTrips() {
        let all: [Destination] = [.inbox, .myTasks, .activity, .scratchpad, .usage, .needsHand, .machines, .intake, .allGoals,
                                  .goal("Maple Factory"), .goal("inbox"), .goal("goal:odd")]
        for destination in all { #expect(Destination(encoded: destination.encoded) == destination) }
        #expect(Destination.goal("inbox").encoded == "goal:inbox")
        #expect(Destination.inbox.encoded == "inbox")
        #expect(Destination(encoded: "nonsense") == nil)
    }

    @Test func rememberedGoalWins() {
        #expect(AppState.destinationAfterSnapshot(.goal("Auth overhaul"), goals: ["Website", "Maple Factory"], focusedGoal: nil,
                                                  remembered: .goal("Maple Factory")) == .goal("Maple Factory"))
    }

    @Test func removedGoalFallsBackToFirst() {
        #expect(AppState.destinationAfterSnapshot(.goal("Auth overhaul"), goals: ["Website", "Maple Factory"], focusedGoal: nil,
                                                  remembered: .goal("Gone")) == .goal("Website"))
    }

    @Test func nonGoalPageRestores() {
        #expect(AppState.destinationAfterSnapshot(.goal("Auth overhaul"), goals: ["Website"], focusedGoal: nil, remembered: .myTasks) == .myTasks)
        // A factory switch lands on the inbox first; its remembered goal still opens.
        #expect(AppState.destinationAfterSnapshot(.inbox, goals: ["Website", "Maple Factory"], focusedGoal: nil,
                                                  remembered: .goal("Maple Factory")) == .goal("Maple Factory"))
        #expect(AppState.destinationAfterSnapshot(.inbox, goals: ["Website"], focusedGoal: nil, remembered: .inbox) == nil)
    }

    @Test func factoriesKeepSeparatePages() throws {
        let suite = "dev.maplefactory.tests.lastpage"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let one = URL(string: "https://one.example.com")!, two = URL(string: "http://two.example.com:8080")!
        #expect(LastPage.load(factory: one, defaults: defaults) == nil)
        LastPage.store(.goal("Maple Factory"), factory: one, defaults: defaults)
        LastPage.store(.inbox, factory: two, defaults: defaults)
        #expect(LastPage.load(factory: one, defaults: defaults) == .goal("Maple Factory"))
        #expect(LastPage.load(factory: two, defaults: defaults) == .inbox)
        #expect(LastPage.key(two) == "lastPage.two.example.com:8080")
    }
}
