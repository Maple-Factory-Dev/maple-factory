import Foundation
import Testing
@testable import MapleFactory

/// What's worked out from the tasks once per change (TaskCache: a task by id, the inbox, raised hands) stays
/// what working it out afresh gives, after a snapshot, task.updated and presence; and a presence change
/// touches only the tasks someone came to or left.
@MainActor struct PerformanceCacheTests {
    private func decode(_ json: String) throws -> Wire.ServerToClient {
        try JSONDecoder().decode(Wire.ServerToClient.self, from: Data(json.utf8))
    }

    private func task(_ id: String, state: String = "drafting", hand: Bool = false, comments: String = "") -> String {
        """
        {"id":"\(id)","goal":"g","title":"Task \(id)","state":"\(state)","owner":"alice","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":1,"reviewsNeeded":0,"shareable":false,"agent":"claude",
         "comments":[\(comments)]\(hand ? #","hand":{"reason":"blocked","summary":"Stuck","at":3,"assignee":"bob"}"# : "")}
        """
    }

    private func presence(_ viewers: [(String, String?)]) -> String {
        let online = viewers.map { login, viewing in #"{"login":"\#(login)","viewing":\#(viewing.map { "\"\($0)\"" } ?? "null"),"since":1}"# }
        return #"{"type":"presence","online":[\#(online.joined(separator: ","))]}"#
    }

    private func snapshot(_ tasks: [String], online: [(String, String?)] = []) -> String {
        let presence = presence(online).replacingOccurrences(of: #"{"type":"presence","online":"#, with: "").dropLast()
        return #"""
        {"type":"snapshot","org":"acme","protocolVersion":1,
         "me":{"login":"bob","role":"member","teams":[]},
         "members":[{"login":"alice","role":"admin","teams":[]},{"login":"bob","role":"member","teams":[]},{"login":"carol","role":"member","teams":[]}],
         "machines":[],"ended":[],"goals":[{"id":"g","name":"Goal","prefix":"MF","color":"#14B8A6","summary":"","lead":"alice","repos":[]}],
         "tasks":[\#(tasks.joined(separator: ","))],"acceptances":[],"online":\#(presence),"notes":[],"follows":[],"intake":[],"repos":[],"secrets":[],
         "policy":{"maxFiles":20,"maxLines":400,"areas":[],"planApprovals":{},"finalReviews":{},"autoMerge":{}}}
        """#
    }

    private let mention = #"{"id":"c1","author":"alice","text":"@bob have a look","at":5,"mentions":["bob"]}"#

    /// The cache, synced to the client, against working everything out afresh.
    private func expectFresh(_ cache: inout TaskCache, _ client: FactoryClient) {
        let tasks = client.factoryTasks
        let me = LiveAdapter.person("bob", members: client.members)
        cache.sync(revision: client.tasksRevision, live: true)
        for task in tasks {
            #expect(cache.index(of: task.id, in: tasks).map { tasks[$0].id } == task.id)
        }
        #expect(cache.index(of: "MF-404", in: tasks) == nil)
        #expect(cache.handRaises(in: tasks).map(\.id) == tasks.filter { $0.hand != nil }.map(\.id))
        let fresh = AppState.liveInbox(tasks, me: me, dismissed: []) { AppState.mentionItems($0, me: me) }
        let cached = cache.inbox(tasks, me: me, dismissed: [])
        #expect(cached.map(\.taskID) == fresh.map(\.taskID))
        #expect(cached.map(\.kind) == fresh.map(\.kind))
    }

    @Test func staysCorrectAfterSnapshotTaskUpdatedAndPresence() throws {
        let client = FactoryClient()
        var cache = TaskCache()
        client.apply(try decode(snapshot([task("MF-1"), task("MF-2", hand: true), task("MF-3", state: "awaitingApproval")])))
        expectFresh(&cache, client)
        #expect(cache.handRaises(in: client.factoryTasks).map(\.id) == ["MF-2"])

        // A new task, a hand going up, and a comment mentioning you: each is a new revision.
        var revision = client.tasksRevision
        client.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-4", hand: true))}"#))
        #expect(client.tasksRevision != revision)
        expectFresh(&cache, client)
        #expect(cache.index(of: "MF-4", in: client.factoryTasks) == 0)
        #expect(Set(cache.handRaises(in: client.factoryTasks).map(\.id)) == ["MF-2", "MF-4"])

        revision = client.tasksRevision
        client.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-1", comments: mention))}"#))
        #expect(client.tasksRevision != revision)
        expectFresh(&cache, client)
        let me = LiveAdapter.person("bob", members: client.members)
        let inbox = cache.inbox(client.factoryTasks, me: me, dismissed: [])
        #expect(inbox.contains { $0.kind == .mention && $0.taskID == "MF-1" })

        client.apply(try decode(#"{"type":"task.removed","id":"MF-2"}"#))
        expectFresh(&cache, client)
        #expect(cache.index(of: "MF-2", in: client.factoryTasks) == nil)

        client.apply(try decode(presence([("alice", "MF-3")])))
        expectFresh(&cache, client)
        #expect(client.factoryTasks[cache.index(of: "MF-3", in: client.factoryTasks)!].viewers.map(\.github) == ["alice"])

        // A second snapshot, as after a reconnect, with other tasks.
        client.apply(try decode(snapshot([task("MF-9", hand: true)])))
        expectFresh(&cache, client)
        #expect(cache.index(of: "MF-1", in: client.factoryTasks) == nil)
        #expect(cache.handRaises(in: client.factoryTasks).map(\.id) == ["MF-9"])
    }

    @Test func keptUntilTheRevisionMoves() throws {
        let client = FactoryClient()
        client.apply(try decode(snapshot([task("MF-1", comments: mention), task("MF-2"), task("MF-3")])))
        let me = LiveAdapter.person("bob", members: client.members)
        var cache = TaskCache()
        func inbox(_ dismissed: Set<String> = [], me: Person = me) -> [InboxItem] {
            cache.sync(revision: client.tasksRevision, live: true)
            return cache.inbox(client.factoryTasks, me: me, dismissed: dismissed)
        }
        #expect(inbox().count == 1)
        #expect(inbox().count == 1)
        #expect(cache.builds.inbox == 1)
        // Dismissing a mention, or someone else signed in, works it out again.
        #expect(inbox(["mention-c1"]).isEmpty)
        _ = inbox(["mention-c1"], me: LiveAdapter.person("carol", members: client.members))
        #expect(cache.builds.inbox == 3)

        // A task edited: a new inbox, but only the edited task's mentions are looked for again, and
        // only if its comments changed.
        _ = inbox()
        let mentionsBefore = cache.builds.mentions
        client.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-2", state: "awaitingApproval"))}"#))
        #expect(inbox().map(\.kind).sorted { "\($0)" < "\($1)" } == [.approval, .mention])
        #expect(cache.builds.inbox == 5)
        #expect(cache.builds.mentions == mentionsBefore)
        client.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-3", comments: mention.replacingOccurrences(of: "c1", with: "c2")))}"#))
        #expect(inbox().filter { $0.kind == .mention }.map(\.taskID).sorted() == ["MF-1", "MF-3"])
        #expect(cache.builds.mentions == mentionsBefore + 1)

        // The mockup's revision isn't the factory's.
        cache.sync(revision: client.tasksRevision, live: false)
        _ = cache.inbox(client.factoryTasks, me: me, dismissed: [])
        #expect(cache.builds.inbox == 7)
    }

    @Test func presenceTouchesOnlyTheTasksSomeoneCameToOrLeft() throws {
        let client = FactoryClient()
        client.apply(try decode(snapshot([task("MF-1"), task("MF-2"), task("MF-3")], online: [("alice", "MF-1"), ("bob", "MF-3")])))
        // You don't count as a viewer of what you're looking at.
        #expect(client.factoryTasks.map { $0.viewers.compactMap(\.github) } == [["alice"], [], []])

        // Alice moves from MF-1 to MF-2: those two change, MF-3 doesn't, in one write.
        let viewers = FactoryClient.viewers(try presenceOnline((presence([("alice", "MF-2"), ("bob", "MF-3")]))), me: "bob", members: client.members)
        #expect(FactoryClient.viewerChanges(client.factoryTasks, viewers: viewers).map(\.index) == [0, 1])
        var revision = client.tasksRevision
        client.apply(try decode(presence([("alice", "MF-2"), ("bob", "MF-3")])))
        #expect(client.tasksRevision == revision &+ 1)
        #expect(client.factoryTasks.map { $0.viewers.compactMap(\.github) } == [[], ["alice"], []])

        // A ping that moves no one but you changes no task.
        revision = client.tasksRevision
        client.apply(try decode(presence([("alice", "MF-2"), ("bob", "MF-1")])))
        client.apply(try decode(presence([("alice", "MF-2"), ("bob", nil), ("carol", nil)])))
        #expect(client.tasksRevision == revision)

        // Carol joins Alice on MF-2: only MF-2.
        let joined = FactoryClient.viewers(try presenceOnline((presence([("alice", "MF-2"), ("carol", "MF-2")]))), me: "bob", members: client.members)
        #expect(FactoryClient.viewerChanges(client.factoryTasks, viewers: joined).map(\.index) == [1])
        client.apply(try decode(presence([("alice", "MF-2"), ("carol", "MF-2")])))
        #expect(client.factoryTasks[1].viewers.compactMap(\.github) == ["alice", "carol"])
    }

    private func presenceOnline(_ json: String) throws -> [Wire.Presence] {
        guard case .presence(let update) = try decode(json) else { throw CocoaError(.coderReadCorrupt) }
        return update.online
    }
}
