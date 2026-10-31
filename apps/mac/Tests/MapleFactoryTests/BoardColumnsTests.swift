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

    @Test func draftsOrderByDraftRank() {
        let ranks: [(String, Double)] = [("D-1", 3000), ("D-2", 1000), ("D-3", 2500), ("D-4", -500)]
        let drafts = ranks.map { id, rank in
            var draft = task(id, state: .drafting, rank: 9000)
            draft.draftRank = rank
            return draft
        }
        let columns = BoardColumns.columns(tasks: drafts, hideEmpty: true) { _ in false }
        #expect(columns.map(\.id) == [.task(.drafting)])
        #expect(columns[0].tasks.map(\.id) == ["D-4", "D-2", "D-3", "D-1"])
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

    // MF-118: the server marks a merge in flight with the live log "Merging…" (engine.ts startMerge).
    private func wire(state: String, liveLog: String?) throws -> Wire.Task {
        let log = liveLog.map { #","liveLog":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(Wire.Task.self, from: Data("""
        {"id":"MF-1","goal":"g","title":"A task","state":"\(state)","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":1,"reviewsNeeded":0,
         "shareable":false,"agent":"claude"\(log)}
        """.utf8))
    }

    @Test func mergingLiveLogMarksTheTaskMerging() throws {
        let merging = LiveAdapter.task(try wire(state: "reviewing", liveLog: "Merging…"), goals: [], members: [], me: "andrea")
        #expect(merging.merging)
        #expect(merging.detail == "Merging…")

        let reviewing = LiveAdapter.task(try wire(state: "reviewing", liveLog: nil), goals: [], members: [], me: "andrea")
        #expect(!reviewing.merging)
        #expect(reviewing.detail == "In review")

        // Only a reviewing task merges; the same line elsewhere is just its live log.
        let building = LiveAdapter.task(try wire(state: "building", liveLog: "Merging…"), goals: [], members: [], me: "andrea")
        #expect(!building.merging)
    }

    @Test func mergingPendingMergeTaskStaysInPendingMerge() {
        var merging = task("MERGING", state: .reviewing)
        merging.liveLog = FactoryTask.mergingLog
        #expect(merging.merging)
        let columns = BoardColumns.columns(tasks: [merging, task("REVIEW", state: .reviewing)], hideEmpty: true) { $0.id == "MERGING" }
        #expect(columns.map(\.id) == [.task(.reviewing), .pendingMerge])
        #expect(columns.first { $0.id == .pendingMerge }?.tasks.map(\.id) == ["MERGING"])
        #expect(columns.flatMap(\.tasks).filter { $0.id == "MERGING" }.count == 1)
    }
}
