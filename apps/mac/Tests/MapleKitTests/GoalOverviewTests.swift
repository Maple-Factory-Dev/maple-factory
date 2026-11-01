import Foundation
import Testing
@testable import MapleKit

/// The iOS goal page's Overview: each task in the one section that says what to do with it.
struct GoalOverviewTests {
    private let day: UInt64 = 86_400_000
    private var now: UInt64 { 100 * day }

    private func task(_ id: String, _ state: Wire.TaskState, owner: String = "andrea", updated: UInt64? = nil, _ edit: (inout Wire.Task) -> Void = { _ in }) -> Wire.Task {
        var t = Wire.Task(id: id, goal: "g1", title: id, state: state, owner: owner, brief: "", createdAt: 1, updatedAt: updated ?? now - day,
                          planVersion: 1, approvalsNeeded: 1, reviewsNeeded: 1, shareable: false, agent: "claude")
        edit(&t)
        return t
    }

    private var worker: Wire.Worker { Wire.Worker(role: .builder, agent: "claude", machine: "m1", session: "s1", startedAt: 1) }
    private func passed() -> Wire.AutoReview { Wire.AutoReview(maxRounds: 3, rounds: [Wire.ReviewRound(number: 1, verdict: .passed, found: 0, at: 1)], summary: "") }

    private func overview(_ tasks: [Wire.Task]) -> GoalOverview { GoalOverview(tasks: tasks, me: "andrea", now: now) }

    @Test func eachStateLandsInItsSection() {
        let o = overview([
            task("draft", .drafting),
            task("plan-q", .planning),
            task("plan-on", .planning) { $0.worker = worker },
            task("approved", .awaitingApproval) { $0.approvals = ["andrea"] },
            task("build-q", .building) { $0.waiting = "Waiting for a free slot" },
            task("build-on", .building) { $0.worker = worker },
            task("review-on", .reviewing) { $0.worker = worker },
            task("merged", .merged),
            task("backlog", .backlog),
            task("closed", .closed),
            task("cancelled", .cancelled),
        ])
        #expect(o.drafts.map(\.id) == ["draft"])
        #expect(o.queued.map(\.id) == ["build-q", "plan-q"])
        #expect(o.planning.map(\.id) == ["plan-on", "approved"])
        #expect(o.inMotion.map(\.id) == ["build-on", "review-on"])
        #expect(o.recentlyLanded.map(\.id) == ["merged"])
        #expect(o.needsYou.isEmpty)
    }

    @Test func nothingAppearsTwice() {
        let tasks = [
            task("a", .awaitingApproval),
            task("b", .building) { $0.hand = Wire.Hand(reason: .proofBurden, summary: "stuck", at: 1, assignee: "andrea") },
            task("c", .planning) { $0.question = Wire.Question(text: "which?", role: .planner, at: 1) },
            task("d", .reviewing) { $0.autoReview = passed() },
            task("e", .building) { $0.waiting = "slot" },
            task("f", .drafting),
            task("g", .building) { $0.worker = worker },
        ]
        let o = overview(tasks)
        let ids = o.needsYou.map(\.id) + o.queued.map(\.id) + o.planning.map(\.id) + o.drafts.map(\.id) + o.inMotion.map(\.id) + o.recentlyLanded.map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(Set(ids) == Set(tasks.map(\.id)))
    }

    @Test func needsYouIsMostPressingFirst() {
        let o = overview([
            task("review", .reviewing) { $0.autoReview = passed() },
            task("approval", .awaitingApproval),
            task("question", .planning) { $0.question = Wire.Question(text: "which?", role: .planner, at: 1) },
            task("hand", .building) { $0.hand = Wire.Hand(reason: .proofBurden, summary: "stuck", at: 1, assignee: "andrea") },
            task("asked", .reviewing, owner: "sam") { $0.requested = ["andrea"] },
        ])
        #expect(o.needsYou.map(\.id) == ["asked", "hand", "question", "approval", "review"])
        #expect(o.needsYou.map(\.reason.action) == ["Review", "Lend a hand", "Answer", "Approve plan", "Review"])
    }

    @Test func othersWorkIsNotYours() {
        let o = overview([
            task("hand", .building) { $0.hand = Wire.Hand(reason: .proofBurden, summary: "stuck", at: 1, assignee: "sam"); $0.worker = worker },
            task("question", .planning, owner: "sam") { $0.question = Wire.Question(text: "which?", role: .planner, at: 1) },
        ])
        #expect(o.needsYou.isEmpty)
        #expect(o.inMotion.map(\.id) == ["hand"])
        #expect(o.planning.map(\.id) == ["question"])
    }

    @Test func queueAndDraftsFollowTheirRanks() {
        let o = overview([
            task("q2", .building) { $0.waiting = "slot"; $0.queueRank = 20 },
            task("q1", .building) { $0.waiting = "slot"; $0.queueRank = 10 },
            task("q3", .building) { $0.waiting = "slot"; $0.queueRank = 30 },
            task("d2", .drafting) { $0.draftRank = 2 },
            task("d1", .drafting) { $0.draftRank = 1 },
        ])
        #expect(o.queued.map(\.id) == ["q1", "q2", "q3"])
        #expect(o.drafts.map(\.id) == ["d1", "d2"])
    }

    @Test func recentlyLandedKeepsTheLastSevenDaysNewestFirst() {
        let o = overview([
            task("old", .merged, updated: now - 8 * day),
            task("week", .merged, updated: now - 7 * day),
            task("today", .merged, updated: now - 1000),
            task("yesterday", .merged, updated: now - day),
        ])
        #expect(o.recentlyLanded.map(\.id) == ["today", "yesterday", "week"])
    }

    @Test func backlogIsLeftOutUnlessItNeedsYou() {
        let o = overview([
            task("parked", .backlog),
            task("stuck", .backlog) { $0.hand = Wire.Hand(reason: .proofBurden, summary: "stuck", at: 1, assignee: "andrea") },
        ])
        #expect(o.needsYou.map(\.id) == ["stuck"])
        #expect(o.queued.isEmpty && o.planning.isEmpty && o.drafts.isEmpty && o.inMotion.isEmpty)
    }

    @Test func stepsCountDoneOfAll() {
        let t = task("b", .building) {
            $0.plan = [Wire.PlanStep(text: "1", file: "", progress: .done, added: false), Wire.PlanStep(text: "2", file: "", progress: .active, added: false), Wire.PlanStep(text: "3", file: "", added: false)]
        }
        #expect(GoalOverview.steps(t)! == (1, 3))
        #expect(GoalOverview.steps(task("p", .building)) == nil)
    }
}
