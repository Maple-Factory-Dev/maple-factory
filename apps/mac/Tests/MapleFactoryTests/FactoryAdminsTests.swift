import Foundation
import Testing
@testable import MapleFactory

/// Factory admins: members.updated replaces everyone (and me), and the People pane's badges say why someone is one.
@MainActor struct FactoryAdminsTests {
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

    /// A client that never connected (every test's) is signed in as bob for itself, but it isn't the app's
    /// identity: FactoryData.me stays the seed afomera that suites running alongside read.
    @Test func aSnapshotOnAnUnconnectedClientLeavesTheAppsMe() throws {
        let client = FactoryClient()
        client.apply(try decode(snapshot))
        #expect(client.me?.login == "bob")
        #expect(FactoryData.me.github == "afomera")
    }

    /// What FactoryData's live state is right now, comparable before and after.
    private func liveState() -> [String] {
        [FactoryData.liveGoals.map { $0.map(\.name).joined(separator: ",") } ?? "nil",
         FactoryData.livePeople.map { $0.compactMap(\.github).joined(separator: ",") } ?? "nil",
         FactoryData.livePresence.map { $0.compactMap(\.person.github).joined(separator: ",") } ?? "nil",
         FactoryData.me.github ?? "nil"]
    }

    /// Only the app's client (publishesLive) writes FactoryData's live goals, people, presence and me.
    /// A test's, unconnected or switched to a saved factory, leaves them exactly as they were, not even nil.
    @Test func aNonAppClientLeavesFactoryDataLiveStateAlone() throws {
        let before = liveState()
        let unconnected = FactoryClient()
        unconnected.apply(try decode(snapshot))
        #expect(liveState() == before)

        let suite = "FactoryAdminsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Nothing port 9 answers: the switch only needs the saved factory and its token.
        let server = try #require(URL(string: "http://localhost:9"))
        let saved = SavedFactory(server: server, org: "acme", name: "acme", lastUsed: Date(), icon: nil)
        SavedFactories.store([saved], defaults)
        defaults.set([server.absoluteString: "token"], forKey: "devFactoryTokens")
        let connected = FactoryClient(defaults: defaults)
        #expect(!connected.publishesLive)
        #expect(connected.switchTo(saved))
        #expect(connected.server == server)
        connected.apply(try decode(snapshot))
        #expect(connected.members.count == 2)
        #expect(liveState() == before)
        connected.signOut()
        #expect(liveState() == before)
        // The shared defaults never saw that factory.
        #expect(AppDefaults.string(forKey: "factoryURL") != server.absoluteString)
    }

    @Test func membersUpdatedMakesMeAdmin() throws {
        let client = FactoryClient()
        client.apply(try decode(snapshot))
        #expect(!client.isAdmin)
        client.apply(try decode(#"""
        {"type":"members.updated","members":[
          {"login":"alice","role":"admin","teams":[],"adminSource":"github"},
          {"login":"bob","role":"admin","teams":[],"adminSource":"granted","adminGrantedBy":"alice"}]}
        """#))
        #expect(client.isAdmin)
        #expect(client.me?.adminGrantedBy == "alice")
        #expect(client.members.map(\.role) == ["admin", "admin"])
    }

    @Test func membersUpdatedAboutSomeoneElseLeavesMe() throws {
        let client = FactoryClient()
        client.apply(try decode(snapshot))
        client.apply(try decode(#"{"type":"members.updated","members":[{"login":"alice","role":"admin","teams":[]},{"login":"bob","role":"member","teams":[]},{"login":"carol","role":"admin","teams":[],"adminSource":"granted","adminGrantedBy":"alice"}]}"#))
        #expect(!client.isAdmin)
        #expect(client.members.count == 3)
    }

    @Test func badges() {
        #expect(FactoryAdminsCard.badge(Wire.Member(login: "alice", role: "admin", teams: [], adminSource: "github")) == "GitHub owner")
        #expect(FactoryAdminsCard.badge(Wire.Member(login: "bob", role: "admin", teams: [], adminSource: "granted", adminGrantedBy: "alice")) == "Admin · added by @alice")
        #expect(FactoryAdminsCard.badge(Wire.Member(login: "carol", role: "member", teams: [])) == "Member")
        // An older server doesn't say why: GitHub was the only way.
        #expect(FactoryAdminsCard.badge(Wire.Member(login: "dana", role: "admin", teams: [])) == "GitHub owner")
    }
}
