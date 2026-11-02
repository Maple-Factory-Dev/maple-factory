import Foundation
import Testing
@testable import MapleKit

/// A task proved on Linux carries the checks its machine couldn't run (`needs macos`), open until waived (MF-335).
struct NotRunChecksTests {
    @Test func taskDecodesItsNotRunChecks() throws {
        let json = Data("""
        {"type":"task.updated","task":{
          "id":"MF-1","goal":"g","title":"A task","state":"reviewing","owner":"andrea","brief":"",
          "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":0,"reviewsNeeded":0,
          "shareable":false,"agent":"claude",
          "checksNotRun":[
            {"command":"xcodebuild test","reason":"needs macos","kind":"requirement","status":"open","machine":"droplet","at":3},
            {"command":"swift test","reason":"needs macos","kind":"requirement","status":"waived","at":3,"note":"CI runs it","by":"andrea","resolvedAt":4}
          ]
        }}
        """.utf8)
        let message = try JSONDecoder().decode(Wire.ServerToClient.self, from: json)
        guard case .taskUpdated(let body) = message else { Issue.record("decoded as \(message)"); return }
        let items = try #require(body.task.checksNotRun)
        #expect(items.map(\.reason) == ["needs macos", "needs macos"])
        #expect(items[0].status == .open && items[0].kind == .requirement && items[0].machine == "droplet")
        #expect(items[1].status == .waived && items[1].note == "CI runs it" && items[1].by == "andrea")
    }

    /// MF-337: a `[macos]` check covered by `→ gha:mac-build` settles from that GitHub check run.
    @Test func decodesCoveredItems() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../protocol/fixtures/task-not-run/covered.json").standardized
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let items = try JSONDecoder().decode([Wire.TaskNotRun].self, from: JSONSerialization.data(withJSONObject: object["items"] as Any))
        #expect(items.map(\.status) == [.covered, .failed, .open])
        #expect(items[0].cover == "mac-build" && items[0].url?.hasSuffix("/job/2") == true)
        #expect(items[2].cover == "ios-build" && items[2].url == nil)
    }

    @Test func unknownStatusDecodesAsOther() throws {
        let json = Data(#"{"command":"x","reason":"needs macos","kind":"requirement","status":"provedSomewhereNew","at":1}"#.utf8)
        let item = try JSONDecoder().decode(Wire.TaskNotRun.self, from: json)
        #expect(item.status == .other("provedSomewhereNew"))
    }

    @Test func olderServersSendNone() throws {
        let json = Data("""
        {"type":"task.updated","task":{"id":"MF-1","goal":"g","title":"A task","state":"reviewing","owner":"andrea","brief":"",
          "createdAt":1,"updatedAt":2,"planVersion":1,"approvalsNeeded":0,"reviewsNeeded":0,"shareable":false,"agent":"claude"}}
        """.utf8)
        guard case .taskUpdated(let body) = try JSONDecoder().decode(Wire.ServerToClient.self, from: json) else { Issue.record("not task.updated"); return }
        #expect(body.task.checksNotRun == nil)
    }

    @Test func waiveCheckEncodes() throws {
        let data = try JSONEncoder().encode(Wire.ClientMessage.taskWaiveCheck(.init(id: "MF-1", command: "xcodebuild test", note: "CI runs it")))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "task.waiveCheck")
        #expect(object["command"] as? String == "xcodebuild test")
        #expect(object["note"] as? String == "CI runs it")
    }
}
