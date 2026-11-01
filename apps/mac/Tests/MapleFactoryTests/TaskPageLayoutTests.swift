import XCTest
@testable import MapleFactory

final class TaskPageLayoutTests: XCTestCase {
    private func index(_ s: TaskPageLayout.Section, _ state: TaskState) -> Int? {
        TaskPageLayout.sections(for: state).sections.firstIndex(of: s)
    }

    func testBannersAlwaysFirstAndTimelineLast() {
        for state in TaskState.allCases {
            let layout = TaskPageLayout.sections(for: state)
            XCTAssertEqual(layout.sections.first, .banners, "\(state)")
            XCTAssertEqual(layout.sections.last, .timeline, "\(state)")
            XCTAssertEqual(Set(layout.sections).count, layout.sections.count, "no repeats for \(state)")
            XCTAssertFalse(layout.folded.contains(.doneWhen), "\(state)")
        }
    }

    func testReviewingMergedClosedLeadWithTheReview() {
        for state in [TaskState.reviewing, .merged, .closed] {
            let order = TaskPageLayout.sections(for: state).sections
            XCTAssertEqual(Array(order.prefix(4)), [.banners, .reviewSummary, .doneWhen, .autoReview], "\(state)")
            XCTAssertLessThan(index(.doneWhen, state)!, index(.brief, state)!)
            XCTAssertLessThan(index(.doneWhen, state)!, index(.plan, state)!)
            XCTAssertEqual(TaskPageLayout.sections(for: state).folded, [.brief, .plan], "\(state)")
        }
    }

    func testPlanningStagesKeepTheBriefFirst() {
        for state in [TaskState.drafting, .planning, .awaitingApproval, .backlog] {
            let layout = TaskPageLayout.sections(for: state)
            XCTAssertLessThan(index(.brief, state)!, index(.plan, state)!, "\(state)")
            XCTAssertLessThan(index(.plan, state)!, index(.doneWhen, state)!, "\(state)")
            XCTAssertNil(index(.reviewSummary, state), "\(state)")
            XCTAssertTrue(layout.folded.isEmpty, "\(state)")
        }
    }

    func testBuildingLeadsWithThePlanAndFoldsTheBrief() {
        let order = TaskPageLayout.sections(for: .building).sections
        XCTAssertEqual(Array(order.prefix(3)), [.banners, .plan, .doneWhen])
        XCTAssertEqual(TaskPageLayout.sections(for: .building).folded, [.brief])
    }
}
