import Foundation
import Testing
@testable import MapleFactory

/// "Ready to merge" only once CI (and any Apple check) has passed, as the server's merge gate reads it (MF-398).
@MainActor struct LiveAdapterMergeLineTests {
    private func task(checks: [String]? = nil, apple: String? = nil, reviewsNeeded: Int = 0) throws -> Wire.Task {
        let pr = checks.map { list in
            let items = list.enumerated().map { #"{"name":"c\#($0.offset)","status":"\#($0.element)","required":true}"# }.joined(separator: ",")
            return #","pr":{"number":12,"state":"open","branch":"b","base":"main","checks":[\#(items)]}"#
        } ?? ""
        let appleJSON = apple.map { #","appleChecks":{"state":"\#($0)","head":"abc1234","commands":[],"needs":[],"checks":[],"at":3}"# } ?? ""
        return try JSONDecoder().decode(Wire.Task.self, from: Data("""
        {"id":"MF-1","goal":"g","title":"A task","state":"reviewing","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":0,"reviewsNeeded":\(reviewsNeeded),
         "reviews":[],"shareable":false,"agent":"claude",
         "autoReview":{"maxRounds":3,"rounds":[{"number":1,"verdict":"passed","found":0,"at":4}],"summary":"","ask":[],"proofs":[],"findings":[]}\(pr)\(appleJSON)}
        """.utf8))
    }

    @Test func runningChecksAreNotReady() throws {
        let t = try task(checks: ["passed", "passed", "passed", "running", "queued"])
        #expect(LiveAdapter.mergeLine(t) == "Checks running · 3/5")
        let mapped = LiveAdapter.task(t, goals: [], members: [], me: nil)
        #expect(mapped.detail == "Checks running · 3/5")
        #expect(!mapped.checksFailing)
    }

    @Test func failingChecksSaySo() throws {
        let t = try task(checks: ["passed", "failed", "failed"])
        #expect(LiveAdapter.mergeLine(t) == "2 checks failing")
        #expect(LiveAdapter.task(t, goals: [], members: [], me: nil).checksFailing)
        #expect(LiveAdapter.mergeLine(try task(checks: ["failed", "running"])) == "1 check failing")
    }

    @Test func aPullRequestWithNoChecksYetWaits() throws {
        #expect(LiveAdapter.mergeLine(try task(checks: [])) == "Waiting for checks")
    }

    @Test func allPassedIsReady() throws {
        let t = try task(checks: ["passed", "passed"])
        #expect(LiveAdapter.mergeLine(t) == "Ready to merge")
        #expect(LiveAdapter.task(t, goals: [], members: [], me: nil).detail == "Ready to merge")
        #expect(LiveAdapter.mergeLine(try task(checks: ["passed"], reviewsNeeded: 1)) == "0 of 1 reviews")
    }

    @Test func appleChecksStillGateTheMerge() throws {
        #expect(LiveAdapter.mergeLine(try task(checks: ["passed"], apple: "waiting")) == "Waiting for Apple checks")
        #expect(LiveAdapter.mergeLine(try task(checks: ["passed"], apple: "running")) == "Waiting for Apple checks")
        #expect(LiveAdapter.mergeLine(try task(checks: ["passed"], apple: "passed")) == "Ready to merge")
    }

    @Test func badgeReadsTheSameSummary() {
        let checks = CICheck.standard(failing: [])
        #expect(CheckSummary(checks).ready)
        #expect(!CheckSummary([]).ready)
    }
}
