import SwiftUI

/// "Mission control" for new work: write a brief like a GitHub issue, see live what the factory will
/// take from it, then park it as a draft or hand it straight to a planner.
struct ComposeView: View {
    @Environment(AppState.self) private var state

    private let editorWidth: CGFloat = 760
    private let panelWidth: CGFloat = 320

    var body: some View {
        @Bindable var state = state
        let reading = BriefReading(state.draft.body)

        let compact = state.contentWidth < 1060
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 36))

        VStack(spacing: 0) {
            ScrollView {
                layout {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.pencil").foregroundStyle(Theme.accent)
                            Text("New task")
                            Text("·").foregroundStyle(Theme.textFaint)
                            Circle().fill(FactoryData.goal(named: state.draft.goal).color).frame(width: 7, height: 7)
                            Text(state.draft.goal)
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)

                        TextField("What needs to happen?", text: $state.draft.title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Theme.text)

                        templates

                        MarkdownEditor(
                            text: $state.draft.body,
                            placeholder: "Describe the outcome, context and constraints.\n\nAdd a “## Done when” checklist: each item becomes a check the builder has to prove.",
                            minHeight: 420
                        )
                    }
                    .frame(maxWidth: editorWidth, alignment: .leading)

                    FactoryReadingPanel(reading: reading)
                        .frame(width: compact ? nil : panelWidth)
                        .frame(maxWidth: compact ? editorWidth : nil)
                }
                .padding(.horizontal, compact ? 24 : 40)
                .padding(.top, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: editorWidth + panelWidth + 116, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            actionBar(reading)
        }
    }

    private var templates: some View {
        HStack(spacing: 6) {
            Text("Start from")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            ForEach(FactoryData.templates, id: \.name) { template in
                chip(template.name, icon: template.icon) { state.draft.body = template.body }
            }
            chip("Example brief", icon: "doc.richtext") {
                state.draft.title = "Passkey sign-in on the login page"
                state.draft.body = FactoryData.sampleBrief
            }
        }
    }

    private func chip(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(title)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Capsule().strokeBorder(Theme.stroke))
        .contentShape(Capsule())
        .onTapGesture(perform: action)
    }

    private func actionBar(_ reading: BriefReading) -> some View {
        let agent = state.assignee(for: state.draft)

        return HStack(spacing: 10) {
            Image(systemName: "info.circle").font(.system(size: 11))
            Text(reading.doneWhen.isEmpty
                 ? "No “Done when” checklist yet. \(agent.name) will propose one with the plan."
                 : "\(reading.doneWhen.count) checks become proof requirements for \(agent.name).")
            Spacer()
            secondaryButton("Save to scratchpad", icon: "note.text") { state.saveDraftAsNote() }
            secondaryButton("Save draft", icon: "pencil.line") { state.submitDraft(sendToPlanning: false) }
            HStack(spacing: 7) {
                Image(systemName: "paperplane.fill").font(.system(size: 11))
                Text("Send to planning")
                Text("⌘↩")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.7)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
            .contentShape(Rectangle())
            .onTapGesture { state.submitDraft(sendToPlanning: true) }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 40)
        .frame(height: 60)
        .overlay(alignment: .top) { Hairline() }
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(title)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.fill)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// Live read-back of the brief: where it goes, who picks it up, what must be proven, and how risky it looks.
struct FactoryReadingPanel: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    let reading: BriefReading

    private var areaLevel: RiskLevel {
        state.policy.sensitiveAreas
            .filter { $0.enabled && reading.areas.contains($0.name) }
            .map(\.level).max() ?? .low
    }

    var body: some View {
        @Bindable var state = state
        let agent = state.assignee(for: state.draft)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(Theme.State.planning)
                Text("Maple reads this as")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    row("Goal") {
                        Picker("", selection: $state.draft.goal) {
                            ForEach(FactoryData.activeGoals) { goal in Text(goal.name).tag(goal.name) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                    if state.isLive, let goal = client.goal(named: state.draft.goal), goal.repos.count > 1 {
                        row("Repo") {
                            Picker("", selection: $state.draft.repo) {
                                Text("\(goal.repos[0]) (default)").tag(String?.none)
                                ForEach(goal.repos.dropFirst(), id: \.self) { repo in Text(repo).tag(String?.some(repo)) }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }
                    if state.isLive {
                        row("Agent") {
                            Picker("", selection: $state.draft.agent) {
                                Text("Claude Code").tag(String?.none)
                                ForEach(state.liveAgents.filter { $0 != "claude" }, id: \.self) { id in
                                    Text(agentTitle(id)).tag(String?.some(id))
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                        }
                    } else {
                        row("Planner") {
                            Picker("", selection: $state.draft.agent) {
                                Text("Auto · \(agent.name)").tag(String?.none)
                                ForEach(FactoryData.agents) { candidate in
                                    Text("\(candidate.name) · \(state.load(candidate)) in flight").tag(String?.some(candidate.name))
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }
                    if !state.draft.tickets.isEmpty {
                        row("Tickets") {
                            HStack(spacing: 4) {
                                ForEach(state.draft.tickets) { ticket in
                                    Text(ticket.key)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .frame(height: 18)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(ticket.system.color))
                                }
                            }
                        }
                    }
                    if let id = state.draft.intakeID, let request = state.intakeRequest(id) {
                        row("From") {
                            HStack(spacing: 5) {
                                AgentAvatar(agent: request.requester, size: 16)
                                Text("\(request.requester.firstName) · \(request.source.title)").foregroundStyle(Theme.text).lineLimit(1)
                            }
                        }
                    }
                    row("Runs on") {
                        Picker("", selection: $state.draft.shareable) {
                            Text("My machines only").tag(false)
                            Text("Shareable with the team").tag(true)
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                    if !reading.mentions.isEmpty {
                        row("Notifies") {
                            HStack(spacing: 5) {
                                Facepile(people: reading.mentions, size: 18, ringColor: Theme.cardBG)
                                Text(reading.mentions.map(\.firstName).joined(separator: ", "))
                                    .foregroundStyle(Theme.text)
                            }
                        }
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        SectionLabel(title: "Done when")
                        Spacer()
                        Text("\(reading.doneWhen.count) checks")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                    }
                    if reading.doneWhen.isEmpty {
                        Text("Add a “## Done when” checklist. Each item becomes a check the builder must prove with a screenshot, video, terminal output or test results.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(reading.doneWhen) { criterion in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: criterion.proof.icon)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.State.planning)
                                .frame(width: 14)
                            Text(LocalizedStringKey(criterion.text))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        SectionLabel(title: "Risk preview")
                        Spacer()
                        RiskBadge(level: areaLevel)
                    }
                    if reading.areas.isEmpty {
                        Text("No sensitive areas mentioned.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    } else {
                        HStack(spacing: 5) {
                            ForEach(reading.areas, id: \.self) { area in
                                HStack(spacing: 4) {
                                    Image(systemName: "lock.shield").font(.system(size: 9.5))
                                    Text(area)
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(areaLevel.color)
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(Capsule().fill(areaLevel.color.opacity(0.12)))
                            }
                        }
                    }
                    Text("Size is estimated once the plan lists files. Over \(state.policy.maxFiles) files or \(state.policy.maxLines) lines and Maple will offer to split it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "What happens next")
                    step(1, "\(agent.name) drafts a plan: steps, files and estimated size.")
                    step(2, "Plan needs \(state.policy.planApprovals[areaLevel, default: 1]) approval\(state.policy.planApprovals[areaLevel, default: 1] == 1 ? "" : "s") at \(areaLevel.title.lowercased()) risk.")
                    step(3, "\(agent.name) builds, opens a PR and attaches proof for each check.")
                    step(4, state.policy.autoMerge[areaLevel, default: false]
                         ? "Auto-merges once proofs and CI pass."
                         : "\(state.policy.finalReviews[areaLevel, default: 1]) review\(state.policy.finalReviews[areaLevel, default: 1] == 1 ? "" : "s") before someone merges.")
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            )
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(Theme.textMuted)
                .frame(width: 64, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.fill))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
