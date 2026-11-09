import MapleKit
import SwiftUI
import UIKit

/// Your day report ("EOD"), like the Mac's: what you merged, reviewed for others, have waiting on review
/// and have in progress, across every goal, for one local day (`report.get`). The server writes the
/// Markdown and Slack text; Copy and Share hand those strings on as they are.
struct DayReportView: View {
    @Environment(FactoryStore.self) private var store
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var copied: String?

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    /// The report for the day showing; a stale one (another day) isn't shown.
    private var report: Wire.DayReport? {
        guard let r = store.dayReport else { return nil }
        return r.since == UInt64(day.timeIntervalSince1970 * 1000) ? r : nil
    }
    /// Changes when any task moves on, so the report follows the feed.
    private var feedKey: String { store.feed.tasks.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: ",") }

    var body: some View {
        List {
            Section { header }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            if let report {
                if report.sections.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Nothing to report",
                            systemImage: "doc.text",
                            description: Text(isToday ? "Nothing merged, reviewed or in flight yet today." : "Nothing merged or reviewed that day.")
                        )
                        .accessibilityIdentifier("dayReport.empty")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(report.sections, id: \.key) { section in
                    Section {
                        ForEach(section.items, id: \.id) { row($0) }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(color(section.key)).frame(width: 8, height: 8)
                            Text(section.title)
                            Text("\(section.items.count)").foregroundStyle(.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("dayReport.section.\(section.key)")
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Day report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { shareMenu } }
        .safeAreaInset(edge: .bottom) {
            if let copied {
                Label("Copied for \(copied)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.approve))
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("dayReport.copied")
            }
        }
        .animation(.snappy(duration: 0.2), value: copied)
        .task(id: day) { store.requestReport(day: day) }
        .onChange(of: feedKey) { store.requestReport(day: day) }
        .refreshable {
            store.requestReport(day: day)
            for _ in 0..<30 where report == nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.wide)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(day.formatted(.dateTime.month(.wide).day()))
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("dayReport.date")
            }
            Spacer()
            HStack(spacing: 4) {
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 30) }
                    .accessibilityLabel("The day before")
                    .accessibilityIdentifier("dayReport.prev")
                Button("Today") { day = Calendar.current.startOfDay(for: Date()) }
                    .disabled(isToday)
                    .accessibilityIdentifier("dayReport.today")
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 30) }
                    .disabled(isToday)
                    .accessibilityLabel("The day after")
                    .accessibilityIdentifier("dayReport.next")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }

    private var shareMenu: some View {
        Menu {
            Button { copy(report?.slack, as: "Slack") } label: { Label("Copy for Slack", systemImage: "number") }
                .accessibilityIdentifier("dayReport.copySlack")
            Button { copy(report?.markdown, as: "Markdown") } label: { Label("Copy as Markdown", systemImage: "doc.on.doc") }
                .accessibilityIdentifier("dayReport.copyMarkdown")
            if let report {
                ShareLink(item: report.markdown, subject: Text(report.title)) { Label("Share…", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("dayReport.share")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(report == nil)
        .accessibilityLabel("Share report")
        .accessibilityIdentifier("dayReport.menu")
    }

    private func row(_ item: Wire.ReportItem) -> some View {
        NavigationLink(value: TaskRoute(id: item.id)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.id)
                        .font(.caption.weight(.semibold).monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(Theme.accent)
                    Text(item.title).font(.body).lineLimit(2)
                }
                HStack(spacing: 6) {
                    let details = [item.note, item.goal].compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · ")).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let pr = item.pr {
                        if let url = item.prUrl.flatMap(URL.init(string:)) {
                            Link("PR #\(pr)", destination: url).fontWeight(.medium)
                        } else {
                            Text("PR #\(pr)")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("dayReport.item.\(item.id)")
    }

    private func step(_ days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: day) { day = Calendar.current.startOfDay(for: next) }
    }

    private func copy(_ text: String?, as kind: String) {
        guard let text else { return }
        UIPasteboard.general.string = text
        copied = kind
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if copied == kind { copied = nil }
        }
    }

    private func color(_ key: String) -> Color {
        switch key {
        case "merged": Theme.state(.merged)
        case "reviewed": Theme.approve
        case "pendingReview": Theme.state(.reviewing)
        default: Theme.state(.building)
        }
    }
}

struct DayReportRoute: Hashable {}
