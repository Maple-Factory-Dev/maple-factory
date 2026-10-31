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

            if !risk.factors.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Why this risk")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                    ForEach(risk.factors) { factor in
                        RiskFactorRow(factor: factor)
                    }
                }
            } else if !risk.areas.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(risk.areas) { area in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 10.5))
                                .foregroundStyle(area.level.color)
                            Text("Touches \(area.name)")
                                .foregroundStyle(Theme.text)
                            Text(area.rule ?? area.paths.first ?? "")
                                .font(.system(size: 10.5, design: area.isRule ? .default : .monospaced))
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
                            risk.autoMerge ? "On when proofs pass" : state.policy.autoMerges ? "Off" : "Off for the factory",
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

/// One of the server's reasons for a task's risk: its level, what raised it, and the files or rule behind it.
struct RiskFactorRow: View {
    let factor: RiskFactor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(factor.level.color)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                .help("\(factor.level.title) risk")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(factor.label).fontWeight(.medium).foregroundStyle(Theme.text)
                    Text(factor.level.title.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                if let detail = factor.detail {
                    Text(detail)
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !factor.files.isEmpty {
                    Text(factor.files.joined(separator: ", "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
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

            group("Task budget") {
                Stepper {
                    row("Agent time per task", state.policy.taskMinutes == 0 ? "Off" : Self.minutes(state.policy.taskMinutes))
                } onIncrement: {
                    state.policy.taskMinutes = Self.stepMinutes(state.policy.taskMinutes, up: true)
                } onDecrement: {
                    state.policy.taskMinutes = Self.stepMinutes(state.policy.taskMinutes, up: false)
                }
                HStack {
                    Text("Cost per task").foregroundStyle(Theme.text)
                    Spacer()
                    TaskCostField(cost: state.policy.taskCostUsd) { state.policy.taskCostUsd = $0 }
                }
                .font(.system(size: 12.5))
                Text("Past either, the agent is asked to stop and raise a hand; if it doesn't within 10 minutes, the factory raises one for it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            group("Risk checks") {
                Text("A change's risk is the highest of the planner's read, each check it trips, and medium over the PR budget. Path checks match the diff's files; the planner cites rules that apply.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach($state.policy.sensitiveAreas) { $area in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: $area.enabled)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(area.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                            if area.isRule {
                                RiskRuleField(rule: area.rule ?? "") { area.rule = $0 }
                            } else {
                                Text(area.paths.joined(separator: "  "))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        Spacer()
                        Picker("", selection: $area.level) {
                            ForEach(RiskLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.top, 3)
                            .contentShape(Rectangle())
                            .onTapGesture { state.policy.sensitiveAreas.removeAll { $0.id == area.id } }
                            .help("Remove \(area.name)")
                            .accessibilityLabel("Remove \(area.name)")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                RiskCheckAdder { state.policy.sensitiveAreas.append($0) }
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
                            .disabled(!state.policy.autoMerges)
                        }
                    }
                }
                .font(.system(size: 12))
                if !state.policy.autoMerges {
                    Label("Off for the whole factory in Settings › Merging", systemImage: "bolt.slash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                }
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

    /// Off, then 15 to 480 minutes in 15-minute steps; a value set elsewhere off the grid snaps to it.
    static func stepMinutes(_ m: Int, up: Bool) -> Int {
        if up { return m <= 0 ? 15 : min(480, (m / 15 + 1) * 15) }
        if m <= 15 { return 0 }
        return min(480, ((m - 1) / 15) * 15)
    }

    static func minutes(_ m: Int) -> String {
        m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
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

/// The cost budget in dollars, saved when editing ends; blank is no cost limit.
private struct TaskCostField: View {
    let cost: Double?
    let save: (Double?) -> Void
    @SwiftUI.State private var text = ""

    var body: some View {
        HStack(spacing: 2) {
            Text("$").foregroundStyle(Theme.textMuted)
            TextField("No limit", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .onAppear { text = Self.format(cost) }
                .onChange(of: cost) { _, new in text = Self.format(new) }
                .onSubmit(commit)
                .onDisappear(perform: commit)
        }
    }

    static func format(_ cost: Double?) -> String {
        guard let cost else { return "" }
        return cost == cost.rounded() ? String(Int(cost)) : String(format: "%.2f", cost)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        let value: Double? = trimmed.isEmpty ? nil : Double(trimmed).map { max(0, $0) }
        if trimmed.isEmpty || value != nil, value != cost { save(value) } else { text = Self.format(cost) }
    }
}

/// A rule check's text, saved when editing ends so a half-typed rule isn't sent on every keystroke.
private struct RiskRuleField: View {
    let rule: String
    let save: (String) -> Void
    @SwiftUI.State private var text = ""

    var body: some View {
        TextField("Rule", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textMuted)
            .onAppear { text = rule }
            .onChange(of: rule) { _, new in text = new }
            .onSubmit(commit)
            .onDisappear(perform: commit)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != rule { save(trimmed) }
    }
}

/// Adds a risk check: a name, a level, and either paths (comma or space separated) or a plain-language rule.
private struct RiskCheckAdder: View {
    let add: (SensitiveArea) -> Void
    @Environment(AppState.self) private var state
    @SwiftUI.State private var open = false
    @SwiftUI.State private var name = ""
    @SwiftUI.State private var isRule = true
    @SwiftUI.State private var text = ""
    @SwiftUI.State private var level: RiskLevel = .medium

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var paths: [String] { text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) }
    private var ready: Bool {
        !trimmedName.isEmpty
            && !state.policy.sensitiveAreas.contains { $0.name.lowercased() == trimmedName.lowercased() }
            && (isRule ? !text.trimmingCharacters(in: .whitespaces).isEmpty : !paths.isEmpty)
    }

    var body: some View {
        if open {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    Picker("", selection: $level) {
                        ForEach(RiskLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Picker("", selection: $isRule) {
                    Text("Rule").tag(true)
                    Text("Paths").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField(isRule ? "Changes the public HTTP API" : "db/migrations/**, lib/auth/**", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: isRule ? .default : .monospaced))
                HStack {
                    Spacer()
                    Button("Cancel") { reset() }
                    Button("Add") {
                        add(SensitiveArea(name: trimmedName, paths: isRule ? [] : paths, level: level,
                                          rule: isRule ? text.trimmingCharacters(in: .whitespaces) : nil))
                        reset()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
                }
                .controlSize(.small)
            }
            .font(.system(size: 12))
        } else {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("Add check")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
            .contentShape(Rectangle())
            .onTapGesture { open = true }
            .accessibilityAddTraits(.isButton)
        }
    }

    private func reset() {
        open = false
        name = ""
        text = ""
        isRule = true
        level = .medium
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
