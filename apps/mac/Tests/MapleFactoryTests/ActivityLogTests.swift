import Foundation
import Testing
@testable import MapleFactory

/// The Activity page's feed (ActivityLog): every task's events newest first, what each filter and the goal
/// scope pick, its pages, and its cache building again only when the tasks change.
@MainActor struct ActivityLogTests {
    private func decode(_ json: String) throws -> Wire.ServerToClient {
        try JSONDecoder().decode(Wire.ServerToClient.self, from: Data(json.utf8))
    }

    /// `events` as (who, at) pairs.
    private func task(_ id: String, goal: String = "g", owner: String = "alice", events: [(String, UInt64)]) -> String {
        let events = events.map { who, at in #"{"who":"\#(who)","text":"did \#(at)","at":\#(at)}"# }
        return """
        {"id":"\(id)","goal":"\(goal)","title":"Task \(id)","state":"building","owner":"\(owner)","brief":"",
         "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":1,"reviewsNeeded":0,"shareable":false,"agent":"claude",
         "events":[\(events.joined(separator: ","))]}
        """
    }

    private func snapshot(_ tasks: [String]) -> String {
        #"""
        {"type":"snapshot","org":"acme","protocolVersion":1,
         "me":{"login":"afomera","role":"member","teams":[]},
         "members":[{"login":"alice","role":"admin","teams":[]},{"login":"afomera","name":"Andrea Fomera","role":"member","teams":[]}],
         "machines":[],"ended":[],
         "goals":[{"id":"g","name":"Goal","prefix":"MF","color":"#14B8A6","summary":"","lead":"alice","repos":[]},
                  {"id":"h","name":"Other","prefix":"OT","color":"#14B8A6","summary":"","lead":"alice","repos":[]}],
         "tasks":[\#(tasks.joined(separator: ","))],"acceptances":[],"online":[],"notes":[],"follows":[],"intake":[],"repos":[],"secrets":[],
         "policy":{"maxFiles":20,"maxLines":400,"areas":[],"planApprovals":{},"finalReviews":{},"autoMerge":{}}}
        """#
    }

    private func client(_ tasks: [String]) throws -> FactoryClient {
        let client = FactoryClient()
        client.apply(try decode(snapshot(tasks)))
        return client
    }

    private func feed(_ client: FactoryClient) -> ActivityLog {
        .live(client.tasks, tasks: client.factoryTasks, members: client.members)
    }

    /// Three tasks: alice's in Goal, yours in Goal, alice's in Other; people and agents interleaved.
    private func factory() throws -> FactoryClient {
        try client([
            task("MF-1", events: [("alice", 10), ("planner", 40), ("builder", 70)]),
            task("MF-2", owner: "afomera", events: [("afomera", 20), ("reviewer", 50)]),
            task("OT-1", goal: "h", events: [("factory", 30), ("alice", 60)]),
        ])
    }

    @Test func newestFirstAcrossTasks() throws {
        let entries = feed(try factory()).entries
        #expect(entries.map(\.at) == [70, 60, 50, 40, 30, 20, 10])
        #expect(entries.map(\.task.id) == ["MF-1", "OT-1", "MF-2", "MF-1", "OT-1", "MF-2", "MF-1"])
        #expect(entries.first?.who.name == "Builder")
        #expect(entries.first?.isAgent == true)
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    @Test func filtersAndScopePickTheirEntries() throws {
        let feed = feed(try factory())
        #expect(feed.entries(filter: .everyone).count == 7)
        #expect(feed.entries(filter: .people).map(\.at) == [60, 20, 10])
        #expect(feed.entries(filter: .agents).map(\.at) == [70, 50, 40, 30])
        // The snapshot makes FactoryData.me its signed-in member, and other suites' snapshots change it: say who's asking.
        #expect(feed.entries(filter: .mine, me: "Andrea Fomera").map(\.at) == [50, 20])
        // Following only Goal: Other's events drop out, in every filter.
        let followed: (FactoryTask) -> Bool = { $0.goal == "Goal" }
        #expect(feed.entries(filter: .everyone, inScope: followed).map(\.at) == [70, 50, 40, 20, 10])
        #expect(feed.entries(filter: .people, inScope: followed).map(\.at) == [20, 10])
        #expect(feed.entries(filter: .agents, inScope: followed).map(\.at) == [70, 50, 40])
    }

    @Test func pagesAreTheNewest() throws {
        let client = try client([
            task("MF-1", events: (0..<60).map { ("builder", UInt64(2 * $0 + 1)) }),
            task("MF-2", events: (0..<60).map { ("alice", UInt64(2 * $0 + 2)) }),
        ])
        let feed = feed(client)
        #expect(feed.entries.count == 120)
        #expect(feed.page(50).map(\.at) == (71...120).reversed().map(UInt64.init))
        #expect(feed.page(200).count == 120)
        #expect(feed.page(200).map(\.id) == feed.entries.map(\.id))
        #expect(feed.page(0).isEmpty)
    }

    @Test func cacheBuildsAgainOnlyWhenTheTasksChange() throws {
        let client = try factory()
        let cache = ActivityLog.Cache()
        func cached() -> ActivityLog { cache.feed(revision: client.tasksRevision, live: true) { feed(client) } }

        #expect(cached().entries.count == 7)
        #expect(cached().entries.count == 7)
        #expect(cache.builds == 1)

        // A task.updated with a new event is a new revision: built again, with it on top.
        client.apply(try decode(#"{"type":"task.updated","task":\#(task("MF-1", events: [("alice", 10), ("planner", 40), ("builder", 70), ("reviewer", 90)]))}"#))
        #expect(cached().entries.first?.at == 90)
        #expect(cached().entries.count == 8)
        #expect(cache.builds == 2)

        // Nothing changed: the same feed.
        #expect(cached().entries.count == 8)
        #expect(cache.builds == 2)

        // Switching to the mockup is another feed.
        _ = cache.feed(revision: client.tasksRevision, live: false) { ActivityLog(entries: []) }
        #expect(cache.builds == 3)
    }

    /// 2,000+ events: building the feed and drawing its first page stays far under a second.
    @Test func largeFactoryBuildsFast() throws {
        let tasks = (0..<100).map { n in
            task("MF-\(n)", goal: n.isMultiple(of: 3) ? "h" : "g", owner: n.isMultiple(of: 5) ? "afomera" : "alice",
                 events: (0..<24).map { (["alice", "planner", "builder", "afomera"][$0 % 4], UInt64(n * 24 + $0) * 1000) })
        }
        let client = try client(tasks)
        let clock = ContinuousClock()
        var feed: ActivityLog?
        var page = 0
        let elapsed = clock.measure {
            let built = self.feed(client)
            let shown = built.entries(filter: .everyone, inScope: { $0.goal == "Goal" })
            page = shown.prefix(ActivityLog.pageSize).map(\.when).count
            feed = built
        }
        print("ActivityLog: built \(feed?.entries.count ?? 0) events and a \(page)-entry page in \(elapsed)")
        #expect(feed?.entries.count == 2400)
        #expect(page == 50)
        #expect(elapsed < .milliseconds(250))
    }
}
