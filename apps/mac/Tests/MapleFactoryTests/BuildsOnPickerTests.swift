import Foundation
import Testing
@testable import MapleFactory

/// The Builds on row's task picker: it lists its goal's other open tasks it doesn't already wait on,
/// leaves out any that would make a loop, filters by ID or title ignoring case, puts building and
/// in-review tasks first and the rest by ID in natural order; picking one adds it through setAfter.
@MainActor
struct BuildsOnPickerTests {
    private func task(_ id: String, _ title: String, _ state: TaskState = .backlog, goal: String = "G",
                      after: [String] = []) -> FactoryTask {
        var task = FactoryTask(id: id, goal: goal, title: title, state: state, detail: "")
        task.after = after
        return task
    }

    private var tasks: [FactoryTask] {
        [
            task("MF-1", "Me", .building),
            task("MF-10", "Session view", .backlog),
            task("MF-2", "Assign picker", .reviewing),
            task("MF-9", "Usage card", .planning),
            task("MF-3", "Old thing", .merged),
            task("MF-4", "Dropped", .cancelled),
            task("MF-5", "Other goal", .building, goal: "H"),
            task("MF-6", "Already added", .building),
            task("MF-7", "Waits on me", .building, after: ["MF-8"]),
            task("MF-8", "Waits on me directly", .backlog, after: ["MF-1"]),
            task("MF-11", "Building later", .building),
        ]
    }

    private var me: FactoryTask { task("MF-1", "Me", .building, after: ["MF-6"]) }

    @Test func excludesItselfFinishedAlreadyAddedOtherGoalsAndLoops() {
        let ids = BuildsOnPopover.matches(for: me, query: "", tasks: tasks).map(\.id)
        #expect(!ids.contains("MF-1"))
        #expect(!ids.contains("MF-3"))
        #expect(!ids.contains("MF-4"))
        #expect(!ids.contains("MF-5"))
        #expect(!ids.contains("MF-6"))
        #expect(!ids.contains("MF-7"))
        #expect(!ids.contains("MF-8"))
    }

    @Test func ordersBuildingAndReviewingFirstThenByIDNaturally() {
        let ids = BuildsOnPopover.matches(for: me, query: "", tasks: tasks).map(\.id)
        #expect(ids == ["MF-2", "MF-11", "MF-9", "MF-10"])
    }

    @Test func filtersByIDOrTitleIgnoringCase() {
        #expect(BuildsOnPopover.matches(for: me, query: "usage", tasks: tasks).map(\.id) == ["MF-9"])
        #expect(BuildsOnPopover.matches(for: me, query: "mf-1", tasks: tasks).map(\.id) == ["MF-11", "MF-10"])
        #expect(BuildsOnPopover.matches(for: me, query: "  PICKER ", tasks: tasks).map(\.id) == ["MF-2"])
        #expect(BuildsOnPopover.matches(for: me, query: "nothing like it", tasks: tasks).isEmpty)
    }

    @Test func pickingATaskAddsItThroughSetAfter() throws {
        let state = AppState()
        let mine = try #require(state.tasks.first { !$0.state.isFinished
            && !BuildsOnPopover.matches(for: $0, query: "", tasks: state.tasks).isEmpty })
        let other = try #require(BuildsOnPopover.matches(for: mine, query: "", tasks: state.tasks).first)
        state.setAfter(mine.id, mine.after + [other.id])
        #expect(state.task(mine.id).after == mine.after + [other.id])
        #expect(state.toast?.text == "\(mine.id) now builds after \(other.id)")
        #expect(!BuildsOnPopover.matches(for: state.task(mine.id), query: "", tasks: state.tasks).contains { $0.id == other.id })
    }
}
