import SwiftUI

/// Creates or edits a goal: its name, the prefix its task ids start with, and where its code is.
struct GoalSheet: View {
    @Environment(FactoryClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let editing: Wire.Goal?

    @State private var name = ""
    @State private var prefix = ""
    @State private var summary = ""
    @State private var source: Source = .folder
    @State private var folder = ""
    @State private var repo = ""
    @State private var base = ""
    @State private var color = 0
    @State private var prefixEdited = false
    @State private var repoFilter = ""
    @State private var team = ""
    /// Fields you've typed in, and whether Create was clicked: problems show for those.
    @State private var touched: Set<Field> = []
    @State private var attempted = false
    /// Sent and waiting on the server's goal.updated, or the refusal it sent instead.
    @State private var saving = false
    @State private var failure: String?

    enum Source: String, CaseIterable { case folder = "A folder on my machines", repo = "A GitHub repo" }
    enum Field { case name, prefix, code }

    private static let colors: [(name: String, hex: String)] = [
        ("Green", "#2EA043"), ("Blue", "#3B82F6"), ("Violet", "#8B5CF6"), ("Amber", "#F59E0B"), ("Pink", "#EC4899"), ("Teal", "#14B8A6"),
    ]

    init(editing: Wire.Goal? = nil, prefill: Wire.NewGoalIdea? = nil) {
        self.editing = editing
        if editing == nil, let idea = prefill {
            // A goal Draft with AI suggested.
            _name = State(initialValue: idea.name)
            _prefix = State(initialValue: Self.prefix(for: idea.name))
            _summary = State(initialValue: idea.summary)
            _source = State(initialValue: idea.repos.isEmpty ? .folder : .repo)
            _repo = State(initialValue: idea.repos.joined(separator: ", "))
        }
        guard let goal = editing else { return }
        _name = State(initialValue: goal.name)
        _prefix = State(initialValue: goal.prefix)
        _prefixEdited = State(initialValue: true)
        _summary = State(initialValue: goal.summary)
        _source = State(initialValue: goal.repo == nil ? .folder : .repo)
        _folder = State(initialValue: goal.folder ?? "")
        _repo = State(initialValue: (goal.repos.isEmpty ? [goal.repo].compactMap { $0 } : goal.repos).joined(separator: ", "))
        _base = State(initialValue: goal.base ?? "")
        _team = State(initialValue: goal.team ?? "")
        _color = State(initialValue: Self.colors.firstIndex { $0.hex.caseInsensitiveCompare(goal.color) == .orderedSame } ?? 0)
    }

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
        if source == .folder {
            if folder.trimmed.isEmpty { problems[.code] = "Say which folder its code is in." }
        } else if repos.isEmpty {
            problems[.code] = "Pick at least one repo."
        } else if let bad = repos.first(where: { $0.range(of: "^[\\w.-]+/[\\w.-]+$", options: .regularExpression) == nil }) {
            problems[.code] = "\(bad) isn't owner/name, like acme/api."
        }
        return problems
    }

    private func problem(_ field: Field) -> String? {
        attempted || touched.contains(field) ? problems[field] : nil
    }

    /// The goal's repos in order, the default first: "acme/api, acme/web".
    private var repos: [String] { repo.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init) }

    /// The org's repos (Settings → Repositories), ticked for this goal; the first ticked is the default.
    private var repoPicker: some View {
        // Picked ones first, then whatever matches the filter: an org can have hundreds.
        let query = repoFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let picked = client.repos.filter { r in repos.contains { $0.caseInsensitiveCompare(r.name) == .orderedSame } }
        let rest = client.repos.filter { r in !picked.contains { $0.name == r.name } && (query.isEmpty || r.name.lowercased().contains(query)) }
        let shown = picked + rest
        return VStack(spacing: 6) {
        TextField("Filter \(client.repos.count) repositories", text: $repoFilter)
            .textFieldStyle(.roundedBorder)
        ScrollView {
            VStack(spacing: 0) {
                ForEach(shown, id: \.name) { org in
                    let picked = repos.contains { $0.caseInsensitiveCompare(org.name) == .orderedSame }
                    HStack(spacing: 8) {
                        Image(systemName: picked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(picked ? Theme.accent : Theme.textFaint)
                        Text(org.name)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        if picked && repos.first?.caseInsensitiveCompare(org.name) == .orderedSame {
                            Text("Default").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textMuted)
                        } else if picked {
                            Text("Make default")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                                .onTapGesture { repo = ([org.name] + repos.filter { $0.caseInsensitiveCompare(org.name) != .orderedSame }).joined(separator: ", ") }
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        repo = (picked ? repos.filter { $0.caseInsensitiveCompare(org.name) != .orderedSame } : repos + [org.name]).joined(separator: ", ")
                    }
                }
            }
        }
        .frame(height: min(CGFloat(max(shown.count, 1)) * 28, 168))
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(editing == nil ? "New goal" : "Edit goal")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("A goal groups tasks with a shared outcome, and says where their code lives.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            }

            HStack(alignment: .top, spacing: 12) {
                field("Name", problem: problem(.name)) {
                    TextField("Auth overhaul", text: $name)
                        .onChange(of: name) { _, value in
                            touched.insert(.name)
                            if !prefixEdited { prefix = Self.prefix(for: value) }
                        }
                }
                field("Task ids", width: 130, problem: problem(.prefix)) {
                    TextField("ATL", text: Binding(get: { prefix }, set: { prefix = $0.uppercased(); prefixEdited = true; touched.insert(.prefix) }))
                }
            }

            field("What it's for") {
                TextField("Move every surface to passkeys ahead of the security review.", text: $summary, axis: .vertical)
                    .lineLimit(2...3)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Team").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
                HStack(spacing: 10) {
                    if client.teams.isEmpty {
                        input { TextField("GitHub team, e.g. platform", text: $team) }.frame(width: 220)
                    } else {
                        Menu {
                            Button("No team") { team = "" }
                            Divider()
                            ForEach(client.teams, id: \.self) { slug in Button("@\(slug)") { team = slug } }
                        } label: {
                            Text(team.isEmpty ? "No team" : "@\(team)")
                        }
                        .fixedSize()
                    }
                    Text("Its members follow it, so it's in their sidebars. Anyone can still find it in All goals.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textFaint)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Code").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
                Picker("", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if source == .folder {
                    HStack(spacing: 12) {
                        input { TextField("~/Projects/atlas", text: $folder) }
                        input { TextField("Base branch (default)", text: $base) }.frame(width: 190)
                    }
                } else if client.repos.isEmpty {
                    HStack(spacing: 12) {
                        input { TextField("acme/api, acme/web", text: $repo) }
                        input { TextField("Base branch (default)", text: $base) }.frame(width: 190)
                    }
                } else {
                    repoPicker
                    input { TextField("Base branch (each repo's default)", text: $base) }.frame(width: 240)
                }
                if let problem = problem(.code) { problemLine(problem) }
                Text(source == .folder
                     ? "The same path on each machine that works on it. Tasks branch from origin/<base> in their own worktrees."
                     : client.repos.isEmpty
                        ? "One or more repos, the first the default. Add the org's in Settings → Repositories to pick from them."
                        : "Each task changes one of these; work across them becomes linked tasks. Machines use their own checkouts, or clone.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
            }
            .onChange(of: folder) { touched.insert(.code) }
            .onChange(of: repo) { touched.insert(.code) }

            HStack(spacing: 8) {
                Text("Color").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
                ForEach(Self.colors.indices, id: \.self) { index in
                    Circle()
                        .fill(Color(hexString: Self.colors[index].hex) ?? .gray)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Theme.text.opacity(color == index ? 0.9 : 0), lineWidth: 2).padding(-3))
                        .contentShape(Circle())
                        .onTapGesture { color = index }
                        .help(Self.colors[index].name)
                }
            }

            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(failure).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.State.cancelled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.State.cancelled.opacity(0.1)))
            }

            HStack(spacing: 8) {
                Spacer()
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                Text(saving ? (editing == nil ? "Creating…" : "Saving…") : editing == nil ? "Create goal" : "Save")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(problems.isEmpty && !saving ? 1 : 0.4)))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: save)
            }
        }
        .padding(24)
        .frame(width: 560)
        // The sheet stays up until the server keeps the goal, or says why it won't.
        .onChange(of: client.goalUpdates) {
            guard saving, client.goals.contains(where: isSaved) else { return }
            stopSaving()
            dismiss()
        }
        .onChange(of: client.notice) { _, notice in
            guard saving, let notice else { return }
            failure = notice
            stopSaving()
            client.notice = nil
        }
        .onDisappear { if saving { stopSaving() } }
    }

    /// The goal this sheet sent: the one being edited, or a new one with its name and prefix.
    private func isSaved(_ goal: Wire.Goal) -> Bool {
        if let editing { return goal.id == editing.id }
        return goal.prefix == prefix && goal.name == name.trimmed
    }

    private func stopSaving() {
        saving = false
        client.savingGoal = false
    }

    private func save() {
        guard !saving else { return }
        guard problems.isEmpty else { attempted = true; return }
        let goal = Wire.Goal(
            id: editing?.id ?? "",
            name: name.trimmed,
            prefix: prefix,
            color: Self.colors[color].hex,
            summary: summary.trimmed,
            lead: editing?.lead ?? client.me?.login ?? "",
            due: editing?.due,
            repo: source == .repo ? repos.first : nil,
            repos: source == .repo ? repos : [],
            folder: source == .folder ? folder.trimmed : nil,
            base: base.trimmed.isEmpty ? nil : base.trimmed,
            archived: editing?.archived,
            team: team.trimmed.isEmpty ? nil : team.trimmed
        )
        failure = nil
        saving = true
        client.savingGoal = true
        client.send(.goalSave(.init(goal: goal)))
    }

    /// "Auth overhaul" → "AO"; one word → its first three letters.
    static func prefix(for name: String) -> String {
        let words = name.uppercased().split { !$0.isLetter && !$0.isNumber }
        let letters = words.count > 1 ? words.prefix(4).compactMap(\.first).map(String.init).joined() : String(words.first?.prefix(3) ?? "")
        return String(letters.drop { !$0.isLetter })
    }

    private func field<Content: View>(_ label: String, width: CGFloat? = nil, problem: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
            input(content)
            if let problem { problemLine(problem) }
        }
        .frame(width: width)
    }

    private func problemLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.State.cancelled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func input<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
