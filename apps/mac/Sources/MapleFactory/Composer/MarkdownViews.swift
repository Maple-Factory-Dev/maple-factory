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

    init(_ source: String) {
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

    var body: some View {
        let blocks = MarkdownBlock.parse(source)

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
            Text(inline(text))
                .font(.system(size: level == 1 ? baseSize + 9 : level == 2 ? baseSize + 4 : baseSize + 1.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, level <= 2 ? 6 : 2)
        case let .task(checked, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Theme.accent : Theme.textMuted)
                Text(inline(text)).foregroundStyle(Theme.text)
            }
            .font(.system(size: baseSize))
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Theme.textMuted)
                Text(inline(text)).foregroundStyle(Theme.text)
            }
            .font(.system(size: baseSize))
        case let .numbered(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).").foregroundStyle(Theme.textMuted).monospacedDigit()
                Text(inline(text)).foregroundStyle(Theme.text)
            }
            .font(.system(size: baseSize))
        case let .quote(text):
            Text(inline(text))
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
            Text(inline(text))
                .font(.system(size: baseSize))
                .foregroundStyle(Theme.text.opacity(0.9))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Hairline()
        case let .image(alt, path):
            LinkedImage(alt: alt, path: path)
        case let .file(name, path):
            AttachmentChip(name: name, path: path)
        }
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
        return result
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
    @Environment(FactoryClient.self) private var client: FactoryClient?

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
                        })
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
        .onReceive(NotificationCenter.default.publisher(for: Self.demoPreview)) { _ in previewing = true }
    }

    /// `-actions "paste:editor; preview:editor"` (AppState.play): paste the clipboard the way ⌘V does,
    /// and open Preview, for recordings.
    static let demoPaste = Notification.Name("MarkdownEditor.demoPaste")
    static let demoPreview = Notification.Name("MarkdownEditor.demoPreview")

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
