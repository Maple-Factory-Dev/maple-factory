import SwiftUI

/// Every task's events as the Activity page's entries, newest first, built in one pass: tasks are found by id
/// and people by login through dictionaries, and the list is sorted once. The page filters and pages it.
@MainActor struct ActivityLog {
    enum Filter: String, CaseIterable { case everyone = "Everyone", people = "People", agents = "Agents", mine = "My tasks" }

    struct Entry: Identifiable {
        let id: String
        let task: FactoryTask
        let who: Person
        let isAgent: Bool
        let text: String
        /// When it happened, in ms since 1970; the mockup's is worked out from its relative label.
        let at: UInt64?
        /// The mockup's relative label ("4m", "2h").
        let label: String?

        var date: Date? { at.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
        /// "now", "4m", "2h", "3d": worked out when asked, so only the rows that are drawn pay for it.
        @MainActor var when: String { label ?? at.map { LiveAdapter.ago($0) } ?? "" }
    }

    static let pageSize = 50
    private static let agents: Set<String> = ["planner", "builder", "reviewer", "factory"]

    /// Newest first.
    let entries: [Entry]

    init(entries: [Entry]) { self.entries = entries }

    /// The factory's: each task's events with their times.
    static func live(_ wire: [Wire.Task], tasks: [FactoryTask], members: [Wire.Member]) -> ActivityLog {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var people: [String: Person] = [:]
        var all: [Entry] = []
        all.reserveCapacity(wire.reduce(0) { $0 + $1.events.count })
        for task in wire {
            guard let model = byID[task.id] else { continue }
            for (index, event) in task.events.enumerated() {
                let who: Person
                if let known = people[event.who] { who = known } else {
                    who = LiveAdapter.person(event.who, members: members)
                    people[event.who] = who
                }
                all.append(Entry(id: "\(task.id)-\(index)", task: model, who: who, isAgent: agents.contains(event.who),
                                 text: event.text, at: event.at, label: nil))
            }
        }
        all.sort { $0.at ?? 0 > $1.at ?? 0 }
        return ActivityLog(entries: all)
    }

    /// The mockup's: relative labels only, ordered by how long ago they read and dated from them, so they fall into days.
    static func mock(_ tasks: [FactoryTask], minutesAgo: (String) -> Int, now: Date = Date()) -> ActivityLog {
        var people: [String: Person] = [:]
        for person in FactoryData.people.reversed() {
            people[person.firstName] = person
            people[person.name] = person
        }
        let items = tasks.flatMap { task in task.activity.enumerated().map { (task: task, index: $0, item: $1) } }
        let minutes = items.map { minutesAgo($0.item.when) }
        let order = items.indices.sorted { minutes[$0] != minutes[$1] ? minutes[$0] < minutes[$1] : $0 < $1 }
        let nowMS = now.timeIntervalSince1970 * 1000
        return ActivityLog(entries: order.map { at in
            let (task, index, item) = items[at]
            let person = people[item.who]
            return Entry(id: "\(task.id)-\(index)", task: task, who: person ?? Agent(name: item.who, color: Theme.State.building),
                         isAgent: person == nil, text: item.text, at: UInt64(max(0, nowMS - Double(minutes[at]) * 60_000)), label: item.when)
        })
    }

    /// What the filter picks, in the goals `inScope` shows; `me` is whose tasks are "My tasks".
    func entries(filter: Filter, inScope: (FactoryTask) -> Bool = { _ in true }, me: String = FactoryData.me.id) -> [Entry] {
        entries.filter { entry in
            let picked = switch filter {
            case .everyone: true
            case .people: !entry.isAgent
            case .agents: entry.isAgent
            case .mine: entry.task.owner.id == me
            }
            return picked && inScope(entry.task)
        }
    }

    /// The newest `count` entries.
    func page(_ count: Int) -> ArraySlice<Entry> { entries.prefix(max(0, count)) }

    /// Kept against the tasks' revision (FactoryClient.tasksRevision, or the mockup's), as TaskCache is:
    /// a filter or scope change re-filters the built feed instead of building it again.
    @MainActor final class Cache {
        private var key: Key?
        private var feed: ActivityLog?
        /// How many times the feed was built (for tests).
        private(set) var builds = 0

        private struct Key: Equatable {
            let revision: Int
            let live: Bool
        }

        func feed(revision: Int, live: Bool, build: () -> ActivityLog) -> ActivityLog {
            let key = Key(revision: revision, live: live)
            if key == self.key, let feed { return feed }
            builds += 1
            let feed = build()
            self.key = key
            self.feed = feed
            return feed
        }
    }
}
