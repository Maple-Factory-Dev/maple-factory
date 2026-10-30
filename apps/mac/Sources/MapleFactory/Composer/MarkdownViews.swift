import SwiftUI

// MARK: - Parsing

/// Just enough Markdown structure for briefs and notes: headings, lists, task lists, quotes, code.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case task(checked: Bool, text: String)
    case bullet(String)
    case numbered(Int, String)
    case quote(String)
    /// A fenced block and its language tag, lowercased (```swift → "swift"), when it has one.
    case code(language: String?, lines: [String])
    case paragraph(String)
    case rule
    /// A line that's just `![alt](path)`: an attachment, or an image on the web.
    case image(alt: String, path: String)
    /// A line that's just `[name](/attachments/…)`: a file attached to the note.
    case file(name: String, path: String)

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: (indent: Int, language: String?, lines: [String])? = nil

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                // Only a bare run of backticks closes the block; "```swift" inside it is code.
                if line.hasPrefix("```"), line.allSatisfy({ $0 == "`" }) {
                    blocks.append(.code(language: open.language, lines: open.lines))
                    fence = nil
                } else {
                    // An indented fence (under a list item, say) indents its lines the same amount.
                    let indent = min(open.indent, raw.prefix(while: { $0 == " " }).count)
                    fence?.lines.append(String(raw.dropFirst(indent)))
                }
                continue
            }
            if line.hasPrefix("```") {
                flush()
                let tag = line.dropFirst(3).split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first
                fence = (raw.prefix(while: { $0 == " " }).count, tag.map { $0.lowercased() }, [])
                continue
            }

            if line.isEmpty { flush(); continue }
            if line == "---" { flush(); blocks.append(.rule); continue }
            if let link = line.wholeMatch(of: /(!?)\[([^\]]*)\]\((\S*)\)/) {
                if !link.1.isEmpty {
                    flush()
                    blocks.append(.image(alt: String(link.2), path: String(link.3)))
                    continue
                }
                if link.3.hasPrefix("/attachments/") {
                    flush()
                    blocks.append(.file(name: String(link.2), path: String(link.3)))
                    continue
                }
            }

            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
               line[hashes] == " " {
                flush()
                let level = line.distance(from: line.startIndex, to: hashes)
                blocks.append(.heading(level: level, text: String(line[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                flush()
                blocks.append(.task(checked: !line.hasPrefix("- [ ]"), text: String(line.dropFirst(6))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]),
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.numbered(number, String(line[line.index(dot, offsetBy: 2)...])))
            } else if line.hasPrefix("> ") {
                flush()
                blocks.append(.quote(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        if let open = fence { blocks.append(.code(language: open.language, lines: open.lines)) }
        flush()
        return blocks
    }
}

/// What the factory understands from a free-form brief: the summary, the acceptance checks, the
/// sensitive areas it's likely to touch, and who it mentions.
struct BriefReading {
    let summary: String
    let doneWhen: [DoneCriterion]
    let areas: [String]
    let mentions: [Person]

    @MainActor init(_ source: String) {
        let blocks = MarkdownBlock.parse(source)

        summary = blocks.compactMap { if case let .paragraph(text) = $0 { text } else { nil } }.first ?? ""

        // Prefer the checklist under a "Done when" heading; fall back to every task-list item.
        var underDoneWhen: [String] = []
        var allTasks: [String] = []
        var inDoneWhen = false
        for block in blocks {
            switch block {
            case let .heading(_, text): inDoneWhen = text.lowercased().contains("done when")
            case let .task(_, text):
                allTasks.append(text)
                if inDoneWhen { underDoneWhen.append(text) }
            case let .bullet(text) where inDoneWhen: underDoneWhen.append(text)
            default: break
            }
        }
        doneWhen = (underDoneWhen.isEmpty ? allTasks : underDoneWhen).map {
            DoneCriterion(text: $0, proof: BriefReading.proofKind(for: $0))
        }

        let lower = source.lowercased()
        let keywords: [(String, [String])] = [
            ("Auth", ["auth", "login", "sign in", "sign-in", "session", "token", "passkey", "sso", "password"]),
            ("Billing", ["billing", "invoice", "stripe", "payment", "subscription", "proration"]),
            ("Migrations", ["migration", "schema", "new table", "add column", "backfill"]),
        ]
        areas = keywords.filter { _, words in words.contains { lower.contains($0) } }.map(\.0)

        mentions = FactoryData.people.filter { person in
            person.github.map { lower.contains("@\($0.lowercased())") } ?? false
        }
    }

    static func proofKind(for text: String) -> DoneCriterion.ProofKind {
        let lower = text.lowercased()
        if ["video", "record", "end to end", "end-to-end", "flow", "walkthrough"].contains(where: lower.contains) { return .video }
        if ["screenshot", "looks", "renders", "shows", "visible", "page"].contains(where: lower.contains) { return .screenshot }
        if ["test", "spec", "suite", "passes"].contains(where: lower.contains) { return .tests }
        return .terminal
    }
}

// MARK: - Preview

struct MarkdownPreview: View {
    let source: String
    var baseSize: CGFloat = 13.5
    /// Images as thumbnails that fit a narrow column (LinkedImage.thumbnail).
    var thumbnails = false
    @Environment(AppState.self) private var appState: AppState?
    private var knownTasks: Set<String> { Set(appState?.tasks.map(\.id) ?? []) }

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        let known = knownTasks

        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty {
                Text("Nothing to preview")
                    .font(.system(size: baseSize))
                    .foregroundStyle(Theme.textFaint)
            }
            // Runs of list items sit closer together than the paragraphs around them.
            ForEach(Array(Self.grouped(blocks).enumerated()), id: \.offset) { _, group in
                if group.count == 1 {
                    view(for: group[0])
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(group.enumerated()), id: \.offset) { _, block in
                            view(for: block)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { open($0, known: known) })
        .onReceive(NotificationCenter.default.publisher(for: TaskRefQuery.demoOpen)) { note in
            // `openref:<id>` (AppState.play): what clicking that reference here does, for recordings.
            guard let id = note.userInfo?["id"] as? String, source.contains(id), let url = TaskRefQuery.url(id) else { return }
            _ = open(url, known: known)
        }
    }

    /// A known task's reference opens it in the panel; other links open as they always have.
    private func open(_ url: URL, known: Set<String>) -> OpenURLAction.Result {
        guard let id = TaskRefQuery.id(from: url) else { return .systemAction }
        if known.contains(id) { appState?.openReference(id) }
        return .handled
    }

    private static func grouped(_ blocks: [MarkdownBlock]) -> [[MarkdownBlock]] {
        func isListItem(_ block: MarkdownBlock) -> Bool {
            switch block {
            case .bullet, .numbered, .task: true
            default: false
            }
        }
        var groups: [[MarkdownBlock]] = []
        for block in blocks {
            if isListItem(block), let last = groups.last?.last, isListItem(last) {
                groups[groups.count - 1].append(block)
            } else {
                groups.append([block])
            }
        }
        return groups
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            let size = level == 1 ? baseSize + 9 : level == 2 ? baseSize + 4 : baseSize + 1.5
            let rendered = inline(text)
            Text(rendered)
                .font(.system(size: size, weight: .semibold))
                .taskRefHover(rendered, size: size, weight: .semibold, known: knownTasks)
                .foregroundStyle(Theme.text)
                .padding(.top, level <= 2 ? 6 : 2)
        case let .task(checked, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Theme.accent : Theme.textMuted)
                hoverable(inline(text)).foregroundStyle(Theme.text)
            }
            .font(.system(size: baseSize))
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Theme.textMuted)
                hoverable(inline(text)).foregroundStyle(Theme.text)
            }
            .font(.system(size: baseSize))
        case let .numbered(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).").foregroundStyle(Theme.textMuted).monospacedDigit()
                hoverable(inline(text)).foregroundStyle(Theme.text)
            }
            .font(.system(size: baseSize))
        case let .quote(text):
            hoverable(inline(text))
                .font(.system(size: baseSize))
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.fillSelected).frame(width: 3) }
        case let .code(language, lines):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlight(lines.joined(separator: "\n"), language: language))
                    .font(.system(size: baseSize - 1.5, design: .monospaced))
                    .foregroundStyle(Theme.Syntax.plain)
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.top, language == nil ? 10 : 24)
                    .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill))
            .overlay(alignment: .topTrailing) {
                if let language {
                    Text(language)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 9)
                        .padding(.top, 6)
                }
            }
        case let .paragraph(text):
            let rendered = inline(text)
            Text(rendered)
                .font(.system(size: baseSize))
                .foregroundStyle(Theme.text.opacity(0.9))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .taskRefHover(rendered, size: baseSize, lineSpacing: 4, known: knownTasks)
        case .rule:
            Hairline()
        case let .image(alt, path):
            LinkedImage(alt: alt, path: path, thumbnail: thumbnails)
        case let .file(name, path):
            AttachmentChip(name: name, path: path)
        }
    }

    /// Body-size inline text whose task references show a preview card on hover (TaskRefHover).
    private func hoverable(_ text: AttributedString) -> some View {
        Text(text).taskRefHover(text, size: baseSize, known: knownTasks)
    }

    private func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].backgroundColor = Theme.fill
            }
            // Only web and mail links open; anything else (javascript:, file:) stays plain text.
            if let url = run.link, !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                result[run.range].link = nil
            }
        }
        for person in FactoryData.people {
            guard let handle = person.github else { continue }
            var rest = result.startIndex..<result.endIndex
            while let range = result[rest].range(of: "@\(handle)") {
                result[range].foregroundColor = Theme.mention
                result[range].inlinePresentationIntent = .stronglyEmphasized
                rest = range.upperBound..<result.endIndex
            }
        }
        Self.linkTasks(in: &result, known: knownTasks)
        return result
    }

    /// Gives each known task ID (TaskRefQuery.references) a `maple-task://` link and the mention-style
    /// accent; not inside code or an existing link.
    static func linkTasks(in result: inout AttributedString, known: Set<String>) {
        let plain = String(result.characters)
        for ref in TaskRefQuery.references(in: plain, known: known) {
            guard let span = Range<AttributedString.Index>(ref.range, in: result) else { continue }
            if result[span].runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) { continue }
            result[span].link = TaskRefQuery.url(ref.id)
            result[span].foregroundColor = Theme.accent
            result[span].inlinePresentationIntent = .stronglyEmphasized
        }
    }
}

// MARK: - Editor

/// A GitHub-issue-style editor: Write/Preview tabs and a toolbar that wraps the current selection.
struct MarkdownEditor: View {
    @Binding var text: String
    var placeholder = "Write in Markdown…"
    var minHeight: CGFloat = 320

    @State private var previewing = false
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var mention = MentionState()
    @State private var taskRef = MentionState()
    @Environment(FactoryClient.self) private var client: FactoryClient?
    @Environment(AppState.self) private var appState: AppState?

    private var mentionQuery: MentionQuery? {
        previewing || selection.length > 0 ? nil : mention.query(text, cursor: selection.location)
    }
    private var mentionCandidates: [Person] {
        mentionQuery.map { MentionQuery.matches(FactoryData.people, $0.query) } ?? []
    }
    private var taskQuery: TaskRefQuery? {
        previewing || selection.length > 0 ? nil : taskRef.taskQuery(text, cursor: selection.location)
    }
    private var taskCandidates: [FactoryTask] {
        taskQuery.map { TaskRefQuery.matches(appState?.tasks ?? [], $0.query) } ?? []
    }

    private enum Format {
        case heading, bold, italic, code, link, bullet, numbered, task, quote, mention
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                tab("Write", active: !previewing) { previewing = false }
                tab("Preview", active: previewing) { previewing = true }
                Spacer()
                if !previewing { toolbar }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(Theme.fillSubtle)
            .overlay(alignment: .bottom) { Hairline() }

            Group {
                if previewing {
                    ScrollView {
                        MarkdownPreview(source: text)
                            .padding(16)
                    }
                } else {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Theme.textFaint)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                        // Signed in, pasted and dropped files go up to the factory; the mockup keeps
                        // the text view's own paste.
                        MarkdownTextView(text: $text, selection: $selection, upload: client.flatMap { client in
                            client.isSignedIn ? { file in try await client.upload(data: file.data, filename: file.name, mime: file.mime) } : nil
                        }, onKey: { mentionKey($0) || taskKey($0) })
                    }
                }
            }
            .frame(minHeight: minHeight)

            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 10.5))
                Text("Paste or drop screenshots, logs and files")
                Spacer()
                Image(systemName: "m.square").font(.system(size: 11))
                Text("Markdown supported")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .overlay(alignment: .top) { Hairline() }
        }
        .background(Theme.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        // The teammates to @mention, just under the text.
        .overlay(alignment: .bottomLeading) {
            let candidates = mentionCandidates
            if !candidates.isEmpty {
                MentionPicker(people: candidates, highlighted: min(mention.highlighted, candidates.count - 1), pick: pickMention)
                    .offset(y: MentionPicker.height(candidates.count) - 34)
                    .padding(.leading, 12)
            }
        }
        // The tasks to reference after a `#`, in the same place.
        .overlay(alignment: .bottomLeading) {
            let candidates = taskCandidates
            if !candidates.isEmpty {
                TaskRefPicker(tasks: candidates, highlighted: min(taskRef.highlighted, candidates.count - 1), pick: pickTask)
                    .offset(y: TaskRefPicker.height(candidates.count) - 34)
                    .padding(.leading, 12)
            }
        }
        .zIndex(mentionCandidates.isEmpty && taskCandidates.isEmpty ? 0 : 1)
        .onChange(of: mentionQuery?.range.location) { mention.highlighted = 0 }
        .onChange(of: taskQuery?.range.location) { taskRef.highlighted = 0 }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoPreview)) { _ in previewing = true }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoType)) { note in
            previewing = false
            text += note.userInfo?["text"] as? String ?? ""
            selection = NSRange(location: (text as NSString).length, length: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: MentionKey.demo)) { note in
            if let key = note.object as? MentionKey { _ = mentionKey(key) || taskKey(key) }
        }
    }

    private func mentionKey(_ key: MentionKey) -> Bool {
        let candidates = mentionCandidates
        guard mention.handle(key, query: mentionQuery, count: candidates.count) else { return false }
        if key == .pick { pickMention(candidates[min(mention.highlighted, candidates.count - 1)]) }
        return true
    }

    private func pickMention(_ person: Person) {
        guard let query = mentionQuery else { return }
        let out = query.inserting(person, into: text)
        text = out.text
        selection = NSRange(location: out.cursor, length: 0)
    }

    private func taskKey(_ key: MentionKey) -> Bool {
        let candidates = taskCandidates
        guard taskRef.handle(key, query: taskQuery, count: candidates.count) else { return false }
        if key == .pick { pickTask(candidates[min(taskRef.highlighted, candidates.count - 1)]) }
        return true
    }

    private func pickTask(_ task: FactoryTask) {
        guard let query = taskQuery else { return }
        let out = query.inserting(task, into: text)
        text = out.text
        selection = NSRange(location: out.cursor, length: 0)
    }

    /// `-actions "paste:editor; preview:editor"` (AppState.play): paste the clipboard the way ⌘V does,
    /// and open Preview, for recordings.
    static let demoPaste = Notification.Name("MarkdownEditor.demoPaste")
    static let demoPreview = Notification.Name("MarkdownEditor.demoPreview")
    /// `-actions "type:See #ATL"`: types at the end of the editor, for recordings.
    static let demoType = Notification.Name("MarkdownEditor.demoType")

    private func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? Theme.text : Theme.textMuted)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.cardBG : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Theme.stroke : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private var toolbar: some View {
        HStack(spacing: 1) {
            toolButton("textformat.size", .heading, "Heading")
            toolButton("bold", .bold, "Bold")
            toolButton("italic", .italic, "Italic")
            toolButton("chevron.left.forwardslash.chevron.right", .code, "Code")
            toolButton("link", .link, "Link")
            divider
            toolButton("list.bullet", .bullet, "Bulleted list")
            toolButton("list.number", .numbered, "Numbered list")
            toolButton("checklist", .task, "Task list")
            toolButton("text.quote", .quote, "Quote")
            divider
            toolButton("at", .mention, "Mention")
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 16).padding(.horizontal, 4)
    }

    private func toolButton(_ icon: String, _ format: Format, _ help: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .onTapGesture { apply(format) }
            .help(help)
    }

    /// Wraps the selection (or inserts at the cursor) the way GitHub's issue editor does.
    private func apply(_ format: Format) {
        let range = Range(selection, in: text) ?? text.endIndex..<text.endIndex
        let selected = String(text[range])
        let atLineStart = range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] == "\n"
        let lineBreak = atLineStart ? "" : "\n"

        let replacement: String = switch format {
        case .heading: "\(lineBreak)## \(selected.isEmpty ? "Heading" : selected)"
        case .bold: "**\(selected.isEmpty ? "bold" : selected)**"
        case .italic: "_\(selected.isEmpty ? "italic" : selected)_"
        case .code: selected.contains("\n") ? "\n```\n\(selected)\n```\n" : "`\(selected.isEmpty ? "code" : selected)`"
        case .link: "[\(selected.isEmpty ? "title" : selected)](https://)"
        case .bullet: "\(lineBreak)- \(selected)"
        case .numbered: "\(lineBreak)1. \(selected)"
        case .task: "\(lineBreak)- [ ] \(selected)"
        case .quote: "\(lineBreak)> \(selected)"
        case .mention: "@"
        }

        let start = NSRange(range, in: text).location
        text.replaceSubrange(range, with: replacement)
        selection = NSRange(location: start + (replacement as NSString).length, length: 0)
    }
}

// MARK: - @mentions

/// The `@name` being typed just before the cursor, for the teammate picker. Not after a word
/// character, so `a@b.com` doesn't start one.
struct MentionQuery: Equatable {
    /// The `@` and what's typed after it, as UTF-16 offsets (what NSTextView's selection uses).
    let range: NSRange
    let query: String

    static func at(_ text: String, cursor: Int) -> MentionQuery? {
        let ns = text as NSString
        guard cursor <= ns.length else { return nil }
        let before = ns.substring(to: cursor) as NSString
        let regex = try! NSRegularExpression(pattern: #"(?:^|[^\w.@/-])@([A-Za-z0-9-]{0,39})$"#)
        guard let match = regex.firstMatch(in: before as String, range: NSRange(location: 0, length: before.length)) else { return nil }
        let name = match.range(at: 1)
        return MentionQuery(range: NSRange(location: name.location - 1, length: name.length + 1), query: before.substring(with: name))
    }

    /// Teammates whose login or name starts with the query (logins first), then ones that contain it.
    static func matches(_ people: [Person], _ query: String, limit: Int = 6) -> [Person] {
        let q = query.lowercased()
        func score(_ p: Person) -> Int? {
            let login = (p.github ?? "").lowercased()
            let name = p.name.lowercased()
            if login.hasPrefix(q) { return 0 }
            if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 1 }
            return login.contains(q) || name.contains(q) ? 2 : nil
        }
        let scored: [(score: Int, login: String, person: Person)] = people.compactMap { p in
            guard p.isHuman, let login = p.github, let s = score(p) else { return nil }
            return (s, login, p)
        }
        let sorted = scored.sorted { $0.score != $1.score ? $0.score < $1.score : $0.login < $1.login }
        return sorted.prefix(limit).map(\.person)
    }

    /// The text with the `@query` swapped for `@login `, and where the cursor goes after it.
    func inserting(_ person: Person, into text: String) -> (text: String, cursor: Int) {
        let insert = "@\(person.github ?? person.name) "
        let replaced = (text as NSString).replacingCharacters(in: range, with: insert)
        return (replaced, range.location + (insert as NSString).length)
    }
}

/// The keys the picker takes while it's open.
enum MentionKey {
    case up, down, pick, close

    /// `-actions "pickerkey:pick"` (AppState.play): presses the key in whichever picker is open, for recordings.
    static let demo = Notification.Name("MentionKey.demo")
}

/// A popover-style list of teammates to mention; the highlighted one is what Return or Tab picks.
struct MentionPicker: View {
    let people: [Person]
    let highlighted: Int
    let pick: (Person) -> Void

    /// How tall it is with this many rows, to place it beside a box without measuring.
    static func height(_ rows: Int) -> CGFloat { CGFloat(rows) * 31 - 1 + 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                HStack(spacing: 8) {
                    AgentAvatar(agent: person, size: 20)
                    Text(person.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text("@\(person.github ?? "")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(index == highlighted ? Theme.accent.opacity(0.16) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { pick(person) }
            }
        }
        .padding(4)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBG))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
    }
}

/// What a text box needs to offer the picker: what's being typed after an `@`, who matches it, and
/// which one is highlighted. Kept in the box's @State.
struct MentionState {
    var highlighted = 0
    var dismissedAt: Int?

    func query(_ text: String, cursor: Int) -> MentionQuery? {
        guard let query = MentionQuery.at(text, cursor: cursor), query.range.location != dismissedAt else { return nil }
        return query
    }

    /// Moves the highlight or closes; `pick` is the caller's. False when the picker isn't taking the key.
    mutating func handle(_ key: MentionKey, query: MentionQuery?, count: Int) -> Bool {
        handle(key, at: query?.range.location, count: count)
    }

    /// The picker open at `location` (its trigger character's offset), or nil when there's none.
    mutating func handle(_ key: MentionKey, at location: Int?, count: Int) -> Bool {
        guard let location, count > 0 else { return false }
        switch key {
        case .up: highlighted = (highlighted - 1 + count) % count
        case .down: highlighted = (highlighted + 1) % count
        case .close: dismissedAt = location
        case .pick: break
        }
        return true
    }
}

// MARK: - Task references

/// The `#ref` being typed just before the cursor, for the task picker: MentionQuery with `#`. Not after
/// a word character or `/`, so `a#b` and `example.com/page#top` don't start one.
struct TaskRefQuery: Equatable {
    /// The `#` and what's typed after it, as UTF-16 offsets (what NSTextView's selection uses).
    let range: NSRange
    let query: String

    static func at(_ text: String, cursor: Int) -> TaskRefQuery? {
        let ns = text as NSString
        guard cursor <= ns.length else { return nil }
        let before = ns.substring(to: cursor) as NSString
        let regex = try! NSRegularExpression(pattern: #"(?:^|[^\w.#/&-])#([A-Za-z0-9-]{0,39})$"#)
        guard let match = regex.firstMatch(in: before as String, range: NSRange(location: 0, length: before.length)) else { return nil }
        let ref = match.range(at: 1)
        return TaskRefQuery(range: NSRange(location: ref.location - 1, length: ref.length + 1), query: before.substring(with: ref))
    }

    /// The task whose ID is the query, then IDs that start with it, then a title word that does, then
    /// anywhere; newest first within each, like the web's matchTasks.
    static func matches(_ tasks: [FactoryTask], _ query: String, limit: Int = 6) -> [FactoryTask] {
        let q = query.lowercased()
        func score(_ t: FactoryTask) -> Int? {
            let id = t.id.lowercased()
            let title = t.title.lowercased()
            if id == q { return 0 }
            if id.hasPrefix(q) { return 1 }
            if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).contains(where: { $0.hasPrefix(q) }) { return 2 }
            return id.contains(q) || title.contains(q) ? 3 : nil
        }
        func number(_ t: FactoryTask) -> Int { Int(t.id.split(separator: "-").last ?? "") ?? 0 }
        let scored = tasks.compactMap { t in score(t).map { (score: $0, task: t) } }
        let sorted = scored.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            if number($0.task) != number($1.task) { return number($0.task) > number($1.task) }
            return $0.task.id < $1.task.id
        }
        return sorted.prefix(limit).map(\.task)
    }

    /// The text with the `#query` swapped for the task's plain ID and a space, and where the cursor goes.
    func inserting(_ task: FactoryTask, into text: String) -> (text: String, cursor: Int) {
        let insert = "\(task.id) "
        let replaced = (text as NSString).replacingCharacters(in: range, with: insert)
        return (replaced, range.location + (insert as NSString).length)
    }

    /// Where `text` names one of `known`'s task IDs, bare (`MF-12`) or after a `#`, word-bounded, so
    /// `UTF-8` (unknown) and `XMF-12` or `MF-12-b` (not on their own) aren't. Ranges include the `#`.
    static func references(in text: String, known: Set<String>) -> [(range: NSRange, id: String)] {
        guard !known.isEmpty else { return [] }
        let regex = try! NSRegularExpression(pattern: #"(?<![\w#-])#?([A-Z][A-Z0-9]*-\d+)(?![\w-])"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let id = ns.substring(with: match.range(at: 1))
            return known.contains(id) ? (match.range, id) : nil
        }
    }

    /// The reference (references(in:known:)) covering a UTF-16 offset, for hovering rendered Markdown.
    static func reference(at characterIndex: Int, in text: String, known: Set<String>) -> (range: NSRange, id: String)? {
        references(in: text, known: known).first { NSLocationInRange(characterIndex, $0.range) }
    }

    /// `-actions "openref:ATL-150"` (AppState.play): clicks that reference in rendered Markdown.
    static let demoOpen = Notification.Name("TaskRefQuery.demoOpen")

    /// The link a reference gets in rendered Markdown; MarkdownPreview opens it in the task panel.
    static let scheme = "maple-task"
    static func url(_ id: String) -> URL? { URL(string: "\(scheme)://\(id)") }
    static func id(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let id = url.absoluteString.dropFirst(scheme.count + 3)
        return id.isEmpty ? nil : String(id)
    }
}

/// A popover-style list of tasks to reference: the ID, a dot in its state's color, and its title.
struct TaskRefPicker: View {
    let tasks: [FactoryTask]
    let highlighted: Int
    let pick: (FactoryTask) -> Void

    static func height(_ rows: Int) -> CGFloat { MentionPicker.height(rows) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                HStack(spacing: 8) {
                    Circle().fill(task.state.color).frame(width: 7, height: 7)
                        .help(task.state.title)
                    Text(task.id)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                    Text(task.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(index == highlighted ? Theme.accent.opacity(0.16) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { pick(task) }
            }
        }
        .padding(4)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBG))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
    }
}

extension MentionState {
    /// What's being typed after a `#`, unless the picker was closed there.
    func taskQuery(_ text: String, cursor: Int) -> TaskRefQuery? {
        guard let query = TaskRefQuery.at(text, cursor: cursor), query.range.location != dismissedAt else { return nil }
        return query
    }

    /// `handle` for the task picker.
    mutating func handle(_ key: MentionKey, query: TaskRefQuery?, count: Int) -> Bool {
        handle(key, at: query?.range.location, count: count)
    }
}
