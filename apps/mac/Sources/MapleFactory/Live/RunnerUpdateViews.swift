import SwiftUI

/// A machine's runner update, inline: what's available, its progress while it runs, and how it ended.
/// The machine card and Settings › Runner both show it.
struct RunnerUpdateRow: View {
    @Environment(FactoryClient.self) private var client
    let machine: Wire.Machine
    /// Whether this person may update it (its owner, or an admin).
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
            if isThisMac {
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
        client.send(.machineUpdate(.init(machine: machine.id)))
    }

    /// This Mac's runner log, where an update's steps and errors are.
    static func showLog() {
        NSWorkspace.shared.open(LocalRunner.logFile)
    }
}

extension View {
    /// What's new for `machine`'s runner as a sheet; `whatsnew:<machine id>` in a headless script opens it too.
    func runnerChanges(_ machine: Wire.Machine, isPresented: Binding<Bool>) -> some View {
        modifier(RunnerChangesPresenter(machine: machine, isPresented: isPresented))
    }
}

private struct RunnerChangesPresenter: ViewModifier {
    @Environment(FactoryClient.self) private var client
    let machine: Wire.Machine
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) { RunnerChangesSheet(machine: machine, since: since) }
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

/// What's new: the runner releases after `since` up to the latest, newest first, each with its date and
/// notes, and the release the machine runs marked at the bottom.
struct RunnerChangesSheet: View {
    @Environment(FactoryClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let machine: Wire.Machine
    let since: String?

    static let demoOpen = Notification.Name("RunnerChangesSheet.demoOpen")

    private var releases: [Wire.RunnerRelease] {
        var list = client.releases(newerThan: since)
        // The release it runs, for what it has now (and on its own when it's up to date).
        if let current = client.release(machine.version), !list.contains(where: { $0.version == current.version }) { list.append(current) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What's New in the Runner").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            .padding(20)
            Divider()
            if releases.isEmpty {
                ContentUnavailableView("No release notes", systemImage: "doc.text", description: Text("This factory's release feed has no runner changelog for these versions."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(releases, id: \.version) { release in
                            row(release)
                            if release.version != releases.last?.version { Divider().padding(.leading, 20) }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 480)
        .background(Theme.cardBG)
    }

    private var subtitle: String {
        let newer = releases.filter { $0.version != machine.version }.count
        guard let version = machine.version else { return machine.name }
        if newer == 0 { return "\(machine.name) runs \(version), the latest release." }
        return "\(machine.name) runs \(version) · \(newer) newer release\(newer == 1 ? "" : "s")"
    }

    private func row(_ release: Wire.RunnerRelease) -> some View {
        let running = release.version == machine.version
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(release.version).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                if release.version == client.runnerLatest { tag("Latest", Theme.State.building) }
                if running { tag("Running here", Theme.State.merged) }
                Spacer()
                if let date = Self.date(release.publishedAt) {
                    // In UTC: the changelog's dates are days, written as midnight UTC.
                    Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                }
            }
            Text(LocalizedStringKey(release.notes ?? "No notes for this release."))
                .font(.system(size: 12.5))
                .foregroundStyle(release.notes == nil ? Theme.textFaint : Theme.textMuted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .opacity(running && releases.count > 1 ? 0.75 : 1)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}
