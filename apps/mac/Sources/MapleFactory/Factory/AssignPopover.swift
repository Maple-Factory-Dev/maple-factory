import SwiftUI

/// Who owns a task, picked GitHub-style: a "Filter people" field over the org's teammates (avatar, name,
/// @login), its current owner checked at the top, then you, then everyone else A–Z. ↑/↓ move the
/// highlight, Return assigns the highlighted person, Esc closes. From the owner chip, the Detail
/// panel's Owner row and the ⋯ menu's Assign….
struct AssignPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let task: FactoryTask
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    /// A demo script's `assignpick:<id>`: Return, on the open picker.
    static let demoPick = Notification.Name("AssignPopover.demoPick")

    private var shown: [(person: Person, current: Bool)] {
        Self.matches(for: task, query: query, everyone: appState.canReassign(task.id))
    }

    var body: some View {
        let shown = shown
        VStack(alignment: .leading, spacing: 0) {
            Text("Assign \(task.id) to")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                TextField("Filter people", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { pick(shown) }
                    .onExitCommand { dismiss() }
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
                Text("No one matches ‘\(query)’")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.person.id) { index, choice in
                            row(choice, highlighted: index == highlighted)
                                .onTapGesture { assign(choice.person) }
                                .onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 280)
        .onAppear {
            focused = true
            if appState.assigningTask == task.id { query = appState.assignQuery }
        }
        .onChange(of: query) { highlighted = 0 }
        .onChange(of: appState.assignQuery) { _, typed in if appState.assigningTask == task.id { query = typed } }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoPick)) { note in
            if note.object as? String == task.id { pick(shown) }
        }
        .onDisappear { if appState.assigningTask == task.id { appState.assigningTask = nil } }
    }

    private func row(_ choice: (person: Person, current: Bool), highlighted: Bool) -> some View {
        let person = choice.person
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.text)
                .opacity(choice.current ? 1 : 0)
                .frame(width: 12)
            AgentAvatar(agent: person, size: 20)
            Text(person.github == FactoryData.me.github ? "\(person.name) (you)" : person.name)
                .font(.system(size: 13, weight: choice.current ? .semibold : .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let login = person.github {
                Text("@\(login)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Theme.fill : .clear))
        .contentShape(Rectangle())
    }

    private func pick(_ shown: [(person: Person, current: Bool)]) {
        guard shown.indices.contains(highlighted) else { return }
        assign(shown[highlighted].person)
    }

    private func assign(_ person: Person) {
        if let login = person.github { appState.assign(task.id, to: login) }
        appState.assigningTask = nil
        dismiss()
    }

    /// The people `task` can go to whose name or login contains `query` (ignoring case): teammates with a
    /// GitHub login, its current owner checked and first, then you, then the rest by name. Without
    /// `everyone` (you can't reassign it) it's only you: Take it over.
    static func matches(for task: FactoryTask, query: String, everyone: Bool = true,
                        people: [Person] = FactoryData.people, me: Person = FactoryData.me) -> [(person: Person, current: Bool)] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        func rank(_ person: Person) -> Int {
            person.github == task.owner.github ? 0 : person.github == me.github ? 1 : 2
        }
        return people
            .filter { $0.github != nil && (everyone || $0.github == me.github) }
            .filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) || $0.github!.localizedCaseInsensitiveContains(needle) }
            .sorted { a, b in
                rank(a) != rank(b) ? rank(a) < rank(b) : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            .map { ($0, $0.github == task.owner.github) }
    }
}
