import Foundation
import Testing
@testable import MapleFactory

/// "Merge approved changes automatically" (the policy's autoMerges): a policy from before it decodes
/// as on, and off stops every auto-merge, whatever the levels or a goal's accepted risk say. In the
/// mockup an auto-merge counts down (mergeAt) like the factory's, and Hold stops it.
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

    /// The mockup with ONB-19 reviewed, proven, green and low risk: ready to auto-merge.
    private func ready() -> AppState {
        let state = AppState()
        state.mergeGrace = .milliseconds(300)
        state.update("ONB-19") { task in
            task.areas = []
            task.hand = nil
            task.mergeAt = nil
            task.autoReview = nil
            for index in task.doneWhen.indices { task.doneWhen[index].status = .proven }
            if var pr = task.pr {
                for index in pr.checks.indices { pr.checks[index].status = .passed }
                task.pr = pr
            }
        }
        #expect(state.mergeGate(for: state.task("ONB-19")).canMerge)
        #expect(state.mergeGate(for: state.task("ONB-19")).autoMerge)
        return state
    }

    @Test func theMockupCountsDownThenMerges() async throws {
        let state = ready()
        let before = Date()
        state.sweepForAutoMerge()
        let counting = state.task("ONB-19")
        let mergeAt = try #require(counting.mergeAt)
        #expect(abs(mergeAt.timeIntervalSince(before) - 0.3) < 0.1)
        #expect(counting.mergeFrom != nil)
        #expect(counting.state == .reviewing)
        // A second sweep mid-countdown doesn't start it over.
        state.sweepForAutoMerge()
        #expect(state.task("ONB-19").mergeAt == mergeAt)
        try await Task.sleep(for: .milliseconds(150))
        #expect(state.task("ONB-19").state == .reviewing)
        try await Task.sleep(for: .milliseconds(400))
        #expect(state.task("ONB-19").state == .merged)
        #expect(state.task("ONB-19").mergeAt == nil)
    }

    @Test func aRaisedHandKeepsItFromCountingDown() throws {
        let hand = try #require(AppState().task("ONB-19").hand)
        let state = ready()
        state.update("ONB-19") { $0.hand = hand }
        state.sweepForAutoMerge()
        #expect(state.task("ONB-19").mergeAt == nil)
    }

    @Test func holdStopsTheMockupsCountdown() async throws {
        let state = ready()
        state.sweepForAutoMerge()
        #expect(state.task("ONB-19").mergeAt != nil)
        state.holdMerge("ONB-19")
        #expect(state.task("ONB-19").mergeAt == nil)
        #expect(state.heldMerges.contains("ONB-19"))
        try await Task.sleep(for: .milliseconds(600))
        #expect(state.task("ONB-19").state == .reviewing)
        // It doesn't count down again; it waits for a person, whose Merge lands it.
        state.sweepForAutoMerge()
        #expect(state.task("ONB-19").mergeAt == nil)
        state.merge("ONB-19")
        #expect(state.task("ONB-19").state == .merged)
    }

    /// Its countdown ran out: the factory has it, before the server says Merging….
    @Test func aPastDueCountdownIsMerging() {
        let state = ready()
        let now = Date()
        state.update("ONB-19") { $0.mergeAt = now.addingTimeInterval(-0.1) }
        #expect(state.isMerging(state.task("ONB-19"), now: now))
        // Still counting down: Hold and Merge now stay live.
        state.update("ONB-19") { $0.mergeAt = now.addingTimeInterval(2) }
        #expect(!state.isMerging(state.task("ONB-19"), now: now))
    }

    @Test func sayingMergingIsMerging() {
        let state = ready()
        state.update("ONB-19") { $0.liveLog = FactoryTask.mergingLog }
        #expect(state.isMerging(state.task("ONB-19")))
    }

    @Test func aMergeInFlightIsMerging() {
        let state = ready()
        state.inFlight["ONB-19"] = .init(kind: .merge, startedAt: Date())
        #expect(state.isMerging(state.task("ONB-19")))
    }

    @Test func aReadyTaskIsntMerging() {
        let state = ready()
        state.update("ONB-19") { $0.liveLog = nil }
        #expect(!state.isMerging(state.task("ONB-19")))
    }
}
