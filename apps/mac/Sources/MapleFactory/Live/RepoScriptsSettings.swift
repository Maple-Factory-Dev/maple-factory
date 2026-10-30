import SwiftUI

/// One repo in Settings › Repositories: its worktree scripts, the repo's own commands for making,
/// preparing the machine for (preflight), setting up, tearing down and archiving a task's worktree, and its prompt additions (after the
/// org's, before a goal's). Admins edit them; everyone else sees them. The runner runs each script
/// with `sh -c` in the repo's main checkout, with the MAPLE_* variables and the repo's secrets (see
/// runner/src/worktree_scripts.rs). Set up with AI has an agent on the admin's machine suggest them.
struct RepoScriptsDetail: View {
    let repo: Wire.OrgRepo
    let back: () -> Void
    @Environment(FactoryClient.self) private var client
    @State private var draft = Draft()
    @State private var saved = false
    /// The setup run whose suggestion fills the form (its startedAt), until it's saved or reverted.
    @State private var suggestedBy: UInt64?

    private var isAdmin: Bool { client.me?.role == "admin" }
    private var stored: Wire.RepoWorktreeScripts? { client.scripts(for: repo.name) }
    private var current: Draft { Draft(stored?.scripts, prompts: stored?.prompts) }
    private var run: Wire.RepoSetupRun? { client.setupRun(for: repo.name) }
    private var running: Bool { run?.state == .running }
    private var suggestion: Wire.RepoSetupSuggestion? {
        guard let run, run.startedAt == suggestedBy else { return nil }
        return run.suggestion
    }

    /// The fields as typed: commands as text, preflight's watched files one per line, the timeout as
    /// digits (blank: the default), and the prompts.
    struct Draft: Equatable {
        var create = "", preflight = "", watch = "", setup = "", teardown = "", archive = "", timeout = ""
        var prompts = Wire.PromptAdditions(planner: "", builder: "", reviewer: "")

        init() {}
        init(_ s: Wire.WorktreeScripts?, prompts p: Wire.PromptAdditions? = nil) {
            create = s?.create ?? ""
            preflight = s?.preflight ?? ""
            watch = s?.preflightWatch ?? ""
            setup = s?.setup ?? ""
            teardown = s?.teardown ?? ""
            archive = s?.archive ?? ""
            timeout = s?.timeoutSecs.map(String.init) ?? ""
            if let p { prompts = p }
        }

        var timeoutSecs: UInt32? { UInt32(timeout.trimmingCharacters(in: .whitespaces)) }
        var timeoutProblem: String? {
            let t = timeout.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return nil }
            guard let n = UInt32(t), (1...3600).contains(n) else { return "1–3600 seconds." }
            return nil
        }
        var tooLong: String? {
            [("create", create), ("preflight", preflight), ("setup", setup), ("teardown", teardown), ("archive", archive)].first { $0.1.utf8.count > 4096 }.map { "The \($0.0) script is over 4 KB." }
        }
        var wire: Wire.WorktreeScripts {
            let clean = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s.trimmingCharacters(in: .whitespacesAndNewlines) }
            let watched = watch.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .init(create: clean(create), preflight: clean(preflight), preflightWatch: watched.isEmpty ? nil : watched.joined(separator: "\n"), setup: clean(setup), teardown: clean(teardown), archive: clean(archive), timeoutSecs: timeoutSecs)
        }
    }

    static let variables: [(String, String)] = [
        ("MAPLE_REPO", "owner/name"),
        ("MAPLE_REPO_ROOT", "the repo's main checkout (where the script runs, except preflight)"),
        ("MAPLE_WORKTREE", "the task's worktree folder"),
        ("MAPLE_BRANCH", "the task's branch, agent/<task>"),
        ("MAPLE_BASE", "the branch it starts from (create, preflight and setup)"),
        ("MAPLE_TASK_ID", "the task, like MF-74"),
        ("MAPLE_PHASE", "create, preflight, setup, teardown or archive"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 36).padding(.top, 18).padding(.bottom, 10)
            ScrollView {
                content.padding(.horizontal, 36).padding(.top, 8).padding(.bottom, 20)
            }
            Divider()
            footer.padding(.horizontal, 36).padding(.vertical, 12)
        }
        .font(.system(size: 13))
        .onAppear { draft = current; suggest() }
        .onChange(of: repo.name) { _, _ in draft = current; saved = false; suggestedBy = nil; suggest() }
        // Another admin's save, or the server's trimmed echo of ours.
        .onChange(of: stored) { _, _ in draft = current; suggestedBy = nil }
        .onChange(of: run) { _, _ in suggest() }
    }

    /// A finished setup run that's newer than what's saved fills the form, for the admin to review.
    private func suggest() {
        guard isAdmin, let run, run.state == .done, let s = run.suggestion, run.startedAt != suggestedBy,
              run.startedAt > stored?.updatedAt ?? 0 else { return }
        draft = Draft(s.scripts, prompts: s.prompts)
        suggestedBy = run.startedAt
        saved = false
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsTitle(title: "Worktree scripts",
                          subtitle: "Your own commands for a task's worktree, in place of or around what the runner does. Each runs with sh -c in the repo's main checkout (preflight in the new worktree), with the variables below and the repo's secrets. One that fails stops the task, with its output.",
                          accessory: isAdmin ? AnyView(setupButton) : nil)
            if let run, run.state != .done || suggestion != nil {
                setupStatus(run)
            }
            SettingsSection("Scripts") {
                field("Create", "Makes the worktree instead of git worktree add. It must leave a git worktree on $MAPLE_BRANCH at $MAPLE_WORKTREE.", "bin/worktree-create", $draft.create)
                field("Preflight", "Sets the machine up for this repo: runtimes, brew bundle, services. Runs in the new worktree before setup, the first time this machine's checkout is used and again when the command or a watched file changes.", "mise install && brew bundle", $draft.preflight)
                field("Watch", "Re-run preflight when these change: paths from the repo's root, one per line (at most 20). Blank watches the usual pins.", ".ruby-version\n.tool-versions\n.node-version\n.nvmrc\n.python-version\nBrewfile\nmise.toml", $draft.watch, lines: 2...7)
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
            SettingsSection("Prompts", caption: "Added to every task in this repo, after the org's instructions and before the goal's.\(suggestion != nil ? " Suggested by Set up with AI: review them, then Save." : "") Agents can also set a repo up through the maple MCP: get_repo_setup and save_repo_setup, from an admin's own Claude Code or Codex session on one of their machines.") {
                SettingsBlock {
                    PromptFields(prompts: $draft.prompts, editable: isAdmin, height: 90)
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

    /// Set up with AI: an agent on your machine reads the repo and suggests its scripts and prompts.
    private var setupButton: some View {
        Button {
            if running { client.cancelSetup(for: repo.name) } else { client.startSetup(for: repo.name) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: running ? "stop.fill" : "sparkles").font(.system(size: 10.5, weight: .semibold))
                Text(running ? "Stop" : "Set up with AI")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Theme.State.planning))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("An agent on one of your machines reads \(repo.name) and suggests its worktree scripts and prompts. It can't change anything, and nothing is saved until you Save.")
    }

    /// How the latest setup run is going, its error, or the notes that came with its suggestion.
    private func setupStatus(_ run: Wire.RepoSetupRun) -> some View {
        SettingsSection("Set up with AI") {
            SettingsBlock(spacing: 6) {
                switch run.state {
                case .running:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(run.progress ?? "Reading the repo…").font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                    }
                case .failed:
                    Label(run.error ?? "It couldn't.", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.State.cancelled)
                default:
                    Label("Suggested by an agent on @\(run.by)'s machine. Review the scripts and prompts below, then Save or Revert.", systemImage: "sparkles")
                        .font(.system(size: 12)).foregroundStyle(Theme.text)
                    ForEach(Array((run.suggestion?.notes ?? []).enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(Theme.textFaint)
                            Text(note).font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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
            } else if suggestion != nil && draft != current {
                Label("Suggested, not saved yet", systemImage: "sparkles").font(.system(size: 12)).foregroundStyle(Theme.State.planning)
            } else if saved && draft == current {
                Text("Saved").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else if let stored {
                let at = Date(timeIntervalSince1970: Double(stored.updatedAt) / 1000)
                (Text("Changed by @\(stored.updatedBy) ") + Text(at, format: .relative(presentation: .named)))
                    .font(.system(size: 12)).foregroundStyle(Theme.textFaint).help(at.formatted())
            }
            Spacer()
            if isAdmin {
                Button("Revert") { draft = current; suggestedBy = nil }.disabled(draft == current)
                Button("Save") {
                    client.save(scripts: draft.wire, prompts: draft.prompts, for: repo.name)
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

    private func field(_ label: String, _ hint: String, _ placeholder: String, _ text: Binding<String>, lines: ClosedRange<Int> = 1...4) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.text).frame(width: 70, alignment: .leading)
                if isAdmin {
                    TextField(placeholder, text: text, axis: .vertical)
                        .lineLimit(lines)
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
