import SwiftUI

/// A live session drawn from its event stream (MF-199/MF-201): messages, tool cards, prompts as buttons and a composer.
struct NativeSessionView: View {
    /// A headless script's step: `[verb, argument…]` (see AppState's `native:` demo action).
    static let demo = Notification.Name("NativeSessionView.demo")
    @Environment(FactoryClient.self) private var client
    let machineID: String
    let sessionID: String
    let agent: String?
    var readOnly = false
    let switchToTerminal: () -> Void

    private var store: NativeSessionStore? { client.nativeEvents[sessionID] }

    var body: some View {
        if !SessionViewMode.isNativeCapable(agent: agent) || store?.unavailable == true {
            unavailableNote
        } else if let store {
            VStack(spacing: 0) {
                NativeTranscript(store: store)
                if let prompt = store.prompt {
                    NativePromptCard(prompt: prompt, answering: store.answering, readOnly: readOnly) { key in
                        client.sendInput(machine: machineID, id: sessionID, input: .key(.init(promptId: prompt.id, key: key)))
                    }
                }
                NativeStatusBar(state: store.turnState, usage: store.usage)
                NativeComposer(agent: agent ?? "claude", readOnly: readOnly) { input in
                    client.sendInput(machine: machineID, id: sessionID, input: input)
                }
            }
            .background(Theme.editorBG)
        } else {
            ProgressView("Reading the session…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.editorBG)
        }
    }

    private var unavailableNote: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble").font(.system(size: 26)).foregroundStyle(Theme.textFaint)
            Text(SessionViewMode.isNativeCapable(agent: agent) ? "No transcript for this session" : "The native view is for Claude and Codex sessions")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Showing the terminal is the reliable view.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
            Button("Switch to Terminal", action: switchToTerminal).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.editorBG)
    }
}

/// The Native | Terminal switch.
struct NativeTerminalToggle: View {
    @Binding var mode: SessionViewMode

    var body: some View {
        Picker("View", selection: $mode) {
            Text("Native").tag(SessionViewMode.native)
            Text("Terminal").tag(SessionViewMode.terminal)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Show this session as a chat (Native) or as its terminal")
        .onReceive(NotificationCenter.default.publisher(for: NativeSessionView.demo)) { note in
            guard let args = note.object as? [String], args.first == "mode", args.count > 1, let picked = SessionViewMode(rawValue: args[1]) else { return }
            mode = picked
        }
    }
}

// MARK: Transcript

private struct NativeTranscript: View {
    let store: NativeSessionStore

    var body: some View {
        let rows = store.rows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if rows.isEmpty {
                    Text("Nothing in this session yet. Send a message below.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(rows) { row in
                    NativeRowView(row: row).id(row.id)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .defaultScrollAnchor(.bottom)
    }
}

private struct NativeRowView: View {
    let row: NativeRow

    var body: some View {
        switch row {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.14)))
            }
        case .assistant(_, let markdown):
            MarkdownPreview(source: markdown).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(_, let text):
            ThinkingRow(text: text)
        case .tool(_, let call, let result):
            ToolCard(call: call, result: result)
        case .turnNote(_, let state, let message):
            Label(state == .interrupted ? "Interrupted" : "Turn failed\(message.map { ": \($0)" } ?? "")",
                  systemImage: state == .interrupted ? "stop.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(state == .interrupted ? Theme.textMuted : Theme.State.cancelled)
        case .other(_, _, let summary):
            Text(summary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .textSelection(.enabled)
                .lineLimit(12)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.stroke).frame(width: 2) }
        }
    }
}

private struct ThinkingRow: View {
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                Image(systemName: "brain").font(.system(size: 11))
                Text(open ? "Thinking" : "Thinking · \(text.prefix(90).replacingOccurrences(of: "\n", with: " "))…").lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            if open {
                Text(text).textSelection(.enabled).padding(.leading, 16)
            }
        }
        .font(.system(size: 12.5).italic())
        .foregroundStyle(Theme.textMuted)
        .onReceive(NotificationCenter.default.publisher(for: NativeSessionView.demo)) { note in
            if (note.object as? [String])?.first == "think" { open = true }
        }
    }
}

struct ToolCard: View {
    let call: Wire.ToolCallInfo
    let result: Wire.SessionEventToolResult?
    @State var open = false

    private var icon: String {
        switch call.name {
        case "Bash", "exec_command", "shell": "terminal"
        case "Edit", "MultiEdit", "apply_patch": "pencil.line"
        case "Write": "doc.badge.plus"
        case "Read": "doc.text"
        case "Grep", "Glob": "magnifyingglass"
        default: call.name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textFaint)
                Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                Text(call.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Text(call.path ?? call.summary)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let diff = call.diff {
                    let lines = NativeDiffLine.parse(diff)
                    Text("+\(lines.filter { $0.kind == .added }.count)").foregroundStyle(Theme.State.merged)
                    Text("−\(lines.filter { $0.kind == .removed }.count)").foregroundStyle(Theme.State.cancelled)
                }
                if let result {
                    Image(systemName: result.ok ? "checkmark" : "xmark").foregroundStyle(result.ok ? Theme.State.merged : Theme.State.cancelled)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10).frame(height: 30)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }

            if open {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let diff = call.diff {
                        diffView(NativeDiffLine.parse(diff))
                    } else {
                        codeBlock(call.summary, prefix: call.name == "Bash" || call.name == "exec_command" ? "$ " : "")
                    }
                    if let result, !result.text.isEmpty, call.diff == nil || !result.ok {
                        codeBlock(result.text, prefix: "")
                    }
                    if result?.truncated == true {
                        Text("truncated").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Theme.fill))
                    }
                }
                .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.cardBG))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke))
        .onReceive(NotificationCenter.default.publisher(for: NativeSessionView.demo)) { note in
            guard let args = note.object as? [String], args.first == "open", args.count > 1 else { return }
            if args[1] == call.name || args[1] == call.callId { open = true }
        }
    }

    private func diffView(_ lines: [NativeDiffLine]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(line.kind == .hunk ? Theme.textFaint : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .background(line.kind == .added ? Theme.State.merged.opacity(0.16) : line.kind == .removed ? Theme.State.cancelled.opacity(0.16) : .clear)
                }
            }
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 6).fill(Term.bg.opacity(0.06)))
    }

    private func codeBlock(_ text: String, prefix: String) -> some View {
        ScrollView {
            Text(prefix + text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
    }
}

// MARK: Bottom

struct NativePromptCard: View {
    let prompt: Wire.SessionEventPrompt
    let answering: String?
    let readOnly: Bool
    let send: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(prompt.text, systemImage: prompt.kind == .permission ? "hand.raised.fill" : "questionmark.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            HStack(spacing: 8) {
                ForEach(prompt.options, id: \.key) { option in
                    let deny = option.choice == .no || option.key == "Escape"
                    Button {
                        send(option.key)
                    } label: {
                        HStack(spacing: 4) {
                            if answering == option.key { ProgressView().controlSize(.mini) }
                            Text(option.label).lineLimit(1)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(deny ? Theme.State.cancelled : option.choice == .yes ? Theme.accent : Theme.State.backlog)
                    .keyboardShortcut(deny ? .cancelAction : option.choice == .yes ? .defaultAction : nil)
                }
            }
            .disabled(answering != nil || readOnly)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.State.awaitingApproval.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.State.awaitingApproval.opacity(0.4)))
        .padding(.horizontal, 14).padding(.bottom, 8)
        .onReceive(NotificationCenter.default.publisher(for: NativeSessionView.demo)) { note in
            guard let args = note.object as? [String], args.first == "key", args.count > 1, answering == nil else { return }
            send(args[1])
        }
    }
}

private struct NativeStatusBar: View {
    let state: Wire.TurnState?
    let usage: Wire.TurnUsage?

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .running?:
                ProgressView().controlSize(.mini)
                Text("Working…").foregroundStyle(Theme.State.building)
            case .waiting?:
                Circle().fill(Theme.State.awaitingApproval).frame(width: 6, height: 6)
                Text("Waiting on you").foregroundStyle(Theme.State.awaitingApproval)
            default:
                Circle().fill(Theme.textFaint).frame(width: 6, height: 6)
                Text("Idle").foregroundStyle(Theme.textMuted)
            }
            Spacer()
            if let usage { Text(Self.describe(usage)).foregroundStyle(Theme.textMuted) }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 14).frame(height: 26)
        .background(Theme.fillSubtle)
    }

    static func describe(_ usage: Wire.TurnUsage) -> String {
        func tokens(_ n: UInt64) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
        var parts = ["\(tokens(usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0))) in", "\(tokens(usage.outputTokens)) out"]
        if let cost = usage.costUsd { parts.append(String(format: "$%.2f", cost)) }
        if let ms = usage.durationMs { parts.append(ms >= 60_000 ? "\(ms / 60_000)m \(ms % 60_000 / 1000)s" : String(format: "%.1fs", Double(ms) / 1000)) }
        return "Last turn · " + parts.joined(separator: " · ")
    }
}

struct NativeComposer: View {
    let agent: String
    let readOnly: Bool
    let send: (Wire.SessionInput) -> Void
    @State var text = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var matches: [(command: String, help: String)] {
        text.contains("\n") || text.contains(" ") ? [] : SlashCommands.matching(text, agent: agent)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !matches.isEmpty { picker }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(readOnly ? "You can watch this session; typing isn't shared with you" : "Message \(agentTitle(agent))… (/ for commands)", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...8)
                    .focused($focused)
                    .disabled(readOnly)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { text += "\n"; return .handled }
                        submit()
                        return .handled
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow, .tab]) { press in
                        guard !matches.isEmpty else { return .ignored }
                        if press.key == .tab { text = matches[min(selected, matches.count - 1)].command; return .handled }
                        selected = (selected + (press.key == .upArrow ? matches.count - 1 : 1)) % matches.count
                        return .handled
                    }
                    .onChange(of: text) { selected = 0 }
                Button { submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.textFaint : Theme.accent)
                    .disabled(readOnly)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke)))
            .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 8)
        }
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: NativeSessionView.demo)) { note in
            guard let args = note.object as? [String], let verb = args.first else { return }
            switch verb {
            case "type": text = args.dropFirst().joined(separator: ":")
            case "send": submit()
            case "down": if !matches.isEmpty { selected = (selected + 1) % matches.count }
            default: break
            }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.command) { index, match in
                HStack(spacing: 10) {
                    Text(match.command).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                    Text(match.help).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(index == selected ? Theme.fillSelected : .clear))
                .contentShape(Rectangle())
                .onTapGesture { run(match.command) }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBG).shadow(color: Theme.slabShadow, radius: 10, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        .padding(.horizontal, 12)
    }

    private func run(_ command: String) {
        send(.slash(.init(command: command)))
        text = ""
    }

    private func submit() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !readOnly else { return }
        if let first = matches.first, !message.contains(" ") {
            run(matches[min(selected, matches.count - 1)].command == message ? message : first.command)
            return
        }
        if message.hasPrefix("/") { send(.slash(.init(command: message))) } else { send(.text(.init(text: message))) }
        text = ""
    }
}
