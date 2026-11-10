import SwiftUI

/// Which shared memories (MF-391) a list shows (MF-394): pure, so it's unit tested.
struct MemoryFilter: Equatable {
    /// What the scope picker offers in a place: a goal page offers all three, a repo's setup only the repo.
    enum ScopeChoice: String, CaseIterable, Hashable { case goal = "This goal", repos = "Repos", org = "Org" }

    /// Nil: every kind.
    var kind: Wire.MemoryKind? = nil
    var scope: ScopeChoice = .goal
    var status: Wire.MemoryStatus = .active

    /// Active and not given to an agent in this long is stale.
    static let staleAfterDays = 90

    /// The goal's id and repos a goal page scopes to; a repo's setup passes just its repo.
    var goalId: String? = nil
    var repos: [String] = []

    func scopeMatches(_ m: Wire.Memory) -> Bool {
        switch scope {
        case .goal: m.scope.kind == .goal && m.scope.key != nil && m.scope.key == goalId
        case .repos: m.scope.kind == .repo && m.scope.key.map(repos.contains) == true
        case .org: m.scope.kind == .org
        }
    }

    func matches(_ m: Wire.Memory) -> Bool {
        scopeMatches(m) && m.status == status && (kind == nil || m.kind == kind)
    }

    /// Newest change first.
    func apply(_ list: [Wire.Memory]) -> [Wire.Memory] {
        list.filter(matches).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// How many each status has in this scope and kind, for the status picker's counts.
    func count(_ list: [Wire.Memory], status: Wire.MemoryStatus) -> Int {
        list.filter { scopeMatches($0) && $0.status == status && (kind == nil || $0.kind == kind) }.count
    }

    /// Active and not given to an agent in 90 days (`lastUsedAt`, or `createdAt` when it was never used).
    static func isStale(_ m: Wire.Memory, now: Date = Date()) -> Bool {
        guard m.status == .active else { return false }
        let last = Double(m.lastUsedAt ?? m.createdAt) / 1000
        return now.timeIntervalSince1970 - last > Double(staleAfterDays) * 86_400
    }

    /// "MF-391 builder on mbp-14 · for afomera · used 12×, 3d ago", without the task id (the row links that).
    static func provenance(_ m: Wire.Memory, now: Date = Date()) -> String {
        var parts: [String] = []
        let s = m.source
        if let agent = s.agent {
            var who = agent
            if let task = s.task, who.hasPrefix(task) { who = String(who.dropFirst(task.count)).trimmingCharacters(in: .whitespaces) }
            if let machine = s.machine { who += " on \(machine)" }
            parts.append(who)
            parts.append("for \(s.by)")
        } else {
            parts.append("by \(s.by)")
        }
        if m.uses > 0, let used = m.lastUsedAt {
            parts.append("used \(m.uses)×, \(ago(used, now: now)) ago")
        } else {
            parts.append("never used")
        }
        return parts.joined(separator: " · ")
    }

    static func ago(_ ms: UInt64, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince1970 - Double(ms) / 1000)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }

    static func kindColor(_ kind: Wire.MemoryKind) -> Color {
        switch kind {
        case .fact: .blue
        case .convention: .green
        case .gotcha: .orange
        case .preference: .purple
        case .other: .gray
        }
    }
}

/// A goal's or a repo's shared memories with kind, scope and status pickers (MF-394).
struct MemoryList: View {
    @Environment(FactoryClient.self) private var client
    @Environment(AppState.self) private var state
    @State var filter: MemoryFilter
    /// Offer the This goal / Repos / Org picker (a goal page); off for a repo's setup.
    var showsScopePicker = true

    var body: some View {
        let shown = filter.apply(client.memories)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if showsScopePicker {
                    Picker("Scope", selection: $filter.scope) {
                        ForEach(MemoryFilter.ScopeChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Picker("Kind", selection: $filter.kind) {
                    Text("All kinds").tag(Wire.MemoryKind?.none)
                    ForEach(Wire.MemoryKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Wire.MemoryKind?.some($0)) }
                }
                .labelsHidden().fixedSize()
                Picker("Status", selection: $filter.status) {
                    ForEach([Wire.MemoryStatus.active, .proposed, .archived], id: \.self) { s in
                        Text("\(s.rawValue.capitalized) · \(filter.count(client.memories, status: s))").tag(s)
                    }
                }
                .labelsHidden().fixedSize()
                Spacer()
            }
            if shown.isEmpty {
                Text(filter.status == .active ? "Nothing remembered here yet." : "No \(filter.status.rawValue) memories here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textFaint).padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(shown, id: \.id) { m in
                        MemoryRow(memory: m, highlighted: state.highlightedMemory == m.id)
                        if m.id != shown.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
            }
        }
        .onAppear(perform: revealHighlight)
        .onChange(of: state.highlightedMemory) { revealHighlight() }
    }

    /// A memory opened from a task's timeline: switch the pickers so it's in view.
    private func revealHighlight() {
        guard let id = state.highlightedMemory, let m = client.memories.first(where: { $0.id == id }) else { return }
        filter.kind = nil
        filter.status = m.status
        switch m.scope.kind {
        case .goal: filter.scope = .goal
        case .repo: filter.scope = .repos
        case .org, .other: filter.scope = .org
        }
    }
}

/// One memory: kind, text, tags, Stale, provenance with a task link, and Edit / Archive / Restore / Accept.
struct MemoryRow: View {
    @Environment(FactoryClient.self) private var client
    @Environment(AppState.self) private var state
    let memory: Wire.Memory
    var highlighted = false
    @State private var editing = false
    @State private var text = ""
    @State private var kind: Wire.MemoryKind = .fact
    @State private var tags = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                chip(memory.kind.rawValue.capitalized, MemoryFilter.kindColor(memory.kind))
                if MemoryFilter.isStale(memory) { chip("Stale", .gray) }
                if memory.status == .proposed { chip("Proposed", .yellow) }
                ForEach(memory.tags, id: \.self) { Text("#\($0)").font(.system(size: 11)).foregroundStyle(Theme.textMuted) }
                Spacer()
                actions
            }
            if editing {
                editor
            } else {
                Text(memory.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(memory.status == .archived ? Theme.textMuted : Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                if let task = memory.source.task {
                    Button(task) { state.openTask(task) }
                        .buttonStyle(.link).font(.system(size: 11.5))
                        .help("Open \(task)")
                }
                Text(MemoryFilter.provenance(memory)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(highlighted ? Theme.accent.opacity(0.10) : .clear)
    }

    @ViewBuilder private var actions: some View {
        if !editing {
            HStack(spacing: 10) {
                if memory.status == .proposed {
                    Button("Accept") { client.setMemoryStatus(memory.id, .active) }
                }
                Button("Edit") {
                    text = memory.text
                    kind = memory.kind
                    tags = memory.tags.joined(separator: ", ")
                    editing = true
                }
                if memory.status == .archived {
                    Button("Restore") { client.setMemoryStatus(memory.id, .active) }
                } else {
                    Button("Archive") { client.setMemoryStatus(memory.id, .archived) }
                }
            }
            .buttonStyle(.borderless).font(.system(size: 11.5))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What to remember", text: $text, axis: .vertical)
                .lineLimit(2...6).textFieldStyle(.roundedBorder).font(.system(size: 12.5))
            HStack(spacing: 8) {
                Picker("Kind", selection: $kind) {
                    ForEach(Wire.MemoryKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden().fixedSize()
                TextField("Tags, comma separated", text: $tags).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                Button("Cancel") { editing = false }
                Button("Save") {
                    let list = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    client.editMemory(memory.id, text: text, kind: kind, tags: list)
                    editing = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 12))
        }
    }

    private func chip(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

/// A task's "Remembered N things" timeline card (MF-394): each memory it wrote, opening the goal's Memory section.
struct MemoryTimelineCard: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    let goal: String
    let memories: [Wire.Memory]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remembered \(memories.count) \(memories.count == 1 ? "thing" : "things")")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
            ForEach(memories, id: \.id) { m in
                Button {
                    state.highlightedMemory = m.id
                    state.destination = .goal(goalName(for: m))
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(m.kind.rawValue.capitalized)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(MemoryFilter.kindColor(m.kind))
                        Text(m.text.split(separator: "\n").first.map(String.init) ?? m.text)
                            .font(.system(size: 12)).lineLimit(1)
                            .strikethrough(m.status == .archived)
                            .foregroundStyle(m.status == .archived ? Theme.textFaint : Theme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show it in the goal's Memory section")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
    }

    /// The memory's own goal when it's goal-scoped, else the task's goal.
    private func goalName(for m: Wire.Memory) -> String {
        if m.scope.kind == .goal, let key = m.scope.key, let g = client.goals.first(where: { $0.id == key }) { return g.name }
        return goal
    }
}
