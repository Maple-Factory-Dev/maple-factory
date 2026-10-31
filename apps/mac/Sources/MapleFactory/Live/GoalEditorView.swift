import SwiftUI

/// Creates or edits a goal, full page in the main content area: its name, the prefix its task ids start
/// with, where its code is, who it's for, how it looks, and what its agents are told on top of the org's.
/// Numbered sections walk a new goal through it; Cancel or a save goes back to where you were.
struct GoalEditorView: View {
    @Environment(FactoryClient.self) private var client
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "repos"
    let editing: Wire.Goal?

    @State private var name = ""
    @State private var prefix = ""
    @State private var summary = ""
    @State private var source: Source = .folder
    @State private var folder = ""
    @State private var repo = ""
    @State private var base = ""
    @State private var color: GoalColors.Choice = .swatch(0)
    /// The last color picked in the system picker, kept while you try swatches.
    @State private var customColor = Color(hexString: "#6366F1") ?? .indigo
    @State private var prefixEdited = false
    @State private var repoFilter = ""
    @State private var team = ""
    /// Who it's for; empty until `me` is known, then the creator.
    @State private var lead = ""
    /// The day it's due, or none.
    @State private var due: Date?
    /// Fields you've typed in, and whether Create was clicked: problems show for those.
    @State private var touched: Set<Field> = []
    @State private var attempted = false
    /// Sent and waiting on the server's goal.updated, or the refusal it sent instead.
    @State private var saving = false
    @State private var failure: String?
    @State private var prompts = LiveAdapter.noPrompts
    /// Org instructions shown in full, by role.
    @State private var expandedOrg: Set<PromptLayers.Role> = []
    /// The section a demo script scrolls to (`goalfill:section:prompts`).
    @State private var jumpTo: Section?

    enum Source: String, CaseIterable { case folder = "A folder on my machines", repo = "A GitHub repo" }
    enum Field { case name, prefix, code }

    enum Section: Int, CaseIterable, Identifiable {
        case basics = 1, code, team, look, prompts
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .basics: "Basics"
            case .code: "Code"
            case .team: "Lead, team & due date"
            case .look: "Look"
            case .prompts: "Agent instructions"
            }
        }
        var explainer: String {
            switch self {
            case .basics: "What the goal is called, and the prefix its task ids start with."
            case .code: "Where its tasks change code. Each task gets its own branch and worktree."
            case .team: "Who it's for, who follows it, and when it should be done."
            case .look: "Its color in the sidebar, on the board and on the timeline."
            case .prompts: "Optional. Extra instructions for this goal's planner, builder and reviewer."
            }
        }
    }

    /// `-actions 'goalfill:prefix:PLATFORM; goalfill:create'` types into a field or clicks Create, for demo videos.
    static let demoFill = Notification.Name("GoalEditorView.demoFill")

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
        _lead = State(initialValue: goal.lead)
        _due = State(initialValue: goal.due.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        _prompts = State(initialValue: goal.prompts ?? LiveAdapter.noPrompts)
        let choice = GoalColors.choice(for: goal.color)
        _color = State(initialValue: choice)
        if case .custom(let hex) = choice, let picked = Color(hexString: hex) { _customColor = State(initialValue: picked) }
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

    /// A section's tick in the rail: required ones once they're valid, optional ones once something's set.
    private func finished(_ section: Section) -> Bool {
        switch section {
        case .basics: problems[.name] == nil && problems[.prefix] == nil
        case .code: problems[.code] == nil
        case .team: true
        case .look: true
        case .prompts: LiveAdapter.prompts(prompts) != nil
        }
    }

    /// Its lead or an admin; whoever makes a goal can set it up, even for someone else. The lead it had when
    /// the editor opened (a new goal's creator), not the one picked here, as goal.save checks, so changing
    /// both in one save isn't half refused.
    private var canEditPrompts: Bool {
        client.me?.role == "admin" || (editing?.lead ?? client.me?.login) == client.me?.login
    }

    private var isAdmin: Bool { client.me?.role == "admin" }

    /// The goal's repos in order, the default first: "acme/api, acme/web".
    private var repos: [String] { repo.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init) }

    private var swatch: Color { Color(hexString: color.hex) ?? .gray }

    // MARK: Page

    var body: some View {
        VStack(spacing: 0) {
            header
            // A refusal (a prefix in use) shows where it's seen, whatever section you're in; the form stays.
            if let failure {
                failureLine(failure)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
            Hairline()
            ScrollViewReader { scroller in
                HStack(alignment: .top, spacing: 0) {
                    rail { section in withAnimation(.snappy) { scroller.scrollTo(section, anchor: .top) } }
                        .frame(width: 210)
                        .padding(.top, 24)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            intro
                            ForEach(Section.allCases) { section in
                                sectionView(section).id(section)
                            }
                            Color.clear.frame(height: 40)
                        }
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onChange(of: jumpTo) { _, section in
                    guard let section else { return }
                    scroller.scrollTo(section, anchor: .top)
                    jumpTo = nil
                }
            }
        }
        .background(Theme.editorBG)
        // It stays up until the server keeps the goal, or says why it won't.
        .onChange(of: client.goalUpdates) {
            guard saving, let saved = client.goals.first(where: isSaved) else { return }
            stopSaving()
            close(savedAs: saved)
        }
        .onChange(of: client.notice) { _, notice in
            guard saving, let notice else { return }
            failure = notice
            stopSaving()
            client.notice = nil
        }
        // A save the server never answers gives up after 15s; the form stays filled in for another try.
        .task(id: saving) {
            guard saving else { return }
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, saving else { return }
            stopSaving()
            failure = "The server didn't answer. Check your connection and try again."
        }
        .onDisappear { if saving { stopSaving() } }
        .onExitCommand { cancel() }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoFill)) { note in
            let value = note.userInfo?["value"] as? String ?? ""
            switch note.userInfo?["field"] as? String {
            case "name": name = value
            case "prefix": prefix = value.uppercased(); prefixEdited = true; touched.insert(.prefix)
            case "summary": summary = value
            case "folder": source = .folder; folder = value
            case "repo": source = .repo; repo = value
            case "repofilter": repoFilter = value
            // `goalfill:due:2026-11-19`, or `goalfill:due:` for none.
            case "due": due = Self.dayFormat.date(from: value)
            // `goalfill:color:Indigo`, or any hex for a custom one: `goalfill:color:#123456`.
            case "color":
                if let index = GoalColors.palette.firstIndex(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) {
                    color = .swatch(index)
                } else {
                    color = GoalColors.choice(for: value)
                }
            case "builder": prompts.builder = value
            // `goalfill:lead:octocat`, as picking them in the Lead menu would.
            case "lead": lead = value
            case "section": jumpTo = Section.allCases.first { "\($0)" == value }
            case "create": save()
            default: break
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(swatch).frame(width: 10, height: 10)
            Text(editing == nil ? "New goal" : "Edit \(editing!.name)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Text(saving ? (editing == nil ? "Creating…" : "Saving…") : editing == nil ? "Create goal" : "Save")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(problems.isEmpty && !saving ? 1 : 0.4)))
                .contentShape(Rectangle())
                .onTapGesture(perform: save)
                .background {
                    Button("", action: save).keyboardShortcut("s").opacity(0).accessibilityHidden(true)
                }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private func rail(jump: @escaping (Section) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { section in
                let done = finished(section)
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(done ? Theme.approve : Theme.fill)
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(section.rawValue)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textMuted)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(section.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
                .onTapGesture { jump(section) }
            }
            Spacer()
        }
        .padding(.leading, 14)
    }

    /// What a goal is, and how it'll look in the sidebar as you fill it in.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editing == nil {
                Text("A goal groups tasks with a shared outcome. It says where their code lives, who follows them, and anything extra its agents should know.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text("In the sidebar").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                previewChip
            }
        }
    }

    /// The goal's sidebar row as it will be, with its first task's id.
    private var previewChip: some View {
        HStack(spacing: 8) {
            Circle().fill(swatch).frame(width: 9, height: 9)
            Text(name.trimmed.isEmpty ? "Untitled goal" : name.trimmed)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(name.trimmed.isEmpty ? Theme.textFaint : Theme.text)
                .lineLimit(1)
            Text(prefix.isEmpty ? "—" : "\(prefix)-1")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.sidebarBG).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke)))
    }

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(section.rawValue)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textFaint)
                    Text(section.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                }
                Text(section.explainer).font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
            }
            switch section {
            case .basics: basics
            case .code: code
            case .team: teamAndDue
            case .look: look
            case .prompts: agentInstructions
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke)))
    }

    // MARK: Sections

    private var basics: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    .lineLimit(2...4)
            }
        }
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
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
    }

    /// The org's repos (Settings → Repositories), ticked for this goal; the first ticked is the default.
    private var repoPicker: some View {
        // Picked ones first whatever the search, then whatever matches it: an org can have hundreds.
        let isPicked = { (r: Wire.OrgRepo) in repos.contains { $0.caseInsensitiveCompare(r.name) == .orderedSame } }
        let entries = RepoList.entries(client.repos, query: repoFilter, pinned: isPicked)
        let height = entries.reduce(CGFloat(0)) { sum, entry in
            if case .repo = entry { sum + 44 } else { sum + 26 }
        }
        return VStack(spacing: 6) {
        RepoList.SearchField(query: $repoFilter, count: client.repos.count)
        ScrollView {
            VStack(spacing: 0) {
                ForEach(entries, id: \.self) { entry in
                    switch entry {
                    case .owner(let owner):
                        RepoList.OwnerHeader(owner: owner).padding(.horizontal, 10).frame(height: 26)
                    case .noMatches(let query):
                        RepoList.NoMatches(query: query).padding(.horizontal, 10).frame(height: 26)
                    case .repo(let org):
                        let picked = isPicked(org)
                        RepoList.Row(repo: org) {
                            Image(systemName: picked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(picked ? Theme.accent : Theme.textFaint)
                        } trailing: {
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
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            repo = (picked ? repos.filter { $0.caseInsensitiveCompare(org.name) != .orderedSame } : repos + [org.name]).joined(separator: ", ")
                        }
                    }
                }
            }
        }
        // About six rows, then it scrolls.
        .frame(height: min(max(height, 26), 6 * 44 + 26))
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
        }
    }

    /// Who it's picked as: the one chosen here, else the goal's lead, else whoever's making it.
    private var shownLead: String { lead.isEmpty ? (editing?.lead ?? client.me?.login ?? "") : lead }

    /// The factory's members, you first, then by name.
    private var leadChoices: [Wire.Member] {
        let me = client.me?.login
        return client.members.sorted { a, b in
            if (a.login == me) != (b.login == me) { return a.login == me }
            return (a.name ?? a.login).localizedCaseInsensitiveCompare(b.name ?? b.login) == .orderedAscending
        }
    }

    private func leadName(_ login: String) -> String {
        if login == client.me?.login { return "You" }
        return client.members.first { $0.login == login }?.name ?? login
    }

    private var leadRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Lead")
            HStack(spacing: 10) {
                // A menu's label draws only text, so the lead's avatar sits beside it.
                AgentAvatar(agent: LiveAdapter.person(shownLead, members: client.members), size: 20)
                Menu {
                    ForEach(leadChoices, id: \.login) { member in
                        Button {
                            lead = member.login
                        } label: {
                            if member.login == shownLead { Image(systemName: "checkmark") }
                            Text(member.login == client.me?.login ? "You (@\(member.login))" : "\(member.name ?? member.login) (@\(member.login))")
                        }
                    }
                } label: {
                    Text(leadName(shownLead))
                }
                .fixedSize()
                .disabled(!canEditPrompts)
                Text("Who it's for: they can change its agent instructions, accept risk and archive it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !canEditPrompts {
                Label("Only \(editing?.lead ?? "its lead") or an admin can hand it to someone else.", systemImage: "lock")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }

    private var teamAndDue: some View {
        VStack(alignment: .leading, spacing: 14) {
            leadRow
            VStack(alignment: .leading, spacing: 6) {
                label("Team")
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
            VStack(alignment: .leading, spacing: 6) {
                label("Due date")
                HStack(spacing: 10) {
                    Menu {
                        if due == nil {
                            Button("Set a due date") { due = Calendar.current.date(byAdding: .day, value: 14, to: Date()) }
                        } else {
                            Button("Remove due date") { due = nil }
                        }
                    } label: {
                        Text(due.map { $0.formatted(.dateTime.month(.abbreviated).day().year()) } ?? "No due date")
                    }
                    .fixedSize()
                    if let day = due {
                        DatePicker("", selection: Binding(get: { day }, set: { due = $0 }), displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .fixedSize()
                    }
                    Text(due == nil ? "Shows on the goal and its timeline." : "Move it later to extend it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
    }

    /// Sixteen named colors, then Custom: any color, from the system picker.
    private var look: some View {
        let columns = Array(repeating: GridItem(.fixed(30), spacing: 8), count: 9)
        let customHex: String? = if case .custom(let hex) = color { hex } else { nil }
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(GoalColors.palette.indices, id: \.self) { index in
                    swatchView(Color(hexString: GoalColors.palette[index].hex) ?? .gray, selected: color == .swatch(index))
                        .onTapGesture { color = .swatch(index) }
                        .help(GoalColors.palette[index].name)
                }
                ZStack {
                    swatchView(customHex == nil ? .clear : customColor, selected: customHex != nil)
                        .background(Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)).frame(width: 22, height: 22).opacity(customHex == nil ? 1 : 0))
                    ColorPicker("", selection: Binding(get: { customColor }, set: { customColor = $0; color = .custom(GoalColors.hex($0)) }), supportsOpacity: false)
                        .labelsHidden()
                        .opacity(0.02)
                        .frame(width: 26, height: 26)
                }
                .help("Custom")
            }
            HStack(spacing: 6) {
                Text(colorName).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                Text(color.hex.uppercased()).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textFaint)
            }
        }
    }

    private var colorName: String {
        switch color {
        case .swatch(let index): GoalColors.palette[index].name
        case .custom: "Custom"
        }
    }

    private func swatchView(_ fill: Color, selected: Bool) -> some View {
        Circle()
            .fill(fill)
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(Theme.text.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-4))
            .frame(width: 30, height: 30)
            .contentShape(Circle())
    }

    /// One card per role: Maple's own prompt, then the org's, then this goal's, as the agent reads them.
    private var agentInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(PromptLayers.all(org: client.prompts, goal: prompts), id: \.role) { layers in
                roleCard(layers)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 10.5))
                Text("Goal instructions are appended after the org's; nothing here replaces Maple's or the org's prompts.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textMuted)
            if !canEditPrompts {
                Label("Only \(editing?.lead ?? "its lead") or an admin can change these.", systemImage: "lock")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func roleCard(_ layers: PromptLayers) -> some View {
        let role = PromptFields.roles[PromptLayers.Role.allCases.firstIndex(of: layers.role)!]
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(role.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                statusBadge(layers.status)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Hairline()
            layerRow(number: 1, title: "Maple built-in", detail: "fixed") {
                Text("The brief, plan and how to report back. The same for every goal.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
            }
            .background(Theme.fillSubtle)
            Hairline()
            layerRow(number: 2, title: "Org", detail: "read-only here") {
                VStack(alignment: .leading, spacing: 4) {
                    if let org = layers.org {
                        Text(org)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(expandedOrg.contains(layers.role) ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        Text("None for \(role.label.lowercased()).").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    }
                    HStack(spacing: 12) {
                        if let org = layers.org, org.count > 120 || org.contains("\n") {
                            Text(expandedOrg.contains(layers.role) ? "Show less" : "Show all")
                                .foregroundStyle(Theme.accent)
                                .onTapGesture {
                                    if expandedOrg.contains(layers.role) { expandedOrg.remove(layers.role) } else { expandedOrg.insert(layers.role) }
                                }
                        }
                        if isAdmin {
                            Text("Edit in Settings → Prompts")
                                .foregroundStyle(Theme.accent)
                                .onTapGesture { settingsTab = "prompts"; openSettings() }
                        }
                    }
                    .font(.system(size: 11.5))
                }
            }
            Hairline()
            layerRow(number: 3, title: "This goal", detail: canEditPrompts ? "appended" : "appended · read-only") {
                PromptEditor(hint: role.hint, text: $prompts[dynamicMember: role.key], editable: canEditPrompts, height: 64)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.editorBG))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
    }

    private func layerRow<Content: View>(number: Int, title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(number)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textFaint)
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textMuted)
                Text("· \(detail)").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusBadge(_ status: PromptLayers.Status) -> some View {
        let (text, tint): (String, Color) = switch status {
        case .addsToOrg: ("Adds to org", Theme.State.planning)
        case .onlyAddition: ("Only addition", Theme.State.building)
        case .notSet: ("Not set", Theme.textMuted)
        }
        return Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func failureLine(_ failure: String) -> some View {
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

    // MARK: Saving

    /// The goal this page sent: the one being edited, or a new one with its name and prefix.
    private func isSaved(_ goal: Wire.Goal) -> Bool {
        if let editing { return goal.id == editing.id }
        return goal.prefix == prefix && goal.name == name.trimmed
    }

    private func stopSaving() {
        saving = false
        client.savingGoal = false
    }

    /// Cancel works mid-save too: if the server answers later, the goal just shows up in the sidebar.
    private func cancel() {
        if saving { stopSaving() }
        close(savedAs: nil)
    }

    /// Back to the page you were on; a goal just made opens instead, unless a draft is waiting on it.
    private func close(savedAs goal: Wire.Goal?) {
        withAnimation(.snappy(duration: 0.2)) {
            state.goalSheet = nil
            if editing == nil, let goal, !state.isComposing { state.destination = .goal(goal.name) }
        }
    }

    private func save() {
        guard !saving else { return }
        guard problems.isEmpty else { attempted = true; return }
        let goal = Wire.Goal(
            id: editing?.id ?? "",
            name: name.trimmed,
            prefix: prefix,
            color: color.hex,
            summary: summary.trimmed,
            lead: lead.isEmpty ? (editing?.lead ?? client.me?.login ?? "") : lead,
            due: due.map(Self.noonMillis),
            repo: source == .repo ? repos.first : nil,
            repos: source == .repo ? repos : [],
            folder: source == .folder ? folder.trimmed : nil,
            base: base.trimmed.isEmpty ? nil : base.trimmed,
            archived: editing?.archived,
            team: team.trimmed.isEmpty ? nil : team.trimmed,
            // All empty clears them (the server stores none); unchanged when you can't edit them.
            prompts: canEditPrompts ? LiveAdapter.prompts(prompts) ?? LiveAdapter.noPrompts : editing?.prompts
        )
        failure = nil
        saving = true
        client.savingGoal = true
        client.send(.goalSave(.init(goal: goal)))
    }

    private static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    /// The picked day at local noon, so it's still that day wherever it's read.
    private static func noonMillis(_ day: Date) -> UInt64 {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        return UInt64(noon.timeIntervalSince1970 * 1000)
    }

    /// "Auth overhaul" → "AO"; one word → its first three letters.
    static func prefix(for name: String) -> String {
        let words = name.uppercased().split { !$0.isLetter && !$0.isNumber }
        let letters = words.count > 1 ? words.prefix(4).compactMap(\.first).map(String.init).joined() : String(words.first?.prefix(3) ?? "")
        return String(letters.drop { !$0.isLetter })
    }

    // MARK: Fields

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted)
    }

    private func field<Content: View>(_ text: String, width: CGFloat? = nil, problem: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(text)
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
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke)))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
