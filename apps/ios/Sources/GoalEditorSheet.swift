import MapleKit
import SwiftUI

/// Creates or edits a goal from the phone: its name, the prefix its task ids start with, its repos (the
/// first the default), its lead and team, and what its agents are told on top of the org's. Sends the
/// same `goal.save` as the Mac's GoalEditorView and stays open until the server keeps the goal, or shows
/// why it won't. Its color, due date and a folder's path are kept as they are; those stay on the Mac.
struct GoalEditorSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let editing: Wire.Goal?
    /// The goal the server kept, once it has.
    var onSaved: (Wire.Goal) -> Void = { _ in }

    @State private var name = ""
    @State private var prefix = ""
    @State private var prefixEdited = false
    /// In order, the default first.
    @State private var repos: [String] = []
    @State private var lead = ""
    @State private var team = ""
    @State private var prompts = Wire.PromptAdditions(planner: "", builder: "", reviewer: "")
    /// Fields you've typed in, and whether Create was tapped: problems show for those.
    @State private var touched: Set<Field> = []
    @State private var attempted = false

    enum Field { case name, prefix, code }

    /// The Mac's first goal color, for a new goal.
    static let firstColor = "#2EA043"
    private static let noPrompts = Wire.PromptAdditions(planner: "", builder: "", reviewer: "")

    init(editing: Wire.Goal?, onSaved: @escaping (Wire.Goal) -> Void = { _ in }) {
        self.editing = editing
        self.onSaved = onSaved
        guard let goal = editing else { return }
        _name = State(initialValue: goal.name)
        _prefix = State(initialValue: goal.prefix)
        _prefixEdited = State(initialValue: true)
        _repos = State(initialValue: goal.repos.isEmpty ? [goal.repo].compactMap { $0 } : goal.repos)
        _lead = State(initialValue: goal.lead)
        _team = State(initialValue: goal.team ?? "")
        _prompts = State(initialValue: goal.prompts ?? Self.noPrompts)
    }

    /// Kept in a folder rather than repos: the folder stays, read-only here.
    private var folder: String? { editing?.repo == nil ? editing?.folder : nil }
    private var saving: Bool { if case .saving = store.goalSave { true } else { false } }
    private var failure: String? { if case .failed(let message) = store.goalSave { message } else { nil } }

    /// What's wrong with each field, the same rules goal.save checks.
    private var problems: [Field: String] {
        var problems: [Field: String] = [:]
        if name.trimmed.isEmpty { problems[.name] = "Give the goal a name." }
        if prefix.isEmpty {
            problems[.prefix] = "Needs a prefix, like ATL."
        } else if prefix.count > 10 {
            problems[.prefix] = "At most 10 letters or digits."
        } else if prefix.range(of: "^[A-Z][A-Z0-9]{0,9}$", options: .regularExpression) == nil {
            problems[.prefix] = "Letters and digits, starting with a letter."
        }
        if folder == nil, repos.isEmpty { problems[.code] = "Pick at least one repo." }
        return problems
    }

    private func problem(_ field: Field) -> String? { attempted || touched.contains(field) ? problems[field] : nil }

    /// Its lead or an admin, as the server checks: the lead before this save (a new goal's creator).
    private var canEditPrompts: Bool { store.isAdmin || (editing?.lead ?? store.me) == store.me }

    /// The org's repos, then any of the goal's that aren't among them.
    private var repoChoices: [String] {
        let org = store.feed.repos.map(\.name)
        return org + repos.filter { r in !org.contains { $0.caseInsensitiveCompare(r) == .orderedSame } }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("goalEditor.failure")
                    }
                }
                basics
                code
                leadAndTeam
                instructions
            }
            .navigationTitle(editing == nil ? "New goal" : "Edit goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.endGoalSave(); dismiss() }.accessibilityIdentifier("goalEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().accessibilityIdentifier("goalEditor.saving")
                    } else {
                        Button(editing == nil ? "Create" : "Save") { save() }
                            .disabled(!problems.isEmpty)
                            .accessibilityIdentifier("goalEditor.save")
                    }
                }
            }
            .interactiveDismissDisabled(saving)
        }
        .onAppear {
            if lead.isEmpty { lead = store.me }
            if store.goalSave != nil, !saving { store.endGoalSave() }
        }
        // It stays up until the server keeps the goal, or says why it won't.
        .onChange(of: store.goalSave) { _, save in
            guard case .saved(let id) = save else { return }
            store.endGoalSave()
            if let goal = store.feed.goal(id) { onSaved(goal) }
            dismiss()
        }
        // A save the server never answers gives up after 15s; the form stays filled in for another try.
        .task(id: saving) {
            guard saving else { return }
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, saving else { return }
            store.endGoalSave(failure: "The server didn't answer. Check your connection and try again.")
        }
    }

    // MARK: Sections

    private var basics: some View {
        Section {
            TextField("Name", text: Binding(get: { name }, set: { value in
                name = value
                touched.insert(.name)
                if !prefixEdited { prefix = Self.prefix(for: value) }
            }))
            .accessibilityIdentifier("goalEditor.name")
            HStack {
                Text("Task ids")
                Spacer()
                TextField("ATL", text: Binding(get: { prefix }, set: { prefix = $0.uppercased(); prefixEdited = true; touched.insert(.prefix) }))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospaced())
                    .accessibilityIdentifier("goalEditor.prefix")
            }
        } header: {
            Text("Goal")
        } footer: {
            if let problem = problem(.name) ?? problem(.prefix) {
                Text(problem).foregroundStyle(.red).accessibilityIdentifier("goalEditor.problem")
            } else {
                Text("Its tasks are numbered \(prefix.isEmpty ? "—" : "\(prefix)-1"), \(prefix.isEmpty ? "—" : "\(prefix)-2")…")
                    .accessibilityIdentifier("goalEditor.preview")
            }
        }
    }

    @ViewBuilder
    private var code: some View {
        if let folder {
            Section {
                LabeledContent("Folder", value: folder)
            } header: {
                Text("Code")
            } footer: {
                Text("This goal's code is in a folder; change that on the Mac.")
            }
        } else {
            Section {
                if repoChoices.isEmpty {
                    Text("No repos yet. An admin adds the org's on the Mac, in Settings → Repositories.").foregroundStyle(.secondary)
                }
                ForEach(repoChoices, id: \.self) { repo in
                    repoRow(repo)
                }
            } header: {
                Text("Repos")
            } footer: {
                if let problem = problem(.code) {
                    Text(problem).foregroundStyle(.red)
                } else {
                    Text("Tick each repo its tasks work in. The first is the default; swipe another to make it the default.")
                }
            }
        }
    }

    private func repoRow(_ repo: String) -> some View {
        let index = repos.firstIndex { $0.caseInsensitiveCompare(repo) == .orderedSame }
        return Button {
            touched.insert(.code)
            if let index { repos.remove(at: index) } else { repos.append(repo) }
        } label: {
            HStack {
                Image(systemName: index == nil ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(index == nil ? Color.secondary : Color.accentColor)
                Text(repo).foregroundStyle(.primary)
                Spacer()
                if index == 0 { Text("Default").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityIdentifier("goalEditor.repo.\(repo)")
        .accessibilityValue(index == nil ? "" : index == 0 ? "default" : "ticked")
        .swipeActions {
            if index != 0 {
                Button("Make default") {
                    touched.insert(.code)
                    repos.removeAll { $0.caseInsensitiveCompare(repo) == .orderedSame }
                    repos.insert(repo, at: 0)
                }
                .tint(.accentColor)
            }
        }
    }

    private var leadAndTeam: some View {
        Section {
            Picker("Lead", selection: $lead) {
                ForEach(leadChoices, id: \.self) { login in
                    Text(store.feed.member(login)?.name.flatMap { $0.isEmpty ? nil : $0 } ?? login).tag(login)
                }
            }
            .accessibilityIdentifier("goalEditor.lead")
            HStack {
                Text("GitHub team")
                Spacer()
                TextField("None", text: $team)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("goalEditor.team")
            }
        } header: {
            Text("Lead & team")
        } footer: {
            Text("The lead approves its plans and changes. Its team follows it.")
        }
    }

    /// Members, plus the lead it has when that's someone no longer listed.
    private var leadChoices: [String] {
        let logins = store.feed.members.map(\.login)
        return lead.isEmpty || logins.contains(lead) ? logins : [lead] + logins
    }

    private var instructions: some View {
        Section {
            promptField("Planner", text: $prompts.planner, id: "planner")
            promptField("Builder", text: $prompts.builder, id: "builder")
            promptField("Reviewer", text: $prompts.reviewer, id: "reviewer")
        } header: {
            Text("Agent instructions")
        } footer: {
            Text(canEditPrompts
                 ? "Added after the org's instructions for this goal's agents."
                 : "Only the goal's lead or an admin can change its agent instructions.")
        }
        .disabled(!canEditPrompts)
    }

    private func promptField(_ title: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField("Nothing extra", text: text, axis: .vertical)
                .lineLimit(2...8)
                .accessibilityIdentifier("goalEditor.prompt.\(id)")
        }
    }

    // MARK: Saving

    private func save() {
        guard !saving else { return }
        guard problems.isEmpty else { attempted = true; return }
        let trimmed = Wire.PromptAdditions(planner: prompts.planner.trimmed, builder: prompts.builder.trimmed, reviewer: prompts.reviewer.trimmed)
        let goal = Wire.Goal(
            id: editing?.id ?? "",
            name: name.trimmed,
            prefix: prefix,
            color: editing?.color ?? Self.firstColor,
            summary: editing?.summary ?? "",
            lead: lead.isEmpty ? (editing?.lead ?? store.me) : lead,
            due: editing?.due,
            repo: folder == nil ? repos.first : nil,
            repos: folder == nil ? repos : [],
            folder: folder,
            base: editing?.base,
            archived: editing?.archived,
            team: team.trimmed.isEmpty ? nil : team.trimmed,
            // All empty clears them (the server stores none); unchanged when you can't edit them.
            prompts: canEditPrompts ? trimmed : editing?.prompts
        )
        store.saveGoal(goal)
    }

    /// "Auth overhaul" → "AO"; one word → its first three letters. As GoalEditorView on the Mac.
    static func prefix(for name: String) -> String {
        let words = name.uppercased().split { !$0.isLetter && !$0.isNumber }
        let letters = words.count > 1 ? words.prefix(4).compactMap(\.first).map(String.init).joined() : String(words.first?.prefix(3) ?? "")
        return String(letters.drop { !$0.isLetter })
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
