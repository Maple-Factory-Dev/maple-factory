import SwiftUI

/// What a task builds on, picked like an owner: a "Filter tasks" field over its goal's other open tasks
/// (ID, title, state), building and in-review ones first, then the rest by ID. ↑/↓ move the highlight,
/// Return adds the highlighted task, Esc closes. From the Detail panel's Builds on row, Add….
struct BuildsOnPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let task: FactoryTask
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    /// A demo script's `linkpick:<id>`: Return, on the open picker.
    static let demoPick = Notification.Name("BuildsOnPopover.demoPick")

    private var shown: [FactoryTask] {
        Self.matches(for: task, query: query, tasks: appState.tasks)
    }

    var body: some View {
        let shown = shown
        VStack(alignment: .leading, spacing: 0) {
            Text("\(task.id) builds on")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                TextField("Filter tasks", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { pick(shown) }
                    .onExitCommand { close() }
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        guard !shown.isEmpty else { return .handled }
                        highlighted = min(max(highlighted + (press.key == .upArrow ? -1 : 1), 0), shown.count - 1)
                        return .handled
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Divider()
            if shown.isEmpty {
                let needle = query.trimmingCharacters(in: .whitespaces)
                Text(needle.isEmpty ? "No other open tasks in this goal" : "No open tasks match ‘\(needle)’")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, other in
                            row(other, highlighted: index == highlighted)
                                .onTapGesture { add(other) }
                                .onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 320)
        .onAppear {
            focused = true
            if appState.linkingTask == task.id { query = appState.linkQuery }
        }
        .onChange(of: query) { highlighted = 0 }
        .onChange(of: appState.linkQuery) { _, typed in if appState.linkingTask == task.id { query = typed } }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoPick)) { note in
            if note.object as? String == task.id { pick(shown) }
        }
        .onDisappear { if appState.linkingTask == task.id { appState.linkingTask = nil } }
    }

    private func row(_ other: FactoryTask, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(other.state.color)
                .frame(width: 7, height: 7)
            Text(other.id)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
            Text(other.title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(other.state.title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Theme.fill : .clear))
        .contentShape(Rectangle())
        .help(other.title)
    }

    private func pick(_ shown: [FactoryTask]) {
        guard shown.indices.contains(highlighted) else { return }
        add(shown[highlighted])
    }

    private func add(_ other: FactoryTask) {
        appState.setAfter(task.id, task.after + [other.id])
        close()
    }

    private func close() {
        if appState.linkingTask == task.id { appState.linkingTask = nil }
        dismiss()
    }

    /// The tasks `task` can build on whose ID or title contains `query` (ignoring case): its goal's other
    /// open tasks it doesn't already wait on, leaving out any that already wait on it (directly or not),
    /// since that would make a loop. Building and in-review tasks come first, then the rest by ID.
    static func matches(for task: FactoryTask, query: String, tasks: [FactoryTask]) -> [FactoryTask] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        /// Whether `id` already waits (directly or not) on `task`, so adding it would make a loop.
        func waitsOnTask(_ id: String) -> Bool {
            var seen = Set<String>(), stack = [id]
            while let next = stack.popLast() {
                if next == task.id { return true }
                guard seen.insert(next).inserted else { continue }
                stack += byID[next]?.after ?? []
            }
            return false
        }
        func rank(_ other: FactoryTask) -> Int { other.state == .building || other.state == .reviewing ? 0 : 1 }
        return tasks
            .filter { $0.goal == task.goal && $0.id != task.id && !$0.state.isFinished && !task.after.contains($0.id) }
            .filter { needle.isEmpty || $0.id.localizedCaseInsensitiveContains(needle) || $0.title.localizedCaseInsensitiveContains(needle) }
            .filter { !waitsOnTask($0.id) }
            .sorted { a, b in
                rank(a) != rank(b) ? rank(a) < rank(b) : a.id.localizedStandardCompare(b.id) == .orderedAscending
            }
    }
}
