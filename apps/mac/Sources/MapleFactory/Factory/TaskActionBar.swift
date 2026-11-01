import SwiftUI

/// A next step for a task that's still being shaped: drafting, waiting in the queue to plan, or parked
/// in the backlog. The same steps the ⋯ menu offers, shown as buttons under the title.
enum TaskNextAction: Equatable {
    case sendToPlanning, planAgain, approveAndBuild, queue, schedule, sendToBacklog, startNow, runNow

    var title: String {
        switch self {
        case .sendToPlanning: "Send to planning"
        case .planAgain: "Plan again"
        case .approveAndBuild: "Approve & build"
        case .queue: "Queue"
        case .schedule: "Schedule…"
        case .sendToBacklog: "Send to backlog"
        case .startNow: "Start now"
        case .runNow: "Run now"
        }
    }

    var icon: String {
        switch self {
        case .sendToPlanning, .planAgain: "paperplane"
        case .approveAndBuild: "hammer"
        case .queue: "list.number"
        case .schedule: "clock"
        case .sendToBacklog: TaskState.backlog.icon
        case .startNow: "play"
        case .runNow: "bolt"
        }
    }

    var help: String {
        switch self {
        case .runNow: "Run now, skip the slot wait"
        default: title
        }
    }
}

enum TaskNextActions {
    /// What `task` can do next, primary first; empty when its state has nothing to pick (or its own block shows it).
    static func `for`(_ task: FactoryTask) -> [TaskNextAction] {
        switch task.state {
        case .drafting:
            return [.sendToPlanning, .queue, .schedule, .sendToBacklog]
        case .planning:
            return task.queued ? [.startNow, .runNow, .schedule] : []
        case .backlog:
            let planned = !task.plan.isEmpty
            return (planned ? [.approveAndBuild] : []) + [planned ? .planAgain : .sendToPlanning]
        default:
            return []
        }
    }
}

/// The task's next steps as a row of buttons under its title; nothing when there are none.
struct TaskActionBar: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @State private var scheduling = false

    var body: some View {
        let actions = TaskNextActions.for(task)
        if let primary = actions.first {
            let busy = appState.isInFlight(task.id, .approvePlan)
            FlowLayout(spacing: 8) {
                PrimaryButton(title: primary.title, icon: primary.icon, busy: busy && primary == .approveAndBuild,
                              busyTitle: "Approving…") { perform(primary) }
                    .fixedSize()
                    .help(primary.help)
                ForEach(actions.dropFirst(), id: \.self) { action in
                    Button { perform(action) } label: {
                        Label(action.title, systemImage: action.icon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(busy)
                    .help(action.help)
                    .popover(isPresented: action == .schedule ? $scheduling : .constant(false), arrowEdge: .bottom) {
                        SchedulePopover(task: task)
                    }
                }
            }
        }
    }

    private func perform(_ action: TaskNextAction) {
        switch action {
        case .sendToPlanning, .planAgain: appState.plan(task.id)
        case .approveAndBuild: appState.approvePlan(task.id)
        case .queue: appState.queue(task.id, before: nil)
        case .schedule: scheduling = true
        case .sendToBacklog: appState.sendToBacklog(task.id)
        case .startNow: appState.startNow(task.id)
        case .runNow: appState.forceStart(task.id)
        }
    }
}
