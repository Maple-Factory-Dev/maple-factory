import MapleKit
import SwiftUI
import UIKit

/// The check whose log the log sheet shows.
struct CheckLogRequest: Identifiable, Hashable {
    let task: String
    let check: String
    var id: String { FactoryStore.checkLogKey(task: task, check: check) }
}

/// One CI check's log, read from GitHub when it opens: monospaced, scrolled to the first error, with
/// Copy, Re-run, Open on GitHub and Reload. The Mac's CheckLogSheet, for the phone.
struct CheckLogSheet: View {
    @Environment(FactoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let request: CheckLogRequest
    @State private var detent: PresentationDetent = .large

    private var pr: Wire.PullRequest? { store.feed.task(request.task)?.pr }
    private var check: Wire.CICheck? { pr?.checks.first { $0.name == request.check } }
    private var load: FactoryStore.CheckLogLoad { store.checkLog(task: request.task, check: request.check) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(request.check)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) { bottomBar }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            CheckLogSheet.icon(check?.status ?? .queued)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.check).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("check-log-subtitle")
            }
            Spacer()
        }
    }

    private var subtitle: String {
        let duration = check?.duration.flatMap { $0.isEmpty ? nil : $0 }
        let status = switch check?.status {
        case .failed: "Failed" + (duration.map { " after \($0)" } ?? "")
        case .passed: "Passed" + (duration.map { " in \($0)" } ?? "")
        case .running: "Running"
        default: "Queued"
        }
        return "#\(pr?.number ?? 0) · \(status)"
    }

    @ViewBuilder private var content: some View {
        switch load {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading the log from GitHub…").font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("No log here", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(message)
            }
        case .loaded(let text, let truncated, let failedStep, _):
            CheckLogText(text: text, truncated: truncated, failedStep: failedStep)
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if case .loaded(let text, _, _, _) = load {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = text
                store.notice = .toast("Copied \(request.check)'s log", taskId: request.task)
            }
            .accessibilityIdentifier("check-log-copy")
        }
        Spacer()
        if let pr, let check {
            Button("Re-run", systemImage: "arrow.clockwise") {
                store.rerunCheck(request.task, check: request.check)
                dismiss()
            }
            .disabled(!FactoryStore.canRerun(check, pr: pr))
            .accessibilityIdentifier("check-log-rerun")
            Spacer()
            if let url = FactoryStore.githubURL(check, pr: pr) {
                Button("Open on GitHub", systemImage: "arrow.up.right.square") { openURL(url) }
                Spacer()
            }
        }
        Button("Reload", systemImage: "arrow.triangle.2.circlepath") { store.loadCheckLog(task: request.task, check: request.check) }
            .disabled(load == .loading)
            .accessibilityIdentifier("check-log-reload")
    }

    @ViewBuilder static func icon(_ status: Wire.CheckStatus) -> some View {
        switch status {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.approve)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
        case .running: Image(systemName: "circle.dotted.circle").foregroundStyle(Theme.warning)
        default: Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }
}

/// The log's lines, GitHub Actions' markers drawn as it draws them: `##[group]` a step's heading,
/// `##[error]` and `##[warning]` tinted. It opens a few lines above the first error.
private struct CheckLogText: View {
    let text: String
    let truncated: Bool
    let failedStep: String?

    struct Line: Identifiable {
        enum Kind { case plain, step, error, warning }
        let id: Int
        let text: String
        let kind: Kind
    }

    static func lines(_ text: String) -> [Line] {
        var out: [Line] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
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
        let lines = Self.lines(text)
        let firstError = lines.first { $0.kind == .error }?.id
        let digits = String(lines.count).count
        VStack(spacing: 0) {
            if let failedStep {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                    Text(failedStep).font(.footnote.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.danger.opacity(0.1))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("check-log-failed-step")
            }
            if truncated {
                Text("Showing the end of the log")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground))
            }
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in row(line, digits: digits).id(line.id) }
                    }
                    .padding(.vertical, 8)
                    .textSelection(.enabled)
                }
                .accessibilityIdentifier("check-log")
                .onAppear {
                    guard let firstError else { return }
                    // A few lines of context above the error.
                    DispatchQueue.main.async { proxy.scrollTo(max(0, firstError - 6), anchor: .top) }
                }
            }
        }
    }

    private func row(_ line: Line, digits: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(line.id + 1))
                .foregroundStyle(.tertiary)
                .frame(width: CGFloat(digits) * 7.5, alignment: .trailing)
            Group {
                switch line.kind {
                case .step: Text("▸ ").foregroundStyle(.secondary) + Text(line.text).fontWeight(.semibold)
                case .error: Text("Error: ").fontWeight(.semibold) + Text(line.text)
                case .warning: Text("Warning: ").fontWeight(.semibold) + Text(line.text)
                case .plain: Text(line.text.isEmpty ? " " : line.text)
                }
            }
            .foregroundStyle(line.kind == .error ? Theme.danger : line.kind == .warning ? Theme.warning : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .error ? Theme.danger.opacity(0.12) : line.kind == .warning ? Theme.warning.opacity(0.1) : .clear)
    }
}
