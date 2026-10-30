import Foundation
import Testing
@testable import MapleFactory

/// Visibility follows rendered membership, including the two columns outside TaskState.
@MainActor
struct BoardColumnsTests {
    private typealias ID = BoardColumns.Column.ID
    private let order: [ID] = [.task(.drafting), .queued, .task(.planning), .task(.awaitingApproval),
                               .task(.backlog), .task(.building), .task(.reviewing), .pendingMerge,
                               .task(.merged), .task(.cancelled)]

    private func task(_ id: String, state: TaskState = .building, queued: Bool = false, rank: Double = 0) -> FactoryTask {
        FactoryTask(id: id, title: id, state: state, detail: "", queued: queued, queueRank: rank)
    }

    @Test func emptyColumnIsARail() {
        #expect(BoardColumns.isRail(count: 0))
    }

    @Test func columnWithCardsIsFull() {
        #expect(!BoardColumns.isRail(count: 1))
        #expect(!BoardColumns.isRail(count: 12))
    }

    @Test(arguments: [false, true])
    func tasklessGoal(hideEmpty: Bool) {
        let columns = BoardColumns.columns(tasks: [], hideEmpty: hideEmpty) { _ in false }
        #expect(columns.map(\.id) == (hideEmpty ? [] : order))
        #expect(columns.allSatisfy { $0.tasks.isEmpty })
    }

    @Test(arguments: TaskState.allCases, [0, 1, 12])
    func stateColumnCounts(taskState: TaskState, count: Int) {
        let tasks = (0..<count).map { task("TASK-\($0)", state: taskState) }
        for hideEmpty in [false, true] {
            let columns = BoardColumns.columns(tasks: tasks, hideEmpty: hideEmpty) { _ in false }
            #expect(columns.map(\.id) == (hideEmpty ? (count == 0 ? [] : [.task(taskState)]) : order))
            #expect(columns.first { $0.id == .task(taskState) }?.tasks.count ?? 0 == count)
            #expect(columns.flatMap(\.tasks).map(\.id) == tasks.map(\.id))
        }
    }

    @Test(arguments: [false, true], [1, 12])
    func specialColumnsRouteExactlyOnce(hideEmpty: Bool, count: Int) {
        let queued = (0..<count).map { task("QUEUE-\($0)", state: .reviewing, queued: true, rank: Double(count - $0)) }
        let pending = (0..<count).map { task("PENDING-\($0)", state: .reviewing) }
        let reviewing = task("REVIEW", state: .reviewing)
        let tasks = queued + pending + [reviewing]
        // Even a queued task eligible for pending merge must belong only to Queued.
        let columns = BoardColumns.columns(tasks: tasks, hideEmpty: hideEmpty) { $0.id != reviewing.id }
        #expect(columns.map(\.id) == (hideEmpty ? [.queued, .task(.reviewing), .pendingMerge] : order))
        #expect(columns.first { $0.id == .queued }?.tasks.map(\.id) == queued.reversed().map(\.id))
        #expect(columns.first { $0.id == .pendingMerge }?.tasks.map(\.id) == pending.map(\.id))
        #expect(columns.first { $0.id == .task(.reviewing) }?.tasks.map(\.id) == [reviewing.id])
        #expect(columns.flatMap(\.tasks).count == tasks.count)
        #expect(Set(columns.flatMap(\.tasks).map(\.id)) == Set(tasks.map(\.id)))
    }

    @Test(arguments: [false, true])
    func populatedColumnsKeepFixedOrder(hideEmpty: Bool) {
        var tasks = TaskState.allCases.reversed().map { task($0.title, state: $0) }
        tasks.insert(task("PENDING", state: .reviewing), at: 0)
        tasks.append(task("QUEUE", queued: true))
        let columns = BoardColumns.columns(tasks: tasks, hideEmpty: hideEmpty) { $0.id == "PENDING" }
        #expect(columns.map(\.id) == order)
        #expect(columns.allSatisfy { $0.tasks.count == 1 })
    }

    @Test(arguments: [false, true])
    func membershipChangesEmptyAndRestoreColumns(hideEmpty: Bool) {
        var card = task("MOVING", state: .drafting)
        func check(_ expected: ID, pending: Bool = false) {
            let columns = BoardColumns.columns(tasks: [card], hideEmpty: hideEmpty) { _ in pending }
            #expect(columns.map(\.id) == (hideEmpty ? [expected] : order))
            #expect(columns.filter { !$0.tasks.isEmpty }.map(\.id) == [expected])
            #expect(columns.flatMap(\.tasks).map(\.id) == [card.id])
        }
        check(.task(.drafting))
        card.queued = true
        check(.queued)
        card.state = .reviewing
        check(.queued, pending: true)
        card.queued = false
        check(.pendingMerge, pending: true)
        check(.task(.reviewing))
        check(.pendingMerge, pending: true)
        card.queued = true
        check(.queued, pending: true)
        card.queued = false
        card.state = .merged
        check(.task(.merged))
        let removed = BoardColumns.columns(tasks: [], hideEmpty: hideEmpty) { _ in false }
        #expect(removed.map(\.id) == (hideEmpty ? [] : order))
    }

    @Test func preferenceDefaultsOffAndSurvivesStateRecreation() throws {
        let suite = "BoardColumnsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = AppDefaults.object(forKey: "boardHidesEmptyColumns") as? Bool
        let state = AppState(boardDefaults: defaults)
        #expect(!state.boardHidesEmptyColumns)
        state.boardHidesEmptyColumns = true
        #expect(defaults.bool(forKey: "boardHidesEmptyColumns"))
        let restored = AppState(boardDefaults: defaults)
        #expect(restored.boardHidesEmptyColumns)
        restored.destination = .goal("Another goal")
        #expect(restored.boardHidesEmptyColumns)
        restored.boardHidesEmptyColumns = false
        #expect(!AppState(boardDefaults: defaults).boardHidesEmptyColumns)
        #expect(AppDefaults.object(forKey: "boardHidesEmptyColumns") as? Bool == saved)
    }
}
