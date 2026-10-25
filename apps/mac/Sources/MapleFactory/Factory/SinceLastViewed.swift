import SwiftUI

/// "What changed while I was away": other people's and agents' activity on a task since you last opened it.
struct SinceLastViewedBanner: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    var compact = false

    var body: some View {
        let changes = state.unseenChanges(for: task)

        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Circle().fill(Theme.State.building).frame(width: 7, height: 7)
                    Text("\(changes.count) change\(changes.count == 1 ? "" : "s") since you last looked")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let label = state.lastViewedLabel(for: task) {
                        Text(label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Text("Mark as seen")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.State.building)
                        .contentShape(Rectangle())
                        .onTapGesture { state.markSeen(task.id) }
                }

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(changes.prefix(compact ? 3 : 8).enumerated()), id: \.offset) { _, change in
                        HStack(spacing: 8) {
                            if let who = FactoryData.identity(named: change.who) {
                                AgentAvatar(agent: who, size: 18)
                            }
                            (Text(FactoryData.identity(named: change.who)?.firstName ?? change.who)
                                .foregroundStyle(Theme.text).fontWeight(.medium)
                             + Text("  \(change.text)").foregroundStyle(Theme.textMuted))
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                            Spacer()
                            Text(change.when)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    if compact, changes.count > 3 {
                        Text("+\(changes.count - 3) more")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.State.building.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.State.building.opacity(0.25)))
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

extension FactoryData {
    /// Resolves an activity author ("Chris", "Maple-1", "Andrea Fomera") to a person or agent.
    static func identity(named name: String) -> Agent? {
        people.first { $0.name == name || $0.firstName == name } ?? agents.first { $0.name == name } ?? (reviewer.name == name ? reviewer : nil)
    }
}
