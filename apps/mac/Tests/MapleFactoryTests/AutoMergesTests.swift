import Foundation
import Testing
@testable import MapleFactory

/// "Merge approved changes automatically" (the policy's autoMerges): a policy from before it decodes
/// as on, and off stops every auto-merge, whatever the levels or a goal's accepted risk say.
@MainActor
struct AutoMergesTests {
    /// A risk policy as a server from before the switch sends it.
    private let oldPolicy = Data("""
    {"maxFiles":12,"maxLines":500,"areas":[],"planApprovals":{"low":1,"medium":1,"high":2},
     "finalReviews":{"low":0,"medium":1,"high":2},"autoMerge":{"low":true,"medium":false,"high":false}}
    """.utf8)

    private var lowRisk: FactoryTask {
        var task = FactoryData.seedTasks.first { $0.id == "ONB-19" }!
        task.areas = []
        return task
    }

    @Test func anOldPolicyDecodesAsOn() throws {
        let wire = try JSONDecoder().decode(Wire.RiskPolicy.self, from: oldPolicy)
        #expect(wire.autoMerges == nil)
        let policy = LiveAdapter.policy(wire)
        #expect(policy.autoMerges)
        #expect(policy.assess(lowRisk)?.autoMerge == true)
    }

    @Test func offStopsEveryAutoMerge() throws {
        var policy = LiveAdapter.policy(try JSONDecoder().decode(Wire.RiskPolicy.self, from: oldPolicy))
        policy.autoMerges = false
        #expect(policy.assess(lowRisk)?.autoMerge == false)
        let acceptance = RiskAcceptance(autoMergeUpTo: .high, acceptedBy: FactoryData.me, when: "now")
        #expect(policy.assess(lowRisk, acceptance: acceptance)?.autoMerge == false)
        #expect(policy.assess(lowRisk, acceptance: acceptance)?.acceptance == nil)
        // And it round-trips to the server as off.
        #expect(LiveAdapter.wire(policy).autoMerges == false)
    }
}
