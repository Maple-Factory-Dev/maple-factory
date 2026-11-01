import SwiftUI

/// The task's GitHub pull request: a link out, and the CI checks that gate merging.
struct PullRequestCard: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    let pr: PullRequest

    private var failed: [CICheck] { pr.checks.filter { $0.status == .failed } }
    private var passed: Int { pr.checks.filter { $0.status == .passed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionLabel(title: "Pull request")
                PRStateChip(state: pr.state)
                Spacer()
                if pr.isLocal {
                    Text("#\(pr.number)").monospacedDigit()
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .help("A local repo: the branch is on its origin, with no pull request page")
                } else {
                    Link(destination: pr.url) {
                        HStack(spacing: 4) {
                            Text("#\(pr.number)").monospacedDigit()
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                    }
                    .help(pr.url.absoluteString)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5))
                Text(pr.branch ?? task.mockBranch).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").font(.system(size: 8.5, weight: .semibold))
                Text(pr.base ?? "main")
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Theme.textMuted)

            if pr.checks.isEmpty {
                Text(pr.isLocal ? "No CI: a local repo's change is checked by its proofs and review." : task.state.isFinished ? "No checks ran on this pull request." : "No checks reported yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if !pr.isLocal, !task.state.isFinished {
                    smallButton("Recheck", icon: "arrow.triangle.2.circlepath") { state.recheckGitHub(task.id) }
                        .help("Read the pull request and its checks from GitHub again")
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(pr.checks.enumerated()), id: \.element.id) { index, check in
                        checkRow(check)
                        if index < pr.checks.count - 1 { Hairline().padding(.leading, 26) }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.fillSubtle)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                )

                HStack(spacing: 8) {
                    Text("\(passed) of \(pr.checks.count) checks passed")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(failed.isEmpty ? Theme.textMuted : Theme.State.cancelled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if !failed.isEmpty, pr.state != .merged {
                        smallButton("Re-run failed", icon: "arrow.clockwise") { state.rerunFailedChecks(task.id) }
                    }
                    if pr.state != .merged, !pr.isLocal {
                        smallButton("Recheck", icon: "arrow.triangle.2.circlepath") { state.recheckGitHub(task.id) }
                            .help("Read the pull request and its checks from GitHub again")
                    }
                    Link(destination: pr.url.appending(path: "checks")) {
                        Text("All checks")
                            .font(.system(size: 11.5))
                            .fixedSize()
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }

    private func checkRow(_ check: CICheck) -> some View {
        HStack(spacing: 8) {
            Self.checkIcon(check.status).frame(width: 14)
            Text(check.name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
            if check.required {
                Text("Required")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background(Capsule().fill(Theme.fill))
            }
            Spacer()
            Text(statusText(check))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(check.status == .failed ? Theme.State.cancelled : Theme.textFaint)
            Menu {
                checkActions(check)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Log, re-run or open \(check.name) on GitHub")
        }
        .contentShape(Rectangle())
        .contextMenu { checkActions(check) }
        .onTapGesture(count: 2) { if !pr.isLocal { state.showCheckLog(task.id, check: check.name) } }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    /// A check row's menu (and right-click): its log, running it again, and its run on GitHub.
    @ViewBuilder private func checkActions(_ check: CICheck) -> some View {
        Button("View Log…", systemImage: "text.alignleft") { state.showCheckLog(task.id, check: check.name) }
            .disabled(pr.isLocal || check.status == .queued)
        Button("Re-run", systemImage: "arrow.clockwise") { state.rerunCheck(task.id, check: check.name) }
            .disabled(!Self.canRerun(check, pr: pr))
        Divider()
        Link(destination: Self.githubURL(check, pr: pr)) { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
    }

    /// A finished check, on a pull request that's still open.
    static func canRerun(_ check: CICheck, pr: PullRequest) -> Bool {
        (check.status == .failed || check.status == .passed) && (pr.state == .open || pr.state == .draft) && !pr.isLocal
    }

    /// The check's own run, or the pull request's Checks tab when the server didn't say.
    static func githubURL(_ check: CICheck, pr: PullRequest) -> URL {
        check.url ?? pr.url.appending(path: "checks")
    }

    @ViewBuilder static func checkIcon(_ status: CICheck.Status) -> some View {
        switch status {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.State.merged)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.State.cancelled)
        case .running: ProgressView().controlSize(.mini)
        case .queued: Image(systemName: "circle.dotted").foregroundStyle(Theme.textFaint)
        }
    }

    private func statusText(_ check: CICheck) -> String {
        switch check.status {
        case .passed: check.duration
        case .failed: "Failed · \(check.duration)"
        case .running: "Running…"
        case .queued: "Queued"
        }
    }

    private func smallButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            Text(title)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Theme.text)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.cardBG)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// Bottom-centre confirmation for actions that change task state.
struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: toast.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(toast.color)
            Text(toast.text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(
            Capsule()
                .fill(Theme.cardBG)
                .overlay(Capsule().strokeBorder(Theme.stroke))
                .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        )
    }
}

/// Draft, open, merged or closed, as a small colored chip.
struct PRStateChip: View {
    let state: PullRequest.State

    var body: some View {
        let (label, icon, color): (String, String, Color) = switch state {
        case .draft: ("Draft", "circle.dashed", Theme.textMuted)
        case .open: ("Open", "arrow.triangle.pull", Theme.State.merged)
        case .merged: ("Merged", "arrow.triangle.merge", Theme.State.planning)
        case .closed: ("Closed", "xmark.circle", Theme.State.cancelled)
        }
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            Text(label)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}
