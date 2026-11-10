import Foundation
import Testing
@testable import MapleKit

/// MF-367: doc decisions from the feed (snapshot, decision.updated), the open-decision badges and the filters.
@Suite struct DecisionFeedTests {
    private func decode(_ json: String) throws -> Wire.ServerToClient {
        try JSONDecoder().decode(Wire.ServerToClient.self, from: Data(json.utf8))
    }

    private func decision(_ id: String, goal: String? = "g1", status: String = "proposed", by: String = "ada", decidedBy: String? = nil, at: Int = 1) -> String {
        let goalField = goal.map { #","goal":"\#($0)""# } ?? ""
        let decided = decidedBy.map { #","decidedBy":"\#($0)","decidedAt":\#(at + 10),"chosen":"b","why":"cheaper""# } ?? ""
        return #"{"id":"\#(id)","doc":"d1"\#(goalField),"question":"Which db?","options":[{"id":"a","label":"Postgres"},{"id":"b","label":"SQLite"}],"rationale":"","status":"\#(status)","proposedBy":"\#(by)","proposedAt":\#(at)\#(decided)}"#
    }

    @Test func snapshotAndUpdatesKeepDecisions() throws {
        var state = FeedState()
        state.apply(try decode(#"{"type":"decision.updated","decision":\#(decision("x1"))}"#))
        state.apply(try decode(#"{"type":"decision.updated","decision":\#(decision("x2", goal: "g2"))}"#))
        state.apply(try decode(#"{"type":"decision.updated","decision":\#(decision("x3", status: "accepted", decidedBy: "grace"))}"#))
        #expect(state.decisions.map(\.id) == ["x1", "x2", "x3"])
        #expect(state.openDecisionTotal == 2)
        #expect(state.openDecisionCount(goal: "g1") == 1)
        #expect(state.openDecisionCount(goal: "g2") == 1)

        // Accepted from the web: the badge drops live, the row is replaced in place.
        state.apply(try decode(#"{"type":"decision.updated","decision":\#(decision("x1", status: "accepted", decidedBy: "grace"))}"#))
        #expect(state.decisions.map(\.id) == ["x1", "x2", "x3"])
        #expect(state.decisions[0].status == .accepted)
        #expect(state.decisions[0].decidedBy == "grace")
        #expect(state.decisions[0].why == "cheaper")
        #expect(state.openDecisionTotal == 1)
        #expect(state.openDecisionCount(goal: "g1") == 0)
    }

    @Test func docCarriesOpenDecisions() throws {
        var state = FeedState()
        state.apply(try decode(#"{"type":"doc.updated","doc":{"id":"d1","title":"Plan","createdBy":"ada","createdAt":1,"updatedAt":2,"openDecisions":2}}"#))
        #expect(state.docs.first?.openDecisions == 2)
    }

    @Test func filtersByStatusPersonAndGoal() throws {
        var state = FeedState()
        for (i, json) in [decision("p1", by: "ada", at: 1), decision("a1", status: "accepted", by: "sam", decidedBy: "grace", at: 2), decision("r1", goal: "g2", status: "rejected", by: "ada", decidedBy: "sam", at: 3)].enumerated() {
            _ = i
            state.apply(try decode(#"{"type":"decision.updated","decision":\#(json)}"#))
        }
        let all = state.decisions
        #expect(FeedState.filterDecisions(all, filter: .open).map(\.id) == ["p1"])
        #expect(FeedState.filterDecisions(all, filter: .accepted).map(\.id) == ["a1"])
        #expect(FeedState.filterDecisions(all, filter: .all).map(\.id) == ["r1", "a1", "p1"])
        #expect(FeedState.filterDecisions(all, filter: .all, person: "grace").map(\.id) == ["a1"])
        #expect(FeedState.filterDecisions(all, filter: .all, person: "sam").map(\.id) == ["r1", "a1"])
        #expect(FeedState.filterDecisions(all, filter: .all, goal: "g2").map(\.id) == ["r1"])
    }
}
