import SwiftUI

/// A small token-based highlighter for fenced code in Markdown: keywords, strings, numbers and
/// comments, enough to make a snippet in a comment readable. Unknown languages stay plain.
enum CodeHighlighter {
    enum Token: Equatable {
        case plain, keyword, string, number, comment, type, added, removed, meta
    }

    struct Grammar {
        var keywords: Set<String>
        var lineComments: [String]
        var blockComment: (open: String, close: String)? = nil
        var quotes: Set<Character> = ["\"", "'"]
        /// Capitalized identifiers read as types (Swift, TypeScript, Go).
        var capitalizedTypes = false
    }

    static func highlight(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString()
        for (text, token) in tokens(code, language: language) {
            var piece = AttributedString(text)
            if token != .plain { piece.foregroundColor = color(token) }
            result += piece
        }
        return result
    }

    static func tokens(_ code: String, language: String?) -> [(String, Token)] {
        let language = language?.lowercased()
        if language == "diff" || language == "patch" { return diff(code) }
        guard let grammar = grammar(for: language) else { return [(code, .plain)] }

        let chars = Array(code)
        var out: [(String, Token)] = []
        var i = 0

        func emit(_ end: Int, _ token: Token) {
            let text = String(chars[i..<end])
            if let last = out.last, last.1 == token {
                out[out.count - 1].0 += text
            } else {
                out.append((text, token))
            }
            i = end
        }
        func starts(_ prefix: String, at index: Int) -> Bool {
            let p = Array(prefix)
            return index + p.count <= chars.count && Array(chars[index..<index + p.count]) == p
        }
        func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

        while i < chars.count {
            let c = chars[i]
            if grammar.lineComments.contains(where: { starts($0, at: i) }) {
                emit(chars[i...].firstIndex(of: "\n") ?? chars.count, .comment)
            } else if let block = grammar.blockComment, starts(block.open, at: i) {
                var j = i + block.open.count
                while j < chars.count, !starts(block.close, at: j) { j += 1 }
                emit(min(j + block.close.count, chars.count), .comment)
            } else if grammar.quotes.contains(c) {
                // Strings end at their closing quote or the end of the line, skipping escapes.
                var j = i + 1
                while j < chars.count, chars[j] != c, c == "`" || chars[j] != "\n" {
                    j += chars[j] == "\\" ? 2 : 1
                }
                emit(min(j + 1, chars.count), .string)
            } else if c.isNumber, i == 0 || !isIdentifier(chars[i - 1]) {
                var j = i + 1
                while j < chars.count,
                      chars[j].isLetter || chars[j].isNumber || chars[j] == "_"
                        || (chars[j] == "." && j + 1 < chars.count && chars[j + 1].isNumber) {
                    j += 1
                }
                emit(j, .number)
            } else if isIdentifier(c) {
                var j = i + 1
                while j < chars.count, isIdentifier(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                let token: Token = grammar.keywords.contains(word) ? .keyword
                    : grammar.capitalizedTypes && word.first?.isUppercase == true ? .type : .plain
                emit(j, token)
            } else {
                emit(i + 1, .plain)
            }
        }
        return out
    }

    static func color(_ token: Token) -> Color {
        switch token {
        case .plain: Theme.Syntax.plain
        case .keyword: Theme.Syntax.keyword
        case .string: Theme.Syntax.string
        case .number: Theme.Syntax.number
        case .comment: Theme.Syntax.comment
        case .type: Theme.Syntax.type
        case .added: Theme.approve
        case .removed: Theme.State.cancelled
        case .meta: Theme.Syntax.punctuation
        }
    }

    private static func diff(_ code: String) -> [(String, Token)] {
        code.components(separatedBy: "\n").enumerated().map { index, line in
            let token: Token =
                line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") ? .meta
                : line.hasPrefix("+") ? .added
                : line.hasPrefix("-") ? .removed
                : .plain
            return ((index == 0 ? "" : "\n") + line, token)
        }
    }

    static func grammar(for language: String?) -> Grammar? {
        switch language {
        case "swift":
            Grammar(keywords: [
                "actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default",
                "defer", "do", "else", "enum", "extension", "false", "fileprivate", "for", "func", "guard",
                "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "private", "protocol",
                "public", "repeat", "return", "self", "Self", "some", "any", "static", "struct", "super", "switch",
                "throw", "throws", "true", "try", "typealias", "var", "where", "while",
            ], lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], capitalizedTypes: true)
        case "ts", "typescript", "tsx", "js", "javascript", "jsx", "mjs", "cjs":
            Grammar(keywords: [
                "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
                "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from",
                "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null",
                "of", "private", "public", "readonly", "return", "static", "super", "switch", "this", "throw",
                "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield",
            ], lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], capitalizedTypes: true)
        case "json", "jsonc":
            Grammar(keywords: ["true", "false", "null"], lineComments: [], quotes: ["\""])
        case "sh", "bash", "shell", "zsh", "console":
            Grammar(keywords: [
                "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in",
                "function", "return", "export", "local", "echo", "cd", "set", "unset", "exit", "source",
            ], lineComments: ["#"])
        case "rb", "ruby":
            Grammar(keywords: [
                "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif",
                "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
                "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until",
                "when", "while", "yield", "require", "attr_reader", "attr_accessor",
            ], lineComments: ["#"], capitalizedTypes: true)
        case "py", "python":
            Grammar(keywords: [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is",
                "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while",
                "with", "yield", "self",
            ], lineComments: ["#"])
        case "go", "golang":
            Grammar(keywords: [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                "false", "for", "func", "go", "goto", "if", "import", "interface", "map", "nil", "package",
                "range", "return", "select", "struct", "switch", "true", "type", "var",
            ], lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], capitalizedTypes: true)
        default:
            nil
        }
    }
}
