import AppKit
import SwiftUI

/// One CI check's log, read from GitHub when it opens: monospaced, scrolled to the first error, with
/// Copy, Re-run and Open on GitHub. The log is never kept; opening it again reads it again.
struct CheckLogSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let request: CheckLogRequest

    private var task: FactoryTask { state.task(request.taskID) }
    private var pr: PullRequest? { task.pr }
    private var check: CICheck? { pr?.checks.first { $0.name == request.check } }
    private var load: CheckLogLoad { state.checkLog(request) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer.padding(12)
        }
        .frame(width: 780, height: 540)
        .background(Theme.cardBG)
    }

    private var header: some View {
        HStack(spacing: 10) {
            PullRequestCard.checkIcon(check?.status ?? .queued).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.check).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        let status = switch check?.status {
        case .failed: "Failed" + (check?.duration.isEmpty == false ? " after \(check!.duration)" : "")
        case .passed: "Passed" + (check?.duration.isEmpty == false ? " in \(check!.duration)" : "")
        case .running: "Running"
        case .queued, nil: "Queued"
        }
        return "\(task.id) · #\(pr?.number ?? 0) · \(status)"
    }

    @ViewBuilder private var content: some View {
        switch load {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the log from GitHub…").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("No log here", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(message)
            } actions: {
                if let pr, let check { Link("Open on GitHub", destination: PullRequestCard.githubURL(check, pr: pr)) }
            }
        case .loaded(let log):
            LogView(log: log)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if case .loaded(let log) = load {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text, forType: .string)
                    state.showToast("Copied \(request.check)'s log", icon: "doc.on.doc")
                }
            }
            if let pr, let check {
                Button("Re-run", systemImage: "arrow.clockwise") {
                    state.rerunCheck(task.id, check: request.check)
                    dismiss()
                }
                .disabled(!PullRequestCard.canRerun(check, pr: pr))
                Link(destination: PullRequestCard.githubURL(check, pr: pr)) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
            }
            Spacer()
            Button("Reload") { state.loadCheckLog(request) }
                .disabled(load == .loading)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .controlSize(.regular)
    }
}

/// The log's lines, GitHub Actions' markers drawn as it draws them: `##[group]` a step's heading,
/// `##[error]` and `##[warning]` highlighted. It opens at the first error.
private struct LogView: View {
    let log: CheckLog

    private struct Line: Identifiable {
        enum Kind { case plain, step, error, warning }
        let id: Int
        let text: String
        let kind: Kind
    }

    private var lines: [Line] {
        var out: [Line] = []
        for raw in log.text.split(separator: "\n", omittingEmptySubsequences: false) {
            // ANSI colours GitHub keeps in the raw log.
            let text = String(raw).replacing(/\u{1B}\[[0-9;]*m/, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if text.hasPrefix("##[endgroup]") { continue }
            let (kind, body): (Line.Kind, String) =
                if text.hasPrefix("##[group]") { (.step, String(text.dropFirst(9))) }
                else if let r = text.range(of: "##[error]") { (.error, String(text[..<r.lowerBound]) + String(text[r.upperBound...])) }
                else if let r = text.range(of: "##[warning]") { (.warning, String(text[..<r.lowerBound]) + String(text[r.upperBound...])) }
                else { (.plain, text) }
            out.append(Line(id: out.count, text: body, kind: kind))
        }
        while out.last?.text.isEmpty == true { out.removeLast() }
        return out
    }

    var body: some View {
        let lines = lines
        let firstError = lines.first { $0.kind == .error }?.id
        VStack(spacing: 0) {
            if log.truncated || log.failedStep != nil {
                HStack(spacing: 8) {
                    if let step = log.failedStep {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.State.cancelled)
                        Text(step).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                    if log.truncated {
                        Text("Showing the end of the log").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(log.failedStep != nil ? Theme.State.cancelled.opacity(0.08) : Theme.fillSubtle)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in row(line, width: String(lines.count).count).id(line.id) }
                    }
                    .padding(.vertical, 8)
                    .textSelection(.enabled)
                }
                .background(Theme.editorBG)
                .onAppear {
                    guard let firstError else { return }
                    // A few lines of context above the error.
                    DispatchQueue.main.async { proxy.scrollTo(max(0, firstError - 6), anchor: .top) }
                }
            }
        }
    }

    private func row(_ line: Line, width: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(line.id + 1))
                .foregroundStyle(Theme.textFaint)
                .frame(width: CGFloat(width) * 7.5, alignment: .trailing)
            Group {
                switch line.kind {
                case .step: Text("▸ ").foregroundStyle(Theme.textFaint) + Text(line.text).fontWeight(.semibold).foregroundStyle(Theme.text)
                case .error: Text("Error: ").fontWeight(.semibold) + Text(line.text)
                case .warning: Text("Warning: ").fontWeight(.semibold) + Text(line.text)
                case .plain: Text(line.text.isEmpty ? " " : line.text)
                }
            }
            .foregroundStyle(line.kind == .error ? Theme.State.cancelled : line.kind == .warning ? Theme.warning : Theme.Syntax.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .error ? Theme.State.cancelled.opacity(0.1) : .clear)
    }
}

extension CheckLog {
    /// The mockup's log for a check: a GitHub Actions job, failing at the end when the check failed.
    static func sample(_ check: String, failed: Bool) -> CheckLog {
        var lines = [
            "##[group]Run actions/checkout@v4",
            "Syncing repository: acme/atlas",
            "Determining the checkout info",
            "##[endgroup]",
            "##[group]Run actions/setup-node@v4",
            "Found in cache @ /opt/hostedtoolcache/node/22.11.0/x64",
            "##[endgroup]",
            "##[group]Run npm ci",
            "added 1214 packages, and audited 1215 packages in 21s",
            "found 0 vulnerabilities",
            "##[endgroup]",
            "##[group]Run npm run \(check)",
            "> atlas@2.14.0 \(check)",
        ]
        lines += (1...14).map { "  ✓ auth/session.spec.ts › keeps the session \($0 == 1 ? "alive" : "warm after \($0 * 5)m") (\(80 + $0 * 13)ms)" }
        if failed {
            lines += [
                "  ✗ auth/sign-out.spec.ts › signs out every other device (5012ms)",
                "",
                "    Error: Timed out 5000ms waiting for expect(locator).toBeHidden()",
                "    Locator: getByRole('button', { name: 'Account' })",
                "      at auth/sign-out.spec.ts:48:41",
                "",
                "  1 failed, 14 passed (38.2s)",
                "##[error]Process completed with exit code 1.",
                "##[endgroup]",
            ]
        } else {
            lines += ["  15 passed (36.9s)", "##[endgroup]"]
        }
        return CheckLog(text: lines.joined(separator: "\n"), truncated: false,
                        failedStep: failed ? "Process completed with exit code 1." : nil, url: nil)
    }
}
