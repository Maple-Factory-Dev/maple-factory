import Foundation
import Testing
@testable import MapleKit

/// The ranking the ⌘K palette and the iPhone's search share.
struct SearchRankTests {
    private func task(_ id: String, _ title: String, goal: String = "g1", state: String = "building") throws -> Wire.Task {
        let json = """
        {"id":"\(id)","goal":"\(goal)","title":"\(title)","state":"\(state)","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":2,"approvalsNeeded":1,"reviewsNeeded":1,
         "shareable":false,"agent":"claude"}
        """
        return try JSONDecoder().decode(Wire.Task.self, from: Data(json.utf8))
    }

    private func goal(_ id: String, _ name: String, prefix: String) throws -> Wire.Goal {
        let json = """
        {"id":"\(id)","name":"\(name)","prefix":"\(prefix)","color":"#D24E26","summary":"","lead":"sam"}
        """
        return try JSONDecoder().decode(Wire.Goal.self, from: Data(json.utf8))
    }

    private let names = ["g1": "Maple", "g2": "Billing"]

    @Test func fieldScoresExactThenPrefixThenWordStartThenContainsThenFuzzy() {
        let exact = SearchRank.fieldScore("passkey", "Passkey")!
        let prefix = SearchRank.fieldScore("pass", "Passkey sign-in")!
        let wordStart = SearchRank.fieldScore("sign", "Passkey sign-in")!
        let contains = SearchRank.fieldScore("ssk", "Passkey")!
        let fuzzy = SearchRank.fieldScore("pskey", "passkey")!
        #expect(exact > prefix && prefix > wordStart && wordStart > contains && contains > fuzzy)
        #expect(fuzzy <= 100)
        #expect(SearchRank.fieldScore("pk", "a long title with p and much later k") == nil)
    }

    @Test func anIdMatchBeatsTheTitle() throws {
        let tasks = [try task("MF-2", "Fix mf-12 crash"), try task("MF-12", "Something else")]
        #expect(SearchRank.tasks("mf-12", tasks) { names[$0] ?? $0 }.map(\.item.id) == ["MF-12", "MF-2"])
    }

    @Test func everyWordHasToMatch() throws {
        let tasks = [try task("MF-1", "Passkey sign-in"), try task("MF-2", "Passkey recovery")]
        #expect(SearchRank.tasks("passkey recovery", tasks) { names[$0] ?? $0 }.map(\.item.id) == ["MF-2"])
        #expect(SearchRank.tasks("passkey zebra", tasks) { names[$0] ?? $0 }.isEmpty)
        #expect(SearchRank.tasks("   ", tasks) { names[$0] ?? $0 }.isEmpty)
    }

    @Test func unfinishedTasksBreakTies() throws {
        let tasks = [try task("MF-1", "Rate limits", state: "merged"), try task("MF-2", "Rate limits")]
        #expect(SearchRank.tasks("rate", tasks) { names[$0] ?? $0 }.map(\.item.id) == ["MF-2", "MF-1"])
    }

    @Test func tasksMatchTheirGoalsName() throws {
        let tasks = [try task("BL-1", "Invoices", goal: "g2"), try task("MF-1", "Passkeys")]
        let ranked = SearchRank.tasks("billing", tasks) { names[$0] ?? $0 }
        #expect(ranked.map(\.item.id) == ["BL-1"])
        // A goal-name match is worth half a title match.
        let titled = SearchRank.tasks("invoices", tasks) { names[$0] ?? $0 }
        #expect(titled[0].score > ranked[0].score)
    }

    @Test func goalsMatchByNameOrPrefix() throws {
        let goals = [try goal("g1", "Maple Factory", prefix: "MF"), try goal("g2", "Billing", prefix: "BL")]
        #expect(SearchRank.goals("bill", goals).map(\.item.id) == ["g2"])
        #expect(SearchRank.goals("mf", goals).map(\.item.id) == ["g1"])
        #expect(SearchRank.goals("factory", goals).map(\.item.id) == ["g1"])
        #expect(SearchRank.goals("nope", goals).isEmpty)
    }

    @Test func tiesKeepTheirOrder() {
        #expect(SearchRank.ranked([("a", 5), ("b", 9), ("c", 5)]).map(\.item) == ["b", "a", "c"])
    }
}
