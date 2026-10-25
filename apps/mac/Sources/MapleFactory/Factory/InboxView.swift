import SwiftUI

/// Everything across the workspace that's blocked on a human, grouped by what kind of attention it needs.
struct InboxView: View {
    @Environment(AppState.self) private var state
    @SwiftUI.State private var filter: InboxItem.Kind? = nil
    @SwiftUI.State private var mineOnly = true

    private var items: [InboxItem] { mineOnly ? state.myInbox : state.inbox }

    private var goalCount: Int {
        Set(items.map { state.task($0.taskID).goal }).count
    }
    private var things: String { items.count == 1 ? "1 thing" : "\(items.count) things" }
    private var goals: String { goalCount == 1 ? "1 goal" : "\(goalCount) goals" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 22)

                VStack(alignment: .leading, spacing: 26) {
                    ForEach(InboxItem.Kind.allCases, id: \.self) { kind in
                        let kindItems = state.inbox(kind, mine: mineOnly)
                        if (filter == nil || filter == kind), !kindItems.isEmpty {
                            group(kind, items: kindItems)
                        }
                    }
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Inbox")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(mineOnly
                         ? "\(things) across \(goals) \(items.count == 1 ? "is" : "are") waiting on you."
                         : "\(things) across \(goals) \(items.count == 1 ? "is" : "are") waiting on the team.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                scopePicker
            }

            HStack(spacing: 6) {
                chip("All", count: items.count, color: Theme.text, kind: nil)
                ForEach(InboxItem.Kind.allCases, id: \.self) { kind in
                    let count = state.inbox(kind, mine: mineOnly).count
                    if count > 0 {
                        chip(kind.shortTitle, count: count, color: kind.color, kind: kind)
                    }
                }
            }
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            scopeOption("For you", count: state.myInbox.count, mine: true) {
                AgentAvatar(agent: FactoryData.me, size: 16)
            }
            scopeOption("Team", count: state.inbox.count, mine: false) {
                Facepile(people: FactoryData.people, size: 16, ringColor: Theme.cardBG)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
    }

    private func scopeOption<Icon: View>(_ title: String, count: Int, mine: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        let active = mineOnly == mine

        return HStack(spacing: 6) {
            icon()
            Text(title)
            Text("\(count)").foregroundStyle(Theme.textMuted).monospacedDigit()
        }
        .font(.system(size: 12.5, weight: active ? .medium : .regular))
        .foregroundStyle(active ? Theme.text : Theme.textMuted)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.cardBG : .clear))
        .shadow(color: .black.opacity(active ? 0.08 : 0), radius: 1, y: 0.5)
        .contentShape(Rectangle())
        .onTapGesture { mineOnly = mine; filter = nil }
    }

    private func chip(_ title: String, count: Int, color: Color, kind: InboxItem.Kind?) -> some View {
        let active = filter == kind

        return HStack(spacing: 6) {
            if let kind {
                Image(systemName: kind.icon).font(.system(size: 10)).foregroundStyle(color)
            }
            Text(title)
            Text("\(count)").foregroundStyle(Theme.textMuted).monospacedDigit()
        }
        .font(.system(size: 12.5, weight: active ? .medium : .regular))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            Capsule()
                .fill(active ? Theme.fillSelected : .clear)
                .overlay(Capsule().strokeBorder(active ? .clear : Theme.stroke))
        )
        .contentShape(Capsule())
        .onTapGesture { filter = kind }
    }

    private func group(_ kind: InboxItem.Kind, items: [InboxItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: kind.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(kind.color)
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(items.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item)
                    if index < items.count - 1 { Hairline().padding(.leading, 52) }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func row(_ item: InboxItem) -> some View {
        let task = state.task(item.taskID)
        let goal = FactoryData.goal(named: task.goal)
        let selected = state.selectedTask == task.id

        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.kind.icon)
                .font(.system(size: 12))
                .foregroundStyle(item.kind.color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(item.kind.color.opacity(0.13)))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(goal.color).frame(width: 6, height: 6)
                    Text(goal.name)
                    Text(task.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textFaint)
                    Text("·").foregroundStyle(Theme.textFaint)
                    Text(item.message).lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            }

            Spacer(minLength: 12)

            if mineOnly {
                if let agent = task.agent { AgentAvatar(agent: agent, size: 20) }
            } else {
                HStack(spacing: 6) {
                    AvatarPair(owner: item.assignee, agent: task.agent, size: 20)
                    Text(item.assignee.id == FactoryData.me.id ? "You" : item.assignee.firstName)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 34, alignment: .leading)
                }
            }
            if let viewer = task.viewers.first {
                PresenceTag(person: viewer)
            }

            actionButton(item)

            Text(item.when)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textFaint)
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(selected ? Theme.fillSubtle : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.openFocus(task.id) }
        .onTapGesture { state.selectedTask = task.id }
    }

    @ViewBuilder private func actionButton(_ item: InboxItem) -> some View {
        let kind = item.kind
        let primary = kind == .approval || kind == .review

        Text(kind.action)
            .font(.system(size: 12, weight: primary ? .semibold : .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
            )
            .contentShape(Rectangle())
            .onTapGesture { perform(item) }
    }

    private func perform(_ item: InboxItem) {
        switch item.kind {
        case .approval:
            state.approvePlan(item.taskID)
        case .failing:
            state.rerunFailedChecks(item.taskID)
        case .mention:
            state.dismissedMentions.insert(item.id)
            state.openFocus(item.taskID)
        case .review, .question:
            state.openFocus(item.taskID)
        }
    }
}
