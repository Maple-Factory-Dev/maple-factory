import Foundation

/// A new task made from review findings picked on Statistics › Review findings: its title, a brief
/// listing each finding with the task it came from, and a Done when item per finding (MF-73).
enum FindingsTask {
    /// Blockers first, then majors, then minors; a severity this build doesn't know goes last.
    private static func rank(_ s: Wire.Severity) -> Int {
        switch s {
        case .blocker: 0
        case .major: 1
        case .minor: 2
        case .other: 3
        }
    }

    /// The findings in the order the brief lists them: by severity, then as they were picked.
    static func ordered(_ rows: [Wire.StatsFindingRow]) -> [Wire.StatsFindingRow] {
        rows.enumerated().sorted { (rank($0.element.severity), $0.offset) < (rank($1.element.severity), $1.offset) }.map(\.element)
    }

    /// One finding's own title: its text, shortened, or what it is when no text was kept.
    static func shortText(_ r: Wire.StatsFindingRow, limit: Int = 72) -> String {
        let text = r.text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty else { return "\(r.severity.rawValue.capitalized) \(r.kind.rawValue) finding from \(r.task)" }
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// The folder all of the findings land in, if they share one: "apps/mac" for apps/mac/…, "apps" for
    /// apps/mac and apps/web. Findings without a file don't say where they are, so they don't count.
    static func commonArea(_ rows: [Wire.StatsFindingRow]) -> String? {
        let areas = rows.map(\.area).filter { !$0.hasPrefix("(") }
        guard let first = areas.first else { return nil }
        var shared = first.split(separator: "/")
        for a in areas.dropFirst() {
            let parts = a.split(separator: "/")
            shared = Array(zip(shared, parts).prefix { $0 == $1 }.map(\.0))
        }
        return shared.isEmpty ? nil : shared.joined(separator: "/")
    }

    static func title(_ rows: [Wire.StatsFindingRow]) -> String {
        if rows.count == 1 { return shortText(rows[0]) }
        let n = "Fix \(rows.count) review findings"
        return commonArea(rows).map { "\(n) in \($0)" } ?? n
    }

    /// Where a finding came from: "from MF-61, round 2".
    static func source(_ r: Wire.StatsFindingRow) -> String { "from \(r.task), round \(r.raisedIn)" }

    static func body(_ rows: [Wire.StatsFindingRow]) -> String {
        let rows = ordered(rows)
        let intro = rows.count == 1
            ? "A review finding to resolve, picked from Statistics › Review findings."
            : "\(rows.count) review findings to resolve, picked from Statistics › Review findings."
        let findings = rows.map { r in
            var line = "- **\(r.severity.rawValue.capitalized) · \(r.kind.rawValue)**"
            if let file = r.file, !file.isEmpty { line += " `\(file)`" }
            line += ": " + (r.text.isEmpty ? "(no text kept)" : r.text.replacingOccurrences(of: "\n", with: " "))
            return line + " (\(source(r)))"
        }
        let done = rows.map { "- [ ] Resolve: \(shortText($0)) (\($0.task))" }
        return """
        \(intro)

        ## Findings
        \(findings.joined(separator: "\n"))

        ## Done when
        \(done.joined(separator: "\n"))
        """
    }

    /// The goal most of the findings' tasks belong to, among the tasks still around; nil when none are,
    /// so the composer picks its usual one. A tie goes to the goal of the finding picked first.
    static func goal(_ rows: [Wire.StatsFindingRow], tasks: [FactoryTask]) -> String? {
        let goals = Dictionary(tasks.map { ($0.id, $0.goal) }, uniquingKeysWith: { a, _ in a })
        var counts: [String: Int] = [:]
        var order: [String] = []
        for r in rows {
            guard let g = goals[r.task], !g.isEmpty else { continue }
            if counts[g] == nil { order.append(g) }
            counts[g, default: 0] += 1
        }
        var best: String?
        for g in order where best == nil || counts[g]! > counts[best!]! { best = g }
        return best
    }
}

extension Wire.StatsFindingRow {
    /// Which finding this is, for picking it in the list: its task, round and text.
    var pickKey: String { "\(task)#\(raisedIn)#\(text)" }
}
