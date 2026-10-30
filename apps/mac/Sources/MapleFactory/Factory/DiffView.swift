import AppKit
import SwiftUI

/// The task's diff as a review: a file tree on the left, the picked file's diff taking the rest of the
/// width. Click a line number to comment on it (shift-click or drag for a range); comments wait in a
/// pending review until it's sent, all at once, as one change request. A task with a GitHub pull
/// request shows its review threads under the lines they're on. Each file and hunk is tagged with the
/// plan step it implements so the review reads against the approved plan.
struct DiffView: View {
    @Environment(AppState.self) private var appState
    @Environment(FactoryClient.self) private var client
    let task: FactoryTask
    let files: [DiffFile]
    @State private var selected: String
    /// Hunks fetched on demand for files that arrive collapsed (large or generated files).
    @State private var loaded: [String: [DiffHunk]] = [:]
    @State private var loading: Set<String> = []
    @AppStorage("diffTreeWidth", store: AppDefaults) private var treeWidth: Double = 280

    // Commenting
    @State private var selection: LineSelection?
    @State private var dragging = false
    @State private var hovered: Int?
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

    static let demo = Notification.Name("DiffView.demo")

    init(task: FactoryTask, files: [DiffFile]) {
        self.task = task
        self.files = files
        _selected = State(initialValue: files.first { !$0.hunks.isEmpty }?.path ?? files.first?.path ?? "")
    }

    private var draft: ReviewDraft { appState.reviewDraft(for: task.id) }

    /// The picked file, else the tree's first with hunks (files can arrive after the view does).
    private var current: DiffFile? {
        if let picked = files.first(where: { $0.path == selected }) { return picked }
        let ordered = DiffTreeNode.build(files).flatMap(\.files)
        return ordered.first { !$0.hunks.isEmpty } ?? ordered.first
    }

    private var threads: [Wire.ReviewThread] {
        appState.isLive ? client.threads[task.id]?.threads ?? [] : FactoryData.reviewThreads(for: task.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            HStack(spacing: 0) {
                if !files.isEmpty {
                    DiffFileTree(
                        task: task,
                        nodes: DiffTreeNode.build(files),
                        selected: current?.path,
                        pending: draft.paths,
                        threaded: Set(threads.map(\.path)),
                        onSelect: pick
                    )
                    .frame(width: treeWidth)
                    .background(Theme.fillSubtle)
                    resizeHandle
                }
                if let current { fileDiff(current) } else { Spacer() }
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
        .onReceive(NotificationCenter.default.publisher(for: Self.demo)) { note in
            if let parts = note.object as? [String] { playDemo(parts) }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(files.count == 1 ? "1 file" : "\(files.count) files")
                .foregroundStyle(Theme.textMuted)
            HStack(spacing: 4) {
                Text("+\(files.map(\.added).reduce(0, +))").foregroundStyle(Theme.State.merged)
                Text("−\(files.map(\.removed).reduce(0, +))").foregroundStyle(Theme.State.cancelled)
            }
            .monospacedDigit()
            Spacer()
            if !threads.isEmpty {
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
        hovered = nil
        if file.hunks.isEmpty, loaded[file.path] == nil, !loading.contains(file.path) { load(file) }
    }

    // MARK: File

    private func hunks(_ file: DiffFile) -> [DiffHunk] { file.hunks.isEmpty ? loaded[file.path] ?? [] : file.hunks }

    private func fileDiff(_ file: DiffFile) -> some View {
        let hunks = hunks(file)
        let lines = DiffReview.rows(hunks)
        return VStack(alignment: .leading, spacing: 0) {
            fileHeader(file)
            if hunks.isEmpty {
                collapsedPlaceholder(file).frame(maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    fileBody(file, hunks: hunks, lines: lines)
                        .padding(.bottom, 24)
                }
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

    /// The file's hunks, cut into runs of lines wherever something sits under a line: a thread, a
    /// pending comment or the composer.
    private func fileBody(_ file: DiffFile, hunks: [DiffHunk], lines: [DiffLine]) -> some View {
        let fileThreads = showThreads ? threads.filter { $0.path == file.path } : []
        let placed = DiffReview.place(fileThreads, in: lines)
        var notes: [Int: [DraftNote]] = [:]
        for note in draft.notes where note.note.path == file.path {
            let row = DiffReview.row(side: note.note.side, line: Int(note.note.end), in: lines) ?? lines.count - 1
            notes[row, default: []].append(note)
        }
        let composerRow = composing && selection?.path == file.path ? selection?.rows.upperBound : nil
        let breaks = Set(placed.rows.keys).union(notes.keys).union(composerRow.map { [$0] } ?? [])
        let prose = Self.proseExtensions.contains((file.path as NSString).pathExtension.lowercased())

        var starts: [Int] = []
        var at = 0
        for hunk in hunks {
            starts.append(at)
            at += hunk.lines.count
        }

        return VStack(alignment: .leading, spacing: 0) {
            if !placed.elsewhere.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not on the lines shown").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textMuted)
                    ForEach(placed.elsewhere, id: \.id) { threadCard($0) }
                }
                .padding(12)
            }
            ForEach(Array(hunks.enumerated()), id: \.offset) { index, hunk in
                hunkHeader(hunk)
                ForEach(runs(starts[index]..<starts[index] + hunk.lines.count, breaks: breaks), id: \.lowerBound) { run in
                    runView(run, path: file.path, lines: lines, prose: prose)
                    let last = run.upperBound - 1
                    if breaks.contains(last) {
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
    }

    /// `rows`, split after every row in `breaks`.
    private func runs(_ rows: Range<Int>, breaks: Set<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = rows.lowerBound
        for row in rows where breaks.contains(row) {
            out.append(start..<row + 1)
            start = row + 1
        }
        if start < rows.upperBound { out.append(start..<rows.upperBound) }
        return out
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

    /// Line numbers that select, beside code that scrolls sideways rather than wrapping.
    private func runView(_ rows: Range<Int>, path: String, lines: [DiffLine], prose: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(rows, id: \.self) { row in gutterCell(lines[row], row: row, path: path, lines: lines) }
            }
            .frame(width: gutterWidth)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let row = min(max(rows.lowerBound + Int((value.location.y / rowHeight).rounded(.down)), 0), lines.count - 1)
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
            }.onEnded { _ in dragging = false })

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.self) { row in codeCell(lines[row], row: row, path: path, prose: prose) }
                }
                .frame(minWidth: codeWidth, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func tint(_ line: DiffLine) -> Color? {
        switch line.kind {
        case .added: Theme.State.merged
        case .removed: Theme.State.cancelled
        case .context: nil
        }
    }

    private func gutterCell(_ line: DiffLine, row: Int, path: String, lines: [DiffLine]) -> some View {
        let picked = selection?.contains(path, row) == true
        let tint = tint(line)
        let showsPlus = !dragging && (hovered == row || (selection.map { $0.path == path && $0.rows.upperBound == row } ?? false && !composing))
        return HStack(spacing: 0) {
            Text(line.old.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(line.new.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                .foregroundStyle(tint ?? Theme.textFaint)
                .frame(width: 22)
        }
        .foregroundStyle(picked ? Theme.text : Theme.textFaint)
        .frame(height: rowHeight)
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
                    .onTapGesture { startComment(path: path, row: row) }
                    .help("Comment on \(selection?.contains(path, row) == true ? "these lines" : "this line")")
            }
        }
        .zIndex(showsPlus ? 1 : 0)
        .onHover { inside in
            if inside { hovered = row } else if hovered == row { hovered = nil }
        }
    }

    private func codeCell(_ line: DiffLine, row: Int, path: String, prose: Bool) -> some View {
        let picked = selection?.contains(path, row) == true
        return Group {
            if prose { Text(line.text).foregroundStyle(Theme.text) } else { Text(SyntaxHighlighter.highlight(line.text)) }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 12)
        .padding(.trailing, 24)
        .frame(height: rowHeight)
        .frame(minWidth: codeWidth, alignment: .leading)
        .background(picked ? Theme.changeBar.opacity(0.16) : tint(line).map { $0.opacity(0.09) } ?? .clear)
        .onHover { inside in
            if inside { hovered = row } else if hovered == row { hovered = nil }
        }
    }

    /// Files read as text rather than code: no syntax colours, which only scramble prose.
    private static let proseExtensions: Set<String> = ["md", "markdown", "mdx", "txt", "rst", "adoc", ""]

    // MARK: Comments

    private func startComment(path: String, row: Int) {
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
            if count == 0 {
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
    /// `diff:summary:<text>` fills the summary and `diff:submit` submits the review.
    private func playDemo(_ parts: [String]) {
        guard let action = parts.first else { return }
        let argument = parts.dropFirst().joined(separator: ":")
        switch action {
        case "file": if let file = files.first(where: { $0.path == argument }) { pick(file) }
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
        default: break
        }
    }
}
