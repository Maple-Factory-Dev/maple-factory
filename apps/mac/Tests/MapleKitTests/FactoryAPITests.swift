import Foundation
import Testing
@testable import MapleKit

/// What someone types to reach a factory, and the socket URLs that follow from it.
struct FactoryAPITests {
    @Test func localHostsAreHTTPAndTheRestHTTPS() {
        #expect(FactoryAPI.serverURL(from: "localhost:8787")?.absoluteString == "http://localhost:8787")
        #expect(FactoryAPI.serverURL(from: "mini.local:8787/")?.absoluteString == "http://mini.local:8787")
        #expect(FactoryAPI.serverURL(from: " factory.acme.dev// ")?.absoluteString == "https://factory.acme.dev")
        #expect(FactoryAPI.serverURL(from: "http://factory.acme.dev")?.absoluteString == "http://factory.acme.dev")
        #expect(FactoryAPI.serverURL(from: "   ") == nil)
    }

    @Test func websocketsFollowTheServersScheme() {
        let secure = FactoryAPI.websocketURL(URL(string: "https://factory.acme.dev")!, path: "/client/connect")
        #expect(secure.absoluteString == "wss://factory.acme.dev/client/connect")
        let local = FactoryAPI.websocketURL(URL(string: "http://localhost:8787")!, path: "/client/terminal")
        #expect(local.absoluteString == "ws://localhost:8787/client/terminal")
    }

    @Test func authedRequestsCarryTheToken() {
        let request = FactoryAPI(server: URL(string: "https://factory.acme.dev")!, token: "t0k").request("/api/machines/m1", method: "DELETE")
        #expect(request.url?.absoluteString == "https://factory.acme.dev/api/machines/m1")
        #expect(request.httpMethod == "DELETE")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
    }
}

/// A task's diff as the factory serves it, parsed into files and hunks.
struct DiffParseTests {
    private let patch = """
    diff --git a/lib/jwt.ts b/lib/jwt.ts
    index 1111111..2222222 100644
    --- a/lib/jwt.ts
    +++ b/lib/jwt.ts
    @@ -3,4 +3,5 @@ import { env } from "@/lib/env";
     const a = 1;
    -const b = 2;
    +const b = 3;
    +const c = 4;
     const d = 5;
     const e = 6;
    """

    @Test func parsesFilesAndHunks() throws {
        let files = DiffFile.parse(patch)
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.path == "lib/jwt.ts")
        #expect(file.added == 2 && file.removed == 1)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.header == "@@ -3,4 +3,5 @@ import { env } from \"@/lib/env\";")
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .added, .added, .context, .context])
        #expect(hunk.lines.map(\.old) == [3, 4, nil, nil, 5, 6])
        #expect(hunk.lines.map(\.new) == [3, nil, 4, 5, 6, 7])
    }

    /// A hunk rebuilt from the parsed lines reads back the same.
    @Test func hunksRoundTrip() throws {
        let hunk = try #require(DiffFile.parse(patch).first?.hunks.first)
        let prefix: [DiffLine.Kind: String] = [.context: " ", .added: "+", .removed: "-"]
        let body = hunk.lines.map { prefix[$0.kind]! + $0.text }.joined(separator: "\n")
        let rebuilt = DiffHunk(oldStart: 3, newStart: 3, context: "import { env } from \"@/lib/env\";", step: nil, body)
        #expect(rebuilt.header == hunk.header)
        #expect(rebuilt.lines.map(\.text) == hunk.lines.map(\.text))
        #expect(rebuilt.lines.map(\.new) == hunk.lines.map(\.new))
    }
}
