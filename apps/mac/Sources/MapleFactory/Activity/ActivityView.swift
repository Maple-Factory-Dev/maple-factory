import SwiftUI

/// Everything happening across the factory, newest first: people approving and steering, agents
/// planning, proving and reviewing, merges. Each line opens its task.
struct ActivityView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @State private var filter: Filter = .everyone

    enum Filter: String, CaseIterable { case everyone = "Everyone", people = "People", agents = "Agents", mine = "My tasks" }

    struct Entry: Identifiable {
        let id: String
        let task: FactoryTask
        let who: Person
        let isAgent: Bool
        let text: String
        let at: Date?
        let when: String
    }

    private static let agents: Set<String> = ["planner", "builder", "reviewer", "factory"]

    /// What the filter picks, in the goals the scope shows.
    private var entries: [Entry] { filtered.filter { state.inScope($0.task) } }

    /// Live: every task's events with their times. The mockup's tasks only have relative labels.
    private var filtered: [Entry] {
        let all: [Entry]
        if state.isLive {
            all = client.tasks.flatMap { wire -> [Entry] in
                guard let task = state.tasks.first(where: { $0.id == wire.id }) else { return [] }
                return wire.events.enumerated().map { index, event in
                    Entry(id: "\(wire.id)-\(index)", task: task, who: LiveAdapter.person(event.who, members: client.members),
                          isAgent: Self.agents.contains(event.who), text: event.text,
                          at: Date(timeIntervalSince1970: Double(event.at) / 1000), when: LiveAdapter.ago(event.at))
                }
            }
            .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
        } else {
            all = state.tasks.flatMap { task in
                task.activity.enumerated().map { index, item in
                    let person = FactoryData.people.first { $0.name == item.who || $0.firstName == item.who }
                    return Entry(id: "\(task.id)-\(index)", task: task, who: person ?? Agent(name: item.who, color: Theme.State.building),
                                 isAgent: person == nil, text: item.text, at: nil, when: item.when)
                }
            }
            .sorted { state.minutesAgo($0.when) < state.minutesAgo($1.when) }
        }
        return all.filter { entry in
            switch filter {
            case .everyone: true
            case .people: !entry.isAgent
            case .agents: entry.isAgent
            case .mine: entry.task.owner.id == FactoryData.me.id
            }
        }
    }

    /// Entries by day ("Today", "Yesterday", "Oct 21"); the mockup's undated ones are all "Recent".
    private var days: [(title: String, entries: [Entry])] {
        var groups: [(title: String, entries: [Entry])] = []
        for entry in entries.prefix(300) {
            let title = entry.at.map { date in
                Calendar.current.isDateInToday(date) ? "Today"
                    : Calendar.current.isDateInYesterday(date) ? "Yesterday"
                    : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            } ?? "Recent"
            if groups.last?.title == title { groups[groups.count - 1].entries.append(entry) } else { groups.append((title, [entry])) }
        }
        return groups
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
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

                if entries.isEmpty {
                    PlaceholderView(title: "Nothing yet", icon: "waveform.path.ecg").frame(height: 240)
                }
                ForEach(days, id: \.title) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: day.title)
                        VStack(spacing: 0) {
                            ForEach(day.entries) { entry in row(entry) }
                        }
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke)))
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
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
