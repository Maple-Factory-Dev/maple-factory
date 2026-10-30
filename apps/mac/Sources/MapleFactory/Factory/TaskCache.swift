import Foundation

/// What the views ask of the tasks on every render (a task by its id, the inbox, the raised hands),
/// worked out once per change to them instead of by scanning every task and comment each time.
/// AppState keeps one against the tasks' revision (FactoryClient.tasksRevision, or the mockup's own);
/// a revision it wasn't filled at empties it.
struct TaskCache {
    private var key: Key?
    private var index: [String: Int]?
    private var hands: [FactoryTask]?
    private var inbox: (dismissed: Set<String>, me: String, items: [InboxItem])?

    private struct Key: Equatable {
        let revision: Int
        let live: Bool
    }

    /// Empties it unless it was filled at this revision of these tasks.
    mutating func sync(revision: Int, live: Bool) {
        let key = Key(revision: revision, live: live)
        guard key != self.key else { return }
        self = TaskCache()
        self.key = key
    }

    /// Where the task with `id` is in `tasks`, or nil when it isn't there.
    mutating func index(of id: String, in tasks: [FactoryTask]) -> Int? {
        if index == nil {
            index = Dictionary(tasks.indices.map { (tasks[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        guard let at = index?[id], tasks.indices.contains(at), tasks[at].id == id else { return nil }
        return at
    }

    /// Every task with a hand up, in the tasks' order.
    mutating func handRaises(in tasks: [FactoryTask]) -> [FactoryTask] {
        if let hands { return hands }
        let raised = tasks.filter { $0.hand != nil }
        hands = raised
        return raised
    }

    /// The inbox `build` makes, kept while the mentions you've dismissed and who you are stay the same.
    mutating func inbox(dismissed: Set<String>, me: String, _ build: () -> [InboxItem]) -> [InboxItem] {
        if let inbox, inbox.dismissed == dismissed, inbox.me == me { return inbox.items }
        let items = build()
        inbox = (dismissed, me, items)
        return items
    }
}
