import MapleKit
import SwiftUI

/// Markdown as the Mac's MarkdownPreview shows it, for comments, change requests and briefs: headings,
/// lists and task lists, quotes, code blocks and rules, with inline bold, italic, code and links.
/// Attached images and files (`![name](path)`, `[name](/attachments/…)`) go through AttachmentGallery, as
/// the brief's do: each run of them is one grid of thumbnails that open the viewer, inline videos and
/// Quick Look chips.
struct MarkdownText: View {
    let source: String
    var font: Font = .callout

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.grouped(blocks).enumerated()), id: \.offset) { _, group in
                if let attachments = Self.attachments(group) {
                    AttachmentGallery(attachments: attachments)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(group.enumerated()), id: \.offset) { _, block in view(for: block) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Runs of list items sit closer together than the paragraphs around them; a run of attachments
    /// becomes one gallery.
    private static func grouped(_ blocks: [MarkdownBlock]) -> [[MarkdownBlock]] {
        func isListItem(_ block: MarkdownBlock) -> Bool {
            switch block {
            case .bullet, .numbered, .task: true
            default: false
            }
        }
        var groups: [[MarkdownBlock]] = []
        for block in blocks {
            if let last = groups.last?.last,
               (isListItem(block) && isListItem(last)) || (attachment(block) != nil && attachment(last) != nil) {
                groups[groups.count - 1].append(block)
            } else {
                groups.append([block])
            }
        }
        return groups
    }

    /// An image or file block as the gallery shows it.
    private static func attachment(_ block: MarkdownBlock) -> LinkedAttachment? {
        switch block {
        case let .image(alt, path): LinkedAttachment(name: alt, path: path, image: true)
        case let .file(name, path): LinkedAttachment(name: name, path: path, image: false)
        default: nil
        }
    }

    /// A group that is all attachments, or nil.
    private static func attachments(_ group: [MarkdownBlock]) -> [LinkedAttachment]? {
        let attachments = group.compactMap(attachment)
        return attachments.count == group.count && !attachments.isEmpty ? attachments : nil
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
        case .image, .file:
            EmptyView() // Drawn by AttachmentGallery, as its group.
        case let .table(header, alignments, rows):
            table(header: header, alignments: alignments, rows: rows)
        }
    }

    /// A bordered grid that scrolls sideways when it's wider than the screen: a semibold header on a
    /// faint fill, dividers between rows, each column aligned as its delimiter row says.
    private func table(header: [String], alignments: [TableAlignment], rows: [[String]]) -> some View {
        func alignment(_ column: Int) -> HorizontalAlignment {
            switch alignments.indices.contains(column) ? alignments[column] : .leading {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }
        func cell(_ text: String, column: Int, header: Bool) -> some View {
            Text(Self.inline(text))
                .font(font.weight(header ? .semibold : .regular))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 36, maxWidth: 280, alignment: Alignment(horizontal: alignment(column), vertical: .center))
                .gridColumnAlignment(alignment(column))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, text in
                        cell(text, column: column, header: true)
                    }
                }
                .background(.quaternary.opacity(0.6))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                            cell(text, column: column, header: false)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .padding(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("markdown.table")
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
