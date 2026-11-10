import Foundation
import Testing
@testable import MapleFactory

/// MF-394: which memories a goal page or a repo's setup shows, and which are stale.
struct MemoryFilterTests {
    private let day: Double = 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func memory(_ id: String, scope: Wire.MemoryScopeKind = .repo, key: String? = "acme/web", kind: Wire.MemoryKind = .fact,
                        status: Wire.MemoryStatus = .active, createdDaysAgo: Double = 1, usedDaysAgo: Double? = nil, updated: UInt64 = 0) -> Wire.Memory {
        let ms = { (days: Double) in UInt64((now.timeIntervalSince1970 - days * day) * 1000) }
        return Wire.Memory(id: id, scope: .init(kind: scope, key: key), kind: kind, text: "Memory \(id)", tags: [], status: status,
                           source: .init(by: "ann", task: "MF-391", role: "builder", agent: "MF-391 builder", machine: "mbp-14"),
                           supersedes: nil, createdAt: ms(createdDaysAgo), updatedAt: updated, lastUsedAt: usedDaysAgo.map(ms), uses: usedDaysAgo == nil ? 0 : 12)
    }

    private var all: [Wire.Memory] {
        [
            memory("g1", scope: .goal, key: "goal-1", kind: .convention),
            memory("g2", scope: .goal, key: "goal-2"),
            memory("r1", kind: .gotcha, updated: 2),
            memory("r2", key: "acme/api", kind: .fact, updated: 1),
            memory("r3", key: "acme/other"),
            memory("o1", scope: .org, key: nil, kind: .preference),
            memory("x1", kind: .gotcha, status: .archived),
            memory("p1", status: .proposed),
        ]
    }

    @Test func scopeKeepsToTheGoalItsReposOrTheOrg() {
        var f = MemoryFilter(scope: .goal, goalId: "goal-1", repos: ["acme/web", "acme/api"])
        #expect(f.apply(all).map(\.id) == ["g1"])
        f.scope = .repos
        #expect(f.apply(all).map(\.id) == ["r1", "r2"], "newest change first, other repos left out")
        f.scope = .org
        #expect(f.apply(all).map(\.id) == ["o1"])
    }

    @Test func kindNarrows() {
        var f = MemoryFilter(scope: .repos, repos: ["acme/web", "acme/api"])
        f.kind = .gotcha
        #expect(f.apply(all).map(\.id) == ["r1"])
        f.kind = .preference
        #expect(f.apply(all).isEmpty)
    }

    @Test func statusPicksActiveProposedOrArchived() {
        var f = MemoryFilter(scope: .repos, repos: ["acme/web"])
        #expect(f.apply(all).map(\.id) == ["r1"])
        f.status = .archived
        #expect(f.apply(all).map(\.id) == ["x1"])
        f.status = .proposed
        #expect(f.apply(all).map(\.id) == ["p1"])
        #expect(f.count(all, status: .active) == 1)
        #expect(f.count(all, status: .archived) == 1)
    }

    @Test func staleAfterNinetyDaysUnused() {
        #expect(!MemoryFilter.isStale(memory("a", createdDaysAgo: 200, usedDaysAgo: 89), now: now))
        #expect(MemoryFilter.isStale(memory("b", createdDaysAgo: 200, usedDaysAgo: 91), now: now))
        // Never used: counted from when it was made.
        #expect(!MemoryFilter.isStale(memory("c", createdDaysAgo: 89), now: now))
        #expect(MemoryFilter.isStale(memory("d", createdDaysAgo: 91), now: now))
        // Only active memories go stale.
        #expect(!MemoryFilter.isStale(memory("e", status: .archived, createdDaysAgo: 400), now: now))
        #expect(!MemoryFilter.isStale(memory("f", status: .proposed, createdDaysAgo: 400), now: now))
    }

    @Test func provenanceNamesTheAgentMachinePersonAndUse() {
        #expect(MemoryFilter.provenance(memory("a", usedDaysAgo: 3), now: now) == "builder on mbp-14 · for ann · used 12×, 3d ago")
        #expect(MemoryFilter.provenance(memory("b"), now: now) == "builder on mbp-14 · for ann · never used")
    }
}
