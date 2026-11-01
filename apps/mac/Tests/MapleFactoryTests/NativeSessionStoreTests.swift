import Foundation
import Testing
@testable import MapleFactory

/// The native session view's store (MF-202): dedupe, epoch reset, prompts, usage, fallback, fixtures and the slash picker.
@MainActor struct NativeSessionStoreTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../../protocol/fixtures/session-events").standardized

    private func fixture(_ name: String) throws -> [Wire.SessionEvent] {
        try JSONDecoder().decode([Wire.SessionEvent].self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).expected.json")))
    }

    private func user(_ seq: UInt64, _ text: String) -> Wire.SessionEvent {
        .user(.init(id: "u\(seq)", session: "s", seq: seq, at: seq, agent: "claude", text: text))
    }

    private func turn(_ seq: UInt64, _ state: Wire.TurnState, usage: Wire.TurnUsage? = nil) -> Wire.SessionEvent {
        .turn(.init(id: "t\(seq)", session: "s", seq: seq, at: seq, agent: "claude", state: state, usage: usage))
    }

    @Test func dedupesAcrossBackfillAndLiveInSeqOrder() {
        let store = NativeSessionStore()
        store.apply(events: [user(3, "c"), user(4, "d")], epoch: "e1") // live arrives first
        store.apply(events: [user(1, "a"), user(2, "b"), user(3, "c")], epoch: "e1") // backfill overlaps it
        store.apply(events: [user(4, "d")], epoch: "e1")
        #expect(store.events.map(\.seq) == [1, 2, 3, 4])
        #expect(store.lastSeq == 4)
        #expect(store.rows.count == 4)
    }

    @Test func aNewEpochStartsOver() {
        let store = NativeSessionStore()
        store.apply(events: [user(1, "a"), user(2, "b")], epoch: "e1")
        store.apply(events: [user(1, "fresh")], epoch: "e2")
        #expect(store.rows == [.user(id: "u1", text: "fresh")])
        #expect(store.epoch == "e2")
        #expect(store.lastSeq == 1)
    }

    @Test func promptOpensAndResolves() throws {
        let store = NativeSessionStore()
        let events = try fixture("claude.notification")
        store.apply(events: [events[0]], epoch: "e")
        #expect(store.prompt?.id == "prompt-1")
        #expect(store.prompt?.options.map(\.key) == ["1", "2", "Escape"])
        #expect(store.turnState == .waiting)
        store.answering = "1"
        store.apply(events: [events[1]], epoch: "e")
        #expect(store.prompt == nil)
        #expect(store.answering == nil)
        #expect(store.turnState == .running)
    }

    @Test func usageComesFromTheTurnThatFinished() {
        let store = NativeSessionStore()
        let usage = Wire.TurnUsage(inputTokens: 1200, outputTokens: 340, costUsd: 0.12, durationMs: 8400)
        store.apply(events: [user(1, "go"), turn(2, .running)], epoch: "e")
        #expect(store.turnState == .running)
        #expect(store.usage == nil)
        store.apply(events: [turn(3, .done, usage: usage)], epoch: "e")
        #expect(store.turnState == .done)
        #expect(store.usage == usage)
    }

    @Test func fallsBackWhenNothingArrives() async {
        let client = FactoryClient()
        client.subscribeEvents(machine: "m", id: "quiet")
        #expect(client.nativeEvents["quiet"]?.unavailable == false)
        try? await Task.sleep(for: .seconds(6.5))
        #expect(client.nativeEvents["quiet"]?.unavailable == true)
        // A late answer brings it back.
        client.apply(.sessionEvents(.init(machine: "m", id: "quiet", events: [], backfill: true, nextSeq: 1, epoch: "e")))
        #expect(client.nativeEvents["quiet"]?.unavailable == false)
    }

    @Test func onlyClaudeAndCodexOfferNative() {
        #expect(SessionViewMode.isNativeCapable(agent: "claude"))
        #expect(SessionViewMode.isNativeCapable(agent: "codex"))
        #expect(!SessionViewMode.isNativeCapable(agent: "shell"))
        #expect(!SessionViewMode.isNativeCapable(agent: nil))
    }

    @Test func claudeFixtureRendersItsRows() throws {
        let store = NativeSessionStore()
        store.apply(events: try fixture("claude"), epoch: "e")
        let rows = store.rows
        #expect(rows.filter { if case .user = $0 { true } else { false } }.count == 2)
        #expect(rows.filter { if case .assistant = $0 { true } else { false } }.count == 2)
        let tools = rows.compactMap { if case .tool(_, let call, let result) = $0 { (call, result) } else { nil } }
        #expect(tools.count == 2)
        #expect(tools.allSatisfy { $0.1 != nil }) // every call paired with its result by callId
        let diffs = tools.compactMap(\.0.diff).map(NativeDiffLine.parse)
        #expect(diffs.count == 1)
        #expect(diffs[0].contains { $0.kind == .added })
        #expect(store.usage != nil)
    }

    @Test func codexFixtureRendersItsRows() throws {
        let store = NativeSessionStore()
        store.apply(events: try fixture("codex"), epoch: "e")
        let rows = store.rows
        #expect(rows.count == 3) // a user message, one exec card and the answer
        #expect(rows.filter { if case .tool(_, _, let r) = $0 { r != nil } else { false } }.count == 1)
        #expect(store.turnState == .done)
    }

    @Test func diffLinesSkipHeadersAndColourChanges() {
        let lines = NativeDiffLine.parse("--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n")
        #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added])
    }

    @Test func slashPickerFilters() {
        #expect(SlashCommands.matching("/", agent: "claude").count == 7)
        #expect(SlashCommands.matching("/r", agent: "claude").first?.command == "/rc")
        #expect(SlashCommands.matching("/co", agent: "claude").map(\.command) == ["/compact", "/context", "/cost"])
        #expect(SlashCommands.matching("/app", agent: "codex").map(\.command) == ["/approvals"])
        #expect(SlashCommands.matching("hello", agent: "claude").isEmpty)
        #expect(SlashCommands.matching("/zzz", agent: "claude").isEmpty)
    }

    @Test func passThroughRecordsShowOnlyTheirText() {
        func other(_ kind: String, _ summary: String) -> Wire.SessionEventOther {
            .init(id: kind, session: "s", seq: 1, at: 1, agent: "claude", kind: kind, summary: summary)
        }
        #expect(NativeRow.shownText(other("system/local_command", #"{"content":"/remote-control is active · Continue at https://claude.ai/code/x","cwd":"/tmp"}"#)) == "/remote-control is active · Continue at https://claude.ai/code/x")
        #expect(NativeRow.shownText(other("atis-latch", #"{"atis":"","sessionId":"x","type":"atis-latch"}"#)) == nil)
        #expect(NativeRow.shownText(other("file-history-snapshot", "snapshot")) == nil)
        #expect(NativeRow.shownText(other("system", "Compacted the conversation")) == "Compacted the conversation")
    }
}
