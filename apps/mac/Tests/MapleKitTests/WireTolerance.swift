import Foundation
import Testing
@testable import MapleKit

/// A newer server may send enum values this build doesn't know (HandReason.mergeFailed broke 0.1.1).
/// They decode as `.other("…")` instead of failing the whole message and dropping the feed.
struct WireTolerance {
    /// `task.updated` as a newer server would send it.
    private func taskUpdated(state: String, reason: String) -> Data {
        Data("""
        {"type":"task.updated","task":{
          "id":"MF-1","goal":"g","title":"A task","state":"\(state)","owner":"andrea","brief":"",
          "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":0,"reviewsNeeded":0,
          "shareable":false,"agent":"claude",
          "hand":{"reason":"\(reason)","summary":"Something new needs you","at":3,"assignee":"andrea"}
        }}
        """.utf8)
    }

    @Test func unknownValuesDecodeAsOther() throws {
        let message = try JSONDecoder().decode(Wire.ServerToClient.self, from: taskUpdated(state: "somethingNewer", reason: "somethingNew"))
        guard case .taskUpdated(let body) = message else { Issue.record("decoded as \(message)"); return }
        #expect(body.task.state == .other("somethingNewer"))
        #expect(body.task.hand?.reason == .other("somethingNew"))
        #expect(body.task.hand?.summary == "Something new needs you")
    }

    @Test func knownValuesRoundTrip() throws {
        let message = try JSONDecoder().decode(Wire.ServerToClient.self, from: taskUpdated(state: "building", reason: "mergeFailed"))
        guard case .taskUpdated(let body) = message else { Issue.record("decoded as \(message)"); return }
        #expect(body.task.state == .building)
        #expect(body.task.hand?.reason == .mergeFailed)
        let again = try JSONDecoder().decode(Wire.ServerToClient.self, from: JSONEncoder().encode(message))
        #expect(again == message)
        #expect(String(decoding: try JSONEncoder().encode(Wire.HandReason.other("somethingNew")), as: UTF8.self) == #""somethingNew""#)
    }

    /// An OrgRepo from before description and ownerAvatarUrl (an older server, or a stored repo list) still decodes.
    @Test func orgRepoWithoutDescriptionOrAvatarDecodes() throws {
        let repo = try JSONDecoder().decode(Wire.OrgRepo.self, from: Data(#"{"name":"acme/api","defaultBranch":null,"isPrivate":false,"source":"manual"}"#.utf8))
        #expect(repo == Wire.OrgRepo(name: "acme/api", isPrivate: false, source: .manual))
        #expect(repo.description == nil && repo.ownerAvatarUrl == nil)
    }

    @Test func allCasesLeavesOutOther() {
        #expect(Wire.HandReason.allCases.count == 6)
        #expect(!Wire.HandReason.allCases.contains { if case .other = $0 { true } else { false } })
        #expect(Wire.HandReason(rawValue: "mergeFailed") == .mergeFailed)
    }

    @Test func undecodableMessagesSayToUpdate() {
        let error = DecodingError.typeMismatch(UInt64.self, .init(codingPath: [], debugDescription: "x"))
        #expect(FactoryAPI.describe(error) == FactoryAPI.tooNewMessage)
    }
}
