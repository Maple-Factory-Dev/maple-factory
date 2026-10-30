import Foundation
import Testing
@testable import MapleFactory

/// The goal ⌘N New Task starts on (MF-85): the goal you're in, else the goal you last made a task in.
@MainActor struct NewTaskGoalTests {
    /// A mockup AppState on Inbox with nothing open, remembering into its own UserDefaults suite.
    private func state() -> AppState {
        let suite = "NewTaskGoalTests.\(UUID().uuidString)"
        let state = AppState()
        state.taskGoalDefaults = UserDefaults(suiteName: suite)!
        state.destination = .inbox
        state.showInspector = false
        state.focusedTask = nil
        return state
    }

    /// Makes a task in `goal` through the composer, the way the person would, then goes to Inbox.
    private func makeTask(in goal: String, _ state: AppState) {
        state.startCompose(goal: goal, title: "Something new")
        state.submitDraft(sendToPlanning: false)
        state.destination = .inbox
        state.showInspector = false
    }

    @Test func onAGoalPageItsThatGoal() {
        let state = state()
        state.destination = .goal("Docs site")
        state.startCompose()
        #expect(state.draft.goal == "Docs site")
        #expect(state.draft.goalChosen)
    }

    @Test func aTaskFocusedFromInboxGivesItsGoal() {
        let state = state()
        let task = state.tasks.first { $0.goal == "Billing v2" }!
        state.openFocus(task.id)
        state.startCompose()
        #expect(state.draft.goal == "Billing v2")
        #expect(state.draft.goalChosen)
    }

    @Test func aTaskInThePanelFromInboxGivesItsGoal() {
        let state = state()
        let task = state.tasks.first { $0.goal == "Performance budget" }!
        state.selectedTask = task.id
        state.showInspector = true
        state.startCompose()
        #expect(state.draft.goal == "Performance budget")
    }

    @Test func onInboxItsTheGoalLastUsedForATask() {
        let state = state()
        makeTask(in: "Onboarding revamp", state)
        state.startCompose()
        #expect(state.draft.goal == "Onboarding revamp")
        // Remembered, not where you are: Draft with AI may still suggest a better one.
        #expect(!state.draft.goalChosen)

        // A fresh launch reading the same defaults remembers it too.
        let relaunched = AppState()
        relaunched.taskGoalDefaults = state.taskGoalDefaults
        relaunched.destination = .inbox
        relaunched.showInspector = false
        relaunched.startCompose()
        #expect(relaunched.draft.goal == "Onboarding revamp")
    }

    @Test func aRememberedGoalThatWasArchivedFallsBackToTheUsualOne() {
        let state = state()
        let usual = state.newTaskGoal.name
        LastTaskGoal.store("Docs site", factory: nil, defaults: state.taskGoalDefaults)
        #expect(state.newTaskGoal.name == "Docs site")

        let saved = FactoryData.liveGoals
        defer { FactoryData.liveGoals = saved }
        FactoryData.liveGoals = FactoryData.seedGoals.map { goal in
            var goal = goal
            if goal.name == "Docs site" { goal.archived = true }
            return goal
        }
        #expect(LastTaskGoal.load(factory: nil, defaults: state.taskGoalDefaults) == nil)
        state.startCompose()
        #expect(state.draft.goal == usual)
        #expect(state.draft.goal != "Docs site")
    }

    @Test func eachFactoryRemembersItsOwn() {
        let defaults = UserDefaults(suiteName: "NewTaskGoalTests.\(UUID().uuidString)")!
        let a = URL(string: "https://a.example.com")!, b = URL(string: "https://b.example.com:8443")!
        LastTaskGoal.store("Billing v2", factory: a, defaults: defaults)
        LastTaskGoal.store("Docs site", factory: b, defaults: defaults)
        #expect(LastTaskGoal.load(factory: a, defaults: defaults) == "Billing v2")
        #expect(LastTaskGoal.load(factory: b, defaults: defaults) == "Docs site")
        #expect(LastTaskGoal.key(b) == "lastTaskGoal.b.example.com:8443")
    }
}
