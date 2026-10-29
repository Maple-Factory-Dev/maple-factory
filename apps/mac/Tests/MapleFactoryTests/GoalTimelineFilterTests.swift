import Testing
@testable import MapleFactory

/// Which tasks the goal Timeline draws, per its "Show merged" toggle.
@MainActor
struct GoalTimelineFilterTests {
    private func task(_ id: String, _ state: TaskState, from start: Int) -> FactoryTask {
        FactoryTask(id: id, title: id, state: state, detail: "", span: start...(start + 2))
    }

    private var tasks: [FactoryTask] {
        [task("MF-3", .merged, from: 4), task("MF-1", .cancelled, from: 6),
         task("MF-2", .building, from: 1), task("MF-4", .merged, from: 0)]
    }

    @Test func hidesMergedByDefault() {
        let ids = GoalTimeline.visibleRows(tasks, showMerged: false).map(\.id)
        #expect(ids == ["MF-2", "MF-1"])
    }

    @Test func showsEverythingWhenToggled() {
        let ids = GoalTimeline.visibleRows(tasks, showMerged: true).map(\.id)
        #expect(ids == ["MF-4", "MF-2", "MF-3", "MF-1"])
    }

    @Test func keepsCancelledAndInFlight() {
        for showMerged in [false, true] {
            let ids = GoalTimeline.visibleRows(tasks, showMerged: showMerged).map(\.id)
            #expect(ids.contains("MF-1"))
            #expect(ids.contains("MF-2"))
        }
    }

    @Test func allMergedLeavesNoRows() {
        let merged = [task("MF-5", .merged, from: 2), task("MF-6", .merged, from: 1)]
        #expect(GoalTimeline.visibleRows(merged, showMerged: false).isEmpty)
        #expect(GoalTimeline.visibleRows(merged, showMerged: true).map(\.id) == ["MF-6", "MF-5"])
    }
}
