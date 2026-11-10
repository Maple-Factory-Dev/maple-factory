import Foundation
import Testing
@testable import MapleFactory

/// Keyboard navigation's ordering: list sections, board columns, the full view's Next/Previous, and
/// where the Inbox cursor goes once the row it was on is cleared.
@MainActor
struct TaskKeyNavTests {
    private func task(_ id: String, _ state: TaskState, queued: Bool = false) -> FactoryTask {
        var task = FactoryTask(id: id, title: id, state: state, detail: "")
        task.queued = queued
        return task
    }

    @Test func listFollowsSectionOrderAndSkipsCollapsed() {
        let tasks = [task("B1", .building), task("P1", .planning), task("R1", .reviewing), task("P2", .planning), task("D1", .drafting)]
        #expect(TaskKeyNav.listRows(tasks) == ["D1", "P1", "P2", "B1", "R1"])
        #expect(TaskKeyNav.listRows(tasks, collapsed: [.planning]) == ["D1", "B1", "R1"])
    }

    @Test func listClampsAtTheEnds() {
        let layout = TaskKeyNav.Layout.list(["A", "B", "C"])
        #expect(TaskKeyNav.move(.down, from: "A", in: layout) == "B")
        #expect(TaskKeyNav.move(.down, from: "C", in: layout) == "C")
        #expect(TaskKeyNav.move(.up, from: "A", in: layout) == "A")
        #expect(TaskKeyNav.move(.up, from: "C", in: layout) == "B")
        #expect(TaskKeyNav.move(.right, from: "B", in: layout) == "B")
    }

    @Test func missingOrStaleCursorGoesToTheFirstRow() {
        let layout = TaskKeyNav.Layout.list(["A", "B"])
        #expect(TaskKeyNav.move(.down, from: nil, in: layout) == "A")
        #expect(TaskKeyNav.move(.up, from: "GONE", in: layout) == "A")
        #expect(TaskKeyNav.move(.down, from: nil, in: .empty) == nil)
        #expect(TaskKeyNav.move(.right, from: "GONE", in: .columns([[], ["X"]])) == "X")
    }

    @Test func boardUpDownStaysInsideAColumn() {
        let layout = TaskKeyNav.Layout.columns([["A1", "A2"], ["B1", "B2", "B3"]])
        #expect(TaskKeyNav.move(.down, from: "A2", in: layout) == "A2")
        #expect(TaskKeyNav.move(.down, from: "B2", in: layout) == "B3")
        #expect(TaskKeyNav.move(.up, from: "B1", in: layout) == "B1")
    }

    @Test func boardLeftRightKeepsTheRowAndSkipsEmptyColumns() {
        let layout = TaskKeyNav.Layout.columns([["A1", "A2", "A3"], [], ["C1"], ["D1", "D2", "D3"]])
        #expect(TaskKeyNav.move(.right, from: "A3", in: layout) == "C1")   // clamped, past the empty column
        #expect(TaskKeyNav.move(.right, from: "C1", in: layout) == "D1")
        #expect(TaskKeyNav.move(.left, from: "C1", in: layout) == "A1")
        #expect(TaskKeyNav.move(.right, from: "D3", in: layout) == "D3")   // last column clamps
        #expect(TaskKeyNav.move(.left, from: "A2", in: layout) == "A2")
    }

    @Test func boardRowsFollowTheBoardsColumnsAndHideEmptyOnes() {
        let tasks = [task("B1", .building), task("Q1", .backlog, queued: true), task("BL", .backlog)]
        let shown = TaskKeyNav.boardRows(tasks, hideEmpty: true, pendingMerge: { _ in false })
        #expect(shown == [["BL"], ["Q1"], ["B1"]])
        let all = TaskKeyNav.boardRows(tasks, hideEmpty: false, pendingMerge: { _ in false })
        #expect(all.count == BoardColumns.Column.ID.ordered.count)
        #expect(TaskKeyNav.move(.right, from: "Q1", in: .columns(all)) == "B1")
    }

    @Test func nextPreviousWalksTheListYouCameFrom() {
        let list = ["A", "B", "C"]
        #expect(TaskKeyNav.neighbour(of: "A", in: list, forward: true) == "B")
        #expect(TaskKeyNav.neighbour(of: "C", in: list, forward: true) == nil)
        #expect(TaskKeyNav.neighbour(of: "B", in: list, forward: false) == "A")
        #expect(TaskKeyNav.neighbour(of: "A", in: list, forward: false) == nil)
        #expect(TaskKeyNav.neighbour(of: "Z", in: list, forward: true) == nil)
        #expect(TaskKeyNav.Layout.columns([["A"], ["B", "C"]]).flat == list)
    }

    @Test func inboxCursorMovesToTheNextRowWhenItsItemClears() {
        #expect(TaskKeyNav.survivor(of: "B", before: ["A", "B", "C"], after: ["A", "C"]) == "C")
        #expect(TaskKeyNav.survivor(of: "C", before: ["A", "B", "C"], after: ["A", "B"]) == "B")
        #expect(TaskKeyNav.survivor(of: "B", before: ["A", "B", "C"], after: ["A", "B", "C"]) == "B")
        #expect(TaskKeyNav.survivor(of: "A", before: ["A"], after: []) == nil)
        #expect(TaskKeyNav.survivor(of: nil, before: [], after: ["X"]) == "X")
    }
}
