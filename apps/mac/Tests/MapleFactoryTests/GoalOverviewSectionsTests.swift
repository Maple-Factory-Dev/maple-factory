import Foundation
import Testing
@testable import MapleFactory

/// The Overview layout's sections: every open task in exactly one, in the order a person works them.
@MainActor
struct GoalOverviewSectionsTests {
    private typealias Sections = GoalOverviewSections
    private let today = 20

    private func task(_ id: String, state: TaskState = .building, needsYou: Bool = false, question: String? = nil,
                      hand: Bool = false, queued: Bool = false, queueRank: Double = 0, draftRank: Double = 0,
                      endedOn: Int = 20) -> FactoryTask {
        var task = FactoryTask(id: id, title: id, state: state, detail: "", needsYou: needsYou, span: 0...endedOn,
                               question: question, queued: queued, queueRank: queueRank, draftRank: draftRank)
        if hand {
            task.hand = HandRaise(reason: .proofBurden, since: "now", headline: "Can't record the video", explanation: "", tried: [], options: [])
        }
        return task
    }

    private func ids(_ tasks: [FactoryTask]) -> [String] { tasks.map(\.id) }

    private func everyID(_ sections: Sections) -> [String] {
        sections.needsYou.map(\.id) + ids(sections.drafts) + ids(sections.queued) + ids(sections.planning)
            + ids(sections.inMotion) + ids(sections.recentlyLanded)
    }

    @Test func eachStateLandsInItsSection() {
        let sections = Sections(tasks: [
            task("DRAFT", state: .drafting),
            task("PLAN", state: .planning),
            task("PARKED", state: .backlog),
            task("WAITING", state: .awaitingApproval),
            task("BUILD", state: .building),
            task("REVIEW", state: .reviewing),
            task("QUEUED", state: .building, queued: true),
            task("ASK", state: .planning, needsYou: true, question: "Which token store?"),
            task("MERGED", state: .merged),
            task("GONE", state: .cancelled),
            task("CLOSED", state: .closed),
        ], today: today)
        #expect(sections.needsYou.map(\.id) == ["ASK"])
        #expect(ids(sections.drafts) == ["DRAFT"])
        #expect(ids(sections.queued) == ["QUEUED"])
        #expect(ids(sections.planning) == ["PLAN", "WAITING"])
        #expect(ids(sections.inMotion) == ["BUILD", "REVIEW"])
        #expect(ids(sections.recentlyLanded) == ["MERGED"])
        // Backlogged and closed tasks show in no section.
        #expect(!everyID(sections).contains("PARKED"))
        #expect(!everyID(sections).contains("CLOSED"))
    }

    @Test(arguments: TaskState.allCases)
    func nothingAppearsTwice(taskState: TaskState) {
        let tasks = [
            task("A", state: taskState),
            task("B", state: taskState, needsYou: true),
            task("C", state: taskState, queued: true),
            task("D", state: taskState, needsYou: true, hand: true, queued: true),
            task("E", state: taskState, needsYou: true, question: "?", queued: true),
        ]
        let all = everyID(Sections(tasks: tasks, today: today))
        #expect(Set(all).count == all.count)
        // Open tasks all show; cancelled and closed ones (and old merges) drop out, and backlogged
        // ones show only when they need you.
        switch taskState {
        case .cancelled, .closed: #expect(all.isEmpty)
        case .backlog: #expect(Set(all) == ["B", "D", "E"])
        default: #expect(all.count == tasks.count)
        }
    }

    @Test func needsYouOrdersHandsThenQuestionsThenApprovalsThenReviews() {
        let sections = Sections(tasks: [
            task("REVIEW", state: .reviewing, needsYou: true),
            task("APPROVE", state: .awaitingApproval, needsYou: true),
            task("ASK", state: .planning, needsYou: true, question: "Which?"),
            task("HAND", state: .building, hand: true),
            task("APPROVE-2", state: .awaitingApproval, needsYou: true),
        ], today: today)
        #expect(sections.needsYou.map(\.id) == ["HAND", "ASK", "APPROVE", "APPROVE-2", "REVIEW"])
        #expect(sections.needsYou.map(\.reason) == [.hand, .question, .approval, .approval, .review])
        #expect(sections.needsYou.first?.why == "Can't record the video")
        #expect(sections.needsYou[1].why == "Which?")
    }

    @Test func backloggedTaskThatNeedsYouStillShowsUnderNeedsYou() {
        let sections = Sections(tasks: [
            task("HAND", state: .backlog, hand: true),
            task("ASK", state: .backlog, needsYou: true, question: "Still wanted?"),
            task("PARKED", state: .backlog),
        ], today: today)
        #expect(sections.needsYou.map(\.id) == ["HAND", "ASK"])
        #expect(sections.needsYou.map(\.reason) == [.hand, .question])
        #expect(sections.planning.isEmpty)
        #expect(!everyID(sections).contains("PARKED"))
    }

    @Test func pendingMergeWaitsOnYou() {
        let ready = task("READY", state: .reviewing)
        let sections = Sections(tasks: [ready, task("BUSY", state: .reviewing)], today: today) { $0.id == "READY" }
        #expect(sections.needsYou.map(\.id) == ["READY"])
        #expect(sections.needsYou.first?.reason == .review)
        #expect(ids(sections.inMotion) == ["BUSY"])
    }

    @Test func draftsFollowTheirRank() {
        let sections = Sections(tasks: [
            task("THIRD", state: .drafting, draftRank: 30),
            task("FIRST", state: .drafting, draftRank: -5),
            task("SECOND", state: .drafting, draftRank: 10),
        ], today: today)
        #expect(ids(sections.drafts) == ["FIRST", "SECOND", "THIRD"])
    }

    @Test func queueFollowsItsPosition() {
        let sections = Sections(tasks: [
            task("BACK", state: .building, queued: true, queueRank: 9),
            task("FRONT", state: .planning, queued: true, queueRank: 1),
            task("MIDDLE", state: .reviewing, queued: true, queueRank: 4),
        ], today: today)
        #expect(ids(sections.queued) == ["FRONT", "MIDDLE", "BACK"])
    }

    @Test func oldMergesDropOutAndRecentOnesAreNewestFirst() {
        let sections = Sections(tasks: [
            task("WEEK-AGO", state: .merged, endedOn: today - 7),
            task("TOO-OLD", state: .merged, endedOn: today - 8),
            task("TODAY", state: .merged, endedOn: today),
            task("YESTERDAY", state: .merged, endedOn: today - 1),
        ], today: today)
        #expect(ids(sections.recentlyLanded) == ["TODAY", "YESTERDAY", "WEEK-AGO"])
    }

    @Test func quietWhenOnlyMergesAndCancellations() {
        #expect(Sections(tasks: [task("M", state: .merged), task("C", state: .cancelled)], today: today).isQuiet)
        #expect(Sections(tasks: [task("B", state: .backlog), task("X", state: .closed)], today: today).isQuiet)
        #expect(!Sections(tasks: [task("D", state: .drafting)], today: today).isQuiet)
    }

    @Test func stepsCountDoneOverTotal() {
        var building = task("B")
        #expect(Sections.steps(building) == nil)
        building.plan = [PlanStep(text: "a", file: "", progress: .done), PlanStep(text: "b", file: "", progress: .active),
                         PlanStep(text: "c", file: "", progress: .pending)]
        #expect(Sections.steps(building)?.done == 1)
        #expect(Sections.steps(building)?.total == 3)
    }
}

/// Which Overview sections are folded, as @AppStorage keeps it.
struct OverviewCollapseTests {
    @Test func defaultCollapsesOnlyLanded() {
        let collapse = OverviewCollapse(raw: OverviewCollapse.defaultRaw)
        #expect(collapse.collapsed == [.landed])
        #expect(collapse == OverviewCollapse())
        for section in OverviewSection.allCases where section != .landed { #expect(!collapse.isCollapsed(section)) }
    }

    @Test func togglingRoundTripsThroughTheStoredString() {
        let raw = OverviewCollapse(raw: OverviewCollapse.defaultRaw).toggling(.drafts).raw
        #expect(raw == "drafts,landed")
        let reread = OverviewCollapse(raw: raw)
        #expect(reread.isCollapsed(.drafts))
        #expect(reread.isCollapsed(.landed))
        let back = reread.toggling(.drafts).toggling(.landed).raw
        #expect(back == "")
        #expect(OverviewCollapse(raw: back).collapsed.isEmpty)
    }

    @Test func unknownAndEmptyKeysAreIgnored() {
        let collapse = OverviewCollapse(raw: "queue,,bogus, inMotion ,")
        #expect(collapse.collapsed == [.queue, .inMotion])
        #expect(OverviewCollapse(raw: "").collapsed.isEmpty)
    }

    @Test func togglingOneSectionLeavesTheOthersAlone() {
        let start = OverviewCollapse(collapsed: [.queue, .landed])
        let next = start.toggling(.needsYou)
        #expect(next.collapsed == [.queue, .landed, .needsYou])
        #expect(next.toggling(.queue).collapsed == [.landed, .needsYou])
    }
}
