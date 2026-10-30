import SwiftUI

/// One repo in Settings › Repositories: its worktree scripts, the repo's own commands for making,
/// setting up, tearing down and archiving a task's worktree. Admins edit them; everyone else sees them.
/// The runner runs each with `sh -c` in the repo's main checkout, with the MAPLE_* variables and the
/// repo's secrets (see runner/src/worktree_scripts.rs).
struct RepoScriptsDetail: View {
    let repo: Wire.OrgRepo
    let back: () -> Void
    @Environment(FactoryClient.self) private var client
    @State private var draft = Draft()
    @State private var saved = false

    private var isAdmin: Bool { client.me?.role == "admin" }
    private var stored: Wire.RepoWorktreeScripts? { client.scripts(for: repo.name) }
    private var current: Draft { Draft(stored?.scripts) }

    /// The fields as typed: commands as text, the timeout as digits (blank: the default).
    struct Draft: Equatable {
        var create = "", setup = "", teardown = "", archive = "", timeout = ""

        init() {}
        init(_ s: Wire.WorktreeScripts?) {
            create = s?.create ?? ""
            setup = s?.setup ?? ""
            teardown = s?.teardown ?? ""
            archive = s?.archive ?? ""
            timeout = s?.timeoutSecs.map(String.init) ?? ""
        }

        var timeoutSecs: UInt32? { UInt32(timeout.trimmingCharacters(in: .whitespaces)) }
        var timeoutProblem: String? {
            let t = timeout.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return nil }
            guard let n = UInt32(t), (1...3600).contains(n) else { return "1–3600 seconds." }
            return nil
        }
        var tooLong: String? {
            [("create", create), ("setup", setup), ("teardown", teardown), ("archive", archive)].first { $0.1.utf8.count > 4096 }.map { "The \($0.0) script is over 4 KB." }
        }
        var wire: Wire.WorktreeScripts {
            let clean = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s.trimmingCharacters(in: .whitespacesAndNewlines) }
            return .init(create: clean(create), setup: clean(setup), teardown: clean(teardown), archive: clean(archive), timeoutSecs: timeoutSecs)
        }
    }

    static let variables: [(String, String)] = [
        ("MAPLE_REPO", "owner/name"),
        ("MAPLE_REPO_ROOT", "the repo's main checkout (where the script runs)"),
        ("MAPLE_WORKTREE", "the task's worktree folder"),
        ("MAPLE_BRANCH", "the task's branch, agent/<task>"),
        ("MAPLE_BASE", "the branch it starts from (create and setup)"),
        ("MAPLE_TASK_ID", "the task, like MF-74"),
        ("MAPLE_PHASE", "create, setup, teardown or archive"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 10)
            ScrollView {
                content.padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 20)
            }
            Divider()
            footer.padding(.horizontal, 28).padding(.vertical, 12)
        }
        .font(.system(size: 13))
        .onAppear { draft = current }
        .onChange(of: repo.name) { _, _ in draft = current; saved = false }
        // Another admin's save, or the server's trimmed echo of ours.
        .onChange(of: stored) { _, _ in draft = current }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsTitle(title: "Worktree scripts",
                          subtitle: "Your own commands for a task's worktree, in place of or around what the runner does. Each runs with sh -c in the repo's main checkout, with the variables below and the repo's secrets. One that fails stops the task, with its output.")
            SettingsSection("Scripts") {
                field("Create", "Makes the worktree instead of git worktree add. It must leave a git worktree on $MAPLE_BRANCH at $MAPLE_WORKTREE.", "bin/worktree-create", $draft.create)
                field("Setup", "Runs once the worktree exists, before the agent starts: install, seed, copy config.", "bin/worktree-setup", $draft.setup)
                field("Teardown", "Runs before a finished task's worktree is removed: stop services, drop databases.", "bin/worktree-teardown", $draft.teardown)
                field("Archive", "Runs instead of the removal when a finished task is cleaned up. It owns the folder and the branch.", "bin/worktree-archive", $draft.archive)
                SettingsRow("Timeout", detail: draft.timeoutProblem, detailColor: Theme.State.cancelled) {
                    if isAdmin {
                        TextField("600", text: $draft.timeout)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                            .frame(width: 80)
                    } else {
                        readOnly(draft.timeout.isEmpty ? "600" : draft.timeout).frame(width: 80)
                    }
                    Text("seconds each").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
            }
            SettingsSection("Variables") {
                SettingsBlock {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(Self.variables, id: \.0) { name, what in
                            GridRow {
                                Text(name).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
                                Text(what).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Label("Repositories", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Text("/").foregroundStyle(Theme.textFaint)
            Text(repo.name).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
            if let branch = repo.defaultBranch {
                Text(branch).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Text(repo.source == .github ? "GitHub App" : "Added by hand").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
    }

    private var footer: some View {
        HStack {
            if !isAdmin {
                Label("Only admins can change these", systemImage: "lock").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else if let problem = draft.tooLong {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.State.cancelled)
            } else if saved && draft == current {
                Text("Saved").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else if let stored {
                let at = Date(timeIntervalSince1970: Double(stored.updatedAt) / 1000)
                (Text("Changed by @\(stored.updatedBy) ") + Text(at, format: .relative(presentation: .named)))
                    .font(.system(size: 12)).foregroundStyle(Theme.textFaint).help(at.formatted())
            }
            Spacer()
            if isAdmin {
                Button("Revert") { draft = current }.disabled(draft == current)
                Button("Save") {
                    client.save(scripts: draft.wire, for: repo.name)
                    saved = true
                }
                .keyboardShortcut("s")
                .disabled(draft == current || draft.timeoutProblem != nil || draft.tooLong != nil)
            }
        }
    }

    /// A command as members see it: selectable text, or "None".
    private func readOnly(_ value: String) -> some View {
        Text(value.isEmpty ? "None" : value)
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(value.isEmpty ? Theme.textFaint : Theme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
    }

    private func field(_ label: String, _ hint: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.text).frame(width: 70, alignment: .leading)
                if isAdmin {
                    TextField(placeholder, text: text, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                } else {
                    readOnly(text.wrappedValue)
                }
            }
            Text(hint).font(SettingsKit.caption).foregroundStyle(Theme.textMuted).padding(.leading, 78).fixedSize(horizontal: false, vertical: true)
        }
        .settingsRowPadding()
    }
}
