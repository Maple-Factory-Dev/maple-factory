import AppKit
import SwiftUI

/// GitHub's own Octicons (MIT, bundled as SVG): the GitHub mark and the pull request state icons.
enum GitHubMark: CaseIterable {
    case logo, open, draft, merged, closed

    init(_ state: PullRequest.State) {
        switch state {
        case .open: self = .open
        case .draft: self = .draft
        case .merged: self = .merged
        case .closed: self = .closed
        }
    }

    /// The SVG's name in the bundle's resources.
    var resource: String {
        switch self {
        case .logo: "github"
        case .open: "pr-open"
        case .draft: "pr-draft"
        case .merged: "pr-merged"
        case .closed: "pr-closed"
        }
    }

    /// The SF Symbol drawn if the SVG is somehow missing.
    var fallbackSymbol: String {
        switch self {
        case .logo: "chevron.left.forwardslash.chevron.right"
        case .open: "arrow.triangle.pull"
        case .draft: "circle.dashed"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }

    /// The bundled icon as a template image, loaded once.
    @MainActor var bundled: NSImage? {
        if let image = Self.cache[self] { return image }
        guard let url = Bundle.module.url(forResource: resource, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        Self.cache[self] = image
        return image
    }

    @MainActor private static var cache: [GitHubMark: NSImage] = [:]
}

/// An Octicon at `size` points, drawn crisply from its SVG and tinted by the foreground style.
struct GitHubIcon: View {
    let mark: GitHubMark
    var size: CGFloat = 14

    var body: some View {
        if let image = mark.bundled {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: mark.fallbackSymbol)
                .font(.system(size: size * 0.8, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

/// GitHub's own state colours (Primer): open green, draft grey, merged purple, closed red.
enum GitHubColor {
    static func state(_ state: PullRequest.State) -> Color {
        switch state {
        case .open: Color(light: 0x1F883D, dark: 0x238636)
        case .draft: Color(light: 0x59636E, dark: 0x656C76)
        case .merged: Color(light: 0x8250DF, dark: 0x8957E5)
        case .closed: Color(light: 0xCF222E, dark: 0xDA3633)
        }
    }

    static let passed = Color(light: 0x1F883D, dark: 0x3FB950)
    static let failed = Color(light: 0xCF222E, dark: 0xF85149)
    static let running = Color(light: 0xBF8700, dark: 0xD29922)
    static let queued = Color(light: 0x8C959F, dark: 0x6E7681)
}

/// What a pull request's checks add up to: the counts, the headline and the bar's parts.
struct CheckSummary: Equatable {
    var passed = 0
    var failed = 0
    var running = 0
    var queued = 0

    init(_ checks: [CICheck]) {
        for check in checks {
            switch check.status {
            case .passed: passed += 1
            case .failed: failed += 1
            case .running: running += 1
            case .queued: queued += 1
            }
        }
    }

    var total: Int { passed + failed + running + queued }

    enum Tone { case passed, failed, running, none }

    var tone: Tone {
        if total == 0 { .none } else if failed > 0 { .failed } else if running + queued > 0 { .running } else { .passed }
    }

    /// "All checks passed", "2 failing", "3 running", "1 queued" or "No checks".
    var headline: String {
        switch tone {
        case .none: "No checks"
        case .passed: total == 1 ? "Check passed" : "All checks passed"
        case .failed: "\(failed) failing"
        case .running: running > 0 ? "\(running) running" : "\(queued) queued"
        }
    }

    /// "4 of 5 passed".
    var detail: String { "\(passed) of \(total) passed" }

    /// The bar's segments in order, with their share of it.
    var segments: [(status: CICheck.Status, count: Int)] {
        [(.passed, passed), (.failed, failed), (.running, running), (.queued, queued)].filter { $0.1 > 0 }
    }
}

/// The task's GitHub pull request: a link out, and the CI checks that gate merging.
struct PullRequestCard: View {
    @Environment(AppState.self) private var state
    let task: FactoryTask
    let pr: PullRequest

    private var summary: CheckSummary { CheckSummary(pr.checks) }
    private var failed: [CICheck] { pr.checks.filter { $0.status == .failed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            branches
            Hairline()
            checksSection
            if let apple = task.appleChecks { AppleChecksRow(apple: apple) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                GitHubIcon(mark: .logo, size: 16)
                    .foregroundStyle(Theme.text)
                Text(pr.isLocal ? "Branch" : "Pull request")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 6)
                if pr.isLocal {
                    Label("Local branch", systemImage: "externaldrive")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .help("A local repo: the branch is on its origin, with no pull request page")
                } else {
                    OpenOnGitHubButton(url: pr.url)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(pr.number)")
                    .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                Text(task.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(task.title)
            }

            PRStateChip(state: pr.state, style: .large)
        }
    }

    // MARK: Branches

    private var branches: some View {
        HStack(spacing: 6) {
            BranchPill(name: pr.branch ?? task.mockBranch, role: "Head")
                .layoutPriority(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textFaint)
            BranchPill(name: pr.base ?? "main", role: "Base")
            Spacer(minLength: 0)
        }
        .help("\(pr.branch ?? task.mockBranch) into \(pr.base ?? "main")")
    }

    // MARK: Checks

    @ViewBuilder private var checksSection: some View {
        if pr.checks.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: pr.isLocal ? "checkmark.seal" : "circle.dashed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
                Text(pr.isLocal ? "No CI: a local repo's change is checked by its proofs and review." : task.state.isFinished ? "No checks ran on this pull request." : "No checks reported yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if !pr.isLocal, !task.state.isFinished {
                smallButton("Recheck", icon: "arrow.triangle.2.circlepath") { state.recheckGitHub(task.id) }
                    .help("Read the pull request and its checks from GitHub again")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Self.summaryIcon(summary.tone)
                    Text(summary.headline)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .fixedSize()
                    if summary.tone != .passed {
                        Text(summary.detail)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Link(destination: pr.url.appending(path: "checks")) {
                        HStack(spacing: 3) {
                            Text("All checks")
                            Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold))
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .fixedSize()
                        .foregroundStyle(Theme.textMuted)
                    }
                    .help("The pull request's Checks tab on GitHub")
                }
                CheckProgressBar(summary: summary)
            }

            VStack(spacing: 0) {
                ForEach(Array(pr.checks.enumerated()), id: \.element.id) { index, check in
                    CheckRow(check: check, statusText: statusText(check), onOpenLog: {
                        if !pr.isLocal { state.showCheckLog(task.id, check: check.name) }
                    }) {
                        checkActions(check)
                    }
                    if index < pr.checks.count - 1 { Hairline().padding(.leading, 38) }
                }
            }
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.fillSubtle)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke))
            )

            if pr.state != .merged, !failed.isEmpty || !pr.isLocal {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if !failed.isEmpty {
                        smallButton("Re-run failed", icon: "arrow.clockwise") { state.rerunFailedChecks(task.id) }
                    }
                    if !pr.isLocal {
                        smallButton("Recheck", icon: "arrow.triangle.2.circlepath") { state.recheckGitHub(task.id) }
                            .help("Read the pull request and its checks from GitHub again")
                    }
                }
            }
        }
    }

    @ViewBuilder static func summaryIcon(_ tone: CheckSummary.Tone) -> some View {
        switch tone {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(GitHubColor.passed)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(GitHubColor.failed)
        case .running: Image(systemName: "circle.dotted.circle").foregroundStyle(GitHubColor.running)
        case .none: Image(systemName: "circle.dashed").foregroundStyle(Theme.textFaint)
        }
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

    static func checkColor(_ status: CICheck.Status) -> Color {
        switch status {
        case .passed: GitHubColor.passed
        case .failed: GitHubColor.failed
        case .running: GitHubColor.running
        case .queued: GitHubColor.queued
        }
    }

    @ViewBuilder static func checkIcon(_ status: CICheck.Status) -> some View {
        switch status {
        case .passed: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(GitHubColor.passed)
        case .failed: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(GitHubColor.failed)
        case .running: ProgressView().controlSize(.mini).scaleEffect(0.75)
        case .queued: Image(systemName: "clock").font(.system(size: 9, weight: .semibold)).foregroundStyle(GitHubColor.queued)
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
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.cardBG)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// "Open on GitHub": the mark, the words and an arrow, as a bordered button.
private struct OpenOnGitHubButton: View {
    let url: URL
    @State private var hovering = false

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 5) {
                GitHubIcon(mark: .logo, size: 12)
                Text("Open on GitHub")
                Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Theme.fillSelected : Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.absoluteString)
    }
}

/// A branch name in a rounded mono pill; a click copies it.
private struct BranchPill: View {
    @Environment(AppState.self) private var state
    let name: String
    let role: String
    @State private var hovering = false

    var body: some View {
        Text(name)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(light: 0x0969DA, dark: 0x4493F8))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(light: 0x0969DA, dark: 0x4493F8).opacity(hovering ? 0.16 : 0.1))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(name, forType: .string)
                state.showToast("Copied \(name)", icon: "doc.on.doc", color: Theme.approve)
            }
            .help("\(role) branch \(name): click to copy")
    }
}

/// A thin bar split into passed, failed, running and queued parts, in proportion.
struct CheckProgressBar: View {
    let summary: CheckSummary

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let parts = summary.segments
            let usable = max(0, geo.size.width - gap * CGFloat(max(parts.count - 1, 0)))
            HStack(spacing: gap) {
                ForEach(parts, id: \.status) { part in
                    Capsule()
                        .fill(PullRequestCard.checkColor(part.status))
                        .frame(width: usable * CGFloat(part.count) / CGFloat(max(summary.total, 1)))
                }
            }
        }
        .frame(height: 5)
        .background(Capsule().fill(Theme.fill))
        .accessibilityLabel(summary.detail)
    }
}

/// One check: a tinted status circle, its name, how it went and its menu; highlighted on hover.
/// The checks a Linux box couldn't run (they need macos, xcode…), handed to a Mac for the PR's head:
/// who runs them or why they wait, then each command with its time and output.
private struct AppleChecksRow: View {
    let apple: Wire.AppleChecks
    @State private var open = false

    private var status: CICheck.Status {
        switch apple.state {
        case .waiting: .queued
        case .running: .running
        case .passed: .passed
        case .failed: .failed
        default: .queued
        }
    }

    private var head: String { String(apple.head.prefix(7)) }

    private var text: String {
        switch apple.state {
        case .waiting: apple.reason ?? "Waiting for a machine with \(apple.needs.joined(separator: ", "))"
        case .running: "Waiting for \(apple.machine ?? "a Mac")"
        case .passed: "Passed on \(apple.machine ?? "a Mac") · \(head)"
        default: "Failed on \(apple.machine ?? "a Mac") · \(head)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(PullRequestCard.checkColor(status).opacity(0.14))
                    PullRequestCard.checkIcon(status)
                }
                .frame(width: 18, height: 18)
                Text("Apple checks")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(apple.needs.joined(separator: ", "))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                Spacer(minLength: 4)
                Text(text)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(status == .failed ? GitHubColor.failed : Theme.textFaint)
                    .lineLimit(2)
                    .help(apple.reason ?? text)
                Button(open ? "Hide log" : "Log") { open.toggle() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
            }
            if open {
                Text("Head \(head)\(apple.message.map { " · \($0)" } ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                ForEach(Array(apple.checks.enumerated()), id: \.offset) { _, run in
                    let ok = run.code == 0 && !run.timedOut
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: ok ? "checkmark" : "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(ok ? GitHubColor.passed : GitHubColor.failed)
                            Text(run.command).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(run.timedOut ? "timed out" : "\(run.code.map { "exit \($0)" } ?? "killed") · \(String(format: "%.1fs", Double(run.ms) / 1000))")
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(Theme.textFaint)
                        }
                        if !run.output.isEmpty {
                            ScrollView {
                                Text(run.output)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 180)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fillSubtle))
                        }
                    }
                }
                if apple.checks.isEmpty {
                    ForEach(apple.commands, id: \.self) { command in
                        Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.fillSubtle)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke))
        )
    }
}

private struct CheckRow<Actions: View>: View {
    let check: CICheck
    let statusText: String
    let onOpenLog: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(PullRequestCard.checkColor(check.status).opacity(0.14))
                PullRequestCard.checkIcon(check.status)
            }
            .frame(width: 18, height: 18)
            Text(check.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if check.required {
                Text("Required")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .overlay(Capsule().strokeBorder(Theme.stroke))
            }
            Spacer(minLength: 4)
            Text(statusText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(check.status == .failed ? GitHubColor.failed : Theme.textFaint)
                .lineLimit(1)
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.textMuted : Theme.textFaint)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Log, re-run or open \(check.name) on GitHub")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.fill : .clear).padding(.horizontal, 3))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { actions() }
        .onTapGesture(count: 2, perform: onOpenLog)
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

/// Draft, open, merged or closed, with GitHub's Octicon and colour: a small tinted chip, or GitHub's filled label.
struct PRStateChip: View {
    enum Style { case compact, large }

    let state: PullRequest.State
    var style: Style = .compact

    static func label(_ state: PullRequest.State) -> String {
        switch state {
        case .draft: "Draft"
        case .open: "Open"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    var body: some View {
        let color = GitHubColor.state(state)
        switch style {
        case .compact:
            HStack(spacing: 4) {
                GitHubIcon(mark: GitHubMark(state), size: 10)
                Text(Self.label(state))
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(color.opacity(0.13)))
            .fixedSize()
        case .large:
            HStack(spacing: 5) {
                GitHubIcon(mark: GitHubMark(state), size: 13)
                Text(Self.label(state))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.leading, 9)
            .padding(.trailing, 11)
            .frame(height: 26)
            .background(Capsule().fill(color))
            .fixedSize()
        }
    }
}
