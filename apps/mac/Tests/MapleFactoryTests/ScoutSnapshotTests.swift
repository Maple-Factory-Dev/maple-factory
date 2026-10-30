import Foundation
import Testing
@testable import MapleFactory

/// A Scout run that's still going when the app (re)connects comes in the snapshot's `scoutRuns`, so
/// the goal's Scout button shows it running; an older server's snapshot, without them, still decodes.
@MainActor struct ScoutSnapshotTests {
    private func decode(_ json: String) throws -> Wire.ServerToClient {
        try JSONDecoder().decode(Wire.ServerToClient.self, from: Data(json.utf8))
    }

    private func snapshot(_ extra: String = "") -> String {
        #"""
        {"type":"snapshot","org":"acme","protocolVersion":1,
         "me":{"login":"bob","role":"member","teams":[]},
         "members":[],"machines":[],"ended":[],"goals":[],"tasks":[],"acceptances":[],"online":[],"notes":[],"follows":[],"intake":[],"repos":[],"secrets":[],
         "policy":{"maxFiles":20,"maxLines":400,"areas":[],"planApprovals":{},"finalReviews":{},"autoMerge":{}}
        """# + extra + "}"
    }

    @Test func aRunningRunInTheSnapshotShowsOnItsGoalsScoutButton() throws {
        let client = FactoryClient()
        client.apply(try decode(snapshot(#","scoutRuns":[{"goal":"g1","by":"bob","state":"running","startedAt":1700000000000,"tasks":[],"error":null},{"goal":"g2","by":"alice","state":"done","startedAt":1,"tasks":["S-3"],"error":null}]"#)))
        let run = try #require(client.scoutRuns["g1"])
        #expect(run.state == .running)
        #expect(run.by == "bob")
        #expect(ScoutButton(run: client.scoutRuns["g1"]) {}.running)
        #expect(client.scoutRuns["g2"]?.tasks == ["S-3"])
        #expect(!ScoutButton(run: client.scoutRuns["g2"]) {}.running)

        // A later scout.updated still replaces that goal's run.
        client.apply(try decode(#"{"type":"scout.updated","run":{"goal":"g1","by":"bob","state":"done","startedAt":1700000000000,"tasks":[],"error":null}}"#))
        #expect(client.scoutRuns["g1"]?.state == .done)
    }

    @Test func aSnapshotWithoutScoutRunsLeavesNone() throws {
        let client = FactoryClient()
        client.apply(try decode(snapshot(#","scoutRuns":[{"goal":"g1","by":"bob","state":"running","startedAt":1,"tasks":[],"error":null}]"#)))
        // An older server's snapshot, on reconnect.
        client.apply(try decode(snapshot()))
        #expect(client.scoutRuns.isEmpty)
    }
}
