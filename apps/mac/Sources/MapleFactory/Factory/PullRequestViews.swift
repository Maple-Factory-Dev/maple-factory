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
                prStateChip
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
                Text(pr.branch ?? branch).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").font(.system(size: 8.5, weight: .semibold))
                Text(pr.base ?? "main")
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Theme.textMuted)

            if pr.checks.isEmpty {
                Text(pr.isLocal ? "No CI: a local repo's change is checked by its proofs and review." : "No checks reported yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Spacer()
                    if !failed.isEmpty, pr.state != .merged {
                        smallButton("Re-run failed", icon: "arrow.clockwise") { state.rerunFailedChecks(task.id) }
                    }
                    Link(destination: pr.url.appending(path: "checks")) {
                        Text("All checks")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }

    private var branch: String {
        let slug = task.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: "-")
        return "\(task.id.lowercased())-\(slug)"
    }

    private var prStateChip: some View {
        let (label, icon, color): (String, String, Color) = switch pr.state {
        case .draft: ("Draft", "circle.dashed", Theme.textMuted)
        case .open: ("Open", "arrow.triangle.pull", Theme.State.merged)
        case .merged: ("Merged", "arrow.triangle.merge", Theme.State.planning)
        }
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            Text(label)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(color.opacity(0.13)))
    }

    private func checkRow(_ check: CICheck) -> some View {
        HStack(spacing: 8) {
            checkIcon(check.status).frame(width: 14)
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
            Link(destination: pr.url.appending(path: "checks")) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textFaint)
            }
            .help("Logs for \(check.name)")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    @ViewBuilder private func checkIcon(_ status: CICheck.Status) -> some View {
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
