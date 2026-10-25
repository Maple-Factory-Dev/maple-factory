import SwiftUI

extension FactoryTask {
    /// Planner and builder agents can be redirected until the work is merged or cancelled.
    var isSteerable: Bool {
        agent != nil && [.planning, .awaitingApproval, .building, .reviewing].contains(state)
    }

    var activeStep: Int? { plan.firstIndex { $0.progress == .active } }

    /// When a new change request will be picked up, phrased for this task's stage.
    var steerTiming: String {
        let name = agent?.name ?? "The agent"
        switch state {
        case .planning: return "\(name) will fold this into the plan"
        case .awaitingApproval: return "\(name) will post plan v\(planVersion + 1)"
        case .building: return activeStep.map { "Applies after step \($0 + 1)" } ?? "Applies at the next step"
        case .reviewing: return "Sends \(id) back to Building"
        default: return "Queued"
        }
    }
}

// MARK: - Plan

struct PlanSection: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask

    @SwiftUI.State private var showChanges = true
    @SwiftUI.State private var hovered: Int? = nil
    @SwiftUI.State private var tweaking: Int? = nil
    @SwiftUI.State private var tweakText = ""
    @FocusState private var tweakFocused: Bool

    private var hasChanges: Bool { task.plan.contains { $0.change != nil } }
    private var doneCount: Int { task.plan.filter { $0.progress == .done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 0) {
                ForEach(Array(task.plan.enumerated()), id: \.offset) { index, step in
                    stepRow(index, step)
                    if index < task.plan.count - 1 { Hairline().padding(.leading, 28) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SectionLabel(title: task.state == .building ? "Progress" : task.state == .planning ? "Draft plan" : "Plan")

            if task.state == .building {
                Text("\(doneCount) of \(task.plan.count) steps")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
            if task.planVersion > 1 {
                Text("v\(task.planVersion)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.State.planning)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(Theme.State.planning.opacity(0.13)))
            }
            Spacer()
            if hasChanges {
                Text(showChanges ? "Hide changes" : "Show changes from v\(task.planVersion - 1)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { showChanges.toggle() } }
            }
        }
    }

    private func stepRow(_ index: Int, _ step: PlanStep) -> some View {
        let added = showChanges && step.change.map { if case .added = $0 { true } else { false } } == true
        let queued = state.changeRequests(for: task).filter { $0.anchor == "Step \(index + 1)" && $0.status != .applied }
        let canTweak = task.isSteerable && task.state != .reviewing && step.progress != .done && !step.file.isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                indicator(index, step)

                VStack(alignment: .leading, spacing: 3) {
                    if showChanges, case let .modified(from)? = step.change {
                        Text(from)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textFaint)
                            .strikethrough(color: Theme.State.cancelled.opacity(0.6))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(step.text)
                            .font(Theme.uiFont)
                            .foregroundStyle(step.progress == .active && task.state == .planning ? Theme.textMuted : Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if showChanges, let change = step.change {
                            changeTag(change)
                        }
                    }
                    if !step.file.isEmpty {
                        Text(step.file)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                    }
                    ForEach(queued) { request in
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .semibold))
                            Text("\(request.author.firstName): \(request.text)").lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.State.awaitingApproval)
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 4)

                if canTweak, hovered == index, tweaking != index {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil").font(.system(size: 9.5, weight: .semibold))
                        Text("Tweak")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.cardBG)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.stroke))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        tweaking = index
                        tweakText = ""
                        tweakFocused = true
                    }
                }
            }

            if tweaking == index {
                tweakEditor(index)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, added ? 8 : 0)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(added ? Theme.State.merged.opacity(0.08) : .clear)
        )
        .overlay(alignment: .leading) {
            if added {
                Rectangle().fill(Theme.State.merged).frame(width: 2).padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
    }

    @ViewBuilder private func indicator(_ index: Int, _ step: PlanStep) -> some View {
        switch step.progress {
        case .done?:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.State.merged)
                .frame(width: 18)
        case .active?:
            ProgressView().controlSize(.mini).frame(width: 18)
        default:
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.fill))
        }
    }

    private func changeTag(_ change: PlanStep.Change) -> some View {
        let (label, color): (String, Color) = switch change {
        case .added: ("New", Theme.State.merged)
        case .modified: ("Changed", Theme.State.awaitingApproval)
        }
        return Text(label)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func tweakEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("What should \(task.agent?.name ?? "the agent") change about step \(index + 1)?", text: $tweakText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($tweakFocused)
                .onSubmit { sendTweak(index) }
            HStack(spacing: 8) {
                Text(task.steerTiming)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text("Cancel")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .onTapGesture { tweaking = nil }
                Text("Send to \(task.agent?.name ?? "agent")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent))
                    .onTapGesture { sendTweak(index) }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.cardBG)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.State.planning.opacity(0.5)))
        )
        .padding(.leading, 28)
    }

    private func sendTweak(_ index: Int) {
        let text = tweakText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state.steering[task.id, default: []].append(
            ChangeRequest(author: FactoryData.me, text: text, anchor: "Step \(index + 1)", timing: task.steerTiming)
        )
        tweaking = nil
        tweakText = ""
    }
}

// MARK: - Live strip

/// What a planner or builder is doing right now, with a pause control.
struct LiveStrip: View {
    let task: FactoryTask
    @SwiftUI.State private var paused = false

    var body: some View {
        HStack(spacing: 9) {
            if paused {
                Image(systemName: "pause.circle.fill").foregroundStyle(Theme.State.awaitingApproval)
            } else {
                ProgressView().controlSize(.mini)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(paused ? "\(task.agent?.name ?? "Agent") is paused" : "\(task.agent?.name ?? "Agent") is \(task.state == .planning ? "planning" : "building")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                if let log = task.liveLog {
                    Text(log)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 9))
                Text(paused ? "Resume" : "Pause")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
            )
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { paused.toggle() } }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(task.state.color.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(task.state.color.opacity(0.22)))
        )
    }
}

// MARK: - Change requests

struct ChangeRequestList: View {
    let task: FactoryTask
    let requests: [ChangeRequest]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(requests) { request in
                HStack(alignment: .top, spacing: 10) {
                    AgentAvatar(agent: request.author, size: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(request.author.id == FactoryData.me.id ? "You" : request.author.firstName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            if let anchor = request.anchor {
                                Text(anchor)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Theme.textMuted)
                                    .padding(.horizontal, 6)
                                    .frame(height: 17)
                                    .background(Capsule().fill(Theme.fill))
                            }
                            Spacer()
                            Text(request.when)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textFaint)
                        }
                        Text(request.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            ChangeStatusChip(status: request.status)
                            if let timing = request.timing {
                                Text(timing)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                }
            }

            if task.state == .awaitingApproval, requests.contains(where: { $0.status != .applied }), !task.approvals.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
                    Text("Approvals reset when \(task.agent?.name ?? "the agent") posts plan v\(task.planVersion + 1).")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
            }
        }
    }
}

struct ChangeStatusChip: View {
    let status: ChangeRequest.Status

    var body: some View {
        let (label, icon, color): (String, String, Color) = switch status {
        case .queued: ("Queued", "clock", Theme.State.awaitingApproval)
        case .applying: ("Applying", "arrow.triangle.2.circlepath", Theme.State.building)
        case .applied: ("Applied", "checkmark", Theme.State.merged)
        }

        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(label)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}
