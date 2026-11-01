import SwiftUI

/// Who's asked to sign off on a task, picked like GitHub's review requests: the Assign picker's "Filter
/// people" field, ↑/↓ and Return, but each row toggles a checkmark and the popover stays open. Requested
/// teammates are checked and listed first. From the Detail panel's Reviewers row.
struct ReviewersPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let task: FactoryTask
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var title: String {
        task.state == .reviewing ? "Request review from" : "Request plan approval from"
    }

    private var shown: [(person: Person, requested: Bool)] {
        Self.matches(for: task, query: query)
    }

    var body: some View {
        let shown = shown
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
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
                    .onSubmit { if shown.indices.contains(highlighted) { toggle(shown[highlighted]) } }
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
                                .onTapGesture { toggle(choice) }
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
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private func row(_ choice: (person: Person, requested: Bool), highlighted: Bool) -> some View {
        let person = choice.person
        let approved = (task.state == .reviewing ? task.reviews : task.approvals).contains { $0.github == person.github }
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.text)
                .opacity(choice.requested ? 1 : 0)
                .frame(width: 12)
            AgentAvatar(agent: person, size: 20)
            Text(person.github == FactoryData.me.github ? "\(person.name) (you)" : person.name)
                .font(.system(size: 13, weight: choice.requested ? .semibold : .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let login = person.github {
                Text("@\(login)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if approved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.State.merged)
                    .help("Already approved")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Theme.fill : .clear))
        .contentShape(Rectangle())
    }

    private func toggle(_ choice: (person: Person, requested: Bool)) {
        guard let login = choice.person.github else { return }
        if choice.requested { appState.requestReviewers(task.id, add: [], remove: [login]) }
        else { appState.requestReviewers(task.id, add: [login]) }
    }

    /// Teammates with a GitHub login other than its owner whose name or login contains `query`: those
    /// already requested checked and first, then the rest by name.
    static func matches(for task: FactoryTask, query: String, people: [Person] = FactoryData.people) -> [(person: Person, requested: Bool)] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let requested = Set(task.requested.compactMap(\.github))
        return people
            .filter { $0.github != nil && $0.github != task.owner.github }
            .filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) || $0.github!.localizedCaseInsensitiveContains(needle) }
            .sorted { a, b in
                let ra = requested.contains(a.github!), rb = requested.contains(b.github!)
                return ra != rb ? ra : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            .map { ($0, requested.contains($0.github!)) }
    }
}

/// The Detail panel's Reviewers row: requested teammates' avatars (amber dot: pending, green check:
/// approved), "None yet", and a button that opens `ReviewersPopover`.
struct ReviewersRow: View {
    let task: FactoryTask
    @State private var picking = false
    @State private var frame: CGRect = .zero

    /// A demo script's `reviewersask:<id>`: opens the picker.
    static let demoOpen = Notification.Name("ReviewersRow.demoOpen")

    private var signedOff: [Person] { task.state == .reviewing ? task.reviews : task.approvals }

    /// The requested, then anyone who approved without being asked, once each.
    private var people: [(person: Person, approved: Bool)] {
        var seen = Set<String>()
        return (task.requested + signedOff).compactMap { p in
            guard seen.insert(p.github ?? p.id).inserted else { return nil }
            return (p, signedOff.contains { $0.github == p.github })
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if people.isEmpty {
                Text("None yet").foregroundStyle(Theme.textMuted)
            } else {
                ForEach(people, id: \.person.id) { entry in
                    ZStack(alignment: .bottomTrailing) {
                        AgentAvatar(agent: entry.person, size: 18)
                        if entry.approved {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white, Theme.State.merged)
                                .offset(x: 3, y: 3)
                        } else {
                            Circle().fill(Theme.State.awaitingApproval)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(Theme.editorBG, lineWidth: 1))
                                .offset(x: 2, y: 2)
                        }
                    }
                    .help("\(entry.person.name): \(entry.approved ? "approved" : "review requested")")
                }
            }
            if !task.state.isFinished {
                Button { picking = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textMuted)
                .help("Request a review or plan approval")
                .background(GeometryReader { g in
                    Color.clear.onAppear { frame = g.frame(in: .global) }.onChange(of: g.frame(in: .global)) { _, f in frame = f }
                })
                .popover(isPresented: $picking, arrowEdge: .bottom) { ReviewersPopover(task: task) }
                .onChange(of: picking) { _, now in if Headless.isOn { Headless.popoverAnchor = now ? frame : nil } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoOpen)) { note in
            if note.object as? String == task.id { picking = true }
        }
    }
}
