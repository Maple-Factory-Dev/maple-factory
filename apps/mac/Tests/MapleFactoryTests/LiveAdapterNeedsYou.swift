import Foundation
import Testing
@testable import MapleFactory

/// A passed automatic review only needs you while a person's review is still owed. A low-risk task that
/// needs none is about to auto-merge, so no "Ready for your review" (MF-172).
@MainActor struct LiveAdapterNeedsYou {
    private func task(reviewsNeeded: Int, reviews: [String] = []) throws -> Wire.Task {
        let reviewed = reviews.map { "\"\($0)\"" }.joined(separator: ",")
        return try JSONDecoder().decode(Wire.Task.self, from: Data("""
        {"id":"MF-1","goal":"g","title":"A task","state":"reviewing","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":0,"reviewsNeeded":\(reviewsNeeded),
         "reviews":[\(reviewed)],"shareable":false,"agent":"claude",
         "autoReview":{"maxRounds":3,"rounds":[{"number":1,"verdict":"passed","found":0,"at":4}],"summary":"","ask":[],"proofs":[],"findings":[]}}
        """.utf8))
    }

    @Test func aPassedTaskThatNeedsNoReviewDoesNotNeedYou() throws {
        #expect(!LiveAdapter.needsYou(try task(reviewsNeeded: 0), me: "bea"))
    }

    @Test func aPassedTaskThatStillNeedsAReviewNeedsYou() throws {
        #expect(LiveAdapter.needsYou(try task(reviewsNeeded: 1), me: "bea"))
    }

    @Test func aPassedTaskWithItsReviewsInDoesNotNeedYou() throws {
        #expect(!LiveAdapter.needsYou(try task(reviewsNeeded: 1, reviews: ["cal"]), me: "bea"))
        #expect(!LiveAdapter.needsYou(try task(reviewsNeeded: 2, reviews: ["bea"]), me: "bea"))
    }
}
