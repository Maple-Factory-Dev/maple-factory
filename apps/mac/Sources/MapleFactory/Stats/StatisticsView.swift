import SwiftUI

/// The factory's statistics, for admins: merges, raised hands, questions, steers, review rounds and the
/// other touchpoints, over the last 7, 30 or 90 days (`stats.get`). Signed out it shows a sample.
struct StatisticsView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @AppStorage("statsDays") private var days = 30
    /// A section pushed over the overview, in the same scroll view: "findings".
    @State private var section: String?

    private var narrow: Bool { state.contentWidth < 920 }
    private var isAdmin: Bool { !state.isLive || client.me?.role == "admin" }
    private var summary: Wire.StatsSummary? { state.isLive ? client.stats.flatMap { $0.days == UInt32(days) ? $0 : nil } : .sample }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if !isAdmin {
                        StatsCard {
                            Text("Only admins can see statistics.")
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                    } else if let summary, section == "findings" {
                        FindingsView(summary: summary, narrow: narrow) { section = nil }
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
                .id("top")
            }
            .defaultScrollAnchor(.top)
            .onReceive(NotificationCenter.default.publisher(for: AppState.demoFindings)) { note in
                switch (note.object as? [String])?.first {
                case "open": section = "findings"
                case "back": section = nil
                default: break
                }
            }
            .task(id: days) { if state.isLive && isAdmin { client.loadStats(days: days) } }
            .onChange(of: section) { proxy.scrollTo("top", anchor: .top) }
            // `-statsSection cost` opens on the Cost card and `-statsSection findings` on the findings, for screenshots.
            .onChange(of: summary == nil, initial: true) {
                guard summary != nil, let section = AppDefaults.string(forKey: "statsSection") else { return }
                if section == "findings" {
                    self.section = section
                    return
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.3))
                    proxy.scrollTo(section, anchor: .top)
                }
            }
        }
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
            BarList(title: "Review findings by kind", note: counted(t.reviewRounds, "round"), rows: s.findingsByKind, label: { $0.capitalized }, trailing: { severities(s, kind: $0.key) },
                    more: ("See all findings →", { section = "findings" }))
        }

        twoUp {
            quality(s)
            BarList(title: "Session ends and restarts", note: "\(t.restarts) restarted", rows: s.restartsByCause, label: endCause, trailing: { _ in nil })
        }

        costCard(s).id("cost")

        if !s.goals.isEmpty { goalTable(s.goals) }
        if !s.agents.isEmpty { agentTable(s.agents) }
        topTasks(s.topTasks)

        if s.inferred > 0 {
            Label("\(s.inferred) of these touchpoints were worked out from older tasks' history, from before statistics were recorded.", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
    }

    /// "2 blocker · 9 major · 4 minor" for one kind, from the findings breakdown.
    private func severities(_ s: Wire.StatsSummary, kind: String) -> String? {
        guard let cells = s.findings?.matrix.filter({ $0.kind.rawValue == kind }), !cells.isEmpty else { return nil }
        return [Wire.Severity.blocker, .major, .minor].compactMap { sev in
            cells.first { $0.severity == sev }.map { "\($0.count) \(sev.rawValue)" }
        }.joined(separator: " · ")
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

    /// What sessions spent, by role and by agent · model. $ is Claude Code's own estimate; Codex says only tokens.
    private func costCard(_ s: Wire.StatsSummary) -> some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Cost")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    if let total = s.costTotal {
                        Text(costFigure(total))
                            .font(.system(size: 20, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.text)
                        Text("\(tokens(total.tokens)) tokens · \(counted(total.sessions, "session"))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                if s.costTotal == nil {
                    Text("No session has reported its spend in this range yet.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    twoUp {
                        CostBars(title: "By role", rows: s.costByRole, label: { $0.capitalized })
                        CostBars(title: "By agent and model", rows: s.costByAgent, label: { $0 })
                    }
                }
                Text("$ is Claude Code's API-equivalent estimate for the session, not a subscription bill. Codex reports tokens only.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
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
                        if let cost = r.costUsd {
                            Text(dollars(cost))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.textFaint)
                                .help("What its sessions spent (Claude Code's estimate)")
                        }
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

func cardTitle(_ title: String, note: String?) -> some View {
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

/// "$12.34", "<$0.01".
private func dollars(_ usd: Double) -> String {
    if usd > 0 && usd < 0.01 { return "<$0.01" }
    return usd >= 1000 ? String(format: "$%.0f", usd) : String(format: "$%.2f", usd)
}

/// "1.2M", "34k", "512".
private func tokens(_ n: UInt64) -> String {
    let d = Double(n)
    if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
    if d >= 10_000 { return "\(Int((d / 1000).rounded()))k" }
    if d >= 1000 { return String(format: "%.1fk", d / 1000) }
    return "\(n)"
}

/// The $ where some session gave one, else its tokens (Codex).
private func costFigure(_ r: Wire.StatsCostRow) -> String {
    r.unpriced == r.sessions ? "\(tokens(r.tokens)) tok" : dollars(r.costUsd)
}

private func percent(_ rate: Double?) -> String {
    rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
}

struct StatsCard<Content: View>: View {
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
    /// A link under the bars, to a section that digs into them.
    var more: (title: String, action: () -> Void)? = nil

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
                if let more {
                    Button(more.title, action: more.action)
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                }
            }
        }
    }
}

/// Spend as horizontal bars, by $ where there is one and by tokens for groups with none (Codex).
private struct CostBars: View {
    let title: String
    let rows: [Wire.StatsCostRow]
    let label: (String) -> String

    var body: some View {
        let topUsd = max(0.0001, rows.map(\.costUsd).max() ?? 0)
        let topTokens = max(1, rows.map(\.tokens).max() ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            ForEach(rows, id: \.key) { row in
                let priced = row.unpriced < row.sessions
                let share = priced ? row.costUsd / topUsd : Double(row.tokens) / Double(topTokens)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(label(row.key)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        Text("\(tokens(row.tokens)) tok · \(row.sessions)")
                            .foregroundStyle(Theme.textFaint)
                        Text(costFigure(row))
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Theme.text)
                    }
                    .font(.system(size: 12.5))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.fill)
                            Capsule().fill(priced ? Theme.accent : Theme.textFaint).frame(width: max(4, geo.size.width * CGFloat(share)))
                        }
                    }
                    .frame(height: 6)
                }
                .help("\(label(row.key)): \(row.sessions) session\(row.sessions == 1 ? "" : "s"), \(tokens(row.tokens)) tokens" + (priced ? ", \(dollars(row.costUsd))" : "") + (row.unpriced > 0 && priced ? " (\(row.unpriced) without a $ figure)" : ""))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
            topTasks: [.init(task: "ATL-147", title: "Passkey sign-in", goal: "auth", state: .reviewing, touchpoints: 9, hands: 2, steers: 4, questions: 1, reviewRounds: 4, costUsd: 18.42),
                       .init(task: "BIL-212", title: "Proration on plan change", goal: "billing", state: .merged, touchpoints: 6, hands: 1, steers: 3, questions: 2, reviewRounds: 3, costUsd: 9.75),
                       .init(task: "ONB-88", title: "Invite flow", goal: "onboarding", state: .building, touchpoints: 4, hands: 1, steers: 2, questions: 0, reviewRounds: 2)],
            costTotal: .init(key: "total", sessions: 186, costUsd: 412.6, tokens: 318_400_000, unpriced: 31),
            costByRole: [.init(key: "builder", sessions: 64, costUsd: 268.3, tokens: 201_000_000, unpriced: 14),
                         .init(key: "reviewer", sessions: 83, costUsd: 98.1, tokens: 82_400_000, unpriced: 12),
                         .init(key: "planner", sessions: 39, costUsd: 46.2, tokens: 35_000_000, unpriced: 5)],
            costByAgent: [.init(key: "claude · claude-opus-5-5", sessions: 121, costUsd: 371.9, tokens: 236_000_000, unpriced: 0),
                          .init(key: "claude · claude-sonnet-5-5", sessions: 34, costUsd: 40.7, tokens: 41_400_000, unpriced: 0),
                          .init(key: "codex · gpt-6.1", sessions: 31, costUsd: 0, tokens: 41_000_000, unpriced: 31)],
            findings: .sample(now: now)
        )
    }
}

extension Wire.StatsFindings {
    /// The sample month's 112 findings, broken down.
    static func sample(now: UInt64) -> Wire.StatsFindings {
        let hour: UInt64 = 3_600_000
        let cells: [(Wire.FindingKind, [UInt32])] = [(.code, [7, 30, 24]), (.proof, [5, 12, 11]), (.scope, [3, 6, 5]), (.risk, [1, 4, 4])]
        let row = { (task: String, title: String, kind: Wire.FindingKind, severity: Wire.Severity, text: String, file: String?, area: String, status: Wire.FindingStatus?, round: UInt32, hoursAgo: UInt64) in
            Wire.StatsFindingRow(task: task, title: title, kind: kind, severity: severity, text: text, file: file, area: area, status: status, raisedIn: round, at: now - hoursAgo * hour)
        }
        return .init(
            matrix: cells.flatMap { k, counts in zip([Wire.Severity.blocker, .major, .minor], counts).map { .init(kind: k, severity: $0, count: $1) } }
                .sorted { $0.count > $1.count },
            areas: [.init(key: "app/api", count: 24, tasks: 11, serious: 15), .init(key: "lib/auth", count: 21, tasks: 7, serious: 14),
                    .init(key: "(no file)", count: 19, tasks: 14, serious: 9), .init(key: "db/migrations", count: 14, tasks: 9, serious: 10),
                    .init(key: "emails", count: 11, tasks: 4, serious: 5), .init(key: "components/billing", count: 9, tasks: 5, serious: 6),
                    .init(key: "lib/session", count: 8, tasks: 3, serious: 7), .init(key: "(root)", count: 6, tasks: 5, serious: 2)],
            outcomes: .init(fixed: 78, disputed: 9, open: 21, unknown: 4, roundsToFixMedian: 1),
            byAgent: [.init(agent: "claude", rounds: 66, findings: 81, serious: 48, perRound: 1.23),
                      .init(agent: "codex", rounds: 17, findings: 31, serious: 20, perRound: 1.82)],
            recent: [
                row("ATL-147", "Passkey sign-in", .code, .major, "The WebAuthn challenge is stored in a cookie without SameSite, so a cross-site POST can replay it.", "lib/auth/passkey.ts:88", "lib/auth", .open, 4, 3),
                row("ATL-147", "Passkey sign-in", .proof, .major, "The screenshot shows Safari only; the plan asked for Chrome and Firefox too.", nil, "(no file)", .open, 4, 3),
                row("ONB-88", "Invite flow", .code, .minor, "inviteUrl() builds the link by string concatenation; use URL so the token is escaped.", "app/api/invites/route.ts:41", "app/api", .fixed, 2, 9),
                row("BIL-212", "Proration on plan change", .scope, .blocker, "customer.subscription.updated arriving after a newer event either drops a real downgrade or re-applies a stale plan.", "app/api/webhooks/stripe/route.ts:64", "app/api", .fixed, 2, 20),
                row("BIL-212", "Proration on plan change", .code, .major, "Event ids aren't unique-indexed; a race can process the same event twice.", "db/migrations/0044_stripe_events.sql", "db/migrations", .fixed, 2, 20),
                row("ATL-147", "Passkey sign-in", .code, .major, "Refresh tokens survive sign-out; revoke the token family too.", "lib/auth/refresh.ts", "lib/auth", .fixed, 2, 26),
                row("ATL-141", "Sign-out everywhere", .scope, .blocker, "Edge session cache isn't purged in every region, so other devices stay signed in for up to 60s.", "lib/session/edge-cache.ts:52", "lib/session", .disputed, 2, 40),
                row("ONB-80", "Welcome email", .proof, .major, "No Outlook render attached; Outlook is where table layouts usually break.", nil, "(no file)", .fixed, 2, 52),
                row("ONB-80", "Welcome email", .code, .major, "Email used a <style> block, which Gmail strips.", "emails/invite.tsx", "emails", .fixed, 1, 60),
                row("BIL-207", "Annual plans", .risk, .major, "The price migration rewrites live subscriptions without a dry run.", "db/migrations/0041_annual.sql", "db/migrations", .fixed, 1, 75),
                row("BIL-207", "Annual plans", .code, .minor, "PlanPicker re-renders on every keystroke; memoise the price table.", "components/billing/PlanPicker.tsx", "components/billing", .open, 1, 75),
                row("ATL-139", "JWT hardening", .risk, .major, "jwtVerify() doesn't pin algorithms; pass { algorithms: ['HS256'] }.", "lib/auth/jwt.ts:21", "lib/auth", .fixed, 1, 110),
                row("ATL-139", "JWT hardening", .code, .blocker, "verifyToken() isn't awaited in withAuth, so the promise is always truthy and any token passes.", "lib/auth/middleware.ts:38", "lib/auth", .fixed, 1, 110),
                row("ONB-71", "Docs links", .code, .minor, "README still links the old setup guide.", "README.md", "(root)", nil, 1, 300),
            ]
        )
    }
}
