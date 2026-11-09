import Foundation

// MARK: - Parsing

/// How a table column lines its cells up, from the delimiter row (`:--`, `:-:`, `--:`).
public enum TableAlignment: Equatable, Sendable {
    case leading, center, trailing
}

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
    /// A GFM table: the header's cells, each column's alignment, and the body rows padded or cut to
    /// the header's width. Cells are inline Markdown.
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])

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

        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
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
            // A pipe line followed by a delimiter row with as many cells starts a table, even
            // straight after a paragraph; each pipe line after it is a row, until one isn't.
            if let header = tableCells(line), index < lines.count,
               let alignments = tableDelimiter(lines[index].trimmingCharacters(in: .whitespaces)),
               alignments.count == header.count {
                flush()
                index += 1
                var rows: [[String]] = []
                while index < lines.count,
                      let cells = tableCells(lines[index].trimmingCharacters(in: .whitespaces)) {
                    let fitted = Array(cells.prefix(header.count))
                    rows.append(fitted + Array(repeating: "", count: header.count - fitted.count))
                    index += 1
                }
                blocks.append(.table(header: header, alignments: alignments, rows: rows))
                continue
            }
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

    /// A line's table cells, split on unescaped pipes with the outer pipes trimmed (`\|` is a
    /// literal pipe), or nil when it has no pipe to split on.
    static func tableCells(_ line: String) -> [String]? {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var split = line.hasPrefix("|") || (line.hasSuffix("|") && !line.hasSuffix("\\|"))
        for character in body {
            if escaped {
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                split = true
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return split ? cells : nil
    }

    /// A delimiter row's column alignments (`|---|:--:|--:|`), or nil when it isn't one.
    static func tableDelimiter(_ line: String) -> [TableAlignment]? {
        guard line.contains("|"), let cells = tableCells(line), !cells.isEmpty else { return nil }
        var alignments: [TableAlignment] = []
        for cell in cells {
            guard cell.wholeMatch(of: /:?-+:?/) != nil else { return nil }
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return alignments
    }
}
