import Foundation
import Testing
@testable import MapleKit

private let t0: UInt64 = 1_790_000_000_000
private let m: UInt64 = 60_000
private func at(_ minutes: UInt64) -> Date { Date(timeIntervalSince1970: Double(t0 + minutes * m) / 1000) }
private func span(_ stage: Wire.TaskState, _ from: UInt64, _ to: UInt64?, _ wait: Wire.StageWait? = nil, inferred: Bool? = nil) -> Wire.StageSpan {
    Wire.StageSpan(stage: stage, wait: wait, from: t0 + from * m, to: to.map { t0 + $0 * m }, inferred: inferred)
}

@Suite struct TaskTimesTests {
    let merged: [Wire.StageSpan] = [
        span(.drafting, 0, 1),
        span(.planning, 1, 10),
        span(.awaitingApproval, 10, 30),
        span(.building, 30, 35, .queued),
        span(.building, 35, 50),
        span(.building, 50, 60, .hand),
        span(.building, 60, 70),
        span(.building, 70, 72, .question),
        span(.building, 72, 90),
        span(.reviewing, 90, 100),
        span(.merged, 100, 100),
    ]

    @Test func totalsAndStagesAddUp() {
        let times = TaskTimes(createdAt: t0, stages: merged, now: at(500))
        #expect(times.total == 100 * m) // ends at the merge, not now
        #expect(times.working == (9 + 15 + 10 + 18 + 10) * m)
        #expect(times.waiting == (20 + 5 + 10 + 2) * m)
        #expect(times.idle == 1 * m)
        #expect(times.working + times.waiting + times.idle == times.total)
        #expect(times.stages.map(\.stage) == [.drafting, .planning, .awaitingApproval, .building, .reviewing])
        let building = times.stages.first { $0.stage == .building }!
        #expect(building.total == 60 * m)
        #expect(building.queued == 5 * m && building.hand == 10 * m && building.question == 2 * m)
        #expect(building.waiting == 17 * m)
        #expect(times.stages.reduce(0) { $0 + $1.total } == times.total)
        #expect(!times.estimated)
        #expect(times.stages.allSatisfy { !$0.open })
    }

    @Test func openStageCountsToNow() {
        let spans = [span(.planning, 0, 10), span(.building, 10, nil)]
        let times = TaskTimes(createdAt: t0, stages: spans, now: at(45))
        #expect(times.total == 45 * m)
        let building = times.stages.last!
        #expect(building.stage == .building && building.open && building.total == 35 * m)
        #expect(times.working == 45 * m)
        // It keeps ticking.
        #expect(TaskTimes(createdAt: t0, stages: spans, now: at(50)).stages.last!.total == 40 * m)
    }

    @Test func emptyStagesFallBackToTotal() {
        let times = TaskTimes(createdAt: t0, stages: [], now: at(90))
        #expect(times.total == 90 * m)
        #expect(!times.hasBreakdown)
        #expect(times.working == 0 && times.waiting == 0)
    }

    @Test func inferredSpansAreEstimated() {
        let times = TaskTimes(createdAt: t0, stages: [span(.planning, 0, 5, inferred: true), span(.building, 5, nil, inferred: true)], now: at(10))
        #expect(times.estimated)
    }

    @Test func format() {
        #expect(TaskTimes.format(45_000) == "45s")
        #expect(TaskTimes.format(12 * m) == "12m")
        #expect(TaskTimes.format(72 * m) == "1h 12m")
        #expect(TaskTimes.format(120 * m) == "2h")
        #expect(TaskTimes.format((3 * 24 + 4) * 60 * m) == "3d 4h")
    }
}
