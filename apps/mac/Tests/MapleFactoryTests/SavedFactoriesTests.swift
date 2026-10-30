import Foundation
import Testing
@testable import MapleFactory

/// The factories this Mac remembers: moving the old single factory in, one entry per host and port,
/// and which one opens after signing out of another.
struct SavedFactoriesTests {
    private func factory(_ url: String, org: String = "acme", at seconds: TimeInterval = 0) -> SavedFactory {
        SavedFactory(server: URL(string: url)!, org: org, name: org, lastUsed: Date(timeIntervalSince1970: seconds))
    }

    @Test func migratesTheSingleFactoryURL() {
        let list = SavedFactories.migrate(nil, currentURL: "https://factory.acme.dev", currentOrg: "acme")
        #expect(list.count == 1)
        #expect(list[0].server.absoluteString == "https://factory.acme.dev")
        #expect(list[0].org == "acme")
        #expect(list[0].name == "acme")
    }

    @Test func migratingALocalFactoryNamesItByHost() {
        let list = SavedFactories.migrate(nil, currentURL: "http://localhost:8787", currentOrg: "local")
        #expect(list.map(\.name) == ["localhost"])
        #expect(list.map(\.id) == ["localhost:8787"])
    }

    @Test func migrationKeepsAListAlreadySaved() {
        let saved = [factory("https://a.dev"), factory("https://b.dev")]
        #expect(SavedFactories.migrate(saved, currentURL: "https://c.dev", currentOrg: "c") == saved)
        #expect(SavedFactories.migrate(nil, currentURL: nil, currentOrg: nil).isEmpty)
        #expect(SavedFactories.migrate(nil, currentURL: "not a url", currentOrg: nil).isEmpty)
    }

    @Test func upsertAddsANewFactory() {
        let list = SavedFactories.upsert(factory("https://b.dev"), into: [factory("https://a.dev")])
        #expect(list.map(\.id) == ["a.dev", "b.dev"])
    }

    @Test func upsertReplacesTheSameHostAndPortInPlace() {
        let list = [factory("https://a.dev"), factory("http://localhost:8787", org: "old"), factory("https://b.dev")]
        let updated = SavedFactories.upsert(factory("https://localhost:8787/", org: "new", at: 5), into: list)
        #expect(updated.map(\.id) == ["a.dev", "localhost:8787", "b.dev"])
        #expect(updated[1].org == "new")
    }

    @Test func aDifferentPortIsADifferentFactory() {
        let list = SavedFactories.upsert(factory("http://localhost:8788"), into: [factory("http://localhost:8787")])
        #expect(list.count == 2)
    }

    @Test func removeDropsOnlyThatFactory() {
        let list = [factory("https://a.dev"), factory("https://b.dev")]
        #expect(SavedFactories.remove(URL(string: "https://a.dev")!, from: list).map(\.id) == ["b.dev"])
        #expect(SavedFactories.remove(URL(string: "https://c.dev")!, from: list) == list)
    }

    @Test func fallbackIsTheMostRecentlyUsed() {
        let list = [factory("https://a.dev", at: 10), factory("https://b.dev", at: 30), factory("https://c.dev", at: 20)]
        #expect(SavedFactories.fallback(list)?.id == "b.dev")
        #expect(SavedFactories.fallback([]) == nil)
    }

    @Test func listRoundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "SavedFactoriesTests"))
        defer { defaults.removePersistentDomain(forName: "SavedFactoriesTests") }
        #expect(SavedFactories.load(defaults) == nil)
        let list = [factory("https://a.dev", at: 1), factory("http://localhost:8787", org: "local", at: 2)]
        SavedFactories.store(list, defaults)
        #expect(SavedFactories.load(defaults) == list)
    }

    @Test func aListSavedBeforeIconsStillLoads() throws {
        let old = #"[{"server":"https://a.dev","org":"acme","name":"acme","lastUsed":0}]"#
        let list = try JSONDecoder().decode([SavedFactory].self, from: Data(old.utf8))
        #expect(list.count == 1)
        #expect(list[0].icon == nil)
    }

    @Test func onlyAnIconLinkGivesAnIconID() {
        #expect(FactoryIcons.id("/icon/2a6b3f0f-690d-43e0-b7b2-a6c2a738394e") == "2a6b3f0f-690d-43e0-b7b2-a6c2a738394e")
        #expect(FactoryIcons.id("/icon/../secrets") == nil)
        #expect(FactoryIcons.id("/attachments/2a6b3f0f-690d-43e0-b7b2-a6c2a738394e/x.png") == nil)
    }
}
