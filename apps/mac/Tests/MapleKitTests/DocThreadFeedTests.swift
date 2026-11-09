import Foundation
import Testing
@testable import MapleKit

/// MF-364: doc comment threads from the feed (doc.threads, doc.thread.updated) and the open-thread badges.
@Suite struct DocThreadFeedTests {
    private func decode(_ json: String) throws -> Wire.ServerToClient {
        try JSONDecoder().decode(Wire.ServerToClient.self, from: Data(json.utf8))
    }

    private func thread(_ id: String, doc: String = "d1", resolved: Bool = false, comments: Int = 1) -> String {
        let list = (0..<comments).map { #"{"id":"c\#($0)","author":"ada","text":"hi @grace","at":\#($0 + 1),"mentions":["grace"]}"# }.joined(separator: ",")
        return #"{"id":"\#(id)","doc":"\#(doc)","anchor":{"from":"AA==","to":"AQ==","quote":"brown fox"},"comments":[\#(list)],"resolved":\#(resolved ? "true" : "null"),"createdBy":"ada","createdAt":1}"#
    }

    private func doc(_ id: String, open: Int?, archived: Bool = false) -> Wire.Doc {
        Wire.Doc(id: id, title: id, createdBy: "ada", createdAt: 1, updatedAt: 1, archived: archived ? true : nil, openThreads: open.map(UInt32.init))
    }

    @Test func decodesDocThreadsAndUpdates() throws {
        var state = FeedState()
        state.apply(try decode(#"{"type":"doc.threads","doc":"d1","threads":[\#(thread("t1")),\#(thread("t2", resolved: true))]}"#))
        let list = try #require(state.docThreads["d1"])
        #expect(list.map(\.id) == ["t1", "t2"])
        #expect(list[0].anchor?.quote == "brown fox")
        #expect(list[0].comments.first?.mentions == ["grace"])
        #expect(list[1].resolved == true)

        // A reply upserts the thread in place; a new thread is appended; another doc's list is separate.
        state.apply(try decode(#"{"type":"doc.thread.updated","thread":\#(thread("t1", comments: 2))}"#))
        state.apply(try decode(#"{"type":"doc.thread.updated","thread":\#(thread("t3"))}"#))
        state.apply(try decode(#"{"type":"doc.thread.updated","thread":\#(thread("t9", doc: "d2"))}"#))
        #expect(state.docThreads["d1"]?.map(\.id) == ["t1", "t2", "t3"])
        #expect(state.docThreads["d1"]?.first?.comments.count == 2)
        #expect(state.docThreads["d2"]?.map(\.id) == ["t9"])
    }

    @Test func docUpdatedCarriesOpenThreads() throws {
        var state = FeedState()
        state.apply(try decode(#"{"type":"doc.updated","doc":{"id":"d1","title":"Plan","createdBy":"ada","createdAt":1,"updatedAt":2,"openThreads":3}}"#))
        #expect(state.docs.first?.openThreads == 3)
        // Resolved elsewhere: the next doc.updated lowers the badge.
        state.apply(try decode(#"{"type":"doc.updated","doc":{"id":"d1","title":"Plan","createdBy":"ada","createdAt":1,"updatedAt":3,"openThreads":2}}"#))
        #expect(state.docs.count == 1)
        #expect(FeedState.threadBadge(state.docs[0]) == 2)
    }

    @Test func badgeCounts() {
        let docs = [doc("a", open: 2), doc("b", open: nil), doc("c", open: 0), doc("d", open: 5, archived: true), doc("e", open: 1)]
        #expect(FeedState.openThreadTotal(docs) == 3)
        #expect(FeedState.threadBadge(docs[0]) == 2)
        #expect(FeedState.threadBadge(docs[1]) == nil)
        #expect(FeedState.threadBadge(docs[2]) == nil)
        #expect(FeedState.threadBadge(docs[3]) == nil, "archived docs show no badge")
        #expect(FeedState.openThreadTotal(docs).nonZeroBadge == "3")
        #expect(0.nonZeroBadge == nil)
    }
}
