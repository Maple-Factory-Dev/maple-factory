import Foundation
import Testing
@testable import MapleFactory

/// A teammate's comment that @mentions you: a Mentions row in the inbox, and a banner when it's new.
/// One that only mentions someone else gives neither (MF-49).
@MainActor struct MentionTests {
    private let members = [
        Wire.Member(login: "andrea", name: "Andrea Fomera", role: "admin", teams: []),
        Wire.Member(login: "alice", name: "Alice Liddell", role: "member", teams: []),
        Wire.Member(login: "bob", name: "Bob", role: "member", teams: []),
    ]
    private let me = Person(name: "Andrea Fomera", color: .pink, isHuman: true, github: "andrea")

    private func task(_ comments: [Wire.Comment]) throws -> Wire.Task {
        var task = try JSONDecoder().decode(Wire.Task.self, from: Data("""
        {"id":"MF-1","goal":"g","title":"A task","state":"building","owner":"andrea","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":0,"reviewsNeeded":0,
         "shareable":false,"agent":"claude"}
        """.utf8))
        task.comments = comments
        return task
    }

    private func inbox(_ t: Wire.Task) -> [InboxItem] {
        AppState.mentionItems(LiveAdapter.task(t, goals: [], members: members, me: "andrea"), me: me)
    }

    private let older = Wire.Comment(id: "c1", author: "bob", text: "Starting on it", at: 1)

    @Test func aNewCommentMentioningYouNotifiesAndShowsInTheInbox() throws {
        let before = try task([older])
        let mention = Wire.Comment(id: "c2", author: "alice", text: "@andrea can you look?", at: 2, mentions: ["andrea"])
        let after = try task([older, mention])

        let reasons = FactoryClient.mentionReasons(was: before, now: after, me: "andrea", members: members)
        #expect(reasons.count == 1)
        guard case .mention(let author, let text) = reasons.first else { Issue.record("not a mention: \(reasons)"); return }
        #expect(author == "Alice")
        #expect(text == "@andrea can you look?")
        #expect(reasons.first?.text == "Alice mentioned you: @andrea can you look?")

        #expect(inbox(before).isEmpty)
        let items = inbox(after)
        #expect(items.count == 1)
        #expect(items.first?.kind == .mention)
        #expect(items.first?.taskID == "MF-1")
        #expect(items.first?.id == "mention-c2")
        #expect(items.first?.message == "Alice: @andrea can you look?")
    }

    @Test func aCommentMentioningSomeoneElseGivesNeither() throws {
        let before = try task([older])
        let other = Wire.Comment(id: "c2", author: "alice", text: "@bob can you look? cc @andreas", at: 2, mentions: ["bob"])
        let after = try task([older, other])
        #expect(FactoryClient.mentionReasons(was: before, now: after, me: "andrea", members: members).isEmpty)
        #expect(inbox(after).isEmpty)
    }

    @Test func anUpdateWithTheSameCommentsStaysQuiet() throws {
        let mention = Wire.Comment(id: "c2", author: "alice", text: "@andrea hi", at: 2, mentions: ["andrea"])
        let same = try task([older, mention])
        #expect(FactoryClient.mentionReasons(was: same, now: same, me: "andrea", members: members).isEmpty)
        // Still in the inbox until it's dismissed.
        #expect(inbox(same).count == 1)
    }

    @Test func yourOwnCommentIsntAMention() throws {
        let mine = Wire.Comment(id: "c2", author: "andrea", text: "note to self @andrea", at: 2)
        let after = try task([mine])
        #expect(FactoryClient.mentionReasons(was: try task([]), now: after, me: "andrea", members: members).isEmpty)
        #expect(inbox(after).isEmpty)
    }

    @Test func anOlderServerWithoutMentionsFallsBackToTheText() throws {
        let legacy = Wire.Comment(id: "c2", author: "alice", text: "@andrea ping", at: 2)
        let after = try task([legacy])
        #expect(FactoryClient.mentionReasons(was: try task([]), now: after, me: "andrea", members: members).count == 1)
        #expect(inbox(after).count == 1)
        // A longer login that starts with yours isn't you.
        #expect(inbox(try task([Wire.Comment(id: "c3", author: "alice", text: "cc @andreas", at: 3)])).isEmpty)
    }

    @Test func eachMentionInATaskIsItsOwnRow() throws {
        let after = try task([
            Wire.Comment(id: "c2", author: "alice", text: "@andrea one", at: 2, mentions: ["andrea"]),
            Wire.Comment(id: "c3", author: "bob", text: "@andrea two", at: 3, mentions: ["andrea"]),
        ])
        #expect(Set(inbox(after).map(\.id)).count == 2)
    }
}
