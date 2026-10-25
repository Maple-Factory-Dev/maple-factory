import SwiftUI

/// A deliberately tiny TSX highlighter — just enough to make the mockup read like real code.
enum SyntaxHighlighter {
    private static let keywords: Set<String> = [
        "import", "from", "export", "function", "const", "let", "type", "return", "if", "else",
    ]
    private static let primitives: Set<String> = ["string", "number", "boolean", "void"]

    static func highlight(_ line: String, squiggle: String? = nil) -> AttributedString {
        var out = AttributedString()
        let chars = Array(line)
        var i = 0

        func append(_ range: Range<Int>, _ color: Color) {
            var piece = AttributedString(String(chars[range]))
            piece.foregroundColor = color
            out += piece
        }
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

        while i < chars.count {
            let c = chars[i]

            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != c { j += 1 }
                j = min(j + 1, chars.count)
                append(i..<j, Theme.Syntax.string)
                i = j
            } else if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < chars.count, isIdent(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                let next: Character? = j < chars.count ? chars[j] : nil
                let afterNext: Character? = j + 1 < chars.count ? chars[j + 1] : nil

                let opensTag = i >= 1 && chars[i - 1] == "<" && (i < 2 || !isIdent(chars[i - 2]))
                let closesTag = i >= 2 && chars[i - 1] == "/" && chars[i - 2] == "<"

                let color: Color
                if keywords.contains(word) { color = Theme.Syntax.keyword }
                else if primitives.contains(word) { color = Theme.Syntax.type }
                else if opensTag || closesTag { color = word.first!.isUppercase ? Theme.Syntax.function : Theme.Syntax.tag }
                else if next == "=", afterNext != "=", afterNext != ">" { color = Theme.Syntax.attribute }
                else if next == "(" || next == "<" { color = Theme.Syntax.function }
                else if word.first!.isUppercase { color = Theme.Syntax.function }
                else { color = Theme.Syntax.plain }
                append(i..<j, color)
                i = j
            } else if c.isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                append(i..<j, Theme.Syntax.number)
                i = j
            } else if c.isWhitespace {
                append(i..<(i + 1), Theme.Syntax.plain)
                i += 1
            } else {
                append(i..<(i + 1), Theme.Syntax.punctuation)
                i += 1
            }
        }

        if let squiggle, let range = out.range(of: squiggle) {
            out[range].underlineStyle = Text.LineStyle(pattern: .solid, color: Theme.warning)
        }
        return out
    }
}
