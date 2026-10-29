import Foundation

/// The personal order of the sidebar's goals: the ones you placed first, in your order; the rest
/// below in the order they were created.
enum GoalOrder {
    enum Move: Equatable {
        case up, down, top, bottom
        /// Dropped before the item at this index of the list (its count puts it last).
        case to(Int)
    }

    /// `items` with those listed in `order` first, in that order, then the rest as they were.
    /// Ids in `order` that no item has any more are ignored.
    static func apply<Item>(_ items: [Item], order: [String]?, key: (Item) -> String?) -> [Item] {
        guard let order, !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = items.compactMap { item in key(item).flatMap { rank[$0] }.map { (item, $0) } }
        let rest = items.filter { key($0).flatMap { rank[$0] } == nil }
        return placed.sorted { $0.1 < $1.1 }.map(\.0) + rest
    }

    /// `ids` with `id` moved; unchanged when it isn't there or can't go further.
    static func move(_ id: String, to move: Move, in ids: [String]) -> [String] {
        guard let from = ids.firstIndex(of: id) else { return ids }
        var dest: Int
        switch move {
        case .up: dest = from - 1
        case .down: dest = from + 1
        case .top: dest = 0
        case .bottom: dest = ids.count - 1
        case .to(let index): dest = index > from ? index - 1 : index
        }
        dest = min(max(dest, 0), ids.count - 1)
        guard dest != from else { return ids }
        var moved = ids
        moved.remove(at: from)
        moved.insert(id, at: dest)
        return moved
    }

    /// Whether `move` would change anything, for disabling menu items at the ends.
    static func canMove(_ id: String, _ move: Move, in ids: [String]) -> Bool {
        self.move(id, to: move, in: ids) != ids
    }

    /// The order to save after reordering the `visible` goals: theirs, then any placed goals that
    /// aren't in the sidebar right now (unfollowed), so following one again finds it placed.
    static func saving(_ visible: [String], over stored: [String]?) -> [String] {
        let shown = Set(visible)
        return visible + (stored ?? []).filter { !shown.contains($0) }
    }
}
