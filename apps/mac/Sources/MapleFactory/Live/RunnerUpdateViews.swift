import SwiftUI

/// A machine's runner update, inline: what's available, its progress while it runs, and how it ended.
/// The machine card and Settings › Runner both show it.
struct RunnerUpdateRow: View {
    @Environment(FactoryClient.self) private var client
    let machine: Wire.Machine
    /// Whether it has its own Update, Retry and Show Log (this person may update it, and nothing beside it does).
    let canUpdate: Bool
    /// Opens What's new (the `runnerChanges` sheet on the view around this).
    let whatsNew: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            content(client.updatePhase(machine))
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
    }

    @ViewBuilder private func content(_ phase: RunnerUpdatePhase) -> some View {
        switch phase {
        case .current:
            EmptyView()
        case .outdated(let latest):
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.State.awaitingApproval)
            Text("Runner \(latest) available").foregroundStyle(Theme.text)
            whatsNew("What's New")
            Spacer(minLength: 4)
            if canUpdate {
                Button("Update") { update() }
                    .controlSize(.small)
                    .disabled(!machine.online)
                    .help(machine.online ? "Download, verify and restart into runner \(latest). Sessions in tmux keep running." : "\(machine.name) is offline.")
            }
        case .checking, .installing, .restarting:
            ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
            Text(phase.progressText ?? "").foregroundStyle(Theme.text)
            Spacer(minLength: 4)
        case .updated(let version, _):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.State.merged)
            Text("Updated to runner \(version)").foregroundStyle(Theme.text)
            whatsNew("What Changed")
            Spacer(minLength: 4)
        case .upToDate(let version):
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.State.merged)
            Text("Runner \(version ?? "") is up to date").foregroundStyle(Theme.text)
            whatsNew("What's New")
            Spacer(minLength: 4)
        case .failed(let message, let target):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.State.cancelled)
            VStack(alignment: .leading, spacing: 1) {
                Text("Couldn't update the runner\(target.map { " to \($0)" } ?? "")").foregroundStyle(Theme.text)
                if let message {
                    Text(message)
                        .font(.system(size: 11.5))
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if canUpdate && isThisMac {
                Button("Show Log") { Self.showLog() }.controlSize(.small)
            }
            if canUpdate {
                Button("Retry") { update() }.controlSize(.small).disabled(!machine.online)
            }
        }
    }

    private var isThisMac: Bool { client.thisMac?.id == machine.id }

    private func whatsNew(_ title: String) -> some View {
        Button(title) { whatsNew() }
            .buttonStyle(.link)
            .disabled(client.runnerReleases.isEmpty)
            .help(client.runnerReleases.isEmpty ? "This factory's release feed has no runner changelog yet." : "The runner releases and what changed in each.")
    }

    private func update() {
        client.updateRunner(machine)
    }

    /// This Mac's runner log, where an update's steps and errors are.
    static func showLog() {
        NSWorkspace.shared.open(LocalRunner.logFile)
    }
}

extension View {
    /// What's new for `machine`'s runner as a sheet; `whatsnew:<machine id>` in a headless script opens it too.
    /// `canUpdate`: whether this person may update it, so the sheet's footer offers Update.
    func runnerChanges(_ machine: Wire.Machine, canUpdate: Bool, isPresented: Binding<Bool>) -> some View {
        modifier(RunnerChangesPresenter(machine: machine, canUpdate: canUpdate, isPresented: isPresented))
    }
}

private struct RunnerChangesPresenter: ViewModifier {
    @Environment(FactoryClient.self) private var client
    let machine: Wire.Machine
    let canUpdate: Bool
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) { RunnerChangesSheet(machine: machine, since: since, canUpdate: canUpdate) }
            .onReceive(NotificationCenter.default.publisher(for: RunnerChangesSheet.demoOpen)) { note in
                if note.object as? String == machine.id { isPresented = true }
            }
    }

    /// The version the sheet lists releases after: the one it updated from, once an update's done.
    private var since: String? {
        if case .updated(_, let from) = client.updatePhase(machine), let from { return from }
        return machine.version
    }
}

/// What's new in the runner, laid out like the app's own update notes (ReleaseNotesSheet and the
/// site's changelog.html): "installed → offered" in the header, a range title, a section per release
/// with its date and badges, Show all releases, and Later and Update in the footer.
struct RunnerChangesSheet: View {
    @Environment(FactoryClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let machine: Wire.Machine
    let since: String?
    var canUpdate = false
    @State private var showAll = false

    static let demoOpen = Notification.Name("RunnerChangesSheet.demoOpen")

    // MARK: The sheet's logic, for tests

    /// The releases the sheet lists, newest first: those after `since` up to `latest`, and the one the
    /// machine runs (for what it has now, and on its own when it's up to date); every release with Show all.
    static func window(_ all: [Wire.RunnerRelease], since: String?, latest: String?, running: String?, showAll: Bool) -> [Wire.RunnerRelease] {
        if showAll { return FactoryClient.releases(all, newerThan: nil, through: nil) }
        var list = FactoryClient.releases(all, newerThan: since, through: latest)
        if let current = all.first(where: { $0.version == running }), !list.contains(where: { $0.version == current.version }) {
            list.append(current)
        }
        return list
    }

    struct RangeTitle: Equatable {
        var title: String
        var subtitle: String?
    }

    /// The title above the releases: what changed since `since`, one release's own heading and date, or
    /// that the machine runs the latest; every release with Show all.
    static func rangeTitle(_ shown: [Wire.RunnerRelease], since: String?, machineName: String, showAll: Bool) -> RangeTitle {
        if showAll {
            let span = shown.count > 1 ? "\(shown.last!.version) to \(shown.first!.version), newest first" : nil
            return RangeTitle(title: "Every runner release · \(count(shown.count))", subtitle: span)
        }
        // The window also holds the release it runs; only the ones after `since` are changes.
        let newer = shown.filter { r in since.map { FactoryClient.version($0, isOlderThan: r.version) } ?? true }
        switch newer.count {
        case 0:
            let version = since ?? shown.first?.version
            return RangeTitle(title: version.map { "\(machineName) runs \($0), the latest release" } ?? "No runner releases yet", subtitle: nil)
        case 1:
            return RangeTitle(title: "Runner \(newer[0].version)", subtitle: date(newer[0].publishedAt).map(dayText))
        default:
            let title = since.map { "Changes since \($0) · \(count(newer.count))" } ?? "Changes up to \(newer[0].version) · \(count(newer.count))"
            return RangeTitle(title: title, subtitle: "\(newer.last!.version) to \(newer[0].version), newest first")
        }
    }

    /// The footer's primary button: Update while the machine is behind, online, and this person may update it.
    static func primaryButton(phase: RunnerUpdatePhase, online: Bool, canUpdate: Bool) -> String? {
        guard case .outdated = phase, online, canUpdate else { return nil }
        return "Update"
    }

    enum NoteBlock: Equatable {
        case paragraph(String)
        case bullet(String)
        case heading(String)
    }

    /// A release's notes as blocks: paragraphs split on blank lines, `- ` and `* ` lines as bullets (an
    /// indented line carries on the one before), and `#` lines as headings.
    static func blocks(_ notes: String) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in notes.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if raw.first?.isWhitespace == true, paragraph.isEmpty, case .bullet(let text)? = blocks.last {
                blocks[blocks.count - 1] = .bullet(text + " " + line)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func count(_ n: Int) -> String { "\(n) release\(n == 1 ? "" : "s")" }

    /// In UTC: the changelog's dates are days, written as midnight UTC.
    static func dayText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt))
    }

    // MARK: The sheet

    private var releases: [Wire.RunnerRelease] {
        Self.window(client.runnerReleases, since: since, latest: client.runnerLatest, running: machine.version, showAll: showAll)
    }

    private var phase: RunnerUpdatePhase { client.updatePhase(machine) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .background(Theme.editorBG)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("What's New in the Runner")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            if let line = versionLine {
                Text(line)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// "0.80.0 → 0.85.0" while it's behind (or just updated), its version when it's current.
    private var versionLine: String? {
        let to: String? = if case .updated(let version, _) = phase { version } else { client.runnerLatest }
        guard let from = since else { return to }
        guard let to, FactoryClient.version(from, isOlderThan: to) else { return from }
        return "\(from) → \(to)"
    }

    @ViewBuilder private var content: some View {
        if client.runnerReleases.isEmpty {
            ContentUnavailableView("No release notes", systemImage: "doc.text", description: Text("This factory's release feed has no runner changelog yet."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    rangeHeader
                    ForEach(releases, id: \.version) { release in
                        Rectangle().fill(Theme.stroke).frame(height: 1)
                        section(release)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var rangeHeader: some View {
        let title = Self.rangeTitle(releases, since: since, machineName: machine.name, showAll: showAll)
        let everything = client.runnerReleases.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(title.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)
            if let subtitle = title.subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textMuted)
            }
            if showAll || releases.count < everything {
                Button(showAll ? "Show fewer" : "Show all releases") { withAnimation(.snappy(duration: 0.2)) { showAll.toggle() } }
                    .buttonStyle(.link)
                    .font(.system(size: 13))
                    .padding(.top, 4)
            }
        }
        .textSelection(.enabled)
        .padding(.bottom, 18)
    }

    private func section(_ release: Wire.RunnerRelease) -> some View {
        let running = release.version == machine.version
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(release.version)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                if release.version == client.runnerLatest { badge("Latest") }
                if running { badge("Running here") }
                Spacer(minLength: 8)
                if let date = Self.date(release.publishedAt) {
                    Text(Self.dayText(date)).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
            }
            if let notes = release.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Self.blocks(notes).enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
            } else {
                Text("No notes for this release.").font(.system(size: 13)).foregroundStyle(Theme.textFaint)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: NoteBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text).font(.system(size: 13)).foregroundStyle(Theme.text).lineSpacing(3)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Theme.textMuted)
                inline(text).lineSpacing(3)
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.leading, 4)
        case .heading(let text):
            inline(text).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text).padding(.top, 4)
        }
    }

    /// Inline Markdown (code, emphasis, links); links open in the browser through the default openURL.
    private func inline(_ text: String) -> Text {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(parsed)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.55)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Later") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let label = Self.primaryButton(phase: phase, online: machine.online, canUpdate: canUpdate) {
                Button(label) {
                    client.updateRunner(machine)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .help("Download, verify and restart into the latest runner. Sessions in tmux keep running.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}
