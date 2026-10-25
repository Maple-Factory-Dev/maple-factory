import SwiftUI

// MARK: Model

/// One rate-limit window on a plan, e.g. the 5-hour session or the 7-day week.
struct UsageWindow: Identifiable {
    let label: String
    let span: String
    var used: Double
    let resetsIn: String
    let resetsAt: String
    /// How far through the window we are (0...1), used to project the burn rate.
    let elapsed: Double
    /// Wall-clock moment the window would run dry at the current pace, if before the reset.
    var runsOutAt: String? = nil
    var id: String { label }

    var projected: Double { elapsed > 0 ? used / elapsed : used }
    var runsOutEarly: Bool { projected > 1 && runsOutAt != nil }
}

enum UsageProduct {
    case claudeCode, codex

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// A plan account. Machines signed in to the same account share its limits.
struct UsageAccount: Identifiable {
    let id: String
    let product: UsageProduct
    let plan: String
    /// Whose subscription this is; nil when the machine didn't report an account.
    let owner: Person?
    let accountName: String?
    let machines: [String]
    var windows: [UsageWindow]
    /// Factory agents currently routed to this account.
    let agents: [Agent]
    var updated: String
    let updatedFrom: String
    let source: String
    var freeResets: Int? = nil

    var sessionWindow: UsageWindow? { windows.first { $0.span == "5h" } }
    var weekWindow: UsageWindow? { windows.first { $0.label == "This week" } }
    var title: String { "\(product.name) · \(plan) · \(accountName ?? "unknown")" }
}

extension FactoryData {
    static let usageAccounts: [UsageAccount] = [
        UsageAccount(
            id: "claude-andrea", product: .claudeCode, plan: "max",
            owner: me, accountName: "Personal", machines: ["mbp-14", "factory-mini"],
            windows: [
                UsageWindow(label: "Current session", span: "5h", used: 0.34, resetsIn: "2h 7m", resetsAt: "1:00 AM", elapsed: 0.58),
                UsageWindow(label: "This week", span: "7d", used: 0.41, resetsIn: "15h 6m", resetsAt: "Sun 2:00 PM", elapsed: 0.91),
                UsageWindow(label: "This week · Fable", span: "7d", used: 0.12, resetsIn: "15h 6m", resetsAt: "Sun 2:00 PM", elapsed: 0.91),
            ],
            agents: [agents[0], agents[1], agents[2]],
            updated: "just now", updatedFrom: "factory-mini",
            source: "From Claude Code's /usage every few minutes, and live from the status line of agent sessions."
        ),
        UsageAccount(
            id: "claude-chris", product: .claudeCode, plan: "max",
            owner: chris, accountName: "Chris · shared", machines: ["chris-studio"],
            windows: [
                UsageWindow(label: "Current session", span: "5h", used: 0.78, resetsIn: "48m", resetsAt: "11:41 PM", elapsed: 0.84),
                UsageWindow(label: "This week", span: "7d", used: 0.63, resetsIn: "3d 10h", resetsAt: "Wed 9:00 AM", elapsed: 0.5, runsOutAt: "Tue 3 PM"),
                UsageWindow(label: "This week · Fable", span: "7d", used: 0.05, resetsIn: "3d 10h", resetsAt: "Wed 9:00 AM", elapsed: 0.5),
            ],
            agents: [agents[3]],
            updated: "4 min ago", updatedFrom: "chris-studio",
            source: "Shared into the workspace by Chris. Maple only routes agents here while it has headroom."
        ),
        UsageAccount(
            id: "codex-andrea", product: .codex, plan: "prolite",
            owner: me, accountName: "Personal", machines: ["mbp-16"],
            windows: [
                UsageWindow(label: "This week", span: "7d", used: 0.08, resetsIn: "6d 22h", resetsAt: "Sat 9:11 PM", elapsed: 0.02),
            ],
            agents: [agents[4]],
            updated: "56 min ago", updatedFrom: "mbp-16",
            source: "Asked from Codex every few minutes, and after a Codex session runs.",
            freeResets: 2
        ),
        UsageAccount(
            id: "codex-unknown", product: .codex, plan: "prolite",
            owner: nil, accountName: nil, machines: ["mbp-14"],
            windows: [
                UsageWindow(label: "This week", span: "7d", used: 0, resetsIn: "6d 22h", resetsAt: "Sat 9:11 PM", elapsed: 0.02),
            ],
            agents: [],
            updated: "2h ago", updatedFrom: "mbp-14",
            source: "From Codex's session files; it updates after a Codex session runs."
        ),
    ]

    /// Share of this week's usage per goal, across every account.
    static let usageByGoal: [(goal: String, share: Double, tasks: String)] = [
        ("Auth overhaul", 0.38, "ATL-144, ATL-147, ATL-141"),
        ("Billing v2", 0.24, "BIL-212, BIL-215"),
        ("Onboarding revamp", 0.17, "ONB-88, ONB-91"),
        ("Performance budget", 0.13, "PRF-31"),
        ("Docs site", 0.08, "DOC-19, DOC-22"),
    ]
}

// MARK: Views

struct UsageView: View {
    @State private var accounts = FactoryData.usageAccounts
    @State private var pauseWhenLow = true
    @State private var rebalance = true
    @State private var keepReserve = true

    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client

    private var live: [UsageAccount] { LiveAdapter.usageAccounts(machines: client.machines, members: client.members) }

    private var narrow: Bool { state.contentWidth < 920 }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: narrow ? 1 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Usage")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("How much of each plan's 5-hour and weekly limits the factory has used, per account. Machines signed in to the same account share its limits, so each card is the newest reading from any of them.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 720, alignment: .leading)
                }

                if state.isLive {
                    liveAccounts
                } else {
                forecastBanner

                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach($accounts) { $account in
                        UsageAccountCard(account: $account)
                    }
                }

                (narrow ? AnyLayout(VStackLayout(spacing: 18)) : AnyLayout(HStackLayout(alignment: .top, spacing: 18))) {
                    byGoal
                    routing
                }
                }
            }
            .padding(.horizontal, narrow ? 24 : 40)
            .padding(.vertical, 30)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
    }

    @ViewBuilder private var liveAccounts: some View {
        if live.isEmpty {
            UsageCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No readings yet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Machines report each account's limits from the status line of Claude Code sessions and from Codex's own reports, once an agent has run there.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(live) { account in UsageAccountCard(account: .constant(account)) }
            }
        }
        Label("Cap how much of an account the factory may use per machine: Machines → ⋯ → Factory Settings.", systemImage: "gauge.with.dots.needle.33percent")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
    }

    @ViewBuilder private var forecastBanner: some View {
        if let account = accounts.first(where: { $0.windows.contains(where: \.runsOutEarly) }),
           let window = account.windows.first(where: \.runsOutEarly) {
            let fallback = accounts.first { $0.id != account.id && $0.product == account.product && !$0.agents.isEmpty }
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(Theme.State.awaitingApproval)
                (Text("\(account.owner?.firstName ?? "This")'s \(account.plan.capitalized) account runs out \(window.runsOutAt ?? "") at this pace")
                    .foregroundStyle(Theme.text).fontWeight(.medium)
                 + Text(", before it resets \(window.resetsAt). \(account.agents.map(\.name).joined(separator: ", ")) will move to \(fallback.map { "your \($0.accountName ?? "other") account" } ?? "another account") when it does.")
                    .foregroundStyle(Theme.textMuted))
                    .font(.system(size: 12.5))
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.State.awaitingApproval.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.State.awaitingApproval.opacity(0.25)))
            )
        }
    }

    private var byGoal: some View {
        UsageCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Where it went this week")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text("all accounts")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textFaint)
                }
                ForEach(FactoryData.usageByGoal, id: \.goal) { entry in
                    let goal = FactoryData.goal(named: entry.goal)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Circle().fill(goal.color).frame(width: 7, height: 7)
                            Text(entry.goal).foregroundStyle(Theme.text)
                            Text(entry.tasks)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(entry.share * 100))%")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Theme.text)
                        }
                        .font(.system(size: 12.5))
                        UsageBar(value: entry.share / 0.4, color: goal.color)
                    }
                }
            }
        }
    }

    private var routing: some View {
        UsageCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("When an account runs low")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                rule("Pause new planning above 90% of a session", detail: "Building and reviews keep going so nothing is left half-done.", isOn: $pauseWhenLow)
                rule("Move queued work to the account with most headroom", detail: "Agents switch accounts between tasks, never mid-task.", isOn: $rebalance)
                rule("Keep 15% of each week in reserve", detail: "Held back for change requests, CI fixes and review follow-ups.", isOn: $keepReserve)
            }
        }
    }

    private func rule(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.accent)
        }
    }
}

private struct UsageCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.cardBG)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
            )
    }
}

struct UsageAccountCard: View {
    @Binding var account: UsageAccount
    @State private var spin = 0.0

    var body: some View {
        UsageCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 18)

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(account.windows) { window in
                        windowRow(window)
                    }
                    if let resets = account.freeResets {
                        (Text("\(resets) free full resets").foregroundStyle(Theme.text).fontWeight(.medium)
                         + Text(" available on this account.").foregroundStyle(Theme.textMuted))
                            .font(.system(size: 12.5))
                    }
                }

                agentsRow
                    .padding(.top, 18)

                Hairline().padding(.vertical, 16)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Updated \(account.updated) from \(account.updatedFrom)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                    Text(account.source)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProductMark(product: account.product)
                Text(account.product.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(account.plan)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.fill))
                Spacer()
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .rotationEffect(.degrees(spin))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture { refresh() }
                    .help("Ask \(account.updatedFrom) for a fresh reading")
            }
            HStack(spacing: 7) {
                if let owner = account.owner {
                    AgentAvatar(agent: owner, size: 18)
                } else {
                    Image(systemName: "person").font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                }
                Text(account.accountName ?? "Account not reported")
                    .foregroundStyle(account.accountName == nil ? Theme.textMuted : Theme.text)
                    .fontWeight(account.accountName == nil ? .regular : .medium)
                if account.accountName != nil {
                    Image(systemName: "pencil").font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                }
                Text(account.machines.count == 1 ? "on \(account.machines[0])" : "on \(account.machines.count) machines")
                    .foregroundStyle(Theme.textMuted)
                    .help(account.machines.joined(separator: ", "))
            }
            .font(.system(size: 13))
        }
    }

    private func windowRow(_ window: UsageWindow) -> some View {
        let color = meterColor(window)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(window.label)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(window.span)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(Int((window.used * 100).rounded()))%")
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(window.used >= 0.75 ? color : Theme.text)
            }
            UsageBar(value: window.used, color: color, pace: window.used > 0 ? min(window.elapsed, 1) : nil)
            HStack(spacing: 6) {
                Text("Resets in \(window.resetsIn) (\(window.resetsAt))")
                    .foregroundStyle(Theme.textMuted)
                if window.runsOutEarly, let when = window.runsOutAt {
                    Text("·").foregroundStyle(Theme.textFaint)
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5))
                        Text("Out \(when) at this pace")
                    }
                    .foregroundStyle(Theme.State.awaitingApproval)
                }
            }
            .font(.system(size: 12))
        }
    }

    @ViewBuilder private var agentsRow: some View {
        HStack(spacing: 8) {
            if account.agents.isEmpty {
                Image(systemName: "moon.zzz").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                Text("No agents routed here")
                    .foregroundStyle(Theme.textMuted)
            } else {
                Facepile(people: account.agents, size: 20, ringColor: Theme.cardBG)
                Text(account.agents.map(\.name).joined(separator: ", "))
                    .foregroundStyle(Theme.text)
                Text("running on this account")
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .font(.system(size: 12.5))
    }

    private func meterColor(_ window: UsageWindow) -> Color {
        if window.used >= 0.9 { return Theme.State.cancelled }
        if window.used >= 0.75 || window.runsOutEarly { return Theme.State.awaitingApproval }
        return account.product == .claudeCode ? ProductMark.claude : Theme.accent
    }

    private func refresh() {
        withAnimation(.easeInOut(duration: 0.8)) { spin += 360 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            withAnimation(.snappy) {
                account.updated = "just now"
                for index in account.windows.indices where account.windows[index].used > 0 {
                    account.windows[index].used = min(account.windows[index].used + 0.01, 1)
                }
            }
        }
    }
}

/// A capsule meter. `pace` draws a tick where usage would be if spent evenly across the window.
struct UsageBar: View {
    let value: Double
    let color: Color
    var pace: Double? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule()
                    .fill(color)
                    .frame(width: max(geo.size.width * min(value, 1), value > 0 ? 7 : 0))
                if let pace {
                    Rectangle()
                        .fill(Theme.textFaint)
                        .frame(width: 1.5, height: 12)
                        .offset(x: geo.size.width * pace - 0.75)
                        .help("Even pace for this point in the window")
                }
            }
        }
        .frame(height: 7)
    }
}

struct ProductMark: View {
    let product: UsageProduct
    static let claude = Color(hex: 0xD97757)

    var body: some View {
        switch product {
        case .claudeCode:
            Image(systemName: "asterisk")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Self.claude)
                .frame(width: 24, height: 24)
        case .codex:
            Image(systemName: "chevron.forward.dotted.chevron.forward")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.editorBG)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.text))
        }
    }
}
