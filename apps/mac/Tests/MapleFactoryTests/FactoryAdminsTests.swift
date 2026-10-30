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
