import MapleKit
import SwiftUI

/// What the Inbox and Goals search finds: every task in the feed by id, title or goal, and goals by name or prefix,
/// ranked like the Mac's ⌘K palette.
struct SearchResults: View {
    @Environment(FactoryStore.self) private var store
    let query: String

    static let taskLimit = 20

    var body: some View {
        let feed = store.feed
        let tasks = SearchRank.tasks(query, feed.tasks) { feed.goal($0)?.name ?? $0 }
        let goals = SearchRank.goals(query, feed.activeGoals)
        let goalsFirst = (goals.first?.score ?? 0) > (tasks.first?.score ?? 0)
        List {
            if tasks.isEmpty && goals.isEmpty {
                ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
            }
            if goalsFirst { goalSection(goals) }
            if !tasks.isEmpty {
                Section("Tasks") {
                    ForEach(tasks.prefix(Self.taskLimit), id: \.item.id) { result in
                        NavigationLink(value: TaskRoute(id: result.item.id)) { TaskRow(task: result.item) }
                            .accessibilityIdentifier("search.task.\(result.item.id)")
                    }
                }
            }
            if !goalsFirst { goalSection(goals) }
        }
        .accessibilityIdentifier("searchResults")
    }

    @ViewBuilder private func goalSection(_ goals: [(item: Wire.Goal, score: Int)]) -> some View {
        if !goals.isEmpty {
            Section("Goals") {
                ForEach(goals, id: \.item.id) { GoalRow(goal: $0.item).accessibilityIdentifier("search.goal.\($0.item.id)") }
            }
        }
    }
}
