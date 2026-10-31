import AppKit
import SwiftUI

/// The task's changes as a review: a file tree on the left, the picked file's diff taking the rest of the
/// width. Click a line number to comment on it (shift-click or drag for a range); comments wait in a
/// pending review until it's sent, all at once, as one change request. A task with a GitHub pull
/// request shows its review threads under the lines they're on. Each file and hunk is tagged with the
/// plan step it implements so the review reads against the approved plan. The toolbar's picker shows
/// one commit at a time instead, read-only: comments go on All changes, where their line numbers hold.
struct DiffView: View {
    @Environment(AppState.self) private var appState
    @Environment(FactoryClient.self) private var client
    let task: FactoryTask
    /// The whole branch's files: All changes.
    let allFiles: [DiffFile]
    @State private var selected: String
    /// The commit picked in the toolbar, by sha; none: All changes.
    @State private var commit: String?
    /// Hunks fetched on demand for files that arrive collapsed (large or generated files).
    @State private var loaded: [String: [DiffHunk]] = [:]
    @State private var loading: Set<String> = []
    @AppStorage("diffTreeWidth", store: AppDefaults) private var treeWidth: Double = 280

    // Commenting
    @State private var selection: LineSelection?
    @State private var dragging = false
    @State private var composing = false
    @State private var composerText = ""
    @State private var editing: UUID?
    @State private var editText = ""
    @FocusState private var composerFocused: Bool

    // GitHub's review threads
    @State private var showThreads = true
    /// Threads opened or closed from how they start (resolved and outdated ones start closed).
    @State private var toggledThreads: Set<String> = []

    private let rowHeight: CGFloat = 20
    private let gutterWidth: CGFloat = 98
    @State private var codeWidth: CGFloat = 600
    @State private var cache = DiffRenderCache()
    /// Where the file's lines are scrolled to, so the demo script can move through a long file.
    @State private var scroll = ScrollPosition(edge: .top)

    static let demo = Notification.Name("DiffView.demo")

    init(task: FactoryTask, files: [DiffFile]) {
        self.task = task
        self.allFiles = files
        _selected = State(initialValue: files.first { !$0.hunks.isEmpty }?.path ?? files.first?.path ?? "")
    }

    private var draft: ReviewDraft { appState.reviewDraft(for: task.id) }

    /// The branch's commits, oldest first; none from a runner that predates them.
    private var commits: [DiffCommit] {
        appState.isLive ? client.commits[task.id]?.commits ?? [] : FactoryData.commits(for: task.id)
    }

    private var pickedCommit: DiffCommit? { commit.flatMap { sha in commits.first { $0.sha == sha } } }

    /// A commit on its own is read-only: its line numbers aren't the ones a comment is sent against.
    private var readOnly: Bool { pickedCommit != nil }

    /// What's shown: All changes, or the picked commit's files.
    private var files: [DiffFile] {
        guard let pickedCommit else { return allFiles }
        return appState.isLive ? client.commitDiffs["\(task.id)@\(pickedCommit.sha)"] ?? [] : FactoryData.diff(for: task.id, commit: pickedCommit.sha)
    }

    /// The picked file, else the tree's first with hunks (files can arrive after the view does).
    private var current: DiffFile? {
        if let picked = files.first(where: { $0.path == selected }) { return picked }
        let ordered = cache.tree(files).flatMap(\.files)
        return ordered.first { !$0.hunks.isEmpty } ?? ordered.first
    }

    private var threads: [Wire.ReviewThread] {
        appState.isLive ? client.threads[task.id]?.threads ?? [] : FactoryData.reviewThreads(for: task.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            if let pickedCommit {
                commitStrip(pickedCommit)
                Hairline()
            }
            HStack(spacing: 0) {
                if !files.isEmpty {
                    DiffFileTree(
                        task: task,
                        nodes: cache.tree(files),
                        selected: current?.path,
                        pending: readOnly ? [] : draft.paths,
                        threaded: readOnly ? [] : Set(threads.map(\.path)),
                        onSelect: pick
                    )
                    .frame(width: treeWidth)
                    .background(Theme.fillSubtle)
                    resizeHandle
                }
                if let current {
                    fileDiff(current)
                } else if readOnly {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
            }
            .frame(maxHeight: .infinity)
            Hairline()
            reviewBar
        }
        .background(Theme.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        .task(id: task.diffKey) {
            if appState.isLive, task.pr != nil, let key = task.diffKey { await client.loadThreads(task: task.id, key: key) }
        }
        .task(id: commit) {
            if appState.isLive, let commit, let key = task.diffKey { await client.loadDiff(task: task.id, key: key, commit: commit) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.demo)) { note in
            if let parts = note.object as? [String] { playDemo(parts) }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            if !commits.isEmpty { commitPicker }
            Text(files.count == 1 ? "1 file" : "\(files.count) files")
                .foregroundStyle(Theme.textMuted)
            HStack(spacing: 4) {
                Text("+\(files.map(\.added).reduce(0, +))").foregroundStyle(Theme.State.merged)
                Text("−\(files.map(\.removed).reduce(0, +))").foregroundStyle(Theme.State.cancelled)
            }
            .monospacedDigit()
            Spacer()
            if !threads.isEmpty, !readOnly {
                let open = threads.filter { !$0.resolved }.count
                HStack(spacing: 5) {
                    Image(systemName: showThreads ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                        .font(.system(size: 10.5))
                    Text("Threads")
                    Text("\(threads.count)")
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }
                .foregroundStyle(showThreads ? Theme.text : Theme.textMuted)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(showThreads ? Theme.fillSelected : Theme.fill))
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { showThreads.toggle() } }
                .help("\(showThreads ? "Hide" : "Show") the pull request's review threads (\(open) open)")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    /// All changes, or one commit: a menu of them in order, and ‹ › to step from one to the next.
    private var commitPicker: some View {
        let index = commit.flatMap { sha in commits.firstIndex { $0.sha == sha } }
        return HStack(spacing: 4) {
            Menu {
                Button { choose(nil) } label: {
                    if commit == nil { Label("All changes", systemImage: "checkmark") } else { Text("All changes") }
                }
                Divider()
                ForEach(Array(commits.enumerated()), id: \.element.sha) { offset, c in
                    Button { choose(c.sha) } label: {
                        let title = "\(offset + 1). \(c.subject)   \(c.shortSHA)   +\(c.added) −\(c.removed)"
                        if c.sha == commit { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: commit == nil ? "square.stack.3d.up" : "smallcircle.filled.circle").font(.system(size: 10.5))
                    Text(pickedCommit.map { $0.subject } ?? "All changes").lineLimit(1).frame(maxWidth: 280, alignment: .leading)
                    Text(index.map { "\($0 + 1)/\(commits.count)" } ?? "\(commits.count) commit\(commits.count == 1 ? "" : "s")")
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(commit == nil ? Theme.fill : Theme.fillSelected))
            .help("Show All changes, or one commit at a time")
            stepButton("chevron.left", help: "Previous commit", enabled: index != nil) { stepCommit(-1) }
            stepButton("chevron.right", help: "Next commit", enabled: index.map { $0 < commits.count - 1 } ?? true) { stepCommit(1) }
        }
    }

    private func stepButton(_ icon: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.textFaint)
                .frame(width: 22, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// Shows a commit (or All changes, nil), keeping the picked file when it's in that one too.
    private func choose(_ sha: String?) {
        guard sha != commit else { return }
        selection = nil
        composing = false
        editing = nil
        scroll = ScrollPosition(edge: .top)
        withAnimation(.snappy(duration: 0.15)) { commit = sha }
    }

    /// The next commit (`by` 1) or the one before (-1); before the first is All changes.
    private func stepCommit(_ by: Int) {
        let order: [String?] = [nil] + commits.map(\.sha)
        let at = order.firstIndex(of: commit) ?? 0
        choose(order[min(max(at + by, 0), order.count - 1)])
    }

    /// The picked commit's message, who made it and when.
    private func commitStrip(_ c: DiffCommit) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(c.subject)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer()
                Text(c.shortSHA)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
                    .help(c.sha)
            }
            if let body = c.body {
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Text("\(c.author) committed \(c.at.formatted(.relative(presentation: .named)))")
                if c.truncated {
                    Text("·")
                    Text("Too big to show in full").foregroundStyle(Theme.State.awaitingApproval)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.State.planning.opacity(0.05))
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { value in
                        treeWidth = min(max(treeWidth + value.translation.width - lastDrag, 180), 560)
                        lastDrag = value.translation.width
                    }.onEnded { _ in lastDrag = 0 })
            }
    }

    @State private var lastDrag: CGFloat = 0

    private func pick(_ file: DiffFile) {
        selected = file.path
        scroll = ScrollPosition(edge: .top)
        if file.hunks.isEmpty, loaded[file.path] == nil, !loading.contains(file.path) { load(file) }
    }

    // MARK: File

    private func hunks(_ file: DiffFile) -> [DiffHunk] { file.hunks.isEmpty ? loaded[file.path] ?? [] : file.hunks }

    private func fileDiff(_ file: DiffFile) -> some View {
        let hunks = hunks(file)
        return VStack(alignment: .leading, spacing: 0) {
            fileHeader(file)
            if hunks.isEmpty {
                collapsedPlaceholder(file).frame(maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    fileBody(file, hunks: hunks, rendered: rendered(file, hunks: hunks))
                        .padding(.bottom, 24)
                }
                .scrollPosition($scroll)
                .id(file.path)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { codeWidth = max($0 - gutterWidth, 200) }
    }

    private func fileHeader(_ file: DiffFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Text(file.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let step = file.step { StepTag(task: task, step: step) }
            if file.inProgress {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("\(task.agent?.name ?? "Agent") is editing")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.State.building)
            }
            Spacer()
            Text("+\(file.added)").foregroundStyle(Theme.State.merged)
            Text("−\(file.removed)").foregroundStyle(Theme.State.cancelled)
        }
        .font(.system(size: 11.5).monospacedDigit())
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.fillSubtle)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// The file's rows and highlighted lines, worked out once per version of the file.
    private func rendered(_ file: DiffFile, hunks: [DiffHunk]) -> DiffRenderCache.Entry {
        let prose = Self.proseExtensions.contains((file.path as NSString).pathExtension.lowercased())
        return cache.entry(path: file.path, version: task.diffKey ?? "", hunks: hunks, prose: prose)
    }

    /// What the file's lazy stack shows, one after another: hunk headers, runs of lines, and the
    /// cards (threads, pending comments, the composer) under the line a run ends on.
    private enum Piece: Identifiable {
        case header(Int)
        case run(Range<Int>)
        case cards(Int)

        var id: String {
            switch self {
            case .header(let hunk): "h\(hunk)"
            case .run(let rows): "r\(rows.lowerBound)"
            case .cards(let row): "c\(row)"
            }
        }
    }

    /// The file's hunks, cut into runs of lines wherever something sits under a line: a thread, a
    /// pending comment or the composer. Long runs are cut again so only those on screen get built.
    private func fileBody(_ file: DiffFile, hunks: [DiffHunk], rendered: DiffRenderCache.Entry) -> some View {
        let lines = rendered.lines
        let fileThreads = showThreads && !readOnly ? threads.filter { $0.path == file.path } : []
        let placed = DiffReview.place(fileThreads, in: lines)
        var notes: [Int: [DraftNote]] = [:]
        for note in draft.notes where note.note.path == file.path && !readOnly {
            let row = DiffReview.row(side: note.note.side, line: Int(note.note.end), in: lines) ?? lines.count - 1
            notes[row, default: []].append(note)
        }
        let composerRow = composing && selection?.path == file.path ? selection?.rows.upperBound : nil
        let breaks = Set(placed.rows.keys).union(notes.keys).union(composerRow.map { [$0] } ?? [])

        var pieces: [Piece] = []
        for (index, hunk) in hunks.enumerated() {
            pieces.append(.header(index))
            let start = rendered.starts[index]
            for run in DiffReview.runs(start..<start + hunk.lines.count, breaks: breaks) {
                pieces.append(.run(run))
                if breaks.contains(run.upperBound - 1) { pieces.append(.cards(run.upperBound - 1)) }
            }
        }

        return LazyVStack(alignment: .leading, spacing: 0) {
            if !placed.elsewhere.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not on the lines shown").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textMuted)
                    ForEach(placed.elsewhere, id: \.id) { threadCard($0) }
                }
                .padding(12)
            }
            ForEach(pieces) { piece in
                switch piece {
                case .header(let index):
                    hunkHeader(hunks[index])
                case .run(let rows):
                    runView(rows, path: file.path, rendered: rendered)
                case .cards(let last):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(placed.rows[last] ?? [], id: \.id) { threadCard($0) }
                        ForEach(notes[last] ?? []) { noteCard($0) }
                        if composerRow == last { composer(file: file, lines: lines) }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.leading, gutterWidth)
                    .padding(.trailing, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        HStack(spacing: 8) {
            Text(hunk.header)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            Spacer()
            if let step = hunk.step, task.plan.indices.contains(step - 1) {
                HStack(spacing: 5) {
                    StepTag(task: task, step: step)
                    Text(task.plan[step - 1].text).lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Theme.State.planning.opacity(0.05))
    }

    // MARK: Lines

    private func runView(_ rows: Range<Int>, path: String, rendered: DiffRenderCache.Entry) -> some View {
        DiffRun(
            rows: rows,
            rendered: rendered,
            path: path,
            selection: selection,
            dragging: dragging,
            composing: composing,
            codeWidth: codeWidth,
            rowHeight: rowHeight,
            gutterWidth: gutterWidth,
            readOnly: readOnly,
            onDrag: { row in drag(to: row, path: path, count: rendered.lines.count) },
            onDragEnd: { dragging = false },
            onComment: { row in startComment(path: path, row: row) }
        )
    }

    /// A press or drag in the gutter at `row`: starts a selection (or extends one with shift), then
    /// moves its far end with the drag.
    private func drag(to row: Int, path: String, count: Int) {
        let row = min(max(row, 0), count - 1)
        if !dragging {
            dragging = true
            if NSEvent.modifierFlags.contains(.shift), var extended = selection, extended.path == path {
                extended.head = row
                selection = extended
            } else {
                selection = LineSelection(path: path, row: row)
                composing = false
            }
        } else if selection?.path == path {
            selection?.head = row
        }
    }

    /// Files read as text rather than code: no syntax colours, which only scramble prose.
    private static let proseExtensions: Set<String> = ["md", "markdown", "mdx", "txt", "rst", "adoc", ""]

    // MARK: Comments

    private func startComment(path: String, row: Int) {
        guard !readOnly else { return }
        if selection?.contains(path, row) != true { selection = LineSelection(path: path, row: row) }
        editing = nil
        composerText = ""
        withAnimation(.snappy(duration: 0.15)) { composing = true }
        composerFocused = true
    }

    private func anchorLabel(_ file: DiffFile, lines: [DiffLine]) -> String {
        guard let selection, let note = DiffReview.note(path: file.path, lines: lines, rows: selection.rows, text: "") else { return file.path }
        return DiffReview.anchor(note)
    }

    private func composer(file: DiffFile, lines: [DiffLine]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.system(size: 11))
                Text("Comment on \(anchorLabel(file, lines: lines))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.textMuted)
            noteEditor($composerText, placeholder: "What should change here?")
            HStack(spacing: 8) {
                Text("⌘↩ to add").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                Spacer()
                smallButton("Cancel") { cancelComment() }
                smallButton("Add to review", primary: true, enabled: !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    saveComment(file: file, lines: lines)
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(cardBackground(Theme.accent.opacity(0.5)))
    }

    private func noteEditor(_ text: Binding<String>, placeholder: String) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .focused($composerFocused)
            .frame(minHeight: 64, maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(Theme.textFaint).padding(.leading, 11).padding(.top, 6).allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.editorBG).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke)))
    }

    private func cancelComment() {
        withAnimation(.snappy(duration: 0.15)) {
            composing = false
            selection = nil
        }
        composerText = ""
    }

    private func saveComment(file: DiffFile, lines: [DiffLine]) {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let selection, let note = DiffReview.note(path: file.path, lines: lines, rows: selection.rows, text: text) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            draft.add(note)
            composing = false
            self.selection = nil
        }
        composerText = ""
    }

    private func noteCard(_ note: DraftNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                AgentAvatar(agent: FactoryData.me, size: 16)
                Text("You").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Pending")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Theme.accent.opacity(0.13)))
                Text(DiffReview.anchor(note.note))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if editing != note.id {
                    iconButton("pencil", help: "Edit") {
                        editText = note.note.text
                        composing = false
                        editing = note.id
                        composerFocused = true
                    }
                    iconButton("trash", help: "Delete") { withAnimation(.snappy(duration: 0.2)) { draft.remove(note.id) } }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            Hairline()
            if editing == note.id {
                VStack(alignment: .leading, spacing: 8) {
                    noteEditor($editText, placeholder: "What should change here?")
                    HStack(spacing: 8) {
                        Spacer()
                        smallButton("Cancel") { editing = nil }
                        smallButton("Save", primary: true, enabled: !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            draft.update(note.id, text: editText.trimmingCharacters(in: .whitespacesAndNewlines))
                            editing = nil
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                .padding(12)
            } else {
                MarkdownPreview(source: note.note.text, baseSize: 13).padding(12)
            }
        }
        .background(cardBackground(Theme.accent.opacity(0.35)))
    }

    // MARK: Threads

    private func threadOpen(_ thread: Wire.ReviewThread) -> Bool {
        let closedByDefault = thread.resolved || thread.outdated
        return closedByDefault == toggledThreads.contains(thread.id)
    }

    private func threadCard(_ thread: Wire.ReviewThread) -> some View {
        let open = threadOpen(thread)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("GitHub")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Theme.fillSelected))
                if let line = thread.line {
                    Text("L\(thread.startLine.map { $0 < line ? "\($0)–" : "" } ?? "")\(line)\(thread.side == .old ? " (old)" : "")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                }
                if thread.resolved { tag("Resolved", Theme.State.merged) }
                if thread.outdated { tag("Outdated", Theme.State.awaitingApproval) }
                if !open, let first = thread.comments.first {
                    Text("\(first.author): \(first.body.replacingOccurrences(of: "\n", with: " "))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text(thread.comments.count == 1 ? "1 comment" : "\(thread.comments.count) comments")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    if toggledThreads.contains(thread.id) { toggledThreads.remove(thread.id) } else { toggledThreads.insert(thread.id) }
                }
            }
            if open {
                Hairline()
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(thread.comments.enumerated()), id: \.offset) { _, comment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(comment.author).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                                if comment.at > 0 {
                                    Text(Date(timeIntervalSince1970: Double(comment.at) / 1000).formatted(.relative(presentation: .named)))
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textFaint)
                                }
                            }
                            MarkdownPreview(source: comment.body, baseSize: 13)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(cardBackground(Theme.stroke))
        .opacity(thread.resolved && !open ? 0.75 : 1)
    }

    private func tag(_ title: String, _ color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(color.opacity(0.13)))
    }

    // MARK: Review bar

    private var reviewBar: some View {
        @Bindable var draft = draft
        let count = draft.notes.count
        return HStack(spacing: 10) {
            if let pickedCommit {
                Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                Text("Viewing \(pickedCommit.shortSHA) on its own, read-only. Comments go on All changes\(count == 0 ? "." : ", where \(count) pending wait.")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                Spacer()
                smallButton("All changes") { choose(nil) }
            } else if count == 0 {
                Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                Text("Click a line number to comment on it; shift-click or drag for a range. Comments wait here until you submit the review.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                Spacer()
            } else {
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    Text("\(count) pending").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                    Text("in \(draft.paths.count) file\(draft.paths.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
                .fixedSize()
                TextField("Summary for \(task.agent?.name ?? "the agent") (optional)", text: $draft.summary)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.editorBG).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke)))
                    .frame(maxWidth: 640)
                Spacer(minLength: 0)
                smallButton("Discard") { withAnimation(.snappy(duration: 0.2)) { draft.clear() } }
                smallButton("Submit review", primary: true, enabled: task.isSteerable) { submit() }
                    .help(task.isSteerable ? "Post the comments and send them to \(task.agent?.name ?? "the agent") as one change request" : "Nothing's working on \(task.id) to take a review")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Theme.fillSubtle)
    }

    private func submit() {
        guard task.isSteerable else { return }
        withAnimation(.snappy(duration: 0.2)) { appState.submitReview(task.id) }
    }

    // MARK: Pieces

    private func smallButton(_ title: String, primary: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primary ? (enabled ? Theme.onAccent : Theme.textFaint) : Theme.text)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(primary ? (enabled ? Theme.accent : Theme.fill) : Theme.fill)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? .clear : Theme.stroke))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
    }

    private func cardBackground(_ border: Color) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Theme.cardBG)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(border))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }

    // MARK: Collapsed files

    private func collapsedPlaceholder(_ file: DiffFile) -> some View {
        VStack(spacing: 8) {
            if appState.isLive {
                Text("No text changes to show")
            } else if loading.contains(file.path) {
                ProgressView().controlSize(.small)
                Text("Loading \(file.added + file.removed) lines…")
            } else {
                Text("Collapsed: \(file.added + file.removed) changed lines")
                smallButton("Load diff") { load(file) }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
        .frame(maxWidth: .infinity)
        .frame(height: 100)
    }

    private func load(_ file: DiffFile) {
        guard !appState.isLive else { return }
        loading.insert(file.path)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.snappy(duration: 0.25)) {
                loaded[file.path] = FactoryData.loadHunks(for: file)
                loading.remove(file.path)
            }
        }
    }

    // MARK: Demo

    /// `diff:file:<path>` picks a file, `diff:select:<from>:<to>` lines by their row in the file,
    /// `diff:comment` opens the composer, `diff:type:<text>` types into it, `diff:add` adds it,
    /// `diff:summary:<text>` fills the summary, `diff:submit` submits the review, `diff:scroll:<y>` (or
    /// `diff:scroll:bottom`) scrolls the file's lines, and `diff:commit:<n>|all`, `diff:next` and `diff:prev`
    /// work the commit picker.
    private func playDemo(_ parts: [String]) {
        guard let action = parts.first else { return }
        let argument = parts.dropFirst().joined(separator: ":")
        switch action {
        case "file": if let file = files.first(where: { $0.path == argument }) { pick(file) }
        case "commit":
            // `diff:commit:<n>` (from 1), or `diff:commit:all`.
            if let n = Int(argument), commits.indices.contains(n - 1) { choose(commits[n - 1].sha) } else { choose(nil) }
        case "next": stepCommit(1)
        case "prev": stepCommit(-1)
        case "select":
            let count = current.map { DiffReview.rows(hunks($0)).count } ?? 0
            guard let current, count > 0, parts.count > 1, let from = Int(parts[1]) else { return }
            let clamp = { (row: Int) in min(max(row, 0), count - 1) }
            var picked = LineSelection(path: current.path, row: clamp(from))
            picked.head = clamp(parts.count > 2 ? Int(parts[2]) ?? from : from)
            selection = picked
        case "comment":
            if let selection { startComment(path: selection.path, row: selection.rows.upperBound) }
        case "type":
            composerText = argument
        case "add":
            if let current { saveComment(file: current, lines: DiffReview.rows(hunks(current))) }
        case "summary": draft.summary = argument
        case "submit": submit()
        case "threads": showThreads.toggle()
        case "scroll":
            if argument == "bottom" { withAnimation { scroll.scrollTo(edge: .bottom) } } else if let y = Double(argument) { withAnimation { scroll.scrollTo(y: y) } }
        default: break
        }
    }
}

/// What the Changes tab works out once rather than on every pass: each file's rows, where its hunks
/// start and its lines' highlighted text, and the file tree. Not observed, so filling it in while a
/// view is drawn redraws nothing.
@MainActor final class DiffRenderCache {
    @MainActor final class Entry {
        let lines: [DiffLine]
        /// The row each hunk starts on.
        let starts: [Int]
        /// Prose files show their text plain, without syntax colours.
        let prose: Bool
        private var highlighted: [AttributedString?]

        init(hunks: [DiffHunk], prose: Bool) {
            lines = DiffReview.rows(hunks)
            var starts: [Int] = []
            var at = 0
            for hunk in hunks {
                starts.append(at)
                at += hunk.lines.count
            }
            self.starts = starts
            self.prose = prose
            highlighted = Array(repeating: nil, count: lines.count)
        }

        /// Row `row`'s highlighted code, highlighted the first time it's asked for.
        func code(_ row: Int) -> AttributedString {
            if let done = highlighted[row] { return done }
            let made = SyntaxHighlighter.highlight(lines[row].text)
            highlighted[row] = made
            return made
        }
    }

    private var entries: [String: Entry] = [:]
    private var treeKey: [String] = []
    private var treeNodes: [DiffTreeNode] = []

    /// The entry for `hunks` of `path` at `version`. Hunks get new ids each time a diff is parsed or
    /// loaded, so the first one's id tells versions apart even without a diff key.
    func entry(path: String, version: String, hunks: [DiffHunk], prose: Bool) -> Entry {
        let key = "\(path)\u{0}\(version)\u{0}\(hunks.first.map { "\($0.id)" } ?? "")\u{0}\(hunks.count)"
        if let entry = entries[key] { return entry }
        if entries.count > 32 { entries.removeAll() }
        let entry = Entry(hunks: hunks, prose: prose)
        entries[key] = entry
        return entry
    }

    /// `DiffTreeNode.build(files)`, built again only when the files change.
    func tree(_ files: [DiffFile]) -> [DiffTreeNode] {
        let key = files.map { "\($0.path)\u{0}\($0.hunks.first.map { "\($0.id)" } ?? "")\u{0}\($0.inProgress)" }
        if key != treeKey {
            treeKey = key
            treeNodes = DiffTreeNode.build(files)
        }
        return treeNodes
    }
}

/// A run of a file's rows: line numbers that select beside code that scrolls sideways rather than
/// wrapping. It keeps which row the pointer is over itself, so hovering redraws only the rows whose
/// look changes rather than the whole file.
private struct DiffRun: View {
    let rows: Range<Int>
    let rendered: DiffRenderCache.Entry
    let path: String
    let selection: LineSelection?
    let dragging: Bool
    let composing: Bool
    let codeWidth: CGFloat
    let rowHeight: CGFloat
    let gutterWidth: CGFloat
    /// A commit on its own: no selecting, no commenting.
    let readOnly: Bool
    let onDrag: (Int) -> Void
    let onDragEnd: () -> Void
    let onComment: (Int) -> Void

    @State private var hovered: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(rows, id: \.self) { row in
                    let picked = selection?.contains(path, row) == true
                    let selectionEnd = selection.map { $0.path == path && $0.rows.upperBound == row } ?? false
                    let showsPlus = !readOnly && !dragging && (hovered == row || (selectionEnd && !composing))
                    DiffGutterRow(
                        line: rendered.lines[row],
                        picked: picked,
                        showsPlus: showsPlus,
                        height: rowHeight,
                        onHover: { hover(row, $0) },
                        onComment: { onComment(row) }
                    )
                    .equatable()
                    .zIndex(showsPlus ? 1 : 0)
                }
            }
            .frame(width: gutterWidth)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onDrag(rows.lowerBound + Int((value.location.y / rowHeight).rounded(.down)))
            }.onEnded { _ in onDragEnd() }, including: readOnly ? .none : .all)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.self) { row in
                        DiffCodeRow(
                            row: row,
                            line: rendered.lines[row],
                            code: rendered.prose ? nil : rendered.code(row),
                            picked: selection?.contains(path, row) == true,
                            codeWidth: codeWidth,
                            height: rowHeight,
                            onHover: { hover(row, $0) }
                        )
                        .equatable()
                    }
                }
                .frame(minWidth: codeWidth, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func hover(_ row: Int, _ inside: Bool) {
        if inside { hovered = row } else if hovered == row { hovered = nil }
    }
}

private func diffTint(_ line: DiffLine) -> Color? {
    switch line.kind {
    case .added: Theme.State.merged
    case .removed: Theme.State.cancelled
    case .context: nil
    }
}

/// A row's line numbers and sign, with the plus button that starts a comment. Equal inputs skip
/// redrawing it (the closures don't count).
private struct DiffGutterRow: View, Equatable {
    let line: DiffLine
    let picked: Bool
    let showsPlus: Bool
    let height: CGFloat
    let onHover: (Bool) -> Void
    let onComment: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.line == b.line && a.picked == b.picked && a.showsPlus == b.showsPlus && a.height == b.height
    }

    var body: some View {
        let tint = diffTint(line)
        HStack(spacing: 0) {
            Text(line.old.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(line.new.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                .foregroundStyle(tint ?? Theme.textFaint)
                .frame(width: 22)
        }
        .foregroundStyle(picked ? Theme.text : Theme.textFaint)
        .frame(height: height)
        .background(picked ? Theme.changeBar.opacity(0.3) : tint.map { $0.opacity(0.13) } ?? .clear)
        .overlay(alignment: .leading) {
            if picked { Rectangle().fill(Theme.changeBar).frame(width: 2) } else if let tint { Rectangle().fill(tint.opacity(0.7)).frame(width: 2) }
        }
        .overlay(alignment: .trailing) {
            if showsPlus {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent))
                    .offset(x: 9)
                    .onTapGesture(perform: onComment)
                    .help("Comment on \(picked ? "these lines" : "this line")")
            }
        }
        .onHover(perform: onHover)
    }
}

/// A row's code: highlighted, or plain for prose (`code` nil).
private struct DiffCodeRow: View, Equatable {
    let row: Int
    let line: DiffLine
    let code: AttributedString?
    let picked: Bool
    let codeWidth: CGFloat
    let height: CGFloat
    let onHover: (Bool) -> Void

    /// The code comes from the line, so the line stands in for it.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.line == b.line && a.picked == b.picked && a.codeWidth == b.codeWidth && a.height == b.height
    }

    var body: some View {
        Group {
            if let code { Text(code) } else { Text(line.text).foregroundStyle(Theme.text) }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 12)
        .padding(.trailing, 24)
        .frame(height: height)
        .frame(minWidth: codeWidth, alignment: .leading)
        .background(picked ? Theme.changeBar.opacity(0.16) : diffTint(line).map { $0.opacity(0.09) } ?? .clear)
        .onHover(perform: onHover)
    }
}
