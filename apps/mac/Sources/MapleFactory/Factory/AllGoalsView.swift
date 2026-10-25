import SwiftUI

/// Every goal in the org, to find and follow ones beyond your own. The sidebar shows only those you
/// follow, which in a big org is a handful of hundreds.
struct AllGoalsView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    @State private var query = ""
    @State private var show: Show = .all
    @State private var team: String? = nil
    @State private var archived = false

    enum Show: String, CaseIterable { case all = "All", following = "Following", notFollowing = "Not following" }

    private var teams: [String] {
        state.isLive ? client.teams : Array(Set(FactoryData.goals.compactMap(\.team))).sorted()
    }

    private var shown: [Goal] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return FactoryData.goals
            .filter { $0.archived == archived }
            .filter { team == nil || $0.team?.caseInsensitiveCompare(team!) == .orderedSame }
            .filter {
                switch show {
                case .all: true
                case .following: state.isFollowing($0)
                case .notFollowing: !state.isFollowing($0)
                }
            }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.prefix.lowercased().hasPrefix(q) || $0.summary.lowercased().contains(q) }
            // Yours first, then by name.
            .sorted { (state.isFollowing($0) ? 0 : 1, $0.name.lowercased()) < (state.isFollowing($1) ? 0 : 1, $1.name.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("All goals")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Every goal in the org. Follow one to keep it in your sidebar; you already follow the ones you lead, work in, or are on the team for.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: 620, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            filters
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Hairline()

            let goals = shown
            if goals.isEmpty {
                Text(query.isEmpty && team == nil ? "No goals here." : "No goals match.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(goals) { goal in
                            row(goal)
                            Hairline().padding(.leading, 24)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filters: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                TextField("Search goals", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 120, maxWidth: 240)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke)))

            Picker("", selection: $show) {
                ForEach(Show.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if !teams.isEmpty {
                Menu {
                    Button("Any team") { team = nil }
                    Divider()
                    ForEach(teams, id: \.self) { slug in Button("@\(slug)") { team = slug } }
                } label: {
                    Text(team.map { "@\($0)" } ?? "Any team")
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 12.5))
                .fixedSize()
            }

            Spacer(minLength: 0)

            Toggle("Archived", isOn: $archived)
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
        }
    }

    private func row(_ goal: Goal) -> some View {
        let stats = state.stats(for: goal)
        let following = state.isFollowing(goal)

        return HStack(spacing: 12) {
            ProgressRing(progress: Double(stats.merged) / Double(max(stats.total, 1)), color: goal.color, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(goal.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if !goal.prefix.isEmpty {
                        Text(goal.prefix)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textFaint)
                    }
                    if let team = goal.team {
                        Text("@\(team)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Capsule().fill(Theme.fill))
                    }
                }
                if !goal.summary.isEmpty {
                    Text(goal.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if !goal.lead.name.isEmpty {
                HStack(spacing: 6) {
                    AgentAvatar(agent: goal.lead, size: 18)
                    Text(goal.lead.id == FactoryData.me.id ? "You" : goal.lead.firstName)
                        .lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 110, alignment: .leading)
            }
            Text(stats.total == 1 ? "\(stats.merged) of 1 task" : "\(stats.merged) of \(stats.total) tasks")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .frame(width: 90, alignment: .trailing)
            FollowButton(following: following) { state.setFollowing(goal, !following) }
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .frame(height: goal.summary.isEmpty ? 48 : 58)
        .contentShape(Rectangle())
        .onTapGesture { state.destination = .goal(goal.name) }
        .contextMenu { GoalContextMenu(goal: goal) }
        // Its Follow button stays its own control; opening the goal is the row's action.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(goal.name)
        .accessibilityAction(named: "Open") { state.destination = .goal(goal.name) }
    }
}

/// What right-clicking a goal offers, in the sidebar and in All goals.
struct GoalContextMenu: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    let goal: Goal

    var body: some View {
        let following = state.isFollowing(goal)
        Button("Open") { state.destination = .goal(goal.name) }
        Button(following ? "Unfollow" : "Follow") { state.setFollowing(goal, !following) }
        if state.isLive, let live = client.goal(named: goal.name) {
            Divider()
            Button("Edit Goal…") { state.goalSheet = .edit(live.id) }
            Button("New Task in \(goal.name)…") { state.startCompose(goal: goal.name) }
                .disabled(goal.archived)
            Divider()
            Button(goal.archived ? "Unarchive" : "Archive Goal") {
                client.send(.goalArchive(.init(id: live.id, archived: !goal.archived)))
            }
        }
    }
}

/// "Goals I follow" / "All goals" for the views that span goals, with how many more the other shows.
struct GoalScopeMenu: View {
    @Environment(AppState.self) private var state
    /// How many items the goals you don't follow would add.
    let hidden: Int

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button { state.goalScope = .following } label: {
                    Label("Goals I follow", systemImage: state.goalScope == .following ? "checkmark" : "")
                }
                Button { state.goalScope = .all } label: {
                    Label("All goals", systemImage: state.goalScope == .all ? "checkmark" : "")
                }
            } label: {
                Label(state.goalScope == .following ? "Goals I follow" : "All goals", systemImage: "scope")
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 12.5))
            .fixedSize()
            .help("Which goals this shows. Your own tasks, mentions of you and hands raised to you always show.")
            if state.goalScope == .following, hidden > 0 {
                Button("+\(hidden) in other goals") { state.goalScope = .all }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }
}

/// "Follow" / "Following": whether a goal is in your sidebar.
struct FollowButton: View {
    let following: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: following ? (hovering ? "xmark" : "checkmark") : "plus")
                    .font(.system(size: 9.5, weight: .bold))
                Text(following ? (hovering ? "Unfollow" : "Following") : "Follow")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(following ? Theme.textMuted : Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(following ? Color.clear : Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(following ? "In your sidebar. Unfollow to take it out." : "Put it in your sidebar")
    }
}
