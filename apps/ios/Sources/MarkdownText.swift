import MapleKit
import SwiftUI

/// Markdown as the Mac's MarkdownPreview shows it, for comments, change requests and briefs: headings,
/// lists and task lists, quotes, code blocks and rules, with inline bold, italic, code and links.
/// Attached images (`![name](/attachments/…)`) show as thumbnails that open full size; attached files as
/// a paperclip row.
struct MarkdownText: View {
    let source: String
    var font: Font = .callout

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.grouped(blocks).enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(group.enumerated()), id: \.offset) { _, block in view(for: block) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Runs of list items sit closer together than the paragraphs around them.
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
            Text(Self.inline(text))
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)
        case let .task(checked, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Theme.accent : .secondary)
                Text(Self.inline(text))
            }
            .font(font)
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(Self.inline(text))
            }
            .font(font)
        case let .numbered(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                Text(Self.inline(text))
            }
            .font(font)
        case let .quote(text):
            Text(Self.inline(text))
                .font(font)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case let .code(_, lines):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.footnote, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
            .accessibilityIdentifier("markdown.code")
        case let .paragraph(text):
            Text(Self.inline(text)).font(font).fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        case let .image(alt, path):
            AttachmentImage(alt: alt, path: path)
        case let .file(name, path):
            AttachmentFileRow(name: name, path: path)
        }
    }

    /// Inline bold, italic, code and links. Only web and mail links stay links.
    static func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].font = .system(.callout, design: .monospaced)
            }
            if let url = run.link, !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                result[run.range].link = nil
            }
        }
        return result
    }
}

/// An image in Markdown: an attachment loaded with your token (the app's mark stands in for it in the
/// demo, which stores nothing), or one on the web. A thumbnail that opens full screen.
struct AttachmentImage: View {
    @Environment(FactoryStore.self) private var store
    let alt: String
    let path: String
    @State private var image: UIImage?
    @State private var failed = false
    @State private var expanded = false

    var body: some View {
        Button { expanded = image != nil } label: {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        if failed { Image(systemName: "photo").foregroundStyle(.secondary) } else { ProgressView() }
                    }
                }
            }
            .frame(width: 160, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        .accessibilityIdentifier("markdown.image")
        .task(id: path) { await load() }
        .fullScreenCover(isPresented: $expanded) {
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let image { Image(uiImage: image).resizable().scaledToFit() }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { expanded = false } } }
                .navigationTitle(alt)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func load() async {
        if store.status == .demo, path.hasPrefix("/attachments/") {
            image = UIImage(named: "Mark")
            return
        }
        let data: Data?
        if path.hasPrefix("/") {
            data = await store.attachment(path)
        } else if let url = URL(string: path), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            data = try? await URLSession.shared.data(from: url).0
        } else {
            data = nil
        }
        image = data.flatMap(UIImage.init(data:))
        failed = image == nil
    }
}

/// A file attached in Markdown (`[name](/attachments/…)`): a paperclip row with its name.
struct AttachmentFileRow: View {
    let name: String
    let path: String

    var body: some View {
        Label(name, systemImage: "paperclip")
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
            .accessibilityIdentifier("markdown.file")
    }
}
