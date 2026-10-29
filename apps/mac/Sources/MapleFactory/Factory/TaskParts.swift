import SwiftUI

// Building blocks shared by the task inspector (sidebar) and the full-focus task view.

enum ComposerMode { case steer, comment }

struct TaskSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title)
            content
        }
    }
}

struct ViewerPill: View {
    let viewer: Person

    var body: some View {
        HStack(spacing: 5) {
            AgentAvatar(agent: viewer, size: 16, online: true)
            Text("\(viewer.firstName) is here")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(viewer.color)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(Capsule().fill(viewer.color.opacity(0.12)))
    }
}

/// State badge followed by "owner → agent".
struct TaskOwnership: View {
    let task: FactoryTask
    var avatarSize: CGFloat = 18

    var body: some View {
        HStack(spacing: 8) {
            StateBadge(state: task.state)
            AgentAvatar(agent: task.owner, size: avatarSize)
            Text(task.owner.id == FactoryData.me.id ? "You" : task.owner.firstName)
                .foregroundStyle(Theme.text)
            if let agent = task.agent {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                AgentAvatar(agent: agent, size: avatarSize)
                Text(agent.name)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
    }
}

/// The ⋯ menu on a task: what to do next, editing it, and getting at it, with Cancel's confirmation
/// and the Rename alert.
struct TaskActionsMenu<Label: View>: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @ViewBuilder var label: Label
    @State private var confirmCancel = false
    @State private var rename = false

    var body: some View {
        Menu {
            TaskActionButtons(task: task, confirmCancel: $confirmCancel, rename: $rename)
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Task actions")
        .cancelTaskConfirmation(task: task, isPresented: Binding(
            get: { confirmCancel || appState.confirmingCancel == task.id },
            set: { if !$0 { confirmCancel = false; appState.confirmingCancel = nil } }
        ))
        .renameTask(task: task, isPresented: $rename)
    }
}

/// Everything you can do to a task, for a menu or a row's context menu, in three groups: next
/// (Send to planning, Retry, Cancel task…), editing (Rename…, teammates' machines) and getting at
/// it (pull request, branch, ID). Cancel and Rename only ask; the caller shows the confirmation
/// (`cancelTaskConfirmation`) and the alert (`renameTask`).
struct TaskActionButtons: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @Binding var confirmCancel: Bool
    @Binding var rename: Bool

    private var open: Bool { task.state != .merged && task.state != .cancelled }
    private var branch: String? { task.gitBranch ?? task.pr?.branch }

    var body: some View {
        if task.state != .merged {
            if task.state == .drafting {
                Button { appState.plan(task.id) } label: { Label("Send to planning", systemImage: "paperplane") }
            }
            // Waiting on its plan's approval, nothing is running to retry; request changes instead.
            if task.state != .drafting && task.state != .awaitingApproval {
                Button { appState.retry(task.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
            }
            if task.state != .cancelled {
                Button(role: .destructive) { confirmCancel = true } label: { Label("Cancel task…", systemImage: "xmark.circle") }
            }
            Divider()
        }
        if open {
            Button { rename = true } label: { Label("Rename…", systemImage: "pencil") }
            Toggle(isOn: Binding(get: { task.shareable }, set: { appState.setShareable(task.id, $0) })) {
                Label("Run on teammates' machines", systemImage: "person.3")
            }
            Divider()
        }
        if let pr = task.pr, !pr.isLocal {
            Button { appState.openPullRequest(task.id) } label: { Label("Open pull request", systemImage: "arrow.up.right.square") }
        }
        if branch != nil {
            Button { appState.copyBranch(task.id) } label: { Label("Copy branch name", systemImage: "arrow.triangle.branch") }
        }
        Button { appState.copyID(task.id) } label: { Label("Copy ID", systemImage: "number") }
    }
}

extension View {
    /// Asks before cancelling `task`, saying what cancelling stops.
    func cancelTaskConfirmation(task: FactoryTask, isPresented: Binding<Bool>) -> some View {
        modifier(CancelTaskConfirmation(task: task, isPresented: isPresented))
    }

    /// Asks for `task`'s new title.
    func renameTask(task: FactoryTask, isPresented: Binding<Bool>) -> some View {
        modifier(RenameTask(task: task, isPresented: isPresented))
    }
}

private struct RenameTask: ViewModifier {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @Binding var isPresented: Bool
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename \(task.id)", isPresented: $isPresented) {
                TextField("Title", text: $title)
                Button("Rename") { appState.rename(task.id, title: title) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A new title everyone sees on the board and in the sidebar.")
            }
            .onChange(of: isPresented) { if isPresented { title = task.title } }
    }
}

private struct CancelTaskConfirmation: ViewModifier {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog("Cancel \(task.id)?", isPresented: $isPresented) {
            Button("Cancel Task", role: .destructive) { appState.cancel(task.id) }
            Button("Keep Working", role: .cancel) {}
        } message: {
            Text(Self.stops(task))
        }
    }

    /// What cancelling ends, in a sentence.
    static func stops(_ task: FactoryTask) -> String {
        var parts: [String] = []
        if let worker = task.worker { parts.append("its running \(worker.role) session") }
        else if task.state == .planning || task.state == .building || task.liveLog != nil { parts.append("its running session") }
        if let pr = task.pr, pr.state == .open || pr.state == .draft { parts.append("its open PR #\(pr.number)") }
        if task.state == .awaitingApproval { parts.append("the pending plan approval") }
        if task.state == .reviewing, task.pr?.state != .merged { parts.append("the pending review") }
        if task.question != nil || task.hand != nil { parts.append("the open question to you") }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.first
        return (list.map { "This stops \($0). " } ?? "") + "Its branch stays, and you can pick it back up with Retry."
    }
}

struct QuestionBlock: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    let question: String
    @State private var replying = false
    @State private var reply = ""

    private var options: [String] { appState.isLive ? task.questionOptions : ["Auto-provision", "Require invite"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Theme.State.planning)
                Text("\(task.agent?.name ?? "Agent") is asking")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Text(question)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.text.opacity(0.9))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if let reply = task.comments.last(where: { $0.via != nil }) {
                HStack(alignment: .top, spacing: 8) {
                    AgentAvatar(agent: reply.author, size: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(reply.author.firstName) replied in \(reply.via ?? "") · \(reply.when) ago")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                        Text(reply.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardBG.opacity(0.7)))
            } else if task.intakeID != nil {
                Label("Also posted to the requester's Slack thread", systemImage: "number")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
            }
            FlowLayout(spacing: 6) {
                ForEach(options + ["Reply…"], id: \.self) { answer in
                    Text(answer)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            Capsule()
                                .fill(Theme.cardBG)
                                .overlay(Capsule().strokeBorder(Theme.stroke))
                        )
                        .contentShape(Capsule())
                        .onTapGesture {
                            if answer == "Reply…" { replying = true } else { appState.answer(task.id, text: answer) }
                        }
                }
            }
            if replying {
                HStack(spacing: 6) {
                    TextField("Your answer", text: $reply)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.cardBG).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke)))
                        .onSubmit(sendReply)
                    Text("Send")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.State.planning))
                        .contentShape(Rectangle())
                        .onTapGesture(perform: sendReply)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.State.planning.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.State.planning.opacity(0.25)))
        )
    }
}

extension QuestionBlock {
    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        appState.answer(task.id, text: text)
        reply = ""
        replying = false
    }
}

// MARK: - Decisions

/// Side by side while both labels fit with their padding, stacked when the column is too narrow.
struct DecisionButtons<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(spacing: 8) { content }
        }
    }
}

struct RequestChangesButton: View {
    /// Off while the approval or merge beside it is in flight.
    var enabled = true
    var action: () -> Void

    var body: some View {
        SecondaryButton(title: "Request changes", enabled: enabled, action: action)
    }
}

struct SecondaryButton: View {
    let title: String
    var enabled = true
    var action: () -> Void

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            )
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .disabled(!enabled)
            .animation(.snappy(duration: 0.2), value: enabled)
    }
}

struct ApprovalBlock: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    var onRequestChanges: () -> Void

    var body: some View {
        let needed = state.risk(for: task)?.approvals ?? task.approvalsNeeded
        let iApproved = task.approvals.contains { $0.id == FactoryData.me.id }

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionLabel(title: "Approvals")
                Text("\(task.approvals.count) of \(needed)")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                SignOffMeter(done: task.approvals.count, needed: needed)
            }
            ForEach(task.approvals) { person in
                SignOffRow(person: person, text: "approved v\(task.planVersion)")
            }
            if task.approvals.count < needed {
                PendingSignOffRow(text: iApproved ? "Needs one more approver" : "Waiting on you", highlight: !iApproved)
            }
            if !iApproved {
                let approving = state.isInFlight(task.id, .approvePlan)
                DecisionButtons {
                    PrimaryButton(title: "Approve plan", icon: "checkmark", busy: approving, busyTitle: "Approving…") {
                        state.approvePlan(task.id)
                    }
                    RequestChangesButton(enabled: !approving, action: onRequestChanges)
                }
                .padding(.top, 2)
            }
        }
    }
}

/// Merging is gated on passing proofs, passing required CI, and however many human reviews the
/// task's risk calls for. When the goal's policy allows it, the factory merges on its own.
struct ReviewActions: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    var onRequestChanges: () -> Void

    var body: some View {
        let gate = state.mergeGate(for: task)
        let iReviewed = task.reviews.contains { $0.id == FactoryData.me.id }
        let autoMerging = state.autoMerging.contains(task.id)

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                gateRow("Proofs", ready: gate.proofsReady, failed: gate.failedProofs > 0,
                        detail: gate.proofsReady ? "All proven" : gate.failedProofs > 0 ? "\(gate.failedProofs) failed" : "\(gate.unproven) pending")
                gateRow("CI", ready: gate.checksReady, failed: gate.failedChecks > 0,
                        detail: gate.checksReady ? "Required checks passing" : gate.failedChecks > 0 ? "\(gate.failedChecks) failing" : "Running")
                if let detail = gate.autoReviewDetail {
                    let verdict = task.autoReview?.current?.verdict
                    gateRow("Auto review", ready: gate.autoReviewReady,
                            failed: verdict == .changesRequested || verdict == .escalated, detail: detail)
                }
                gateRow("Reviews", ready: gate.reviewsReady, failed: false,
                        detail: gate.reviewsNeeded == 0 ? "Not required" : "\(task.reviews.count) of \(gate.reviewsNeeded)")
            }

            if gate.reviewsNeeded > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(task.reviews) { person in
                        SignOffRow(person: person, text: "approved the changes")
                    }
                    if !gate.reviewsReady {
                        if !gate.autoReviewReady && !iReviewed {
                            PendingSignOffRow(text: "Waiting on the automatic review", highlight: false)
                        } else {
                            PendingSignOffRow(text: iReviewed ? "Needs one more reviewer" : "Waiting on you", highlight: !iReviewed)
                        }
                    }
                }
            }

            if autoMerging {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Factory is merging #\(task.pr?.number ?? 0)…")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.State.merged)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.State.merged.opacity(0.1)))
            } else if let hand = task.hand, hand.reason == .mergeFailed {
                // The merge failed: a person picks how it goes on, so Merge gives way to the hand's options.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: hand.reason.icon).foregroundStyle(hand.reason.color)
                    Text(hand.explanation).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                DecisionButtons {
                    PrimaryButton(title: "Send back to fix", icon: "arrow.uturn.backward") {
                        state.resolveHand(task.id, option: hand.options.first { $0.title == "Send it back to fix" }, note: "")
                    }
                    SecondaryButton(title: "Retry merge") {
                        state.resolveHand(task.id, option: hand.options.first { $0.title == "Try the merge again" }, note: "")
                    }
                    RequestChangesButton(action: onRequestChanges)
                }
            } else {
                let approving = state.isInFlight(task.id, .approveChanges)
                let merging = state.isInFlight(task.id, .merge)
                DecisionButtons {
                    if !gate.autoReviewReady && !gate.reviewsReady && !iReviewed {
                        // The server refuses approvals until the reviewer passes the round, so say so instead of failing silently.
                        PrimaryButton(title: "Approve after review", icon: "hourglass", enabled: false) {}
                    } else if !gate.reviewsReady && !iReviewed {
                        PrimaryButton(title: "Approve changes", icon: "checkmark", busy: approving, busyTitle: "Approving…") {
                            state.approveChanges(task.id)
                        }
                    } else {
                        PrimaryButton(title: "Merge", icon: "arrow.triangle.merge", enabled: gate.canMerge,
                                      busy: merging, busyTitle: "Merging #\(task.pr?.number ?? 0)…") {
                            state.merge(task.id)
                        }
                    }
                    RequestChangesButton(enabled: !approving && !merging, action: onRequestChanges)
                }
            }

            statusLine(gate)
        }
    }

    private func gateRow(_ label: String, ready: Bool, failed: Bool, detail: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: ready ? "checkmark.circle.fill" : failed ? "xmark.circle.fill" : "circle.dashed")
                .font(.system(size: 11.5))
                .foregroundStyle(ready ? Theme.State.merged : failed ? Theme.State.cancelled : Theme.textFaint)
            Text(label).foregroundStyle(Theme.text)
            Spacer()
            Text(detail).foregroundStyle(failed ? Theme.State.cancelled : Theme.textMuted)
        }
        .font(.system(size: 12))
    }

    private func statusLine(_ gate: MergeGate) -> some View {
        let risk = state.risk(for: task)
        let level = risk?.level.title.lowercased() ?? "this"
        let (icon, text, color): (String, String, Color) = {
            if task.hand?.reason == .mergeFailed {
                return ("hand.raised", "Nothing merges it again until someone picks a way forward.", Theme.textMuted)
            }
            if !gate.autoReviewReady {
                switch task.autoReview?.current?.verdict {
                case .changesRequested?:
                    return ("arrow.triangle.2.circlepath", "The reviewer asked for changes; the builder is fixing them. You can approve once it passes.", Theme.textMuted)
                case .escalated?:
                    return ("exclamationmark.triangle", "The reviewer escalated this round. Approval unlocks once the automatic review passes.", Theme.textMuted)
                default:
                    let round = gate.autoReviewRound.map { "round \($0)" } ?? "its first round"
                    return ("hourglass", "The factory's reviewer is on \(round). You can approve once it passes.", Theme.textMuted)
                }
            }
            if let acceptance = risk?.acceptance {
                return ("bolt.shield", "\(acceptance.acceptedBy.firstName) accepted \(level) risk for \(task.goal). The factory merges once proofs and CI pass.", Theme.State.merged)
            }
            if gate.autoMerge {
                return ("bolt.fill", "\(risk?.level.title ?? "Low") risk: auto-merges once proofs and CI pass.", Theme.State.merged)
            }
            if gate.canMerge {
                return ("hand.tap", "Ready. Auto-merge is off for \(level) risk, so a person merges.", Theme.textMuted)
            }
            return ("lock", "Merge unlocks when proofs, CI and reviews are all green.", Theme.textMuted)
        }()

        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(color)
    }
}

struct PrimaryButton: View {
    let title: String
    let icon: String
    var enabled = true
    /// Sent and waiting on the factory: a spinner and `busyTitle`, and taps do nothing.
    var busy = false
    var busyTitle: String? = nil
    var color = Theme.approve
    var action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.mini).tint(.white)
            } else {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
            }
            Text(busy ? busyTitle ?? title : title)
                .contentTransition(.opacity)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(enabled ? .white : Theme.textFaint)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(enabled ? color.opacity(busy ? 0.7 : 1) : Theme.fill))
        .contentShape(Rectangle())
        .onTapGesture { if enabled && !busy { action() } }
        .disabled(!enabled || busy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(busy ? busyTitle ?? title : title)
        .accessibilityAddTraits(.isButton)
        .animation(.snappy(duration: 0.2), value: busy)
    }
}

struct SignOffMeter: View {
    let done: Int
    let needed: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(needed, 1), id: \.self) { index in
                Capsule()
                    .fill(index < done ? Theme.State.merged : Theme.fillSelected)
                    .frame(width: 18, height: 4)
            }
        }
    }
}

struct SignOffRow: View {
    let person: Person
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            AgentAvatar(agent: person, size: 20)
            Text(person.id == FactoryData.me.id ? "You" : person.firstName).foregroundStyle(Theme.text)
            Text(text).foregroundStyle(Theme.textMuted)
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.State.merged)
        }
        .font(.system(size: 12.5))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct PendingSignOffRow: View {
    let text: String
    var highlight = true

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(Theme.textFaint, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: 20, height: 20)
            Text(text).foregroundStyle(highlight ? Theme.State.awaitingApproval : Theme.textMuted)
            Spacer()
        }
        .font(.system(size: 12.5, weight: .medium))
    }
}

// MARK: - Conversation

struct DiscussionList: View {
    let comments: [Comment]
    var avatarSize: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                HStack(alignment: .top, spacing: 10) {
                    AgentAvatar(agent: comment.author, size: avatarSize)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(comment.author.id == FactoryData.me.id ? "You" : comment.author.firstName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            if let anchor = comment.anchor {
                                Text(anchor)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Theme.textMuted)
                                    .padding(.horizontal, 6)
                                    .frame(height: 17)
                                    .background(Capsule().fill(Theme.fill))
                            }
                            Spacer()
                            Text(comment.when)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textFaint)
                        }
                        MarkdownPreview(source: comment.text, baseSize: 12.5)
                    }
                }
            }
        }
    }
}

struct ActivityFeed: View {
    let items: [ActivityItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Theme.textFaint).frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                    (Text(item.who).foregroundStyle(Theme.text).fontWeight(.medium)
                     + Text("  \(item.text)").foregroundStyle(Theme.textMuted))
                        .font(.system(size: 12.5))
                    Spacer()
                    Text(item.when)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
    }
}

// MARK: - Peek

/// Short stand-ins the task panel shows in place of whole sections; the full view has the rest.

/// One line for a section: what it is, how far along, and a tap to open it.
struct PeekRow<Trailing: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text)
            if let detail {
                Text("· \(detail)")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(hovered ? Theme.fill : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}

extension PeekRow where Trailing == EmptyView {
    init(icon: String, title: String, detail: String? = nil, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, detail: detail, action: action) { EmptyView() }
    }
}

/// Peek rows stacked in one bordered box, divided by hairlines.
struct PeekGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    row
                    if index < rows.count - 1 { Hairline().padding(.leading, 36) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.fillSubtle)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        )
    }
}

/// The pull request as one row: number, state and checks, opening it on GitHub (or the full view for a local repo).
struct PullRequestRow: View {
    @Environment(\.openURL) private var openURL
    let pr: PullRequest
    let openFull: () -> Void

    private var checks: String? {
        guard !pr.checks.isEmpty else { return nil }
        let passed = pr.checks.filter { $0.status == .passed }.count
        return "\(passed) of \(pr.checks.count) checks"
    }

    var body: some View {
        PeekRow(icon: "arrow.triangle.pull", title: "#\(pr.number)", detail: checks, action: {
            if pr.isLocal { openFull() } else { openURL(pr.url) }
        }) {
            PRStateChip(state: pr.state)
        }
        .help(pr.isLocal ? "A local repo: open the full view for its branch" : pr.url.absoluteString)
    }
}

/// The latest comments, with how many earlier ones the full view holds.
struct DiscussionPeek: View {
    let comments: [Comment]
    var shown = 2
    let openFull: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel(title: "Discussion")
                Spacer()
                if comments.count > shown {
                    Text("\(comments.count - shown) more")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: openFull)
                        .help("Open full view (⌘↩)")
                }
            }
            DiscussionList(comments: Array(comments.suffix(shown)))
        }
    }
}

// MARK: - Composer

/// One input for both audiences: steer the task's agent, or comment to teammates.
struct TaskComposer: View {
    @Environment(AppState.self) private var appState
    let task: FactoryTask
    @Binding var mode: ComposerMode
    var focused: FocusState<Bool>.Binding

    @State private var draft = ""
    @State private var interruptNow = false

    var body: some View {
        // A merged or cancelled task can't be redirected any more, whatever tab was picked before.
        let steering = mode == .steer && task.isSteerable

        VStack(alignment: .leading, spacing: 12) {
            if task.isSteerable, let agent = task.agent {
                HStack(spacing: 2) {
                    modeTab("Steer \(agent.name)", icon: "sparkle", mode: .steer)
                    modeTab("Comment", icon: "bubble.left", mode: .comment)
                    Spacer()
                    if steering, task.state == .building {
                        Menu {
                            Button("At next step") { interruptNow = false }
                            Button("Interrupt now") { interruptNow = true }
                        } label: {
                            Text(interruptNow ? "Interrupt now" : "At next step")
                        }
                        .menuStyle(.borderlessButton)
                        .font(.system(size: 11.5))
                        .fixedSize()
                    }
                }
            }

            if steering {
                HStack(spacing: 6) {
                    ForEach(quickTweaks, id: \.self) { tweak in
                        Text(tweak)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Capsule().strokeBorder(Theme.stroke))
                            .contentShape(Capsule())
                            .onTapGesture { draft = tweak; focused.wrappedValue = true }
                    }
                }
            }

            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.text)
                .focused(focused)
                .onExitCommand { focused.wrappedValue = false }
                .onSubmit(send)

            HStack {
                Image(systemName: "paperclip").foregroundStyle(Theme.textMuted)
                if steering {
                    Text(interruptNow && task.state == .building ? "Interrupts after the current edit" : task.steerTiming)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: steering ? "arrow.uturn.backward" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(steering ? .white : Theme.onAccent)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(steering ? Theme.State.planning : Theme.accent))
                    .onTapGesture(perform: send)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.raised.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(steering && focused.wrappedValue ? Theme.State.planning.opacity(0.6) : Theme.stroke)
                )
        )
    }

    private var placeholder: String {
        guard mode == .steer, task.isSteerable, let agent = task.agent else { return "Comment or @mention someone…" }
        switch task.state {
        case .building: return "Tell \(agent.name) what to change mid-build…"
        case .reviewing: return "What should \(agent.name) fix before merge?"
        default: return "Tell \(agent.name) what to change in the plan…"
        }
    }

    private var quickTweaks: [String] {
        switch task.state {
        case .building: ["Add a test for this", "Smaller commits", "Explain the last change"]
        case .reviewing: ["Record a longer video", "Re-run the flaky test", "Add a screenshot"]
        default: ["Smaller steps", "Add a done-when check", "What's the riskiest step?"]
        }
    }

    private func modeTab(_ title: String, icon: String, mode tabMode: ComposerMode) -> some View {
        let active = mode == tabMode

        return HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(title)
        }
        .font(.system(size: 12, weight: active ? .semibold : .regular))
        .foregroundStyle(active ? (tabMode == .steer ? Theme.State.planning : Theme.text) : Theme.textMuted)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.fill : .clear))
        .contentShape(Rectangle())
        .onTapGesture { mode = tabMode }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(.snappy(duration: 0.25)) {
            if mode == .steer, task.isSteerable {
                appState.steer(task.id, text: text, interruptNow: interruptNow)
            } else {
                appState.comment(task.id, text: text)
            }
        }
        draft = ""
    }
}
