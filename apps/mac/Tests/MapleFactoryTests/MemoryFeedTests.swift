import Foundation
import Testing
@testable import MapleFactory

/// Shared memories (MF-391): the Mac has no screen for them yet, so memory.updated and memory.removed
/// decode and go through FactoryClient.apply without touching anything the app shows.
@MainActor struct MemoryFeedTests {
    private func decode(_ json: String) throws -> Wire.ServerToClient {
        try JSONDecoder().decode(Wire.ServerToClient.self, from: Data(json.utf8))
    }

    private let snapshot = #"""
    {"type":"snapshot","org":"acme","protocolVersion":1,
     "me":{"login":"bob","role":"member","teams":[]},
     "members":[{"login":"alice","role":"admin","teams":[],"adminSource":"github"},{"login":"bob","role":"member","teams":[]}],
     "machines":[],"ended":[],"goals":[],"tasks":[],"acceptances":[],"online":[],"notes":[],"follows":[],"intake":[],"repos":[],"secrets":[],
     "policy":{"maxFiles":20,"maxLines":400,"areas":[],"planApprovals":{},"finalReviews":{},"autoMerge":{}}}
    """#

    private let updated = #"""
    {"type":"memory.updated","memory":{"id":"mem_1","scope":{"kind":"repo","key":"acme/app"},"kind":"gotcha",
     "text":"The Mac workflow only runs by hand.","tags":["ci","mac"],"status":"active",
     "source":{"by":"alice","task":"MF-391","role":"builder","agent":"MF-391 builder"},
     "createdAt":10,"updatedAt":20,"uses":3}}
    """#

    private let removed = #"{"type":"memory.removed","id":"mem_1"}"#

    @Test func bothMessagesDecode() throws {
        guard case .memoryUpdated(let body) = try decode(updated) else {
            Issue.record("memory.updated didn't decode as .memoryUpdated")
            return
        }
        #expect(body.memory.id == "mem_1")
        #expect(body.memory.scope.kind == .repo)
        #expect(body.memory.kind == .gotcha)
        #expect(body.memory.status == .active)
        #expect(body.memory.source.task == "MF-391")

        guard case .memoryRemoved(let gone) = try decode(removed) else {
            Issue.record("memory.removed didn't decode as .memoryRemoved")
            return
        }
        #expect(gone.id == "mem_1")
    }

    @Test func applyingThemLeavesTheFactoryAsItWas() throws {
        let client = FactoryClient()
        client.apply(try decode(snapshot))
        let goals = client.goals
        let tasks = client.tasks
        let tasksRevision = client.tasksRevision
        let decisions = client.decisions
        let members = client.members

        client.apply(try decode(updated))
        client.apply(try decode(removed))

        #expect(client.goals == goals)
        #expect(client.tasks == tasks)
        #expect(client.tasksRevision == tasksRevision)
        #expect(client.decisions == decisions)
        #expect(client.members == members)
        #expect(client.members.count == 2)
        #expect(client.me?.login == "bob")
    }
}
