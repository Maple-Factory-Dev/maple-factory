import Foundation
import Observation

/// Lines picked in a file's diff, by their place in the file's rows (its hunks' lines one after
/// another). Where the drag or click started stays put; the other end follows shift-clicks and drags.
struct LineSelection: Equatable {
    let path: String
    var anchor: Int
    var head: Int

    init(path: String, row: Int) {
        self.path = path
        anchor = row
        head = row
    }

    var rows: ClosedRange<Int> { min(anchor, head)...max(anchor, head) }

    func contains(_ path: String, _ row: Int) -> Bool { self.path == path && rows.contains(row) }
}

/// Turning picked diff lines into review notes, and placing GitHub's review threads on the lines.
enum DiffReview {
    /// A file's lines as the Diff tab shows them: each hunk's, one hunk after another.
    static func rows(_ hunks: [DiffHunk]) -> [DiffLine] { hunks.flatMap(\.lines) }

    /// `rows`, split after every row in `breaks` and into runs of at most `limit`, so a long file
    /// builds only the runs on screen.
    static func runs(_ rows: Range<Int>, breaks: Set<Int>, limit: Int = 100) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = rows.lowerBound
        for row in rows where breaks.contains(row) || row + 1 - start >= limit {
            out.append(start..<row + 1)
            start = row + 1
        }
        if start < rows.upperBound { out.append(start..<rows.upperBound) }
        return out
    }

    /// The lines a selection covers, numbered the way GitHub would: removed lines alone are on the
    /// old side; otherwise the new side, by the added and unchanged lines' numbers.
    static func span(_ lines: [DiffLine]) -> (start: Int, end: Int, side: Wire.DiffSide)? {
        let new = lines.compactMap { $0.kind == .removed ? nil : $0.new }
        if let first = new.min(), let last = new.max() { return (first, last, .new) }
        let old = lines.compactMap(\.old)
        if let first = old.min(), let last = old.max() { return (first, last, .old) }
        return nil
    }

    /// The lines as the diff showed them: `+`, `-` or a space, then the line.
    static func snippet(_ lines: [DiffLine]) -> String {
        lines.map { line in
            let sign = switch line.kind {
            case .added: "+"
            case .removed: "-"
            case .context: " "
            }
            return sign + line.text
        }
        .joined(separator: "\n")
    }

    /// A note on `rows` of a file's lines, or nil when there's nothing there to comment on.
    static func note(path: String, lines: [DiffLine], rows: ClosedRange<Int>, text: String) -> Wire.ReviewNote? {
        let first = max(rows.lowerBound, 0), last = min(rows.upperBound, lines.count - 1)
        guard first <= last else { return nil }
        let picked = Array(lines[first...last])
        guard let span = span(picked) else { return nil }
        return Wire.ReviewNote(path: path, start: UInt32(span.start), end: UInt32(span.end), side: span.side, snippet: snippet(picked), text: text)
    }

    /// The row that `line` on `side` is: an added or unchanged line by its new number, a removed or
    /// unchanged one by its old number.
    static func row(side: Wire.DiffSide, line: Int, in lines: [DiffLine]) -> Int? {
        lines.firstIndex { side == .old ? $0.kind != .added && $0.old == line : $0.kind != .removed && $0.new == line }
    }

    /// Where a file's threads go: under the row each ends on, and the rest (outdated, or on lines
    /// this diff doesn't show) above the file's lines.
    static func place(_ threads: [Wire.ReviewThread], in lines: [DiffLine]) -> (rows: [Int: [Wire.ReviewThread]], elsewhere: [Wire.ReviewThread]) {
        var rows: [Int: [Wire.ReviewThread]] = [:]
        var elsewhere: [Wire.ReviewThread] = []
        for thread in threads {
            if let line = thread.line, let row = row(side: thread.side, line: Int(line), in: lines) {
                rows[row, default: []].append(thread)
            } else {
                elsewhere.append(thread)
            }
        }
        return (rows, elsewhere)
    }

    /// A note's anchor as the factory writes it: `path:L12` or `path:L12–18`.
    static func anchor(_ note: Wire.ReviewNote) -> String {
        "\(note.path):L\(note.start)\(note.end > note.start ? "–\(note.end)" : "")"
    }

    /// The path and lines in a code comment's anchor (`lib/auth/jwt.ts:L12–18`), or nil for any other anchor.
    static func parseAnchor(_ anchor: String) -> (path: String, lines: String)? {
        guard let colon = anchor.range(of: ":L", options: .backwards) else { return nil }
        let lines = anchor[colon.upperBound...]
        guard !lines.isEmpty, lines.allSatisfy({ $0.isNumber || $0 == "–" }), lines.first?.isNumber == true else { return nil }
        return (String(anchor[..<colon.lowerBound]), "L" + lines)
    }

    /// A code comment's text split into the fenced snippet it opens with and what was said about it.
    static func splitSnippet(_ text: String) -> (snippet: String, body: String)? {
        let lines = text.components(separatedBy: "\n")
        guard let open = lines.first, open.hasPrefix("```") else { return nil }
        let fence = String(open.prefix { $0 == "`" })
        guard let close = lines.dropFirst().firstIndex(where: { $0 == fence }) else { return nil }
        let snippet = lines[1..<close].joined(separator: "\n")
        let body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (snippet, body)
    }
}

/// A comment drafted on lines of the diff, waiting to be sent with the rest of the review.
struct DraftNote: Identifiable, Equatable {
    let id = UUID()
    var note: Wire.ReviewNote
}

/// A task's review in progress: the notes drafted in its Diff tab and a summary. It outlives the tab,
/// so switching to the overview and back keeps them.
@MainActor @Observable
final class ReviewDraft {
    var notes: [DraftNote] = []
    var summary = ""

    var isEmpty: Bool { notes.isEmpty && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Files with notes waiting.
    var paths: Set<String> { Set(notes.map(\.note.path)) }

    func add(_ note: Wire.ReviewNote) { notes.append(DraftNote(note: note)) }

    func update(_ id: UUID, text: String) {
        guard let at = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[at].note.text = text
    }

    func remove(_ id: UUID) { notes.removeAll { $0.id == id } }

    func clear() {
        notes = []
        summary = ""
    }
}
