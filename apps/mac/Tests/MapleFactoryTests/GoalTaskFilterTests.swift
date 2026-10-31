import Foundation
import Testing
@testable import MapleFactory

/// MF-192: a goal's Everyone | You switch filters what its layouts show, and is remembered.
@MainActor
struct GoalTaskFilterTests {
    private let me = FactoryData.me
    private let chris = FactoryData.chris

    private func task(_ id: String, owner: Person) -> FactoryTask {
        var task = FactoryTask(id: id, title: id, state: .building, detail: "")
        task.owner = owner
        return task
    }

    private var tasks: [FactoryTask] {
        [task("A-1", owner: me), task("A-2", owner: chris), task("A-3", owner: me), task("A-4", owner: chris)]
    }

    @Test func everyoneKeepsEveryTask() {
        #expect(GoalView.visibleTasks(tasks, filter: .everyone, me: me.id).map(\.id) == ["A-1", "A-2", "A-3", "A-4"])
    }

    @Test func youKeepsOnlyYourTasksInOrder() {
        #expect(GoalView.visibleTasks(tasks, filter: .mine, me: me.id).map(\.id) == ["A-1", "A-3"])
        #expect(GoalView.visibleTasks(tasks, filter: .mine, me: chris.id).map(\.id) == ["A-2", "A-4"])
    }

    @Test func youWithNoneOfYoursIsEmpty() {
        let theirs = tasks.filter { $0.owner.id == chris.id }
        #expect(GoalView.visibleTasks(theirs, filter: .mine, me: me.id).isEmpty)
        #expect(GoalView.visibleTasks([], filter: .everyone, me: me.id).isEmpty)
    }

    @Test func launchArgumentsParse() {
        #expect(GoalTaskFilter(argument: "mine") == .mine)
        #expect(GoalTaskFilter(argument: "You") == .mine)
        #expect(GoalTaskFilter(argument: "everyone") == .everyone)
        #expect(GoalTaskFilter(argument: "nope") == nil)
    }

    @Test func preferenceDefaultsToEveryoneAndSurvivesStateRecreation() throws {
        let suite = "GoalTaskFilterTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = AppDefaults.string(forKey: "goalTaskFilter")
        let state = AppState(boardDefaults: defaults)
        #expect(state.goalTaskFilter == .everyone)
        state.goalTaskFilter = .mine
        #expect(defaults.string(forKey: "goalTaskFilter") == "You")
        let restored = AppState(boardDefaults: defaults)
        #expect(restored.goalTaskFilter == .mine)
        // One choice for every goal and layout.
        restored.destination = .goal("Another goal")
        restored.layout = .timeline
        #expect(restored.goalTaskFilter == .mine)
        restored.goalTaskFilter = .everyone
        #expect(AppState(boardDefaults: defaults).goalTaskFilter == .everyone)
        #expect(AppDefaults.string(forKey: "goalTaskFilter") == saved)
    }
}
