import SwiftUI

/// Everything happening across the factory, newest first: people approving and steering, agents
/// planning, proving and reviewing, merges. Each line opens its task.
struct ActivityView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @State private var filter: Filter = .everyone
    /// How many entries are drawn; "Show 50 more" adds a page, and a new filter or scope starts again at one.
    @State private var shown = ActivityLog.pageSize
    @State private var cache = ActivityLog.Cache()

    static let demo = Notification.Name("ActivityView.demo")

    typealias Filter = ActivityLog.Filter
    typealias Entry = ActivityLog.Entry

    /// Built once per change to the tasks. Live: every task's events with their times; the mockup's only have relative labels.
    private var feed: ActivityLog {
        cache.feed(revision: state.tasksRevision, live: state.isLive) {
            state.isLive ? .live(client.tasks, tasks: state.tasks, members: client.members) : .mock(state.tasks, minutesAgo: state.minutesAgo)
        }
    }

    /// Entries by day ("Today", "Yesterday", "Oct 21").
    private func days(_ entries: ArraySlice<Entry>) -> [(title: String, entries: [Entry])] {
        var groups: [(title: String, entries: [Entry])] = []
        for entry in entries {
            let title = entry.date.map { date in
                Calendar.current.isDateInToday(date) ? "Today"
                    : Calendar.current.isDateInYesterday(date) ? "Yesterday"
                    : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            } ?? "Recent"
            if groups.last?.title == title { groups[groups.count - 1].entries.append(entry) } else { groups.append((title, [entry])) }
        }
        return groups
    }

    var body: some View {
        let filtered = feed.entries(filter: filter)
        let entries = filtered.filter { state.inScope($0.task) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Activity")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text(state.goalScope == .all ? "What people and agents did across every goal, newest first." : "What people and agents did in the goals you follow and on your tasks, newest first.")
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        GoalScopeMenu(hidden: filtered.count - entries.count)
                            .padding(.trailing, 8)
                        Picker("", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    .id("top")

                    if entries.isEmpty {
                        PlaceholderView(title: "Nothing yet", icon: "waveform.path.ecg").frame(height: 240)
                    }
                    ForEach(days(entries.prefix(shown)), id: \.title) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(title: day.title)
                            LazyVStack(spacing: 0) {
                                ForEach(day.entries) { entry in row(entry) }
                            }
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke)))
                        }
                    }
                    if entries.count > shown { footer(total: entries.count).id("footer") }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 28)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // A new filter or scope starts again at the top, one page in.
            .onChange(of: filter) { shown = ActivityLog.pageSize; proxy.scrollTo("top", anchor: .top) }
            .onChange(of: state.goalScope) { shown = ActivityLog.pageSize; proxy.scrollTo("top", anchor: .top) }
            .onReceive(NotificationCenter.default.publisher(for: Self.demo)) { note in
                guard let parts = note.object as? [String] else { return }
                switch parts.first {
                case "seed": seed(Int(parts.count > 1 ? parts[1] : "") ?? 2400)
                case "more": shown += ActivityLog.pageSize
                case "bottom": proxy.scrollTo("footer", anchor: .bottom)
                case "top": proxy.scrollTo("top", anchor: .top)
                case "filter": filter = Filter(rawValue: parts.count > 1 ? parts[1] : "") ?? filter
                default: break
                }
            }
        }
    }

    /// The mockup's tasks with `count` events between them, a few minutes apart, for a big factory's Activity page.
    private func seed(_ count: Int) {
        var tasks = state.tasks
        guard !tasks.isEmpty else { return }
        let names = [FactoryData.me.firstName, "Planner", "Builder", FactoryData.chris.firstName, "Reviewer"]
        for n in 0..<count {
            tasks[n % tasks.count].activity.append(ActivityItem(who: names[n % names.count], text: "worked on step \(n % 7 + 1)", when: "\(n * 7 + 1)m"))
        }
        state.tasks = tasks
    }

    /// "Showing 50 of 2,140", and the next page.
    private func footer(total: Int) -> some View {
        HStack(spacing: 12) {
            Text("Showing \(shown.formatted()) of \(total.formatted())")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
            Spacer()
            SecondaryButton(title: "Show \(min(ActivityLog.pageSize, total - shown)) more") { shown += ActivityLog.pageSize }
                .fixedSize()
        }
        .padding(.horizontal, 4)
    }

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(agent: entry.who, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                (Text(entry.who.isHuman && entry.who.id == FactoryData.me.id ? "You" : entry.who.firstName).fontWeight(.semibold).foregroundColor(Theme.text)
                    + Text(" \(entry.text)").foregroundColor(Theme.text.opacity(0.85)))
                    .font(.system(size: 13))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.task.id).font(.system(size: 11, design: .monospaced))
                    Text(entry.task.title).lineLimit(1)
                    Circle().fill(FactoryData.goal(named: entry.task.goal).color).frame(width: 5, height: 5)
                    Text(entry.task.goal).lineLimit(1)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            Text(entry.when)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            state.destination = .goal(entry.task.goal)
            state.openFocus(entry.task.id)
        }
        .overlay(alignment: .bottom) { Hairline().padding(.leading, 46) }
    }
}
