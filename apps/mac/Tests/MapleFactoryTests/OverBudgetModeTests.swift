import Foundation
import Testing
@testable import MapleFactory

/// Risk policy › Task budget's When a task goes over (the policy's overBudget): an older server's policy, without
/// it, reads as Ask, and the picker's choice goes back to the server as "ask" or "handOff".
@MainActor struct OverBudgetModeTests {
    private let oldPolicy = Data("""
    {"maxFiles":12,"maxLines":500,"areas":[],"planApprovals":{"low":1,"medium":1,"high":2},
     "finalReviews":{"low":0,"medium":1,"high":2},"autoMerge":{"low":true,"medium":false,"high":false}}
    """.utf8)

    @Test func noneIsAskAndTheChoiceRoundTrips() throws {
        var policy = LiveAdapter.policy(try JSONDecoder().decode(Wire.RiskPolicy.self, from: oldPolicy))
        #expect(!policy.handOffOverBudget)
        #expect(LiveAdapter.wire(policy).overBudget == "ask")
        policy.handOffOverBudget = true
        let wire = LiveAdapter.wire(policy)
        #expect(wire.overBudget == "handOff")
        #expect(LiveAdapter.policy(wire).handOffOverBudget)
    }
}
