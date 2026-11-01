import MapleKit
import SwiftUI

struct ActivityRoute: Hashable {}

/// Everything happening across the factory, newest first, like the Mac's Activity page: people approving
/// and steering, agents planning, proving and reviewing, merges. Each row opens its task.
struct ActivityView: View {
    @Environment(FactoryStore.self) private var store
    @State private var filter: ActivityEntry.Filter = .everyone
    /// How many rows are drawn; "Show 50 more" adds a page, and a new filter starts again at one.
    @State private var shown = ActivityEntry.pageSize

    var body: some View {
        let entries = store.feed.activity(filter: filter, me: store.me)
        List {
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(ActivityEntry.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("activity.filter")
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if entries.isEmpty, store.feed.hasSnapshot {
                ContentUnavailableView("Nothing yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("What people and agents do on tasks shows up here."))
                    .listRowBackground(Color.clear)
            }
            ForEach(Self.days(entries.prefix(shown)), id: \.title) { day in
                Section(day.title) {
                    ForEach(day.entries) { entry in
                        NavigationLink(value: TaskRoute(id: entry.task)) { ActivityRow(entry: entry) }
                            .accessibilityIdentifier("activity.row.\(entry.task)")
                    }
                }
            }
            if entries.count > shown {
                Section {
                    Button("Show \(min(ActivityEntry.pageSize, entries.count - shown)) more") { shown += ActivityEntry.pageSize }
                        .accessibilityIdentifier("activity.more")
                } footer: {
                    Text("Showing \(shown.formatted()) of \(entries.count.formatted())")
                }
            }
        }
        .navigationTitle("Activity")
        .refreshable { await store.refresh() }
        .onChange(of: filter) { shown = ActivityEntry.pageSize }
        .overlay { if !store.feed.hasSnapshot { ProgressView() } }
    }

    /// Entries by day ("Today", "Yesterday", "Monday, Oct 21"), keeping their order.
    static func days(_ entries: ArraySlice<ActivityEntry>) -> [(title: String, entries: [ActivityEntry])] {
        var groups: [(title: String, entries: [ActivityEntry])] = []
        for entry in entries {
            let date = entry.date
            let title = Calendar.current.isDateInToday(date) ? "Today"
                : Calendar.current.isDateInYesterday(date) ? "Yesterday"
                : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            if groups.last?.title == title { groups[groups.count - 1].entries.append(entry) } else { groups.append((title, [entry])) }
        }
        return groups
    }
}

struct ActivityRow: View {
    @Environment(FactoryStore.self) private var store
    let entry: ActivityEntry

    var body: some View {
        let task = store.feed.task(entry.task)
        let goal = task.flatMap { store.feed.goal($0.goal) }
        HStack(alignment: .top, spacing: 10) {
            if entry.isAgent {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.secondary.gradient))
            } else {
                Avatar(login: entry.who, size: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                (Text(name).fontWeight(.semibold) + Text(" \(entry.text)").foregroundColor(.primary.opacity(0.85)))
                    .font(.subheadline)
                    .lineLimit(3)
                HStack(spacing: 5) {
                    Text(entry.task).font(.caption.monospaced())
                    Text(task?.title ?? "").lineLimit(1)
                    if let goal {
                        Circle().fill(Color(goalHex: goal.color)).frame(width: 6, height: 6)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(When.ago(entry.at)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// "You", a person's name, or the agent's role ("Planner").
    private var name: String {
        if entry.who == store.me { return "You" }
        if entry.isAgent { return entry.who.capitalized }
        return store.feed.member(entry.who)?.name ?? entry.who
    }
}
