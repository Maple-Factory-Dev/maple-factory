import SwiftUI
import MapleKit

/// The top bar's andon cord (MF-397): an outlined red "Stop the line" button, or a filled red "Line stopped" pill
/// while any merge hold is on. Either opens `StopTheLinePopover`.
struct StopTheLineButton: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    @State private var frame: CGRect = .zero

    var body: some View {
        @Bindable var state = state
        let holds = client.mergeHolds
        let stopped = !holds.isEmpty
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold))
            if !state.isCompact {
                Text(stopped ? (LineStop.pillLabel(holds) ?? "Line stopped") : "Stop the line")
                    .lineLimit(1)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(stopped ? .white : GitHubColor.failed)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(stopped ? GitHubColor.failed : GitHubColor.failed.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(GitHubColor.failed.opacity(stopped ? 0 : 0.55)))
        )
        .contentShape(Rectangle())
        .onTapGesture { state.showsStopTheLine.toggle() }
        .help(stopped ? "Merges are on hold: see or lift the holds" : "Stop the line: hold every merge into a repo, across all goals")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stopped ? (LineStop.pillLabel(holds) ?? "Line stopped") : "Stop the line")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { state.showsStopTheLine.toggle() }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        // Headless shots draw a popover from what it points at (a background app's popover sits off on its own).
        .onChange(of: state.showsStopTheLine) { _, open in
            guard Headless.isOn else { return }
            Headless.popoverAnchor = open ? frame : nil
        }
        .popover(isPresented: $state.showsStopTheLine, arrowEdge: .bottom) {
            StopTheLinePopover()
                .environment(state)
                .environment(client)
        }
        .padding(.leading, 4)
    }
}

/// Holds on now (each with Lift), then: which repo, why, and a destructive "Stop the line".
struct StopTheLinePopover: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    /// A headless script's `stopline:go`.
    static let demoSubmit = Notification.Name("StopTheLinePopover.demoSubmit")

    private var target: LineStop.Target? {
        get { state.stopLineTarget }
        nonmutating set { state.stopLineTarget = newValue }
    }
    private var reason: String { state.stopLineReason }

    private var goals: [Wire.Goal] { client.goals.filter { $0.archived != true } }
    private var currentRepo: String? { state.currentGoalName.flatMap { LineStop.repo(of: client.goal(named: $0)) } }
    private var offered: [String] {
        LineStop.offeredRepos(current: currentRepo, goals: goals, orgRepos: client.repos.map(\.name))
    }
    private var chosen: LineStop.Target? { target ?? offered.first.map { .repo($0) } }
    private var toHold: [String] {
        chosen.map { LineStop.repos(for: $0, goals: goals, holds: client.mergeHolds) } ?? []
    }
    private var trimmedCount: Int { reason.trimmingCharacters(in: .whitespacesAndNewlines).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !client.mergeHolds.isEmpty {
                Text("Line stopped").font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(client.mergeHolds, id: \.repo) { hold in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hold.repo).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                            MergeHoldBanner(hold: hold) { client.releaseMerges(repo: hold.repo) }
                        }
                    }
                }
                Hairline()
            }
            Text(client.mergeHolds.isEmpty ? "Stop the line" : "Stop another repo").font(.system(size: 14, weight: .semibold))
            Text("Nothing merges into it, on any goal, until someone lifts the hold: auto-merge countdowns stop and Merge is refused. Tasks keep building and reviewing.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if offered.isEmpty {
                Text("No repositories yet: goals pick theirs in Settings › Repositories.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else {
                Picker("Repo", selection: Binding(get: { chosen ?? .allGoalRepos }, set: { target = $0 })) {
                    ForEach(offered, id: \.self) { repo in
                        Text(client.mergeHold(for: repo) != nil ? "\(repo) (on hold)" : repo).tag(LineStop.Target.repo(repo))
                    }
                    if LineStop.goalRepos(goals).count > 1 {
                        Divider()
                        Text("All goal repos (\(LineStop.goalRepos(goals).count))").tag(LineStop.Target.allGoalRepos)
                    }
                }
                .pickerStyle(.menu)
                TextField("Why? e.g. Incident #42: bad deploy, rolling back", text: Bindable(state).stopLineReason)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                if trimmedCount > LineStop.maxReason {
                    Text("Keep it to \(LineStop.maxReason) characters.").font(.system(size: 11)).foregroundStyle(GitHubColor.failed)
                } else if toHold.isEmpty {
                    Text("Already on hold.").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { state.showsStopTheLine = false }.keyboardShortcut(.cancelAction)
                    Button(role: .destructive, action: submit) {
                        Label(toHold.count > 1 ? "Stop \(toHold.count) repos" : "Stop the line", systemImage: "hand.raised.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                    .tint(GitHubColor.failed)
                    .disabled(LineStop.validReason(reason) == nil || toHold.isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .onReceive(NotificationCenter.default.publisher(for: Self.demoSubmit)) { _ in submit() }
    }

    private func submit() {
        guard let why = LineStop.validReason(reason), !toHold.isEmpty else { return }
        client.stopLine(repos: toHold, reason: why)
        state.stopLineReason = ""
        target = nil
        state.showsStopTheLine = false
    }
}

/// The andon strip under the top bar on every screen while any merge hold is on.
struct LineStoppedBanner: View {
    @Environment(AppState.self) private var state
    @Environment(FactoryClient.self) private var client
    /// A headless script's `stopline:liftask`: opens the Lift confirmation.
    static let demoLift = Notification.Name("LineStoppedBanner.demoLift")
    /// "Lift" asks first (MF-412).
    @State private var confirmsLift = false

    var body: some View {
        let holds = client.mergeHolds
        if !holds.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .semibold))
                (Text("Line stopped: ").bold() + Text(LineStop.bannerTitle(holds)) + Text(holds.count == 1 ? ": \(LineStop.detail(holds[0]))" : ""))
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if holds.count == 1 {
                    bannerButton("Lift") { confirmsLift = true }
                        .help("Let merges into \(holds[0].repo) go again; the tasks waiting merge on their own")
                        .liftConfirmation(isPresented: $confirmsLift, hold: holds[0]) { client.releaseMerges(repo: holds[0].repo) }
                } else {
                    bannerButton("Show") { state.showsStopTheLine = true }
                        .help("See every hold and lift them")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(GitHubColor.failed)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Line stopped")
            .transition(.move(edge: .top).combined(with: .opacity))
            .onReceive(NotificationCenter.default.publisher(for: Self.demoLift)) { _ in
                if client.mergeHolds.count == 1 { confirmsLift = true }
            }
        }
    }

    private func bannerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.5)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(title))
            .accessibilityAction { action() }
    }
}

extension View {
    /// "Lift the hold on acme/api?" before a Lift sends repos.releaseMerges: the banner's, the popover's and Settings'.
    func liftConfirmation(isPresented: Binding<Bool>, hold: Wire.MergeHold, lift: @escaping () -> Void) -> some View {
        alert(LineStop.liftTitle(repos: [hold.repo]), isPresented: isPresented) {
            Button(LineStop.liftButton(count: 1), role: .destructive, action: lift)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LineStop.liftMessage(holds: [hold]))
        }
    }
}
