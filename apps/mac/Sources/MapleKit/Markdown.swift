import Foundation

// MARK: - Parsing

/// Just enough Markdown structure for briefs and notes: headings, lists, task lists, quotes, code.
public enum MarkdownBlock: Equatable, Sendable {
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

    public static func parse(_ source: String) -> [MarkdownBlock] {
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

