import SwiftUI
import AppKit
import MapleKit

/// The docs the app lists (docs/planning-docs.md): the feed's index when signed in, the bundled demo doc otherwise.
enum DocsIndex {
    @MainActor static func docs(_ client: FactoryClient) -> [Wire.Doc] {
        client.isSignedIn ? FeedState.activeDocs(client.docs) : [DemoDoc.doc]
    }

    /// A doc's goal by name; the demo's goal id is the mock goal's name.
    @MainActor static func goalName(_ id: String?, client: FactoryClient) -> String? {
        guard let id else { return nil }
        return client.isSignedIn ? client.goals.first { $0.id == id }?.name : id
    }

    /// A goal page's goal id, from its name.
    @MainActor static func goalId(name: String, client: FactoryClient) -> String? {
        client.isSignedIn ? client.goals.first { $0.name == name }?.id : name
    }

    /// Grouped by goal, goals by name, "No goal" last.
    @MainActor static func grouped(_ docs: [Wire.Doc], client: FactoryClient) -> [(goal: String?, title: String, docs: [Wire.Doc])] {
        let byGoal = Dictionary(grouping: docs, by: \.goal)
        let named = byGoal.keys.compactMap { $0 }.map { ($0, goalName($0, client: client) ?? "Unknown goal") }.sorted { $0.1 < $1.1 }
        var out = named.map { (goal: Optional($0.0), title: $0.1, docs: byGoal[$0.0] ?? []) }
        if let loose = byGoal[nil], !loose.isEmpty { out.append((goal: nil, title: "No goal", docs: loose)) }
        return out
    }

    static func link(_ id: String) -> String { "maplefactory://doc/\(id)" }

    static func edited(_ doc: Wire.Doc) -> String {
        let date = Date(timeIntervalSince1970: Double(doc.updatedAt) / 1000)
        return date.formatted(.relative(presentation: .named))
    }
}

/// The signed-out mockup's one doc: opened from the bundled embed in demo mode, with no network.
enum DemoDoc {
    static let id = "demo"
    static let doc = Wire.Doc(id: id, title: "Docs in Maple Factory", goal: "Auth overhaul", createdBy: "afomera",
                              createdAt: 1_762_000_000_000, updatedAt: UInt64(Date().timeIntervalSince1970 * 1000) - 120_000)
    static let markdown = """
    # Docs in Maple Factory

    Plans, specs and notes live next to the work. Everyone in the factory edits the same doc at once, with live cursors.

    ## Try it

    - [x] Open a doc from the sidebar or a goal
    - [ ] Type `/` for blocks, `@` to mention someone, `#` to link a task
    - [ ] Paste Markdown and it turns into rich text

    > This demo runs offline. Sign in to edit your factory's docs with your team.
    """
}

/// The Docs page: every active doc, by goal, with native create, rename and archive.
struct DocsView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @State private var creating = false

    var body: some View {
        let docs = DocsIndex.docs(client)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Docs").font(.system(size: 20, weight: .semibold))
                Text("\(docs.count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.textMuted)
                Spacer()
                Button { creating = true } label: { Label("New doc", systemImage: "plus") }
                    .disabled(!client.isSignedIn)
                    .help(client.isSignedIn ? "New doc" : "Sign in to make docs")
            }
            .padding(.horizontal, 28).padding(.top, 52).padding(.bottom, 14)

            if docs.isEmpty {
                ContentUnavailableView("No docs yet", systemImage: "doc.richtext",
                                       description: Text("Plans, specs and notes your team writes together."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(DocsIndex.grouped(docs, client: client), id: \.title) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title.uppercased())
                                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textFaint)
                                    .padding(.horizontal, 10).padding(.bottom, 4)
                                ForEach(group.docs) { doc in DocRow(doc: doc, showGoal: false) }
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.editorBG)
        .sheet(isPresented: $creating) { NewDocSheet(goal: nil) }
        .onChange(of: state.creatingDoc, initial: true) { _, on in
            if on, client.isSignedIn { creating = true }
            state.creatingDoc = false
        }
    }
}

/// A doc's open comment threads (MF-364): a small native badge, nothing when there are none.
struct ThreadBadge: View {
    let count: Int?
    var body: some View {
        if let count, count > 0 {
            Label("\(count)", systemImage: "text.bubble")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.accent.opacity(0.12)))
                .help("\(count) open comment thread\(count == 1 ? "" : "s")")
        }
    }
}

/// A goal's open decisions (MF-367): opens the Decisions page; nothing when there are none.
struct DecisionBadge: View {
    @Environment(AppState.self) private var state
    let count: Int
    var body: some View {
        if count > 0 {
            Button { state.destination = .decisions } label: {
                Label("\(count) open decision\(count == 1 ? "" : "s")", systemImage: "checkmark.seal")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Decisions in this goal's docs waiting for a person")
        }
    }
}

/// One doc in a list: opens on click; a context menu renames it inline, moves it to another goal, archives it or copies its link.
struct DocRow: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    let doc: Wire.Doc
    var showGoal = true
    @State private var renaming = false
    @State private var title = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext").font(.system(size: 13)).foregroundStyle(Theme.textMuted).frame(width: 18)
            if renaming {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain).focused($focused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
                    .onAppear { focused = true }
            } else {
                Text(doc.title.isEmpty ? "Untitled" : doc.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            if showGoal, let goal = DocsIndex.goalName(doc.goal, client: client) {
                Text(goal).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer()
            ThreadBadge(count: FeedState.threadBadge(doc))
            Text(DocsIndex.edited(doc)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.fill : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !renaming { state.closeFocus(); state.destination = .doc(doc.id) } }
        .contextMenu {
            Button("Open") { state.destination = .doc(doc.id) }
            if client.isSignedIn {
                Button("Rename") { title = doc.title; renaming = true }
                Menu("Move to goal") {
                    moveItem("No goal", goal: nil)
                    Divider()
                    ForEach(client.goals.filter { $0.archived != true }, id: \.id) { goal in
                        moveItem(goal.name, goal: goal.id)
                    }
                }
                Button("Archive") { client.archiveDoc(id: doc.id) }
            }
            Divider()
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(DocsIndex.link(doc.id), forType: .string)
            }
        }
    }

    /// One Move to goal choice: checked when the doc is already there; picking it sends doc.move.
    @ViewBuilder private func moveItem(_ name: String, goal: String?) -> some View {
        if doc.goal == goal {
            Button { } label: { Label(name, systemImage: "checkmark") }
        } else {
            Button(name) { client.moveDoc(id: doc.id, goal: goal) }
        }
    }

    private func commitRename() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != doc.title { client.renameDoc(id: doc.id, title: trimmed) }
        renaming = false
    }
}

/// A goal page's Docs section: that goal's docs and a "+ New doc" that files it there.
struct GoalDocsSection: View {
    @Environment(FactoryClient.self) private var client
    let goalName: String
    @State private var creating = false

    var body: some View {
        let goalId = DocsIndex.goalId(name: goalName, client: client)
        let docs = DocsIndex.docs(client).filter { goalId != nil && $0.goal == goalId }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Docs").font(.system(size: 13, weight: .semibold))
                Text("\(docs.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textMuted)
                ThreadBadge(count: FeedState.openThreadTotal(docs))
                if let goalId { DecisionBadge(count: FeedState.openDecisionCount(client.decisions, goal: goalId)) }
                Spacer()
                if client.isSignedIn {
                    Button { creating = true } label: { Label("New doc", systemImage: "plus").font(.system(size: 12)) }
                        .buttonStyle(.borderless)
                }
            }
            if docs.isEmpty {
                Text("No docs for this goal yet.").font(.system(size: 12)).foregroundStyle(Theme.textFaint).padding(.vertical, 4)
            }
            ForEach(docs) { doc in DocRow(doc: doc, showGoal: false) }
        }
        .sheet(isPresented: $creating) { NewDocSheet(goal: goalId) }
    }
}

/// Names a new doc and files it in a goal (or none).
struct NewDocSheet: View {
    @Environment(FactoryClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State var goal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New doc").font(.system(size: 15, weight: .semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).onSubmit(create)
            Picker("Goal", selection: $goal) {
                Text("No goal").tag(String?.none)
                ForEach(client.goals.filter { $0.archived != true }, id: \.id) { goal in Text(goal.name).tag(Optional(goal.id)) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 380)
    }

    private func create() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        client.createDoc(title: trimmed, goal: goal)
        dismiss()
    }
}

/// One doc, open in the shared editor, under a native title bar: title, sync dot, who's editing.
struct DocPage: View {
    /// A headless run's `docpeer:<login>:<rrggbb>[:avatar]` action: someone else joins the open doc, with
    /// their GitHub avatar (github.com/<login>.png) when `avatar` is given.
    static let demoPeer = Notification.Name("DocPage.demoPeer")
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @Environment(\.colorScheme) private var scheme
    let id: String
    @State private var status = DocEditorStatus()
    @State private var reload = 0

    var body: some View {
        let doc = client.isSignedIn ? client.docs.first { $0.id == id } : (id == DemoDoc.id ? DemoDoc.doc : nil)
        VStack(spacing: 0) {
            titleBar(doc)
            Divider()
            if let error = status.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(error).lineLimit(2)
                    Spacer()
                    Button("Retry") { reload += 1 }
                }
                .font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 8).background(Theme.raised)
            }
            if let source {
                DocEditorView(docId: id, source: source, me: me, members: members, tasksJSON: tasksJSON,
                              threadsJSON: threadsJSON, decisionsJSON: decisionsJSON,
                              goals: client.goals.filter { $0.archived != true }.map { ["id": $0.id, "name": $0.name] },
                              docGoal: doc?.goal, dark: scheme == .dark,
                              status: status, reloadToken: reload,
                              focusOnSync: state.focusDoc == id,
                              onFocused: { if state.focusDoc == id { state.focusDoc = nil } },
                              onCommand: { client.sendDocCommand($0) }) { task in state.openFullView(task) }
            } else {
                ContentUnavailableView("Doc not found", systemImage: "doc.richtext", description: Text("It may have been removed."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.editorBG)
        .task(id: "\(id)-\(client.isSignedIn)") { if client.isSignedIn { client.askDocThreads(id) } }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoPeer)) { note in
            if let peer = (note.userInfo as? [String: Any]).flatMap(DocEditorStatus.Peer.parse) { status.peers.append(peer) }
        }
    }

    /// The doc's threads as JSON for `mapleDocs.updateThreads` (MF-364).
    private var threadsJSON: String {
        let list = client.docThreads[id] ?? []
        guard let data = try? JSONEncoder().encode(list) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The doc's decisions as JSON for `mapleDocs.updateDecisions` (MF-367).
    private var decisionsJSON: String {
        let list = client.decisions.filter { $0.doc == id }
        guard let data = try? JSONEncoder().encode(list) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private var source: DocEditorView.Source? {
        if client.isSignedIn {
            guard let embed = client.docEmbed() else { return nil }
            return .live(url: embed.url, token: embed.token)
        }
        return id == DemoDoc.id ? .demo(markdown: DemoDoc.markdown) : nil
    }

    private var me: [String: Any] {
        guard let me = client.me else { return ["login": "you", "name": "You"] }
        return ["login": me.login, "name": me.name ?? me.login, "avatar": me.avatarUrl as Any]
    }

    private var members: [[String: Any]] {
        client.members.map { ["login": $0.login, "name": $0.name ?? $0.login, "avatar": $0.avatarUrl as Any] }
    }

    /// Tasks for the # menu, task embeds and decision cards (MF-368: state, goal and fromDoc too), JSON-encoded and
    /// pushed with `mapleDocs.updateTasks` when they change.
    private var tasksJSON: String {
        let embed = client.isSignedIn
            ? client.tasks.prefix(500).map { EmbedTask(id: $0.id, title: $0.title, state: $0.state.rawValue, goal: $0.goal, fromDoc: $0.fromDoc) }
            : state.tasks.prefix(200).map { EmbedTask(id: $0.id, title: $0.title, state: nil, goal: nil, fromDoc: nil) }
        guard let data = try? JSONEncoder().encode(embed) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct EmbedTask: Encodable {
        let id: String, title: String, state: String?, goal: String?
        let fromDoc: Wire.TaskDocSource?
    }

    private func titleBar(_ doc: Wire.Doc?) -> some View {
        HStack(spacing: 10) {
            Button { state.destination = .docs } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).help("All docs")
            Image(systemName: "doc.richtext").foregroundStyle(Theme.textMuted)
            Text(doc?.title ?? "Doc").font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if let goal = DocsIndex.goalName(doc?.goal, client: client) {
                Text(goal).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            Circle().fill(dotColor).frame(width: 7, height: 7)
                .help(status.synced ? "Synced" : status.status.capitalized)
            Spacer()
            ThreadBadge(count: doc.flatMap(FeedState.threadBadge))
            HStack(spacing: -6) {
                ForEach(status.peers.prefix(5), id: \.login) { peer in
                    PeerAvatar(peer: peer, avatar: peer.avatar ?? client.members.first { $0.login == peer.login }?.avatarUrl)
                        .help("\(peer.name) is editing")
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 40).padding(.bottom, 10)
    }

    private var dotColor: Color {
        if status.error != nil { return Theme.State.cancelled }
        if status.synced && status.status == "connected" { return Theme.State.merged }
        return Theme.State.awaitingApproval
    }
}

/// Someone else in the doc: their GitHub avatar ringed in their cursor color, with their initial on that
/// color until it loads (or when there isn't one).
struct PeerAvatar: View {
    let peer: DocEditorStatus.Peer
    let avatar: String?
    var size: CGFloat = 22

    var body: some View {
        let color = Color(hex: peer.color)
        let shape = AgentAvatar.personShape(size: size)
        let inner = size - 4
        ZStack {
            AgentAvatar.personShape(size: inner).fill(color)
            Text(String(peer.name.prefix(1)).uppercased())
                .font(.system(size: inner * 0.45, weight: .bold)).foregroundStyle(.white)
            if let avatar, !avatar.isEmpty, let url = URL(string: avatar) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .frame(width: inner, height: inner)
        .clipShape(AgentAvatar.personShape(size: inner))
        .frame(width: size, height: size)
        .background(shape.fill(color))
        .overlay(shape.strokeBorder(Theme.editorBG, lineWidth: 1))
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
