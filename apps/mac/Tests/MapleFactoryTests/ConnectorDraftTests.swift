import Testing
@testable import MapleFactory

/// Settings → Connectors' sheet: arguments read the way a shell reads them, and switching transport
/// drops the stored secrets the other kind of server has no values for.
struct ConnectorDraftTests {
    @Test func argumentsKeepQuotedSpaces() {
        #expect(ShellWords.split(#"-y  mcp-atlassian "--config=/a b/c.json" '{"k": 1}' it\'s"#)
            == ["-y", "mcp-atlassian", "--config=/a b/c.json", #"{"k": 1}"#, "it's"])
        #expect(ShellWords.split("   ") == [])
        #expect(ShellWords.split(#"a "" b"#) == ["a", "", "b"])
    }

    @Test func argumentsRoundTrip() {
        let args = ["-y", "server", "/path with spaces", #"{"k": "v"}"#, "it's", "", "$HOME"]
        #expect(ShellWords.split(ShellWords.join(args)) == args)
        #expect(ShellWords.join(["-y", "pkg"]) == "-y pkg")
    }

    @Test func switchingTransportDropsStoredSecrets() {
        let saved = Wire.McpConnector(name: "jira", transport: .stdio, command: "npx", args: ["-y", "/a b"], url: nil,
                                      env: ["JIRA_TOKEN": ""], headers: [:], enabled: true, autoAllow: false)
        var draft = ConnectorDraft(saved)
        #expect(draft.args == "-y '/a b'")
        #expect(draft.secrets.map(\.key) == ["JIRA_TOKEN"])
        draft.transport = .http
        draft.transportChanged()
        #expect(draft.secrets.isEmpty)
        draft.secrets.append(.init(key: "Authorization", value: "Bearer x", stored: false))
        draft.transport = .stdio
        draft.transportChanged()
        #expect(draft.secrets.map(\.key) == ["JIRA_TOKEN", "Authorization"])
        #expect(draft.connector.args == ["-y", "/a b"])
    }
}
