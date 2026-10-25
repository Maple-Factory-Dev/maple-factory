import SwiftUI

struct RiskBadge: View {
    let level: RiskLevel
    var compact = false

    var body: some View {
        if compact {
            Image(systemName: level.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(level.color)
                .help("\(level.title) risk")
        } else {
            HStack(spacing: 4) {
                Image(systemName: level.icon).font(.system(size: 10, weight: .semibold))
                Text("\(level.title) risk")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(level.color)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(level.color.opacity(0.13)))
        }
    }
}

/// Why a task is as risky as it is, what that means for sign-off, and what to do if it's over budget.
struct RiskBox: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    let risk: RiskAssessment
    @SwiftUI.State private var showPolicy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SectionLabel(title: "Risk")
                RiskBadge(level: risk.level)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10))
                    Text("Policy")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .contentShape(Rectangle())
                .onTapGesture { showPolicy = true }
                .popover(isPresented: $showPolicy, arrowEdge: .leading) { RiskPolicyEditor() }
            }

            VStack(spacing: 10) {
                BudgetMeter(label: "Files", value: risk.files, limit: state.policy.maxFiles, estimated: risk.estimated)
                BudgetMeter(label: "Lines", value: risk.lines, limit: state.policy.maxLines, estimated: risk.estimated)
            }

            if !risk.areas.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(risk.areas) { area in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 10.5))
                                .foregroundStyle(area.level.color)
                            Text("Touches \(area.name)")
                                .foregroundStyle(Theme.text)
                            Text(area.paths.first ?? "")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                        }
                        .font(.system(size: 12))
                    }
                }
            }

            Hairline()

            VStack(alignment: .leading, spacing: 7) {
                requirement("checkmark.circle", "Plan approvals", "\(risk.approvals)")
                requirement("person.2", "Reviews of the final change", risk.reviews == 0 ? "None" : "\(risk.reviews)")
                requirement(risk.autoMerge ? "bolt.fill" : "bolt.slash", "Auto-merge",
                            risk.autoMerge ? "On when proofs pass" : "Off",
                            highlight: risk.autoMerge ? Theme.State.merged : nil)
            }

            if let acceptance = risk.acceptance {
                acceptanceBanner(acceptance)
            }

            if let split = risk.suggestedSplit, !state.keptWhole.contains(task.id),
               task.state != .merged, task.plan.count >= split {
                splitSuggestion(split)
            }
        }
    }

    private func requirement(_ icon: String, _ label: String, _ value: String, highlight: Color? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(highlight ?? Theme.textMuted)
                .frame(width: 14)
            Text(label).foregroundStyle(Theme.textMuted)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(highlight ?? Theme.text)
        }
        .font(.system(size: 12))
    }

    private func acceptanceBanner(_ acceptance: RiskAcceptance) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AgentAvatar(agent: acceptance.acceptedBy, size: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(acceptance.acceptedBy.firstName) accepted risk up to \(acceptance.autoMergeUpTo.title.lowercased()) for \(task.goal) on \(acceptance.when).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                if let note = acceptance.note {
                    Text("“\(note)”")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.State.merged.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.State.merged.opacity(0.25)))
        )
    }

    private func splitSuggestion(_ parts: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "scissors")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.State.awaitingApproval)
                    .padding(.top, 1)
                Text("Over the PR budget. \(task.agent?.name ?? "The agent") can split this into \(parts) PRs that each stay under \(state.policy.maxFiles) files and \(state.policy.maxLines) lines.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text("Split into \(parts) tasks")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.cardBG)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { state.split(task.id, into: parts) }
                Text("Keep as one")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .contentShape(Rectangle())
                    .onTapGesture { state.keepWhole(task.id) }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.State.awaitingApproval.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.State.awaitingApproval.opacity(0.25)))
        )
    }
}

/// Usage against a budget; the bar turns red and overflows its track when the limit is exceeded.
struct BudgetMeter: View {
    let label: String
    let value: Int
    let limit: Int
    var estimated = false

    var body: some View {
        let over = value > limit
        let color = over ? Theme.State.cancelled : Double(value) / Double(limit) > 0.8 ? Theme.State.awaitingApproval : Theme.State.merged

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(Theme.textMuted)
                Spacer()
                Text("\(estimated ? "~" : "")\(value.formatted())")
                    .foregroundStyle(over ? Theme.State.cancelled : Theme.text)
                    .fontWeight(.medium)
                Text("/ \(limit.formatted())").foregroundStyle(Theme.textFaint)
            }
            .font(.system(size: 12).monospacedDigit())

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fillSelected)
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * min(Double(value) / Double(limit), 1))
                    if over {
                        // Hatched end cap so "over" reads at a glance, not just by colour.
                        Capsule()
                            .fill(color.opacity(0.35))
                            .frame(width: 14)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .frame(height: 5)
        }
    }
}

/// Workspace risk rules, edited in place so the effect on every task's badge is immediate.
struct RiskPolicyEditor: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Risk policy")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Workspace default · every goal inherits this unless it overrides it")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
            }

            group("PR budget") {
                Stepper(value: $state.policy.maxFiles, in: 1...100) {
                    row("Max files per PR", "\(state.policy.maxFiles)")
                }
                Stepper(value: $state.policy.maxLines, in: 50...5000, step: 50) {
                    row("Max changed lines", "\(state.policy.maxLines)")
                }
            }

            group("Sensitive areas") {
                ForEach($state.policy.sensitiveAreas) { $area in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $area.enabled)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(area.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                            Text(area.paths.joined(separator: "  "))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Picker("", selection: $area.level) {
                            ForEach(RiskLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    Text("Add area")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            }

            group("Factory auto-merge by goal") {
                Text("Accepting risk lets the factory merge without human review once proofs and CI pass. Who accepted it, and when, is recorded.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(FactoryData.activeGoals) { goal in
                    HStack(spacing: 8) {
                        Circle().fill(goal.color).frame(width: 7, height: 7)
                        Text(goal.name).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        if let acceptance = state.acceptances[goal.name] {
                            AgentAvatar(agent: acceptance.acceptedBy, size: 14)
                                .help("Accepted by \(acceptance.acceptedBy.firstName) · \(acceptance.when)")
                        }
                        Spacer()
                        Picker("", selection: acceptanceBinding(for: goal.name)) {
                            Text("Policy default").tag(RiskLevel?.none)
                            ForEach(RiskLevel.allCases, id: \.self) { level in
                                Text("Up to \(level.title.lowercased())").tag(RiskLevel?.some(level))
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
            }

            group("Sign-off by risk level") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                    GridRow {
                        Text("")
                        ForEach(RiskLevel.allCases, id: \.self) { level in
                            RiskBadge(level: level).gridColumnAlignment(.center)
                        }
                    }
                    GridRow {
                        Text("Plan approvals").foregroundStyle(Theme.textMuted)
                        ForEach(RiskLevel.allCases, id: \.self) { level in
                            countStepper($state.policy.planApprovals, level, range: 1...4)
                        }
                    }
                    GridRow {
                        Text("Final reviews").foregroundStyle(Theme.textMuted)
                        ForEach(RiskLevel.allCases, id: \.self) { level in
                            countStepper($state.policy.finalReviews, level, range: 0...4)
                        }
                    }
                    GridRow {
                        Text("Auto-merge").foregroundStyle(Theme.textMuted)
                        ForEach(RiskLevel.allCases, id: \.self) { level in
                            Toggle("", isOn: Binding(
                                get: { state.policy.autoMerge[level, default: false] },
                                set: { state.policy.autoMerge[level] = $0 }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .gridColumnAlignment(.center)
                        }
                    }
                }
                .font(.system(size: 12))
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    private func acceptanceBinding(for goal: String) -> Binding<RiskLevel?> {
        Binding(
            get: { state.acceptances[goal]?.autoMergeUpTo },
            set: { level in
                if let level {
                    state.acceptances[goal] = RiskAcceptance(autoMergeUpTo: level, acceptedBy: FactoryData.me, when: "just now")
                    state.showToast("You accepted \(level.title.lowercased()) risk for \(goal)", icon: "bolt.shield", color: level.color)
                } else {
                    state.acceptances[goal] = nil
                }
            }
        )
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.text)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(Theme.text)
        }
        .font(.system(size: 12.5))
    }

    private func countStepper(_ binding: Binding<[RiskLevel: Int]>, _ level: RiskLevel, range: ClosedRange<Int>) -> some View {
        let value = binding.wrappedValue[level, default: 0]
        return HStack(spacing: 6) {
            Image(systemName: "minus")
                .onTapGesture { binding.wrappedValue[level] = max(range.lowerBound, value - 1) }
            Text("\(value)").monospacedDigit().fontWeight(.semibold).frame(minWidth: 10)
            Image(systemName: "plus")
                .onTapGesture { binding.wrappedValue[level] = min(range.upperBound, value + 1) }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fill))
        .gridColumnAlignment(.center)
    }
}

struct RiskPolicyButton: View {
    @Environment(AppState.self) private var state
    @SwiftUI.State private var open = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 11))
            Text("Risk policy")
            Text("\(state.policy.maxFiles) files · \(state.policy.maxLines) lines")
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.fill)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
        )
        .contentShape(Rectangle())
        .onTapGesture { open = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Risk policy")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open = true }
        .popover(isPresented: $open, arrowEdge: .bottom) { RiskPolicyEditor() }
    }
}
