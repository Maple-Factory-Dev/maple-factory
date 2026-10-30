//! Agent definitions: the built-ins, changed or extended by `~/.config/maple/agents.toml`
//! (see `agent_config`), and how each one is started.

use serde::{Deserialize, Serialize};

/// How a first prompt reaches the agent.
#[derive(Debug, Clone, PartialEq)]
pub enum PromptMode {
    /// As the last argument: `claude "fix the tests"`.
    Positional,
    /// After a flag: `aider --message "fix the tests"`.
    Flag(String),
    /// The agent doesn't take one; the box is hidden in the UI.
    None,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Agent {
    pub id: String,
    pub label: String,
    /// The program. Empty means the user's login shell.
    pub command: String,
    /// Extra arguments, after any hook arguments and before the prompt.
    pub args: Vec<String>,
    pub prompt: PromptMode,
    /// Whether the runner adds its status hooks (Claude Code and Codex only).
    pub hooks: bool,
}

impl Agent {
    pub fn takes_prompt(&self) -> bool {
        self.prompt != PromptMode::None
    }

    pub fn advertised(&self) -> Advertised {
        Advertised { id: self.id.clone(), label: self.label.clone(), takes_prompt: self.takes_prompt() }
    }
}

/// What `hello` tells the hub about each agent, for validation and the New session picker.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Advertised {
    pub id: String,
    pub label: String,
    pub takes_prompt: bool,
}

pub fn builtins() -> Vec<Agent> {
    let agent = |id: &str, label: &str, command: &str, prompt: PromptMode, hooks: bool| Agent {
        id: id.into(),
        label: label.into(),
        command: command.into(),
        args: vec![],
        prompt,
        hooks,
    };
    vec![
        agent("claude", "Claude Code", "claude", PromptMode::Positional, true),
        agent("codex", "Codex", "codex", PromptMode::Positional, true),
        agent("shell", "Shell", "", PromptMode::None, false),
    ]
}

/// Variables an agent sets for its own child processes. If the runner was
/// started from inside an agent session (say, a `claude` terminal), sessions
/// would inherit them and act as sub-sessions of that agent, and its
/// messaging token would leak into every session.
pub const INHERITED_SESSION_MARKERS: &[&str] = &[
    "AI_AGENT",
    "CLAUDECODE",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_EXECPATH",
    "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_SESSION_ATTENDED",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_EFFORT",
    "CLAUDE_PID",
];

/// The argv for an agent.
///
/// Agents run through the user's login shell, interactive (`-i`) as well, so they get the
/// same environment as a normal terminal even when the runner is started by launchd: zsh
/// reads `.zshrc` only for interactive shells, and that's where version managers (rbenv,
/// mise, atlas-env…) usually put their PATH. The pane is a tty, so `-i` is safe. The command,
/// its arguments and the prompt are separate argv entries (`exec "$0" "$@"`),
/// never interpolated into a shell string, so quotes and `$` in them are inert.
/// tmux runs a multi-argument command directly, without another shell in between.
///
/// A `model` (Settings → Factory, from `session.open`) starts Claude Code or Codex with
/// `--model <m>` after the agent's own arguments, in place of any `--model`/`-m` that
/// agents.toml gave it. Other agents ignore it: there's no telling what their flag is.
/// So do they `unattended` (see `permission_args`), whose flags come last, before the prompt.
/// A task's `images` (local files, see `images`) reach Codex as `--image=<a>,<b>` after those, in
/// the `=` form so the flag, which takes several values, can't swallow the prompt. Other agents read
/// the paths in their prompt.
/// `resume` (Reopen on an ended session) continues the agent's newest conversation in that folder:
/// `claude --continue`, `codex resume --last`, right after the command since Codex's is a subcommand.
/// Other agents ignore it and start afresh.
// The hub's session.open, field by field; a struct would only repeat it.
#[allow(clippy::too_many_arguments)]
pub fn argv(
    shell: &str,
    agent: &Agent,
    resume: bool,
    hook_args: Vec<String>,
    model: Option<&str>,
    unattended: Option<&Unattended>,
    images: &[String],
    prompt: Option<&str>,
) -> Vec<String> {
    if agent.command.is_empty() {
        return vec![shell.into(), "-l".into()];
    }
    let mut argv = vec![shell.into(), "-l".into(), "-i".into(), "-c".into(), r#"exec "$0" "$@""#.into(), agent.command.clone()];
    if resume {
        argv.extend(resume_args(&agent.id).iter().map(|a| a.to_string()));
    }
    argv.extend(hook_args);
    match model.filter(|m| !m.trim().is_empty() && takes_model(&agent.id)) {
        Some(model) => {
            argv.extend(without_model(&agent.args));
            argv.extend(["--model".into(), model.into()]);
        }
        None => argv.extend(agent.args.iter().cloned()),
    }
    if let Some(u) = unattended {
        argv.extend(permission_args(&agent.id, u));
    }
    if !images.is_empty() && agent.id == "codex" {
        argv.push(format!("--image={}", images.join(",")));
    }
    if let Some(prompt) = prompt.filter(|p| !p.trim().is_empty()) {
        match &agent.prompt {
            PromptMode::Positional => argv.push(prompt.into()),
            PromptMode::Flag(flag) => argv.extend([flag.clone(), prompt.into()]),
            PromptMode::None => {}
        }
    }
    argv
}

/// Where a long prompt waits for its session: tmux refuses a command over about 16 KB ("command too
/// long"), and a review's or a planner's prompt can be that big, so the shell reads it from this file.
pub const PROMPT_FILE_ENV: &str = "MAPLE_PROMPT_FILE";

/// Like `argv` with a prompt, but the prompt is read from the file `MAPLE_PROMPT_FILE` names (and the file
/// removed) by the shell that starts the agent, so the command tmux gets stays short.
pub fn argv_with_prompt_file(
    shell: &str,
    agent: &Agent,
    resume: bool,
    hook_args: Vec<String>,
    model: Option<&str>,
    unattended: Option<&Unattended>,
    images: &[String],
) -> Vec<String> {
    let mut argv = argv(shell, agent, resume, hook_args, model, unattended, images, None);
    let flag = match &agent.prompt {
        _ if agent.command.is_empty() => return argv,
        PromptMode::None => return argv,
        PromptMode::Positional => String::new(),
        PromptMode::Flag(flag) => format!("'{}' ", flag.replace('\'', r"'\''")),
    };
    // Command substitution strips trailing newlines. A sentinel keeps them part of the
    // prompt, then parameter expansion removes only that sentinel (without shell evaluation).
    argv[4] = format!(r#"p="$(cat -- "${PROMPT_FILE_ENV}"; printf .)"; p="${{p%.}}"; rm -f -- "${PROMPT_FILE_ENV}"; exec "$0" "$@" {flag}"$p""#);
    argv
}

/// What `session.open`'s `resume` adds: the flags that pick up an agent's last conversation in its folder.
pub fn resume_args(agent: &str) -> &'static [&'static str] {
    match agent {
        "claude" => &["--continue"],
        "codex" => &["resume", "--last"],
        _ => &[],
    }
}

/// Whether `session.open`'s model applies: Claude Code and Codex both take `--model`.
pub fn takes_model(agent: &str) -> bool {
    matches!(agent, "claude" | "codex")
}

/// How a factory session (a task, planner or setup session) treats the agent's permission prompts,
/// from Settings → Factory via `session.open`. Sessions the user opens never carry one.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Unattended {
    pub mode: UnattendedMode,
    /// The project's setup, test, lint and dev commands; "project" allows each one's program.
    #[serde(default)]
    pub commands: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UnattendedMode {
    /// Stop at every prompt: the agent's own settings, as for any session.
    Ask,
    /// Edits, the project's commands' programs and git.
    Project,
    /// No prompts at all.
    Skip,
}

/// Programs a `Bash(<program>:*)` rule would hand everything to, so "project" never allows them
/// even when a project's command starts with one.
const WRAPPERS: &[&str] = &["sudo", "doas", "sh", "bash", "zsh", "fish", "dash", "env", "eval", "exec", "command", "xargs", "nohup", "time", "nice"];

/// The flags that keep Claude Code or Codex from stopping at permission prompts, as far as
/// `unattended` says; none for "ask" or another agent. Checked against `claude --help` (2.1) and
/// `codex --help` (0.164) and https://learn.chatgpt.com/docs/sandboxing/auto-review:
/// - Claude Code, "project": `--allowedTools=mcp__agents,Bash(git:*),Bash(npm:*),…` (one argument: the flag takes
///   several values and would swallow a prompt after it) and `--permission-mode auto`: Claude Code's
///   classifier approves routine commands (`sed`, `grep`, …) and denies risky ones instead of waiting
///   for someone, where `acceptEdits` stopped a builder at its first `sed -i`.
/// - Claude Code, "skip": `--permission-mode bypassPermissions`.
/// - Codex, "project": `--ask-for-approval on-request -c approvals_reviewer="auto_review"` routes eligible
///   approvals (including Maple MCP calls) to automatic review: "Approve for me". With `never`, there
///   is nothing to review. `--sandbox workspace-write -c sandbox_workspace_write.network_access=true`
///   keeps the existing filesystem sandbox and network access for `npm ci` and `cargo fetch`.
///   These invocation overrides follow agents.toml's arguments on every launch, including retries;
///   they don't change personal configuration or override managed requirements.
/// - Codex, "skip": `--dangerously-bypass-approvals-and-sandbox`.
pub fn permission_args(agent: &str, unattended: &Unattended) -> Vec<String> {
    let args: &[&str] = match (agent, unattended.mode) {
        (_, UnattendedMode::Ask) => &[],
        ("claude", UnattendedMode::Project) => {
            // The runner's own `agents` MCP server too: planners write their card with it and builders
            // prove with it, and the hub already decides what each session may do there (Off/Read/Full,
            // a note or project grant), so asking here would only stop the session at night.
            let rules = std::iter::once("mcp__agents".to_string())
                .chain(programs(&unattended.commands).iter().map(|p| format!("Bash({p}:*)")))
                .collect::<Vec<_>>()
                .join(",");
            return vec![format!("--allowedTools={rules}"), "--permission-mode".into(), "auto".into()];
        }
        ("claude", UnattendedMode::Skip) => &["--permission-mode", "bypassPermissions"],
        ("codex", UnattendedMode::Project) => &[
            "--ask-for-approval",
            "on-request",
            "-c",
            r#"approvals_reviewer="auto_review""#,
            "--sandbox",
            "workspace-write",
            "-c",
            "sandbox_workspace_write.network_access=true",
        ],
        ("codex", UnattendedMode::Skip) => &["--dangerously-bypass-approvals-and-sandbox"],
        _ => &[],
    };
    args.iter().map(|a| a.to_string()).collect()
}

/// The programs "project" allows: git, then the first word of each step of each command (`cd runner
/// && cargo test` gives cd and cargo), past any `VAR=value`. Only plain names and paths; never a shell
/// or another wrapper that would run anything it's given.
pub fn programs(commands: &[String]) -> Vec<String> {
    let mut out = vec!["git".to_string()];
    for step in commands.iter().flat_map(|c| c.split(['&', '|', ';', '\n', '(', ')'])) {
        let Some(program) = step.split_whitespace().find(|w| !is_assignment(w)) else { continue };
        let plain = program.chars().all(|c| c.is_ascii_alphanumeric() || "._/+-@".contains(c));
        if plain && !program.starts_with('-') && !WRAPPERS.contains(&program) && !out.iter().any(|p| p == program) {
            out.push(program.to_string());
        }
    }
    out
}

/// `FOO=bar` in front of a command.
fn is_assignment(word: &str) -> bool {
    word.split_once('=').is_some_and(|(name, _)| !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'))
}

/// An agent's arguments without the model it was given (`--model x`, `-m x`, `--model=x`).
fn without_model(args: &[String]) -> Vec<String> {
    let mut out = Vec::with_capacity(args.len());
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        if arg == "--model" || arg == "-m" {
            args.next();
        } else if !arg.starts_with("--model=") {
            out.push(arg.clone());
        }
    }
    out
}

/// The user's login shell: $SHELL, else their /etc/passwd entry, else the first of zsh, bash
/// and sh that exists. (A systemd user service may not have $SHELL, and many Linux machines
/// have no zsh.)
pub fn login_shell() -> String {
    if let Ok(shell) = std::env::var("SHELL")
        && !shell.trim().is_empty()
    {
        return shell;
    }
    let user = std::env::var("USER").or_else(|_| std::env::var("LOGNAME")).unwrap_or_default();
    let passwd = std::fs::read_to_string("/etc/passwd").unwrap_or_default();
    pick_shell(&user, &passwd, |p| std::path::Path::new(p).exists())
}

fn pick_shell(user: &str, passwd: &str, exists: impl Fn(&str) -> bool) -> String {
    let from_passwd = passwd
        .lines()
        .map(|l| l.split(':').collect::<Vec<_>>())
        .find(|f| f.len() >= 7 && !user.is_empty() && f[0] == user)
        .map(|f| f[6].to_string())
        .filter(|s| !s.is_empty() && exists(s));
    from_passwd.or_else(|| ["/bin/zsh", "/bin/bash", "/bin/sh"].into_iter().find(|s| exists(s)).map(String::from)).unwrap_or_else(|| "/bin/sh".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_a_shell_that_exists() {
        let passwd = "root:x:0:0:root:/root:/bin/bash\nme:x:1000:1000::/home/me:/usr/bin/fish\n";
        assert_eq!(pick_shell("me", passwd, |_| true), "/usr/bin/fish");
        // A Linux box without zsh, and no passwd entry for us.
        assert_eq!(pick_shell("ghost", passwd, |p| p != "/bin/zsh"), "/bin/bash");
        assert_eq!(pick_shell("", "", |p| p == "/bin/sh"), "/bin/sh");
    }

    fn get(id: &str) -> Agent {
        builtins().into_iter().find(|a| a.id == id).unwrap()
    }

    #[test]
    fn shell_is_a_login_shell() {
        assert_eq!(argv("/bin/zsh", &get("shell"), false, vec![], None, None, &[], Some("ignored")), ["/bin/zsh", "-l"]);
    }

    #[test]
    fn prompt_is_its_own_argv_entry() {
        let mut claude = get("claude");
        claude.args = vec!["--model".into(), "opus".into()];
        let a = argv("/bin/zsh", &claude, false, vec!["--settings".into(), "/x.json".into()], None, None, &[], Some(r#"say "hi" $HOME"#));
        assert_eq!(a, ["/bin/zsh", "-l", "-i", "-c", r#"exec "$0" "$@""#, "claude", "--settings", "/x.json", "--model", "opus", r#"say "hi" $HOME"#]);
        // A blank prompt isn't passed at all.
        assert_eq!(argv("/bin/zsh", &claude, false, vec![], None, None, &[], Some("  ")).last().unwrap(), "opus");
    }

    #[test]
    fn model_goes_after_the_agents_own_arguments() {
        // agents.toml's model makes way for the one the hub asked for, in either spelling.
        let mut claude = get("claude");
        claude.args = vec!["--model".into(), "opus".into(), "--verbose".into(), "--model=sonnet".into()];
        let hooks = vec!["--settings".into(), "/x.json".into()];
        assert_eq!(
            argv("/bin/zsh", &claude, false, hooks.clone(), Some("claude-opus-5-5[1m]"), None, &[], Some("fix it"))[5..],
            ["claude", "--settings", "/x.json", "--verbose", "--model", "claude-opus-5-5[1m]", "fix it"]
        );
        // Without one (or a blank one), agents.toml's arguments stand as they are.
        assert_eq!(
            argv("/bin/zsh", &claude, false, hooks.clone(), None, None, &[], None)[5..],
            ["claude", "--settings", "/x.json", "--model", "opus", "--verbose", "--model=sonnet"]
        );
        assert_eq!(argv("/bin/zsh", &claude, false, vec![], Some(" "), None, &[], None)[5..], ["claude", "--model", "opus", "--verbose", "--model=sonnet"]);

        let mut codex = get("codex");
        codex.args = vec!["-m".into(), "o3".into(), "--search".into()];
        assert_eq!(
            argv("/bin/zsh", &codex, false, vec![], Some("gpt-5.5-codex"), None, &[], Some("go"))[5..],
            ["codex", "--search", "--model", "gpt-5.5-codex", "go"]
        );

        // Other agents ignore it; a shell has no arguments at all.
        let aider = Agent {
            id: "aider".into(),
            label: "Aider".into(),
            command: "aider".into(),
            args: vec!["-m".into(), "x".into()],
            prompt: PromptMode::None,
            hooks: false,
        };
        assert_eq!(argv("/bin/sh", &aider, false, vec![], Some("gpt-5"), None, &[], None)[5..], ["aider", "-m", "x"]);
        assert_eq!(argv("/bin/zsh", &get("shell"), false, vec![], Some("gpt-5"), None, &[], None), ["/bin/zsh", "-l"]);
    }

    fn unattended(mode: UnattendedMode, commands: &[&str]) -> Unattended {
        Unattended { mode, commands: commands.iter().map(|c| c.to_string()).collect() }
    }

    #[test]
    fn a_long_prompt_reaches_the_agent_through_a_file_byte_for_byte() {
        // Over tmux's ~16 KB command limit, with everything a shell might mangle.
        let prompt = format!("Review this card.\n\n{}\n'quotes' \"double\" $HOME `ticks` \\ backslash\nlast line", "x".repeat(20_000));
        let dir = std::env::temp_dir().join(format!("maple-prompt-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let run = |agent: &Agent| {
            let file = dir.join("p.txt");
            std::fs::write(&file, &prompt).unwrap();
            let argv = argv_with_prompt_file("/bin/sh", agent, false, vec![], None, None, &[]);
            assert!(argv.iter().all(|a| a.len() < 1024), "the command tmux gets stays short");
            let out = std::process::Command::new(&argv[0]).args(&argv[1..]).env(PROMPT_FILE_ENV, &file).output().unwrap();
            assert!(!file.exists(), "the shell removes the prompt file");
            String::from_utf8(out.stdout).unwrap()
        };
        // Positional: the prompt is the last argument (printf's %s prints it as it is).
        let printf =
            Agent { id: "p".into(), label: "p".into(), command: "printf".into(), args: vec!["%s".into()], prompt: PromptMode::Positional, hooks: false };
        assert_eq!(run(&printf), prompt);
        // Flag: the flag, then the prompt.
        let flagged = Agent { args: vec!["%s|%s".into()], prompt: PromptMode::Flag("--message".into()), ..printf };
        assert_eq!(run(&flagged), format!("--message|{prompt}"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn codex_prompt_transports_preserve_every_argument_including_on_resume() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("maple-codex-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let capture = dir.join("capture arguments");
        std::fs::write(&capture, "#!/bin/sh\nprintf '%s\\0' \"$@\"\n").unwrap();
        std::fs::set_permissions(&capture, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut codex = get("codex");
        codex.command = capture.to_string_lossy().into_owned();
        codex.args = vec!["--model=old".into(), "--search".into()];
        let hooks = vec!["-c".into(), "notify=[\"runner\",\"hook\",\"codex\"]".into(), "-c".into(), "mcp_servers.maple.command=\"runner\"".into()];
        let project = unattended(UnattendedMode::Project, &[]);
        let images = vec!["/tmp/image with spaces.png".into()];
        for resume in [false, true] {
            for prompt in ["short 'quoted' $HOME `ticks` \\ ".to_string(), format!("multiline\n{}\n'quoted' $HOME `ticks` \\ café\n\n", "x".repeat(1100))] {
                let mut expected: Vec<String> = if resume { vec!["resume".into(), "--last".into()] } else { vec![] };
                expected.extend(hooks.clone());
                expected.extend(["--search".into(), "--model".into(), "test-model".into()]);
                expected.extend(permission_args("codex", &project));
                expected.extend(["--image=/tmp/image with spaces.png".into(), prompt.clone()]);
                for file_backed in [false, true] {
                    let file = dir.join("prompt.txt");
                    std::fs::write(&file, &prompt).unwrap();
                    let args = if file_backed {
                        argv_with_prompt_file("/bin/sh", &codex, resume, hooks.clone(), Some("test-model"), Some(&project), &images)
                    } else {
                        argv("/bin/sh", &codex, resume, hooks.clone(), Some("test-model"), Some(&project), &images, Some(&prompt))
                    };
                    let out = std::process::Command::new(&args[0]).args(&args[1..]).env(PROMPT_FILE_ENV, &file).output().unwrap();
                    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
                    let captured: Vec<_> = out.stdout.strip_suffix(&[0]).unwrap().split(|b| *b == 0).map(|b| String::from_utf8(b.to_vec()).unwrap()).collect();
                    assert_eq!(captured, expected, "resume={resume}, file_backed={file_backed}");
                    if file_backed {
                        assert!(!file.exists());
                    }
                }
            }
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn unattended_sessions_get_the_agents_permission_flags() {
        let hooks = vec!["--mcp-config=/m.json".to_string()];
        let commands = ["npm ci", "npm run typecheck\nnpm test --workspace web", "cd runner && cargo fmt --check && cargo test", "npx playwright test"];
        // "project": Claude Code allows edits, git and each command's program, in one `=` argument so
        // the prompt after it stays the prompt; the model and agents.toml's arguments come first.
        let project = unattended(UnattendedMode::Project, &commands);
        assert_eq!(
            argv("/bin/zsh", &get("claude"), false, hooks.clone(), Some("claude-opus-5-5"), Some(&project), &[], Some("fix it"))[5..],
            [
                "claude",
                "--mcp-config=/m.json",
                "--model",
                "claude-opus-5-5",
                "--allowedTools=mcp__agents,Bash(git:*),Bash(npm:*),Bash(cd:*),Bash(cargo:*),Bash(npx:*)",
                "--permission-mode",
                "auto",
                "fix it"
            ]
        );
        assert_eq!(
            argv("/bin/zsh", &get("codex"), false, vec![], None, Some(&project), &[], Some("fix it"))[5..],
            [
                "codex",
                "--ask-for-approval",
                "on-request",
                "-c",
                r#"approvals_reviewer="auto_review""#,
                "--sandbox",
                "workspace-write",
                "-c",
                "sandbox_workspace_write.network_access=true",
                "fix it"
            ]
        );
        // "skip": nothing asks.
        let skip = unattended(UnattendedMode::Skip, &[]);
        assert_eq!(
            argv("/bin/zsh", &get("claude"), false, vec![], None, Some(&skip), &[], Some("go"))[5..],
            ["claude", "--permission-mode", "bypassPermissions", "go"]
        );
        assert_eq!(
            argv("/bin/zsh", &get("codex"), false, vec![], None, Some(&skip), &[], Some("go"))[5..],
            ["codex", "--dangerously-bypass-approvals-and-sandbox", "go"]
        );
        // "ask", or none at all (the user's own sessions), adds nothing; nor does it for other agents.
        let ask = unattended(UnattendedMode::Ask, &commands);
        assert_eq!(argv("/bin/zsh", &get("claude"), false, vec![], None, Some(&ask), &[], Some("go"))[5..], ["claude", "go"]);
        assert_eq!(argv("/bin/zsh", &get("claude"), false, vec![], None, None, &[], Some("go"))[5..], ["claude", "go"]);
        assert_eq!(argv("/bin/zsh", &get("shell"), false, vec![], None, Some(&skip), &[], None), ["/bin/zsh", "-l"]);
        let aider = Agent { id: "aider".into(), label: "Aider".into(), command: "aider".into(), args: vec![], prompt: PromptMode::None, hooks: false };
        assert_eq!(argv("/bin/sh", &aider, false, vec![], None, Some(&skip), &[], None)[5..], ["aider"]);
    }

    #[test]
    fn codex_project_launches_review_approvals_after_configured_args() {
        let mut codex = get("codex");
        // An ordinary agents.toml reviewer override must precede the factory's override.
        codex.args = vec!["-c".into(), r#"approvals_reviewer="user""#.into(), "-m".into(), "old-model".into()];
        let hooks = vec!["-c".into(), "notify=[]".into()];
        let project = unattended(UnattendedMode::Project, &[]);
        let images = vec!["/tmp/first image.png".into(), "/tmp/second.png".into()];
        let prompt = "Read the repo.\n'quotes' \"double\" $HOME `ticks` --sandbox";
        // Both new/retried launches and resume, with either prompt transport, use the same overrides.
        for resume in [false, true] {
            for prompt_file in [false, true] {
                let actual = if prompt_file {
                    argv_with_prompt_file("/bin/sh", &codex, resume, hooks.clone(), Some("factory-model"), Some(&project), &images)
                } else {
                    argv("/bin/sh", &codex, resume, hooks.clone(), Some("factory-model"), Some(&project), &images, Some(prompt))
                };
                let mut expected = vec!["codex"];
                if resume {
                    expected.extend(["resume", "--last"]);
                }
                expected.extend([
                    "-c",
                    "notify=[]",
                    "-c",
                    r#"approvals_reviewer="user""#,
                    "--model",
                    "factory-model",
                    "--ask-for-approval",
                    "on-request",
                    "-c",
                    r#"approvals_reviewer="auto_review""#,
                    "--sandbox",
                    "workspace-write",
                    "-c",
                    "sandbox_workspace_write.network_access=true",
                    "--image=/tmp/first image.png,/tmp/second.png",
                ]);
                if prompt_file {
                    assert_eq!(actual[4], r#"p="$(cat -- "$MAPLE_PROMPT_FILE")"; rm -f -- "$MAPLE_PROMPT_FILE"; exec "$0" "$@" "$p""#);
                } else {
                    expected.push(prompt);
                }
                assert_eq!(actual[5..], expected, "resume={resume}, prompt_file={prompt_file}");
            }
        }
    }

    #[test]
    fn codex_project_prompt_file_keeps_the_prompt_intact() {
        let dir = std::env::temp_dir().join(format!("maple-codex-prompt-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let prompt = format!("Read this repo.\n{}\n'quotes' \"double\" $HOME `ticks` \\ backslash\nlast line", "x".repeat(20_000));
        // Capture the actual argv delivered by the shell without launching a real Codex.
        use std::os::unix::fs::PermissionsExt;
        let capture = dir.join("capture");
        std::fs::write(&capture, "#!/bin/sh\nprintf '%s\\0' \"$@\"\n").unwrap();
        std::fs::set_permissions(&capture, std::fs::Permissions::from_mode(0o700)).unwrap();
        let codex = Agent { command: capture.to_str().unwrap().into(), ..get("codex") };
        let project = unattended(UnattendedMode::Project, &[]);
        for resume in [false, true] {
            let file = dir.join("prompt.txt");
            std::fs::write(&file, &prompt).unwrap();
            let args = argv_with_prompt_file("/bin/sh", &codex, resume, vec![], None, Some(&project), &[]);
            let out = std::process::Command::new(&args[0]).args(&args[1..]).env(PROMPT_FILE_ENV, &file).output().unwrap();
            assert!(out.status.success());
            assert!(!file.exists());
            let stdout = String::from_utf8(out.stdout).unwrap();
            let received: Vec<_> = stdout.split_terminator('\0').collect();
            let mut expected = if resume { vec!["resume", "--last"] } else { vec![] };
            expected.extend([
                "--ask-for-approval",
                "on-request",
                "-c",
                r#"approvals_reviewer="auto_review""#,
                "--sandbox",
                "workspace-write",
                "-c",
                "sandbox_workspace_write.network_access=true",
                &prompt,
            ]);
            assert_eq!(received, expected);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn permission_modes_outside_codex_project_keep_existing_flags() {
        let mut codex = get("codex");
        codex.args = vec!["-c".into(), r#"approvals_reviewer="user""#.into()];
        for mode in [None, Some(UnattendedMode::Ask), Some(UnattendedMode::Skip)] {
            let settings = mode.map(|m| unattended(m, &[]));
            let mut expected = vec!["codex", "-c", r#"approvals_reviewer="user""#];
            if mode == Some(UnattendedMode::Skip) {
                expected.push("--dangerously-bypass-approvals-and-sandbox");
            }
            expected.push("go");
            assert_eq!(argv("/bin/sh", &codex, false, vec![], None, settings.as_ref(), &[], Some("go"))[5..], expected);
        }
        let custom = Agent {
            id: "custom".into(),
            label: "Custom".into(),
            command: "custom".into(),
            args: vec!["--own-permissions".into()],
            prompt: PromptMode::Positional,
            hooks: false,
        };
        for mode in [UnattendedMode::Ask, UnattendedMode::Project, UnattendedMode::Skip] {
            let settings = unattended(mode, &["npm test"]);
            assert_eq!(argv("/bin/sh", &get("shell"), false, vec![], None, Some(&settings), &[], None), ["/bin/sh", "-l"]);
            assert_eq!(argv("/bin/sh", &custom, false, vec![], None, Some(&settings), &[], Some("go"))[5..], ["custom", "--own-permissions", "go"]);
        }
    }

    #[test]
    fn codex_gets_a_tasks_images_once_before_the_prompt() {
        let images = vec!["/h/.config/maple/images/t1/3f9c1a2b-a.png".to_string(), "/h/.config/maple/images/t1/77d0e4aa-b.jpg".to_string()];
        let project = unattended(UnattendedMode::Project, &[]);
        // After the model and the permission flags, one `=` argument, then the prompt.
        assert_eq!(
            argv("/bin/zsh", &get("codex"), false, vec![], Some("gpt-5.5-codex"), Some(&project), &images, Some("fix it"))[5..],
            [
                "codex",
                "--model",
                "gpt-5.5-codex",
                "--ask-for-approval",
                "on-request",
                "-c",
                r#"approvals_reviewer="auto_review""#,
                "--sandbox",
                "workspace-write",
                "-c",
                "sandbox_workspace_write.network_access=true",
                "--image=/h/.config/maple/images/t1/3f9c1a2b-a.png,/h/.config/maple/images/t1/77d0e4aa-b.jpg",
                "fix it"
            ]
        );
        // A long prompt (from a file) gets it too, last.
        let long = argv_with_prompt_file("/bin/sh", &get("codex"), false, vec![], None, None, &images);
        assert_eq!(long[5..], ["codex", "--image=/h/.config/maple/images/t1/3f9c1a2b-a.png,/h/.config/maple/images/t1/77d0e4aa-b.jpg"]);
        assert_eq!(long.iter().filter(|a| a.starts_with("--image")).count(), 1);
        // No images, no flag.
        assert_eq!(argv("/bin/zsh", &get("codex"), false, vec![], None, None, &[], Some("go"))[5..], ["codex", "go"]);
        // Claude Code and custom agents read the paths in their prompt instead.
        assert_eq!(
            argv("/bin/zsh", &get("claude"), false, vec![], None, Some(&project), &images, Some("go")).iter().filter(|a| a.contains("--image")).count(),
            0
        );
        let aider = Agent { id: "aider".into(), label: "Aider".into(), command: "aider".into(), args: vec![], prompt: PromptMode::Positional, hooks: false };
        assert_eq!(argv("/bin/sh", &aider, false, vec![], None, None, &images, Some("go"))[5..], ["aider", "go"]);
    }

    #[test]
    fn project_commands_allow_only_their_programs() {
        let commands = |c: &[&str]| programs(&c.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        // git always; then each step's program once, past `VAR=value`, in order.
        assert_eq!(commands(&[]), ["git"]);
        assert_eq!(
            commands(&["RAILS_ENV=test bin/rails test", "bundle exec rspec || true; git status", "(cd web && pnpm build) | tee out"]),
            ["git", "bin/rails", "bundle", "true", "cd", "pnpm", "tee"]
        );
        // Never a shell or a wrapper that runs whatever it's given, nor anything that isn't a plain name.
        assert_eq!(
            commands(&["sudo make install", "sh -c 'rm -rf /'", "env FOO=1 node x.js", "bash scripts/test.sh", "\"quoted\" x", "~/bin/x", "-x"]),
            ["git"]
        );
        // The hub's JSON: `commands` may be missing.
        let u: Unattended = serde_json::from_str(r#"{"mode":"skip"}"#).unwrap();
        assert_eq!(u, unattended(UnattendedMode::Skip, &[]));
        assert!(serde_json::from_str::<Unattended>(r#"{"mode":"yolo"}"#).is_err());
    }

    #[test]
    fn resume_continues_the_last_conversation_before_the_other_args() {
        let hooks = vec!["--settings".to_string(), "/x.json".to_string()];
        let mut claude = get("claude");
        claude.args = vec!["--verbose".into()];
        assert_eq!(
            argv("/bin/zsh", &claude, true, hooks.clone(), Some("opus"), None, &[], None)[5..],
            ["claude", "--continue", "--settings", "/x.json", "--verbose", "--model", "opus"]
        );
        // Codex's is a subcommand, so it comes straight after the program, before the `-c` hooks.
        let codex_hooks = vec!["-c".to_string(), "notify=[]".to_string()];
        assert_eq!(argv("/bin/zsh", &get("codex"), true, codex_hooks, None, None, &[], None)[5..], ["codex", "resume", "--last", "-c", "notify=[]"]);
        // A long prompt's file form keeps it too.
        assert_eq!(argv_with_prompt_file("/bin/sh", &get("claude"), true, vec![], None, None, &[])[5..], ["claude", "--continue"]);
        // Without it, nothing changes.
        assert_eq!(argv("/bin/zsh", &get("claude"), false, vec![], None, None, &[], None)[5..], ["claude"]);
        // A shell, and custom agents, start afresh: there's no telling what their flag is.
        assert_eq!(argv("/bin/zsh", &get("shell"), true, vec![], None, None, &[], None), ["/bin/zsh", "-l"]);
        let aider =
            Agent { id: "aider".into(), label: "Aider".into(), command: "aider".into(), args: vec!["-x".into()], prompt: PromptMode::None, hooks: false };
        assert_eq!(argv("/bin/sh", &aider, true, vec![], None, None, &[], None)[5..], ["aider", "-x"]);
    }

    #[test]
    fn prompt_modes() {
        let mut aider = Agent {
            id: "aider".into(),
            label: "Aider".into(),
            command: "aider".into(),
            args: vec![],
            prompt: PromptMode::Flag("--message".into()),
            hooks: false,
        };
        assert_eq!(argv("/bin/sh", &aider, false, vec![], None, None, &[], Some("go"))[5..], ["aider", "--message", "go"]);
        aider.prompt = PromptMode::None;
        assert_eq!(argv("/bin/sh", &aider, false, vec![], None, None, &[], Some("go"))[5..], ["aider"]);
        assert!(!aider.takes_prompt());
    }
}
