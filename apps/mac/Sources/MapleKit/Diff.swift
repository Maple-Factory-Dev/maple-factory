import Foundation

// A unified diff, as the factory serves a task's (`GET /api/tasks/<id>/diff`), parsed into files and hunks.

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case context, added, removed }

    public let kind: Kind
    public let text: String
    public let old: Int?
    public let new: Int?

    public init(kind: Kind, text: String, old: Int?, new: Int?) {
        self.kind = kind
        self.text = text
        self.old = old
        self.new = new
    }
}

public struct DiffHunk: Identifiable, Sendable {
    public let id = UUID()
    public let header: String
    /// The plan step (1-based) this hunk implements, so reviewers can read code against intent.
    public let step: Int?
    public let lines: [DiffLine]

    /// Builds a hunk from unified-diff text: each line prefixed with " ", "+" or "-".
    public init(oldStart: Int, newStart: Int, context: String = "", step: Int?, _ body: String) {
        self.init(oldStart: oldStart, newStart: newStart, context: context, step: step, lines: body.split(separator: "\n", omittingEmptySubsequences: false))
    }

    /// Builds a hunk from its lines, each prefixed with " ", "+" or "-", counting each side's lines
    /// as it goes.
    public init(oldStart: Int, newStart: Int, context: String = "", step: Int?, lines raws: [Substring]) {
        var old = oldStart, new = newStart
        var parsed: [DiffLine] = []
        parsed.reserveCapacity(raws.count)
        for raw in raws {
            let prefix = raw.first ?? " "
            let text = String(raw.dropFirst())
            switch prefix {
            case "+":
                parsed.append(DiffLine(kind: .added, text: text, old: nil, new: new)); new += 1
            case "-":
                parsed.append(DiffLine(kind: .removed, text: text, old: old, new: nil)); old += 1
            default:
                parsed.append(DiffLine(kind: .context, text: text, old: old, new: new)); old += 1; new += 1
            }
        }
        self.header = "@@ -\(oldStart),\(old - oldStart) +\(newStart),\(new - newStart) @@ \(context)"
        self.step = step
        self.lines = parsed
    }
}

public struct DiffFile: Identifiable, Sendable {
    public let path: String
    public let added: Int
    public let removed: Int
    public var step: Int? = nil
    public var hunks: [DiffHunk] = []
    /// Still being written by a building agent.
    public var inProgress = false
    public var id: String { path }

    public init(path: String, added: Int, removed: Int, step: Int? = nil, hunks: [DiffHunk] = [], inProgress: Bool = false) {
        self.path = path
        self.added = added
        self.removed = removed
        self.step = step
        self.hunks = hunks
        self.inProgress = inProgress
    }
}

extension DiffFile {
    /// The files in a unified diff (`git diff` output), with their hunks.
    public static func parse(_ patch: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var path: String?
        var added = 0, removed = 0
        var hunks: [DiffHunk] = []
        var hunk: (old: Int, new: Int, context: String, lines: [Substring])?

        func closeHunk() {
            if let h = hunk { hunks.append(DiffHunk(oldStart: h.old, newStart: h.new, context: h.context, step: nil, lines: h.lines)) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let path { files.append(DiffFile(path: path, added: added, removed: removed, hunks: hunks)) }
            path = nil
            added = 0
            removed = 0
            hunks = []
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                closeFile()
                // "diff --git a/x b/x": the b side, until +++ says better.
                path = line.components(separatedBy: " b/").last
            } else if hunk == nil, line.hasPrefix("+++ ") {
                if line != "+++ /dev/null" { path = String(line.dropFirst(4)).replacingOccurrences(of: "b/", with: "", options: .anchored) }
            } else if hunk == nil, line.hasPrefix("--- ") || line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("Binary files") {
                continue
            } else if line.hasPrefix("@@") {
                closeHunk()
                // @@ -12,7 +12,9 @@ context
                let parts = line.split(separator: " ", maxSplits: 4)
                let start = { (s: Substring) in Int(s.dropFirst().split(separator: ",").first ?? "") ?? 1 }
                let context = line.components(separatedBy: "@@").dropFirst(2).joined(separator: "@@").trimmingCharacters(in: .whitespaces)
                hunk = (parts.count > 1 ? start(parts[1]) : 1, parts.count > 2 ? start(parts[2]) : 1, context, [])
            } else if hunk != nil, let first = line.first, "+- ".contains(first) {
                if first == "+" { added += 1 } else if first == "-" { removed += 1 }
                hunk?.lines.append(line)
            }
        }
        closeFile()
        return files
    }
}
