import Foundation

/// Keyboard navigation through the tasks on screen: which rows are visible, in what order, and where
/// ↑↓←→ (and J/K) take the cursor from where it is. Pure, so its ordering is tested without a window.
@MainActor enum TaskKeyNav {
    enum Direction: Equatable { case up, down, left, right }

    /// What's on screen: one ordered list (task lists, My tasks, the Inbox, Needs a hand) or the board's columns.
    enum Layout: Equatable {
        case list([String])
        case columns([[String]])

        static let empty = Layout.list([])

        /// Every row top to bottom (column by column on the board): what the full view's Next/Previous walks.
        var flat: [String] {
            switch self {
            case .list(let ids): ids
            case .columns(let columns): columns.flatMap { $0 }
            }
        }

        var isEmpty: Bool { flat.isEmpty }
    }

    // MARK: Rows on screen

    /// A task list's rows: grouped in TaskState section order, each section in its given order, skipping collapsed sections.
    static func listRows(_ tasks: [FactoryTask], collapsed: Set<TaskState> = []) -> [String] {
        TaskState.allCases.filter { !collapsed.contains($0) }.flatMap { taskState in
            tasks.filter { $0.state == taskState }.map(\.id)
        }
    }

    /// The board's columns as on screen, empty ones included (←/→ steps over them).
    static func boardRows(_ tasks: [FactoryTask], hideEmpty: Bool, pendingMerge: (FactoryTask) -> Bool) -> [[String]] {
        BoardColumns.columns(tasks: tasks, hideEmpty: hideEmpty, pendingMerge: pendingMerge).map { $0.tasks.map(\.id) }
    }

    // MARK: Moving

    /// Where a key takes the cursor. A missing or stale cursor lands on the first row; the ends clamp.
    /// On the board ↑/↓ stay in the column, and ←/→ keep the row index (clamped) in the next non-empty column.
    static func move(_ direction: Direction, from cursor: String?, in layout: Layout) -> String? {
        switch layout {
        case .list(let ids):
            guard let first = ids.first else { return nil }
            guard let cursor, let index = ids.firstIndex(of: cursor) else { return first }
            switch direction {
            case .up: return ids[max(0, index - 1)]
            case .down: return ids[min(ids.count - 1, index + 1)]
            case .left, .right: return cursor
            }
        case .columns(let columns):
            guard let firstColumn = columns.firstIndex(where: { !$0.isEmpty }) else { return nil }
            guard let cursor, let col = columns.firstIndex(where: { $0.contains(cursor) }),
                  let row = columns[col].firstIndex(of: cursor) else { return columns[firstColumn][0] }
            let column = columns[col]
            switch direction {
            case .up: return column[max(0, row - 1)]
            case .down: return column[min(column.count - 1, row + 1)]
            case .left, .right:
                let step = direction == .left ? -1 : 1
                var next = col + step
                while columns.indices.contains(next) {
                    if !columns[next].isEmpty { return columns[next][min(row, columns[next].count - 1)] }
                    next += step
                }
                return cursor
            }
        }
    }

    /// The full view's Next/Previous Task: the neighbour in the list you came from, nil at either end.
    static func neighbour(of id: String, in list: [String], forward: Bool) -> String? {
        guard let index = list.firstIndex(of: id) else { return nil }
        let next = index + (forward ? 1 : -1)
        return list.indices.contains(next) ? list[next] : nil
    }

    /// When the cursor's row leaves the list (an approved plan leaves the Inbox), the row that took its
    /// place: the next one, or the new last when it was last. `before` is the list as it was.
    static func survivor(of cursor: String?, before: [String], after: [String]) -> String? {
        guard let cursor else { return after.first }
        if after.contains(cursor) { return cursor }
        guard let index = before.firstIndex(of: cursor) else { return after.first }
        // The first row after it that's still there, else the nearest one before it.
        if let next = before[(index + 1)...].first(where: after.contains) { return next }
        return before[..<index].last(where: after.contains)
    }
}
