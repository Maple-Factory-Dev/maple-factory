import Foundation

/// How typed search words rank tasks, goals and pages, shared by the Mac's ⌘K palette and the iPhone's search.
/// Every word has to match; each word scores its best field and the scores add up.
public enum SearchRank {
    /// The typed text, lowercased and split on whitespace.
    public static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// How well one typed word matches a field: exact, prefix, a word's start, anywhere, then in order with gaps.
    public static func fieldScore(_ word: String, _ field: String) -> Int? {
        let field = field.lowercased()
        if field == word { return 1000 }
        if field.hasPrefix(word) { return 800 }
        if field.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(word) }) { return 600 }
        if field.contains(word) { return 400 }
        return fuzzy(word, field)
    }

    /// The word's letters in order, close together: 100 for a tight run, less as it spreads out.
    static func fuzzy(_ word: String, _ field: String) -> Int? {
        guard word.count >= 2 else { return nil }
        let letters = Array(field)
        var index = 0, first: Int? = nil
        for char in word {
            while index < letters.count && letters[index] != char { index += 1 }
            guard index < letters.count else { return nil }
            if first == nil { first = index }
            index += 1
        }
        let span = index - first!
        guard span <= word.count * 3 else { return nil }
        return max(1, 100 - (span - word.count) * 10)
    }

    /// Every word has to match a name (or, weaker, a keyword); the sum of each word's best.
    public static func score(_ words: [String], _ names: [String], also keywords: [String] = []) -> Int? {
        var total = 0
        for word in words {
            let name = names.compactMap { fieldScore(word, $0) }.max() ?? 0
            let keyword = (keywords.compactMap { fieldScore(word, $0) }.max() ?? 0) / 2
            let best = max(name, keyword)
            guard best > 0 else { return nil }
            total += best
        }
        return total
    }

    /// An id match beats the title, which beats the goal and state; unfinished tasks break ties.
    /// With no words, every task scores the same, unfinished ones first.
    public static func taskScore(_ words: [String], id: String, title: String, goal: String, state: String, finished: Bool) -> Int? {
        let open = finished ? 0 : 1
        guard !words.isEmpty else { return open }
        var total = 0
        for word in words {
            let idScore = fieldScore(word, id).map { $0 * 2 } ?? 0
            let titleScore = fieldScore(word, title) ?? 0
            let other = max(fieldScore(word, goal) ?? 0, fieldScore(word, state) ?? 0) / 2
            let best = max(idScore, titleScore, other)
            guard best > 0 else { return nil }
            total += best
        }
        return total * 2 + open
    }

    /// Items with a score, best first; ties keep their order.
    public static func ranked<T>(_ scored: [(T, Int)]) -> [(item: T, score: Int)] {
        scored.enumerated()
            .sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }
            .map { (item: $0.element.0, score: $0.element.1) }
    }

    /// Tasks matching every word by id, title, goal name or state, best first. Nothing typed: nothing.
    public static func tasks(_ query: String, _ tasks: [Wire.Task], goalName: (String) -> String) -> [(item: Wire.Task, score: Int)] {
        let words = words(query)
        guard !words.isEmpty else { return [] }
        return ranked(tasks.compactMap { task in
            taskScore(words, id: task.id, title: task.title, goal: goalName(task.goal), state: stateTitle(task.state),
                      finished: isFinished(task.state)).map { (task, $0) }
        })
    }

    /// Goals matching every word by name or task-id prefix, best first. Nothing typed: nothing.
    public static func goals(_ query: String, _ goals: [Wire.Goal]) -> [(item: Wire.Goal, score: Int)] {
        let words = words(query)
        guard !words.isEmpty else { return [] }
        return ranked(goals.compactMap { goal in score(words, [goal.name, goal.prefix]).map { (goal, $0) } })
    }

    static func isFinished(_ state: Wire.TaskState) -> Bool {
        switch state {
        case .merged, .cancelled, .closed: true
        default: false
        }
    }

    static func stateTitle(_ state: Wire.TaskState) -> String {
        switch state {
        case .awaitingApproval: "Awaiting approval"
        case .other(let value): value
        default: state.rawValue.capitalized
        }
    }
}
