import MapleKit
import SwiftUI

/// The factory's statistics, for admins (Settings → Statistics): the Mac's headline numbers, finding
/// outcomes, top areas and top findings over the last 24 hours, 3, 7, 30 or 90 days (`stats.get`).
/// Read-only. For screenshots, `-statsSection findings` scrolls to the findings and `-statsCycle YES`
/// steps through every range (Debug builds only).
struct StatisticsView: View {
    @Environment(FactoryStore.self) private var store
    @AppStorage("statsDays") private var days = 7

    private static let ranges: [(days: Int, label: String)] = [(1, "24h"), (3, "3d"), (7, "7d"), (30, "30d"), (90, "90d")]

    /// Only a reply for the picked range, so a slow one for the last range never shows under this one.
    private var summary: Wire.StatsSummary? { store.stats.flatMap { $0.days == UInt32(days) ? $0 : nil } }

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onChange(of: summary?.generatedAt) {
                    guard UserDefaults.standard.string(forKey: "statsSection") == "findings" else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        proxy.scrollTo("findings", anchor: .top)
                    }
                }
        }
        #if DEBUG
        .task {
            guard UserDefaults.standard.bool(forKey: "statsCycle") else { return }
            for range in Self.ranges {
                try? await Task.sleep(for: .seconds(4))
                days = range.days
            }
        }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                Picker("Range", selection: $days) {
                    ForEach(Self.ranges, id: \.days) { Text($0.label).tag($0.days) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let summary {
                content(summary)
            } else {
                Section { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.loadStats(days: days) }
        .onChange(of: days) { _, new in store.loadStats(days: new) }
        .refreshable {
            let before = store.stats?.generatedAt
            store.loadStats(days: days)
            for _ in 0..<30 where store.stats?.generatedAt == before { try? await Task.sleep(for: .milliseconds(100)) }
        }
    }

    @ViewBuilder private func content(_ s: Wire.StatsSummary) -> some View {
        let t = s.totals
        Section("Headline") {
            headline("Merged", "\(t.merged)", t.autoMerged > 0 ? "\(t.autoMerged) auto-merged" : "\(t.created) created")
            headline("Cycle time", duration(t.cycleMedianMs), "median, to merge")
            headline("First-try plans", percent(t.firstTryApproval), t.avgPlanVersions.map { String(format: "%.1f versions on average", $0) } ?? "no approvals yet")
            headline("Hands raised", "\(t.handsRaised)", t.handOpenMedianMs.map { "up \(duration($0)) (median)" } ?? "\(t.handsOpen) up now")
            headline("Steers per task", t.steersPerTask.map { String(format: "%.1f", $0) } ?? "–", "\(counted(t.steers, "steer")), \(counted(t.questions, "question"))")
            headline("Review rounds", t.reviewRoundsPerMerge.map { String(format: "%.1f", $0) } ?? "–", "per merge · \(counted(t.findings, "finding"))")
            if let cost = s.costTotal {
                headline("Cost", costFigure(cost), counted(cost.sessions, "session"))
            }
        }
        if let f = s.findings {
            Section("Findings") {
                LabeledContent("Fixed", value: "\(f.outcomes.fixed)")
                LabeledContent("Disputed", value: "\(f.outcomes.disputed)")
                LabeledContent("Open", value: "\(f.outcomes.open)")
                LabeledContent("Rounds to fix", value: f.outcomes.roundsToFixMedian.map { String(format: "%.1f (median)", $0) } ?? "–")
            }
            .id("findings")
            if f.recent.isEmpty && f.areas.isEmpty {
                Section { Text("No findings in this range").foregroundStyle(.secondary) }
            } else {
                if !f.areas.isEmpty {
                    Section("Top areas") {
                        ForEach(f.areas.prefix(5), id: \.key) { area in
                            LabeledContent {
                                Text("\(area.count)" + (area.serious > 0 ? " · \(area.serious) serious" : "")).monospacedDigit()
                            } label: {
                                Text(area.key).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                Section("Top findings") {
                    if f.recent.isEmpty {
                        Text("No findings in this range").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(top(f.recent).enumerated()), id: \.offset) { _, row in findingRow(row) }
                    }
                }
            }
        } else {
            Section("Findings") {
                Text("This factory's server doesn't send findings yet. Update it to see them here.").foregroundStyle(.secondary)
            }
        }
    }

    private func headline(_ label: String, _ value: String, _ detail: String) -> some View {
        LabeledContent {
            Text(value).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
        } label: {
            Text(label)
            Text(detail)
        }
    }

    /// Open first, then blocker > major > minor, then newest; at most 10.
    private func top(_ rows: [Wire.StatsFindingRow]) -> [Wire.StatsFindingRow] {
        Array(rows.sorted { a, b in
            let ao = a.status == .open, bo = b.status == .open
            if ao != bo { return ao }
            if rank(a.severity) != rank(b.severity) { return rank(a.severity) < rank(b.severity) }
            return a.at > b.at
        }.prefix(10))
    }

    private func rank(_ severity: Wire.Severity) -> Int {
        switch severity {
        case .blocker: 0
        case .major: 1
        case .minor: 2
        default: 3
        }
    }

    @ViewBuilder private func findingRow(_ row: Wire.StatsFindingRow) -> some View {
        let label = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color(row.severity)).frame(width: 8, height: 8)
                Text("\(row.severity.rawValue) · \(row.kind.rawValue)").font(.caption.weight(.semibold)).foregroundStyle(color(row.severity))
                if let status = row.status {
                    Spacer()
                    Text(status.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(status == .open ? Theme.accent : .secondary)
                }
            }
            Text("\(row.task) · \(row.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(row.text).font(.callout).lineLimit(3)
            if let file = row.file {
                Text(file).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        if store.feed.task(row.task) != nil {
            NavigationLink(value: TaskRoute(id: row.task)) { label }
        } else {
            label
        }
    }

    private func color(_ severity: Wire.Severity) -> Color {
        switch severity {
        case .blocker: Theme.danger
        case .major: Theme.warning
        default: .secondary
        }
    }
}

// Formatters copied from the Mac's StatisticsView (MapleKit doesn't share them).

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

/// "1 round", "2 rounds".
private func counted(_ n: some BinaryInteger, _ noun: String) -> String {
    "\(n) \(noun)\(n == 1 ? "" : "s")"
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
