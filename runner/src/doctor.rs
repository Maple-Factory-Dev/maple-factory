//! `maple-runner doctor`: checks this machine has what sessions need (git, tmux, Node and npx,
//! the configured agent CLIs, Playwright's browser and its system libraries, and on Linux
//! systemd lingering), and lists what's missing with the command that installs each.
//! `--fix` turns lingering on and installs Playwright's pieces when that needs no password.
//! It never fails over a missing tool, so install.sh can end with it.

use std::path::Path;
use std::process::{Command, Stdio};

use crate::agents::Agent;
use crate::style;

/// The package manager that installs system tools here.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Pm {
    Apt,
    Dnf,
    Yum,
    Brew,
}

impl Pm {
    /// The first package manager `has` finds.
    pub fn detect(has: impl Fn(&str) -> bool) -> Option<Self> {
        [("apt-get", Pm::Apt), ("dnf", Pm::Dnf), ("yum", Pm::Yum), ("brew", Pm::Brew)].into_iter().find(|(c, _)| has(c)).map(|(_, pm)| pm)
    }
}

/// The command that installs a system `tool` (git, tmux, node, npx). apt, dnf and yum need
/// root, so they get `sudo` in front unless we're root already.
pub fn package_command(pm: Option<Pm>, tool: &str, root: bool) -> String {
    let sudo = if root { "" } else { "sudo " };
    let packages = match (pm, tool) {
        (Some(Pm::Brew), "node" | "npx") => "node",
        (_, "node" | "npx") => "nodejs npm",
        (_, t) => t,
    };
    match pm {
        Some(Pm::Apt) => format!("{sudo}apt-get install -y {packages}"),
        Some(Pm::Dnf) => format!("{sudo}dnf install -y {packages}"),
        Some(Pm::Yum) => format!("{sudo}yum install -y {packages}"),
        Some(Pm::Brew) => format!("brew install {packages}"),
        None => format!("install {packages} with your package manager"),
    }
}

/// The command that installs an agent's CLI.
pub fn agent_install_command(command: &str) -> String {
    match command {
        "claude" => "npm i -g @anthropic-ai/claude-code".into(),
        "codex" => "npm i -g @openai/codex".into(),
        other => format!("install {other} and put it on PATH"),
    }
}

/// The programs the configured agents run, without the shell agent (an empty command is the
/// login shell) and without duplicates.
pub fn agent_commands(agents: &[Agent]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for a in agents {
        let cmd = a.command.trim();
        if !cmd.is_empty() && a.id != "shell" && !out.iter().any(|c| c == cmd) {
            out.push(cmd.to_string());
        }
    }
    out
}

/// One thing the runner wants on this machine.
#[derive(Debug, PartialEq)]
pub struct Check {
    pub name: String,
    pub ok: bool,
    /// What's here, or why it matters, shown after the name.
    pub detail: String,
    /// The commands that fix it when it's missing, in order.
    pub fix: Vec<String>,
}

impl Check {
    fn new(name: &str, ok: bool, detail: impl Into<String>, fix: Vec<String>) -> Self {
        Self { name: name.into(), ok, detail: detail.into(), fix }
    }
}

/// The report: a line per check, then the still-needed list (or a single "ready" line).
pub fn render(checks: &[Check]) -> String {
    let mut out = String::new();
    for c in checks {
        let mark = if c.ok { style::ok("✓") } else { style::warn("✗") };
        let detail = if c.detail.is_empty() { String::new() } else { format!(" {}", style::dim(&c.detail)) };
        out += &format!("  {mark} {}{detail}\n", c.name);
    }
    let missing: Vec<&Check> = checks.iter().filter(|c| !c.ok).collect();
    if missing.is_empty() {
        out += &format!("\n{} everything the runner needs is here.\n", style::ok("Ready:"));
        return out;
    }
    out += &format!("\n{}\n", style::warn("Still needed:"));
    for c in missing {
        out += &format!("  {}\n", style::bold(&c.name));
        for f in &c.fix {
            out += &format!("      {f}\n");
        }
    }
    out
}

/// Where `cmd` is on the login shell's PATH (the one agents run with), or `None`.
fn which(cmd: &str) -> Option<String> {
    let shell = crate::agents::login_shell();
    let out = Command::new(&shell).args(["-lc", &format!("command -v {}", shell_quote(cmd))]).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    let path = String::from_utf8_lossy(&out.stdout).trim().lines().last().unwrap_or("").to_string();
    (out.status.success() && !path.is_empty()).then_some(path)
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Runs `cmd` through the login shell (so npx is the one agents get), with no stdin so
/// nothing waits on a password. Its output goes straight to the terminal.
fn run_shell(cmd: &str) -> bool {
    println!("{} {cmd}", style::dim("Running"));
    Command::new(crate::agents::login_shell()).args(["-lc", cmd]).stdin(Stdio::null()).status().is_ok_and(|s| s.success())
}

/// Whether Playwright's Chromium has been downloaded for this user.
fn browser_installed(home: &Path) -> bool {
    let cache = if cfg!(target_os = "macos") { home.join("Library/Caches/ms-playwright") } else { home.join(".cache/ms-playwright") };
    std::fs::read_dir(cache).is_ok_and(|d| d.flatten().any(|e| e.file_name().to_string_lossy().starts_with("chromium")))
}

/// Libraries Chromium needs that a minimal server image lacks.
const CHROMIUM_LIBS: [&str; 3] = ["libnss3.so", "libgbm.so.1", "libatk-1.0.so.0"];

/// The Chromium libraries `ldconfig -p` doesn't list (Linux; empty elsewhere or when it can't tell).
pub fn missing_libs(ldconfig: &str) -> Vec<&'static str> {
    CHROMIUM_LIBS.into_iter().filter(|lib| !ldconfig.lines().any(|l| l.trim_start().starts_with(lib))).collect()
}

fn system_missing_libs() -> Vec<&'static str> {
    if !cfg!(target_os = "linux") {
        return vec![];
    }
    let ldconfig = ["ldconfig", "/sbin/ldconfig", "/usr/sbin/ldconfig"]
        .into_iter()
        .find_map(|c| Command::new(c).arg("-p").stderr(Stdio::null()).output().ok().filter(|o| o.status.success()));
    match ldconfig {
        Some(o) => missing_libs(&String::from_utf8_lossy(&o.stdout)),
        None => vec![],
    }
}

/// Whether this machine runs a systemd user service for the runner.
fn systemd() -> bool {
    cfg!(target_os = "linux") && Command::new("systemctl").arg("--version").stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success())
}

pub fn run(fix: bool) -> anyhow::Result<()> {
    let home = std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default());
    let root = crate::service::is_root();
    let pm = Pm::detect(|c| which(c).is_some());
    let mut checks = Vec::new();

    if systemd() {
        let user = crate::service::current_user();
        let mut on = crate::service::linger_enabled(&user);
        if fix && on != Some(true) {
            let _ = crate::service::linger_step(&user, false);
            on = crate::service::linger_enabled(&user);
        }
        checks.push(match on {
            Some(true) => Check::new("linger", true, "on: the runner keeps running after logout and starts at boot", vec![]),
            _ => Check::new("linger", false, "off: the runner stops when you log out", vec![crate::service::linger_command(&user)]),
        });
    }

    for tool in ["git", "tmux", "node", "npx"] {
        let found = which(tool);
        let why = match tool {
            "git" => "worktrees and commits",
            "tmux" => "agents run in tmux",
            _ => "agent CLIs and Playwright screenshots",
        };
        checks.push(match found {
            Some(path) => Check::new(tool, true, path, vec![]),
            None => Check::new(tool, false, format!("missing ({why})"), vec![package_command(pm, tool, root)]),
        });
    }
    let has_npx = checks.iter().any(|c| c.name == "npx" && c.ok);

    for cmd in agent_commands(&crate::agent_config::load()) {
        checks.push(match which(&cmd) {
            Some(path) => Check::new(&cmd, true, path, vec![]),
            None => Check::new(&cmd, false, "missing (an agent CLI)", vec![agent_install_command(&cmd)]),
        });
    }

    // Playwright: system libraries (Linux, root), then the browser (per user).
    let can_root = root || crate::service::sudo_nopasswd();
    let deps = crate::proof::install_deps_command();
    let browser = crate::proof::install_command();
    let mut libs = system_missing_libs();
    if fix && has_npx && can_root && !libs.is_empty() {
        let _ = run_shell(&deps);
        libs = system_missing_libs();
    }
    if !libs.is_empty() {
        let cmd = if root { deps.clone() } else { format!("sudo env PATH=\"$PATH\" {deps}") };
        let cmd = if has_npx { cmd } else { format!("{cmd}   (once Node is installed)") };
        checks.push(Check::new("playwright libraries", false, format!("missing {}", libs.join(", ")), vec![cmd]));
    } else if cfg!(target_os = "linux") {
        checks.push(Check::new("playwright libraries", true, "", vec![]));
    }
    let mut has_browser = browser_installed(&home);
    if fix && has_npx && !has_browser {
        let _ = run_shell(&browser);
        has_browser = browser_installed(&home);
    }
    checks.push(if has_browser {
        Check::new("playwright browser", true, "chromium", vec![])
    } else {
        Check::new("playwright browser", false, "missing (screenshots for proofs)", vec![browser])
    });

    println!("{}", style::bold("maple-runner doctor"));
    print!("{}", render(&checks));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_commands() {
        assert_eq!(package_command(Some(Pm::Apt), "tmux", true), "apt-get install -y tmux");
        assert_eq!(package_command(Some(Pm::Apt), "tmux", false), "sudo apt-get install -y tmux");
        assert_eq!(package_command(Some(Pm::Apt), "node", true), "apt-get install -y nodejs npm");
        assert_eq!(package_command(Some(Pm::Dnf), "npx", false), "sudo dnf install -y nodejs npm");
        assert_eq!(package_command(Some(Pm::Yum), "git", true), "yum install -y git");
        assert_eq!(package_command(Some(Pm::Brew), "node", false), "brew install node");
        assert_eq!(package_command(None, "tmux", true), "install tmux with your package manager");
        assert_eq!(agent_install_command("claude"), "npm i -g @anthropic-ai/claude-code");
        assert_eq!(agent_install_command("codex"), "npm i -g @openai/codex");
        assert_eq!(agent_install_command("aider"), "install aider and put it on PATH");
    }

    #[test]
    fn detects_the_package_manager() {
        assert_eq!(Pm::detect(|c| c == "dnf" || c == "brew"), Some(Pm::Dnf));
        assert_eq!(Pm::detect(|c| c == "apt-get"), Some(Pm::Apt));
        assert_eq!(Pm::detect(|_| false), None);
    }

    #[test]
    fn agent_commands_come_from_agents_toml() {
        let agents = crate::agent_config::parse("[agents.aider]\nlabel = \"Aider\"\ncommand = \"aider\"\n\n[agents.codex]\ncommand = \"codex\"\n").unwrap();
        assert_eq!(agent_commands(&agents), ["claude", "codex", "aider"]);
        assert_eq!(agent_commands(&crate::agents::builtins()), ["claude", "codex"]);
    }

    #[test]
    fn renders_the_still_needed_list() {
        let checks =
            vec![Check::new("git", true, "/usr/bin/git", vec![]), Check::new("claude", false, "missing", vec!["npm i -g @anthropic-ai/claude-code".into()])];
        let text = render(&checks);
        assert!(text.contains("Still needed:"), "{text}");
        assert!(text.contains("      npm i -g @anthropic-ai/claude-code\n"), "{text}");
        assert!(!text.contains("Ready:"), "{text}");

        let ready = render(&[Check::new("git", true, "", vec![])]);
        assert_eq!(ready.matches("Ready:").count(), 1);
        assert!(!ready.contains("Still needed"), "{ready}");
    }

    #[test]
    fn reads_missing_libraries() {
        let ld = "3 libs found in cache\n\tlibnss3.so (libc6,x86-64) => /lib/x86_64-linux-gnu/libnss3.so\n\tlibgbm.so.1 (libc6,x86-64) => /lib/libgbm.so.1\n";
        assert_eq!(missing_libs(ld), ["libatk-1.0.so.0"]);
        assert_eq!(missing_libs(""), CHROMIUM_LIBS);
    }
}
