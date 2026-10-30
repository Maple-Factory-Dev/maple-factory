import Foundation

/// What the views ask of the tasks on every render (a task by its id, the inbox, the raised hands),
/// worked out once per change to them instead of by scanning every task and comment each time.
/// AppState keeps one against the tasks' revision (FactoryClient.tasksRevision, or the mockup's own);
/// a revision it wasn't filled at empties it.
@MainActor struct TaskCache {
    private var key: Key?
    private var index: [String: Int]?
    private var hands: [FactoryTask]?
    private var inbox: (dismissed: Set<String>, me: String, items: [InboxItem])?
    /// Each task's @mentions of you, by its id, kept across revisions while its comments stay the same:
    /// a task changes far more often than its comments do.
    private var mentions: [String: (comments: [String], me: String, items: [InboxItem])] = [:]
    /// How many times the inbox, and a task's mentions, were worked out (for tests).
    private(set) var builds = (inbox: 0, mentions: 0)

    private struct Key: Equatable {
        let revision: Int
        let live: Bool
    }

    /// Empties it unless it was filled at this revision of these tasks.
    mutating func sync(revision: Int, live: Bool) {
        let key = Key(revision: revision, live: live)
        guard key != self.key else { return }
        let kept = key.live == self.key?.live ? mentions : [:]
        let builds = builds
        self = TaskCache()
        self.key = key
        self.mentions = kept
        self.builds = builds
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

    /// The factory's inbox (AppState.liveInbox), kept while the mentions you've dismissed and who you are stay the same.
    mutating func inbox(_ tasks: [FactoryTask], me: Person, dismissed: Set<String>) -> [InboxItem] {
        if let inbox, inbox.dismissed == dismissed, inbox.me == me.id { return inbox.items }
        builds.inbox += 1
        let items = AppState.liveInbox(tasks, me: me, dismissed: dismissed) { mentionItems($0, me: me) }
        inbox = (dismissed, me.id, items)
        if mentions.count > tasks.count {
            let ids = Set(tasks.map(\.id))
            mentions = mentions.filter { ids.contains($0.key) }
        }
        return items
    }

    /// AppState.mentionItems for `task`, worked out again only when its comments change.
    private mutating func mentionItems(_ task: FactoryTask, me: Person) -> [InboxItem] {
        let comments = task.comments.compactMap(\.id)
        // Comments without the factory's ids (this session's own) can't be told apart: worked out each time.
        guard comments.count == task.comments.count else { return AppState.mentionItems(task, me: me) }
        if let memo = mentions[task.id], memo.comments == comments, memo.me == me.id { return memo.items }
        builds.mentions += 1
        let items = AppState.mentionItems(task, me: me)
        mentions[task.id] = (comments, me.id, items)
        return items
    }
}
