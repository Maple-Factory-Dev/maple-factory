import SwiftUI

/// The factory's statistics, for admins: merges, raised hands, questions, steers, review rounds and the
/// other touchpoints, over the last 7, 30 or 90 days (`stats.get`). Signed out it shows a sample.
struct StatisticsView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @AppStorage("statsDays") private var days = 30

    private var narrow: Bool { state.contentWidth < 920 }
    private var isAdmin: Bool { !state.isLive || client.me?.role == "admin" }
    private var summary: Wire.StatsSummary? { state.isLive ? client.stats.flatMap { $0.days == UInt32(days) ? $0 : nil } : .sample }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !isAdmin {
                    StatsCard {
                        Text("Only admins can see statistics.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                } else if let summary {
                    content(summary)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, narrow ? 24 : 40)
            .padding(.vertical, 30)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
        .task(id: days) { if state.isLive && isAdmin { client.loadStats(days: days) } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Statistics")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("What the factory merged, and every time a person had to step in: raised hands, questions, steers, permission prompts and review rounds. The same numbers are at /api/stats for tuning prompts and loops.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 720, alignment: .leading)
            }
            Spacer()
            if isAdmin {
                Picker("Range", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    @ViewBuilder private func content(_ s: Wire.StatsSummary) -> some View {
        let t = s.totals
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: narrow ? 2 : 6), spacing: 14) {
            StatTile(label: "Merged", value: "\(t.merged)", detail: t.autoMerged > 0 ? "\(t.autoMerged) auto-merged" : "\(t.created) created")
            StatTile(label: "Cycle time", value: duration(t.cycleMedianMs), detail: "median, to merge")
            StatTile(label: "First-try plans", value: percent(t.firstTryApproval), detail: t.avgPlanVersions.map { String(format: "%.1f versions on average", $0) } ?? "no approvals yet")
            StatTile(label: "Hands raised", value: "\(t.handsRaised)", detail: t.handOpenMedianMs.map { "up \(duration($0)) (median)" } ?? "\(t.handsOpen) up now")
            StatTile(label: "Steers per task", value: t.steersPerTask.map { String(format: "%.1f", $0) } ?? "–", detail: "\(counted(t.steers, "steer")), \(counted(t.questions, "question"))")
            StatTile(label: "Review rounds", value: t.reviewRoundsPerMerge.map { String(format: "%.1f", $0) } ?? "–", detail: "per merge · \(counted(t.findings, "finding"))")
        }

        twoUp {
            DailyBars(title: "Merges", days: s.daily, value: \.merges, color: Theme.State.merged)
            DailyBars(title: "Hands raised", days: s.daily, value: \.hands, color: Theme.State.cancelled)
        }

        twoUp {
            BarList(title: "Hands by reason", note: "median time up", rows: s.handsByReason, label: handReason, trailing: { $0.medianMs.map(duration) })
            BarList(title: "Review findings by kind", note: counted(t.reviewRounds, "round"), rows: s.findingsByKind, label: { $0.capitalized }, trailing: { _ in nil })
        }

        twoUp {
            quality(s)
            BarList(title: "Session ends and restarts", note: "\(t.restarts) restarted", rows: s.restartsByCause, label: endCause, trailing: { _ in nil })
        }

        if !s.goals.isEmpty { goalTable(s.goals) }
        if !s.agents.isEmpty { agentTable(s.agents) }
        topTasks(s.topTasks)

        if s.inferred > 0 {
            Label("\(s.inferred) of these touchpoints were worked out from older tasks' history, from before statistics were recorded.", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func twoUp<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        (narrow ? AnyLayout(VStackLayout(spacing: 18)) : AnyLayout(HStackLayout(alignment: .top, spacing: 18))) { content() }
    }

    private func quality(_ s: Wire.StatsSummary) -> some View {
        let t = s.totals
        let yes = s.prompts.first { $0.key == "yes" }?.count ?? 0
        let no = s.prompts.first { $0.key == "no" }?.count ?? 0
        return StatsCard {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("Plans and reviews", note: nil)
                metric("Plan versions written", "\(t.planVersions)")
                metric("Plans approved", "\(t.approvals)")
                metric("Approved at version 1", percent(t.firstTryApproval))
                metric("Review rounds", "\(t.reviewRounds)" + (s.reviewVerdicts.isEmpty ? "" : " (" + s.reviewVerdicts.map { "\($0.count) \(verdict($0.key))" }.joined(separator: ", ") + ")"))
                metric("Questions answered in", duration(t.answerMedianMs) + (t.answerMedianMs == nil ? "" : " (median)"))
                metric("Permission prompts", t.prompts == 0 ? "0" : "\(yes) allowed, \(no) denied")
                metric("Cancelled", "\(t.cancelled)")
            }
        }
    }

    private func goalTable(_ rows: [Wire.StatsGoalRow]) -> some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 0) {
                cardTitle("By goal", note: nil).padding(.bottom, 10)
                tableRow(["Goal", "Tasks", "Merged", "Hands", "Steers", "Rounds", "Cycle"], header: true)
                ForEach(rows, id: \.goal) { r in
                    Hairline()
                    tableRow([r.name, "\(r.tasks)", "\(r.merged)", "\(r.hands)", "\(r.steers)", "\(r.reviewRounds)", duration(r.cycleMedianMs)], dot: FactoryData.goal(named: r.name).color)
                }
            }
        }
    }

    private func agentTable(_ rows: [Wire.StatsAgentRow]) -> some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 0) {
                cardTitle("By agent", note: nil).padding(.bottom, 10)
                tableRow(["Agent", "Tasks", "Merged", "Hands", "Steers", "Rounds", "First-try"], header: true)
                ForEach(rows, id: \.agent) { r in
                    Hairline()
                    tableRow([r.agent.capitalized, "\(r.tasks)", "\(r.merged)", "\(r.hands)", "\(r.steers)", "\(r.reviewRounds)", percent(r.firstTryApproval)])
                }
            }
        }
    }

    private func tableRow(_ cells: [String], header: Bool = false, dot: Color? = nil) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(cells[0]).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(cells.dropFirst().indices, id: \.self) { i in
                Text(cells[i]).frame(width: 74, alignment: .trailing).monospacedDigit()
            }
        }
        .font(.system(size: header ? 11.5 : 12.5, weight: header ? .medium : .regular))
        .foregroundStyle(header ? Theme.textMuted : Theme.text)
        .padding(.vertical, 7)
    }

    private func topTasks(_ rows: [Wire.StatsTaskRow]) -> some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 0) {
                cardTitle("Most touched tasks", note: "where people stepped in most").padding(.bottom, 10)
                if rows.isEmpty {
                    Text("Nothing needed a person in this range.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                }
                ForEach(rows, id: \.task) { r in
                    if r.task != rows.first?.task { Hairline() }
                    let stateColor = LiveAdapter.state(r.state).color
                    HStack(spacing: 10) {
                        Image(systemName: LiveAdapter.state(r.state).icon)
                            .font(.system(size: 11))
                            .foregroundStyle(stateColor)
                            .frame(width: 16)
                            .help(LiveAdapter.state(r.state).title)
                        Text(r.task)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                        Text(r.title).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        Text(touchSummary(r))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                        Text("\(r.touchpoints)")
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.text)
                            .frame(minWidth: 24, alignment: .trailing)
                    }
                    .font(.system(size: 12.5))
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { if state.isLive { state.openFocus(r.task) } }
                    .help("Open \(r.task)")
                }
            }
        }
    }

    private func touchSummary(_ r: Wire.StatsTaskRow) -> String {
        [(r.hands, "hand"), (r.steers, "steer"), (r.questions, "question"), (r.reviewRounds, "round")]
            .filter { $0.0 > 0 }
            .map { counted($0.0, $0.1) }
            .joined(separator: " · ")
    }

    /// "1 round", "2 rounds".
    private func counted(_ n: some BinaryInteger, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textMuted)
            Spacer()
            Text(value).foregroundStyle(Theme.text).monospacedDigit()
        }
        .font(.system(size: 12.5))
    }

    private func handReason(_ key: String) -> String {
        switch key {
        case "reviewLoop": "Review rounds ran out"
        case "proofBurden": "Can't produce a proof"
        case "needsInput": "Needs input"
        case "overBudget": "Over budget"
        case "sessionEnded": "Session ended"
        case "mergeFailed": "Didn't merge"
        default: key
        }
    }

    private func endCause(_ key: String) -> String {
        switch key {
        case "machineSlept": "Machine slept"
        case "tmuxLost": "tmux went away"
        case "runnerUpdated": "Runner updated"
        case "outOfMemory": "Out of memory"
        case "authExpired": "Login expired"
        case "usageLimit": "Usage limit"
        case "killed": "Killed"
        case "exited": "Exited early"
        case "signaled": "Signaled"
        default: key.capitalized
        }
    }

    private func verdict(_ key: String) -> String {
        switch key {
        case "changesRequested": "changes"
        case "escalated": "escalated"
        default: key
        }
    }
}

// MARK: Pieces

private func cardTitle(_ title: String, note: String?) -> some View {
    HStack {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
        Spacer()
        if let note {
            Text(note)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textFaint)
        }
    }
}

private func duration(_ ms: UInt64?) -> String {
    guard let ms else { return "–" }
    let minutes = Double(ms) / 60_000
    if minutes < 1 { return "<1m" }
    if minutes < 60 { return "\(Int(minutes.rounded()))m" }
    if minutes < 48 * 60 { return String(format: "%.1fh", minutes / 60) }
    return String(format: "%.1fd", minutes / 1440)
}

private func percent(_ rate: Double?) -> String {
    rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
}

private struct StatsCard<Content: View>: View {
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

/// One headline number.
private struct StatTile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.cardBG)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        )
    }
}

/// A day-by-day bar sparkline of one series, its total as the title's figure; hover a bar for its day.
private struct DailyBars: View {
    let title: String
    let days: [Wire.StatsDay]
    let value: KeyPath<Wire.StatsDay, UInt32>
    let color: Color

    var body: some View {
        let top = max(1, days.map { $0[keyPath: value] }.max() ?? 1)
        let total = days.reduce(0) { $0 + Int($1[keyPath: value]) }
        StatsCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle(title, note: "\(total) in \(days.count) days")
                GeometryReader { geo in
                    let gap: CGFloat = days.count > 40 ? 1 : 2
                    let width = max(1, (geo.size.width - gap * CGFloat(days.count - 1)) / CGFloat(max(1, days.count)))
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(days, id: \.day) { d in
                            let n = d[keyPath: value]
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                UnevenRoundedRectangle(topLeadingRadius: min(3, width / 2), topTrailingRadius: min(3, width / 2))
                                    .fill(n == 0 ? Theme.fill : color)
                                    .frame(height: n == 0 ? 2 : max(3, geo.size.height * CGFloat(n) / CGFloat(top)))
                            }
                            .frame(width: width)
                            .contentShape(Rectangle())
                            .help("\(d.day): \(n)")
                        }
                    }
                }
                .frame(height: 64)
                HStack {
                    Text(days.first?.day ?? "")
                    Spacer()
                    Text("today")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textFaint)
            }
        }
    }
}

/// Counts as horizontal bars, largest first, each labelled in text ink.
private struct BarList: View {
    let title: String
    let note: String?
    let rows: [Wire.StatsCount]
    let label: (String) -> String
    let trailing: (Wire.StatsCount) -> String?

    var body: some View {
        let top = max(1, rows.map(\.count).max() ?? 1)
        StatsCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle(title, note: note)
                if rows.isEmpty {
                    Text("None in this range.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                }
                ForEach(rows, id: \.key) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(label(row.key)).foregroundStyle(Theme.text)
                            Spacer()
                            if let extra = trailing(row) {
                                Text(extra).foregroundStyle(Theme.textFaint)
                            }
                            Text("\(row.count)")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Theme.text)
                        }
                        .font(.system(size: 12.5))
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.fill)
                                Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * CGFloat(row.count) / CGFloat(top)))
                            }
                        }
                        .frame(height: 6)
                    }
                    .help("\(label(row.key)): \(row.count)")
                }
            }
        }
    }
}

// MARK: Sample (signed out)

extension Wire.StatsSummary {
    /// What the page looks like with a month of work behind it, for the design mockup.
    static var sample: Wire.StatsSummary {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let daily = (0..<30).map { i in
            Wire.StatsDay(day: String(ISO8601DateFormatter.string(from: Date().addingTimeInterval(Double(i - 29) * 86_400), timeZone: .gmt, formatOptions: [.withFullDate])),
                          merges: UInt32([0, 1, 2, 1, 3, 0, 0, 2, 4, 1, 2, 3, 1, 0, 0, 2, 3, 2, 1, 4, 0, 0, 3, 2, 2, 1, 3, 0, 1, 2][i]),
                          hands: UInt32([1, 0, 0, 2, 1, 0, 0, 0, 1, 1, 0, 2, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 2, 0, 1, 0, 0, 0, 1][i]))
        }
        return .init(
            days: 30, goal: nil, since: now - 30 * 86_400_000, generatedAt: now, inferred: 0,
            totals: .init(merged: 47, autoMerged: 12, cancelled: 3, created: 58, tasksTouched: 61, handsRaised: 16, handsOpen: 2, questions: 9, steers: 34,
                          prompts: 11, restarts: 4, reviewRounds: 83, findings: 112, planVersions: 74, approvals: 52,
                          cycleMedianMs: 5 * 3_600_000, handOpenMedianMs: 42 * 60_000, answerMedianMs: 18 * 60_000,
                          firstTryApproval: 0.71, avgPlanVersions: 1.4, reviewRoundsPerMerge: 1.7, steersPerTask: 0.56),
            handsByReason: [.init(key: "sessionEnded", count: 6, medianMs: 25 * 60_000), .init(key: "needsInput", count: 5, medianMs: 70 * 60_000),
                            .init(key: "proofBurden", count: 3, medianMs: 3_600_000), .init(key: "reviewLoop", count: 2, medianMs: 2 * 3_600_000)],
            findingsByKind: [.init(key: "code", count: 61), .init(key: "proof", count: 28), .init(key: "scope", count: 14), .init(key: "risk", count: 9)],
            findingsBySeverity: [.init(key: "major", count: 52), .init(key: "minor", count: 44), .init(key: "blocker", count: 16)],
            restartsByCause: [.init(key: "machineSlept", count: 3), .init(key: "usageLimit", count: 2), .init(key: "killed", count: 1)],
            prompts: [.init(key: "yes", count: 9), .init(key: "no", count: 2)],
            reviewVerdicts: [.init(key: "passed", count: 49), .init(key: "changesRequested", count: 32), .init(key: "escalated", count: 2)],
            daily: daily,
            goals: [.init(goal: "auth", name: "Auth overhaul", tasks: 21, merged: 18, hands: 6, steers: 14, reviewRounds: 31, cycleMedianMs: 4 * 3_600_000),
                    .init(goal: "billing", name: "Billing v2", tasks: 17, merged: 13, hands: 4, steers: 9, reviewRounds: 24, cycleMedianMs: 6 * 3_600_000),
                    .init(goal: "onboarding", name: "Onboarding revamp", tasks: 12, merged: 10, hands: 3, steers: 7, reviewRounds: 17, cycleMedianMs: 5 * 3_600_000)],
            agents: [.init(agent: "claude", tasks: 49, merged: 39, hands: 12, steers: 27, reviewRounds: 66, firstTryApproval: 0.74),
                     .init(agent: "codex", tasks: 12, merged: 8, hands: 4, steers: 7, reviewRounds: 17, firstTryApproval: 0.58)],
            topTasks: [.init(task: "ATL-147", title: "Passkey sign-in", goal: "auth", state: .reviewing, touchpoints: 9, hands: 2, steers: 4, questions: 1, reviewRounds: 4),
                       .init(task: "BIL-212", title: "Proration on plan change", goal: "billing", state: .merged, touchpoints: 6, hands: 1, steers: 3, questions: 2, reviewRounds: 3),
                       .init(task: "ONB-88", title: "Invite flow", goal: "onboarding", state: .building, touchpoints: 4, hands: 1, steers: 2, questions: 0, reviewRounds: 2)]
        )
    }
}
