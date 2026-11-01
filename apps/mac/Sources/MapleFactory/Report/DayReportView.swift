import AppKit
import MapleKit
import SwiftUI

/// Your day report ("EOD"): what you merged, reviewed for others, have waiting on review and have in
/// progress, across every goal, for one local day (`report.get`). Copy as Markdown or for Slack to post it.
struct DayReportView: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var copied: String?

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var narrow: Bool { state.contentWidth < 920 }
    /// The report for the day showing; a stale one (another day) isn't shown.
    private var report: Wire.DayReport? {
        guard let r = client.dayReport else { return nil }
        let since = UInt64(day.timeIntervalSince1970 * 1000)
        return r.since == since ? r : nil
    }
    /// Changes when any task moves on, so the report follows the feed.
    private var feedKey: String { state.tasks.map { "\($0.id):\($0.state)" }.joined(separator: ",") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !state.isLive {
                    StatsCard { muted("Sign in to see your day report.") }
                } else if let report {
                    if report.sections.isEmpty {
                        StatsCard { muted(isToday ? "Nothing merged, reviewed or in flight yet today." : "Nothing merged or reviewed that day.") }
                    }
                    ForEach(report.sections, id: \.key) { section in
                        sectionCard(section)
                    }
                    footer(report)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, narrow ? 24 : 40)
            .padding(.vertical, 30)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: day) { if state.isLive { client.requestReport(day: day) } }
        .onChange(of: feedKey) { if state.isLive { client.requestReport(day: day) } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Day report")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            HStack(spacing: 4) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("The day before")
                Button("Today") { day = Calendar.current.startOfDay(for: Date()) }
                    .disabled(isToday)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isToday)
                    .help("The day after")
            }
            .controlSize(.regular)
        }
    }

    private func step(_ days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: day) { day = Calendar.current.startOfDay(for: next) }
    }

    private func sectionCard(_ section: Wire.ReportSection) -> some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(color(section.key)).frame(width: 8, height: 8)
                    Text(section.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("\(section.items.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(section.items, id: \.id) { row($0) }
                }
            }
        }
    }

    private func row(_ item: Wire.ReportItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { state.openTask(item.id) } label: {
                Text(item.id)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fill))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Open \(item.id)")
            Text(item.title)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let note = item.note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            if let goal = item.goal {
                Text(goal).font(.system(size: 12)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            if let pr = item.pr {
                if let url = item.prUrl.flatMap(URL.init(string:)) {
                    Link("PR #\(pr)", destination: url).font(.system(size: 12.5, weight: .medium))
                } else {
                    Text("PR #\(pr)").font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    private func footer(_ report: Wire.DayReport) -> some View {
        HStack(spacing: 8) {
            Button { copy(report.markdown, as: "Markdown") } label: { Label("Copy as Markdown", systemImage: "doc.on.doc") }
            Button { copy(report.slack, as: "Slack") } label: { Label("Copy for Slack", systemImage: "number") }
                .buttonStyle(.borderedProminent)
            if let copied {
                Label("Copied for \(copied)", systemImage: "checkmark")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.approve)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: copied)
    }

    private func copy(_ text: String, as kind: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = kind
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if copied == kind { copied = nil }
        }
    }

    private func muted(_ text: String) -> some View {
        Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.textMuted)
    }

    private func color(_ key: String) -> Color {
        switch key {
        case "merged": Theme.State.merged
        case "reviewed": Theme.approve
        case "pendingReview": Theme.State.reviewing
        default: Theme.State.building
        }
    }
}
