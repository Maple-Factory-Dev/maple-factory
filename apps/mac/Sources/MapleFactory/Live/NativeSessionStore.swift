import Foundation
import Observation

/// One session's native-view stream (MF-199/MF-201 `session.events`): events in seq order, deduped by id
/// across backfill and live, reset when the runner's epoch changes, plus what the view needs on top.
@MainActor @Observable final class NativeSessionStore {
    private(set) var events: [Wire.SessionEvent] = []
    private var ids: Set<String> = []
    private(set) var epoch: String?
    /// The highest seq seen, for resubscribing with `since` after a reconnect.
    private(set) var lastSeq: UInt64?
    /// Any `session.events` answer has arrived (a backfill, even an empty one).
    private(set) var received = false
    /// Nothing came back in time, or the subscribe was refused: the terminal is the reliable view.
    var unavailable = false
    /// The open prompt, until its `prompt.resolved`.
    private(set) var prompt: Wire.SessionEventPrompt?
    private(set) var turnState: Wire.TurnState?
    private(set) var usage: Wire.TurnUsage?
    /// A key for the open prompt has been sent and not yet resolved.
    var answering: String?

    func apply(events new: [Wire.SessionEvent], epoch: String) {
        received = true
        unavailable = false
        if let old = self.epoch, old != epoch { reset() }
        self.epoch = epoch
        var added = false
        for event in new {
            guard let id = event.eventID, !ids.contains(id) else { continue }
            ids.insert(id)
            events.append(event)
            added = true
            lastSeq = max(lastSeq ?? 0, event.seq)
        }
        guard added else { return }
        events.sort { $0.seq < $1.seq }
        recompute()
    }

    private func reset() {
        events = []
        ids = []
        lastSeq = nil
        prompt = nil
        turnState = nil
        usage = nil
        answering = nil
    }

    /// The prompt, turn and usage follow the events in order, so a late backfill can't reopen a resolved prompt.
    private func recompute() {
        var prompt: Wire.SessionEventPrompt?
        var state: Wire.TurnState?
        var usage: Wire.TurnUsage?
        for event in events {
            switch event {
            case .prompt(let p): prompt = p; state = .waiting
            case .promptResolved(let r): if prompt?.id == r.promptId { prompt = nil; state = .running }
            case .turn(let t):
                state = t.state
                if let u = t.usage { usage = u }
                if t.state != .waiting { prompt = nil }
            case .user, .toolCall, .assistant, .thinking, .toolResult:
                if state == nil || state == .done || state == .interrupted || state == .error {
                    if case .user = event { state = .running }
                }
            case .other, .unknown: break
            }
        }
        if prompt?.id != self.prompt?.id { answering = nil }
        self.prompt = prompt
        self.turnState = state
        self.usage = usage
    }

    /// What the view draws, in order: tool calls paired with their result by callId.
    var rows: [NativeRow] {
        var results: [String: Wire.SessionEventToolResult] = [:]
        for case .toolResult(let r) in events { results[r.callId] = r }
        var rows: [NativeRow] = []
        for event in events {
            switch event {
            case .user(let u): rows.append(.user(id: u.id, text: u.text))
            case .assistant(let a): rows.append(.assistant(id: a.id, markdown: a.markdown))
            case .thinking(let t): rows.append(.thinking(id: t.id, text: t.text))
            case .toolCall(let c): rows.append(.tool(id: c.id, call: c.call, result: results[c.call.callId]))
            case .turn(let t) where t.state == .error || t.state == .interrupted:
                rows.append(.turnNote(id: t.id, state: t.state, message: t.message))
            case .other(let o):
                if let text = NativeRow.shownText(o) { rows.append(.other(id: o.id, kind: o.kind, summary: text)) }
            default: break
            }
        }
        return rows
    }
}

enum NativeRow: Identifiable, Hashable {
    case user(id: String, text: String)
    case assistant(id: String, markdown: String)
    case thinking(id: String, text: String)
    case tool(id: String, call: Wire.ToolCallInfo, result: Wire.SessionEventToolResult?)
    case turnNote(id: String, state: Wire.TurnState, message: String?)
    /// A record the runner passes through unmapped (a slash command's output, say), shown plainly.
    case other(id: String, kind: String, summary: String)

    /// What a pass-through record shows, if anything: plain text as is; a JSON record only its
    /// `content` (a slash command's output, like /remote-control's link). Bookkeeping (file
    /// snapshots, latches, tool lists, invalid lines) stays hidden.
    static func shownText(_ o: Wire.SessionEventOther) -> String? {
        let summary = o.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, o.kind != "invalid", !o.kind.contains("snapshot") else { return nil }
        guard summary.hasPrefix("{") else { return summary }
        // The summary may be cut, so read `content` by hand rather than as JSON.
        guard let range = summary.range(of: #""content":""#) else { return nil }
        var text = "", escaped = false
        for ch in summary[range.upperBound...] {
            if escaped { text.append(ch == "n" ? "\n" : ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch == "\"" { break }
            else { text.append(ch) }
        }
        return text.isEmpty ? nil : text
    }

    var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _), .thinking(let id, _), .tool(let id, _, _), .turnNote(let id, _, _), .other(let id, _, _): id
        }
    }
}

/// One line of a unified diff, coloured by what it does.
struct NativeDiffLine: Hashable {
    enum Kind { case added, removed, hunk, context }
    let kind: Kind
    let text: String

    static func parse(_ diff: String) -> [NativeDiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = String(raw)
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return nil }
            if line.hasPrefix("@@") { return NativeDiffLine(kind: .hunk, text: line) }
            if line.hasPrefix("+") { return NativeDiffLine(kind: .added, text: line) }
            if line.hasPrefix("-") { return NativeDiffLine(kind: .removed, text: line) }
            return line.isEmpty ? nil : NativeDiffLine(kind: .context, text: line)
        }
    }
}

extension Wire.SessionEvent {
    var eventID: String? {
        switch self {
        case .user(let e): e.id
        case .assistant(let e): e.id
        case .thinking(let e): e.id
        case .toolCall(let e): e.id
        case .toolResult(let e): e.id
        case .prompt(let e): e.id
        case .promptResolved(let e): e.id
        case .turn(let e): e.id
        case .other(let e): e.id
        case .unknown: nil
        }
    }

    var seq: UInt64 {
        switch self {
        case .user(let e): e.seq
        case .assistant(let e): e.seq
        case .thinking(let e): e.seq
        case .toolCall(let e): e.seq
        case .toolResult(let e): e.seq
        case .prompt(let e): e.seq
        case .promptResolved(let e): e.seq
        case .turn(let e): e.seq
        case .other(let e): e.seq
        case .unknown: 0
        }
    }
}

/// The agents' own slash commands, for the composer's picker.
enum SlashCommands {
    static func all(agent: String) -> [(command: String, help: String)] {
        switch agent {
        case "codex":
            [("/model", "Choose the model"), ("/approvals", "Choose what Codex may do without asking"), ("/compact", "Summarise the conversation to free context"),
             ("/new", "Start a new chat"), ("/diff", "Show the git diff"), ("/status", "Session settings and token usage"), ("/init", "Write an AGENTS.md")]
        default:
            [("/rc", "Remote Control: continue this session from claude.ai or the Claude app"), ("/compact", "Summarise the conversation to free context"),
             ("/clear", "Clear the conversation"), ("/model", "Choose the model"), ("/context", "Show what fills the context window"),
             ("/cost", "Show this session's cost"), ("/help", "Claude Code's help")]
        }
    }

    /// The commands that match what's typed after `/`, prefix matches first.
    static func matching(_ typed: String, agent: String) -> [(command: String, help: String)] {
        guard typed.hasPrefix("/") else { return [] }
        let query = typed.dropFirst().lowercased()
        let commands = all(agent: agent)
        if query.isEmpty { return commands }
        let prefix = commands.filter { $0.command.dropFirst().lowercased().hasPrefix(query) }
        let rest = commands.filter { c in !prefix.contains { $0.command == c.command } && c.command.lowercased().contains(query) }
        return prefix + rest
    }
}

/// Native or Terminal, remembered per user under `sessionViewMode`.
enum SessionViewMode: String, CaseIterable {
    case native, terminal
    static let storageKey = "sessionViewMode"

    static func isNativeCapable(agent: String?) -> Bool { agent == "claude" || agent == "codex" }
}
