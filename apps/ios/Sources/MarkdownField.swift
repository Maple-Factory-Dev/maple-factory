import SwiftUI

/// A Markdown text field: Write/Preview, a formatting bar (bold, italic, code, list, checklist, quote,
/// link) that wraps the selection or inserts at the cursor, and the editor. `previewSource` is what
/// Preview renders, when it's more than the text (ComposeSheet adds its attachments' links).
struct MarkdownField: View {
    let placeholder: String
    @Binding var text: String
    let identifier: String
    var minHeight: CGFloat = 140
    var previewSource: String?
    var focused: FocusState<Bool>.Binding?
    @State private var selection: TextSelection?
    @State private var previewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Mode", selection: $previewing) {
                    Text("Write").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
                .accessibilityIdentifier("\(identifier).mode")
                Spacer(minLength: 0)
            }
            if previewing {
                let source = previewSource ?? text
                Group {
                    if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Nothing to preview").foregroundStyle(.secondary).font(.callout)
                    } else {
                        MarkdownText(source: source)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("\(identifier).preview")
            } else {
                formattingBar
                editor
                    .frame(minHeight: minHeight)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier(identifier)
            }
        }
    }

    @ViewBuilder private var editor: some View {
        if let focused {
            TextEditor(text: $text, selection: $selection).focused(focused)
        } else {
            TextEditor(text: $text, selection: $selection)
        }
    }

    private var formattingBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                button("Bold", "bold") { wrap("**", "**", placeholder: "bold") }
                button("Italic", "italic") { wrap("_", "_", placeholder: "italic") }
                button("Code", "chevron.left.forwardslash.chevron.right") { wrap("`", "`", placeholder: "code") }
                button("List", "list.bullet") { prefixLines("- ") }
                button("Checklist", "checklist") { prefixLines("- [ ] ") }
                button("Quote", "text.quote") { prefixLines("> ") }
                button("Link", "link") { wrap("[", "](https://)", placeholder: "link") }
            }
        }
        .accessibilityIdentifier("\(identifier).format")
    }

    private func button(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 34, height: 30)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
        .accessibilityIdentifier("format.\(label.lowercased())")
    }

    /// The selection, or the cursor (the end, when the editor hasn't had one), as offsets into the text.
    private var selectedOffsets: Range<Int> {
        let end = text.count
        guard case let .selection(range) = selection?.indices,
              range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else { return end..<end }
        return text.distance(from: text.startIndex, to: range.lowerBound)..<text.distance(from: text.startIndex, to: range.upperBound)
    }

    private func index(_ offset: Int) -> String.Index { text.index(text.startIndex, offsetBy: min(offset, text.count)) }

    /// `**selection**`, or `**bold**` at the cursor with "bold" selected to type over.
    func wrap(_ open: String, _ close: String, placeholder: String) {
        let offsets = selectedOffsets
        let range = index(offsets.lowerBound)..<index(offsets.upperBound)
        let selected = String(text[range])
        let inner = selected.isEmpty ? placeholder : selected
        text.replaceSubrange(range, with: open + inner + close)
        let start = offsets.lowerBound + open.count
        selection = TextSelection(range: index(start)..<index(start + inner.count))
    }

    /// Puts `prefix` at the start of each selected line (the cursor's line, or a new one).
    func prefixLines(_ prefix: String) {
        let offsets = selectedOffsets
        let lower = index(offsets.lowerBound)
        var lineStart = text[..<lower].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        if offsets.isEmpty, lower == text.endIndex, lineStart != lower {
            // At the end of a line with text: start a new line for the item.
            text += "\n"
            lineStart = text.endIndex
        }
        let start = text.distance(from: text.startIndex, to: lineStart)
        let upper = index(max(offsets.upperBound, start))
        let lineEnd = text[upper...].firstIndex(of: "\n") ?? text.endIndex
        let lines = text[lineStart..<lineEnd].components(separatedBy: "\n").map { prefix + $0 }.joined(separator: "\n")
        text.replaceSubrange(lineStart..<lineEnd, with: lines)
        let cursor = index(start + lines.count)
        selection = TextSelection(insertionPoint: cursor)
    }
}
