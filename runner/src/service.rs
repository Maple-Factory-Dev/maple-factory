//! Installing the runner as a per-user service.
//!
//! `maple-runner install` copies this binary to `~/.local/share/maple/bin/maple-runner` and registers
//! that copy with launchd (macOS) or systemd (Linux) so it starts at login and comes back
//! after a crash. The copy is what lets the runner update itself: it lives somewhere the
//! user can write, away from a cargo `target/` directory that a rebuild would change, and
//! the service only ever runs it. The service runs it with no arguments: everything it needs
//! comes from `~/.config/maple/runner.json`, so the service file holds no secrets and
//! re-enrolling doesn't mean reinstalling.
//!
//! The service file text is built by pure functions so it can be tested (and shown with
//! `--dry-run`) without touching the real launchd or systemd.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

pub const LAUNCHD_LABEL: &str = "dev.maplefactory.runner";
pub const SYSTEMD_UNIT: &str = "maple-runner.service";

/// Where agents usually live, added to the service's PATH after the installing shell's own
/// (launchd starts services with a bare `/usr/bin:/bin:/usr/sbin:/sbin`).
const DEFAULT_PATH: &[&str] = &["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"];

/// Where `maple-runner install` puts the binary the service runs, relative to HOME.
const INSTALLED_EXE: &str = ".local/share/maple/bin/maple-runner";

/// The installed copy of the runner under `home`.
pub fn installed_exe_in(home: &Path) -> PathBuf {
    home.join(INSTALLED_EXE)
}

/// The installed copy of the runner for this user.
pub fn installed_exe() -> Result<PathBuf> {
    Ok(installed_exe_in(Path::new(&std::env::var("HOME").context("HOME is not set")?)))
}

/// Whether `exe` is the installed copy. Compares canonical paths, so a symlinked HOME
/// or a `..` in the path doesn't matter; a missing file is never the installed copy.
pub fn is_installed_copy(exe: &Path, installed: &Path) -> bool {
    match (exe.canonicalize(), installed.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

/// Copies `src` to `dest` (mode 0755), creating its directory. The copy is written next to
/// `dest` and renamed over it, so a running service keeps the old file (renaming replaces
/// the directory entry, not the file it's executing) and nothing ever sees half a binary.
/// Never `cp` over a running binary on macOS: the kernel kills it for a bad code signature.
pub fn copy_binary(src: &Path, dest: &Path) -> Result<()> {
    let dir = dest.parent().context("the install path has no directory")?;
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    let tmp = dir.join(format!(".maple-runner.install-{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let result = (|| {
        std::fs::copy(src, &tmp).with_context(|| format!("copying {} to {}", src.display(), tmp.display()))?;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
        std::fs::rename(&tmp, dest).with_context(|| format!("replacing {}", dest.display()))
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// What a binary says its version is (`maple-runner --version`), or why it couldn't say.
pub fn binary_version(exe: &Path) -> String {
    match Command::new(exe).arg("--version").output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        Ok(out) => format!("`--version` failed: {}", String::from_utf8_lossy(&out.stderr).trim()),
        Err(e) => format!("can't run it: {e}"),
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Manager {
    Launchd,
    Systemd,
}

impl Manager {
    pub fn current() -> Result<Self> {
        match std::env::consts::OS {
            "macos" => Ok(Self::Launchd),
            "linux" => Ok(Self::Systemd),
            os => bail!("installing a service isn't supported on {os}; run `maple-runner run` yourself"),
        }
    }
}

/// Everything about the service on this machine, worked out up front so a dry run can
/// show exactly what a real run would do.
pub struct Service {
    manager: Manager,
    home: PathBuf,
    /// The service definition file.
    pub file: PathBuf,
    /// launchd's `gui/<uid>` domain (macOS only).
    domain: String,
}

impl Service {
    pub fn detect() -> Result<Self> {
        let manager = Manager::current()?;
        let home = PathBuf::from(std::env::var("HOME").context("HOME is not set")?);
        let uid = if manager == Manager::Launchd { uid()? } else { 0 };
        Ok(Self::new(manager, home, uid))
    }

    fn new(manager: Manager, home: PathBuf, uid: u32) -> Self {
        let (file, domain) = match manager {
            Manager::Launchd => (home.join(format!("Library/LaunchAgents/{LAUNCHD_LABEL}.plist")), format!("gui/{uid}")),
            Manager::Systemd => (home.join(".config/systemd/user").join(SYSTEMD_UNIT), String::new()),
        };
        Self { manager, home, file, domain }
    }

    /// launchd or systemd, as something to tell the user.
    pub fn manager_name(&self) -> &'static str {
        match self.manager {
            Manager::Launchd => "launchd",
            Manager::Systemd => "systemd",
        }
    }

    /// Where the service's output ends up, as something to tell the user.
    pub fn logs(&self) -> String {
        match self.manager {
            Manager::Launchd => format!("{} (tail -f it)", self.log_file().display()),
            Manager::Systemd => "journalctl --user -u maple-runner -f".into(),
        }
    }

    fn log_file(&self) -> PathBuf {
        self.home.join("Library/Logs/maple-runner.log")
    }

    /// The service file for running `exe`.
    pub fn render(&self, exe: &Path) -> String {
        let path = service_path(&self.home, std::env::var("PATH").ok().as_deref());
        match self.manager {
            Manager::Launchd => launchd_plist(exe, &self.home, &self.log_file(), &path),
            Manager::Systemd => systemd_unit(exe, &self.home, &path),
        }
    }

    /// Commands that (re)load the service after its file is written: ones that may fail
    /// (nothing loaded yet), then ones that must succeed. Reinstalling restarts the
    /// service so a moved or rebuilt binary takes effect.
    fn load_commands(&self) -> (Vec<Vec<String>>, Vec<Vec<String>>) {
        let file = self.file.to_string_lossy().into_owned();
        match self.manager {
            Manager::Launchd => (
                vec![args(&["launchctl", "bootout", &format!("{}/{LAUNCHD_LABEL}", self.domain)])],
                vec![args(&["launchctl", "bootstrap", &self.domain, &file])],
            ),
            Manager::Systemd => (
                vec![],
                vec![
                    args(&["systemctl", "--user", "daemon-reload"]),
                    args(&["systemctl", "--user", "enable", "maple-runner"]),
                    args(&["systemctl", "--user", "restart", "maple-runner"]),
                ],
            ),
        }
    }

    /// Commands that stop the service; all may fail if it isn't loaded.
    fn unload_commands(&self) -> Vec<Vec<String>> {
        match self.manager {
            Manager::Launchd => vec![args(&["launchctl", "bootout", &format!("{}/{LAUNCHD_LABEL}", self.domain)])],
            Manager::Systemd => vec![args(&["systemctl", "--user", "disable", "--now", "maple-runner"])],
        }
    }

    pub fn install(&self, exe: &Path, dry_run: bool) -> Result<()> {
        let text = self.render(exe);
        let (optional, required) = self.load_commands();
        if dry_run {
            println!("Would write {}:\n\n{text}", self.file.display());
            println!("Would run:");
            for cmd in &optional {
                println!("  {}   (failure ignored)", cmd.join(" "));
            }
            for cmd in &required {
                println!("  {}", cmd.join(" "));
            }
            if self.manager == Manager::Systemd {
                match linger_step(&current_user(), true) {
                    LingerStep::AlreadyOn => println!("Lingering is already on, so the service keeps running after logout and starts at boot."),
                    LingerStep::Plan(LingerPlan::Run(cmd)) => println!("Would run:\n  {}   (lingering, so the service outlives logout)", cmd.join(" ")),
                    LingerStep::Plan(LingerPlan::Print(cmd)) | LingerStep::Failed(cmd, _) => println!("Would ask you to run: {cmd}"),
                }
            }
            println!("\nLogs would go to {}", self.logs());
            return Ok(());
        }
        let dir = self.file.parent().expect("service file has a parent");
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        if self.manager == Manager::Launchd {
            std::fs::create_dir_all(self.log_file().parent().expect("log file has a parent"))?;
        }
        std::fs::write(&self.file, text).with_context(|| format!("writing {}", self.file.display()))?;
        println!("{} {}", crate::style::ok("Wrote"), crate::style::accent(self.file.display()));

        for cmd in &optional {
            let _ = run(cmd);
        }
        for cmd in &required {
            // launchd can still be tearing down the old job right after `bootout`.
            let mut attempt = 0;
            loop {
                match run(cmd) {
                    Ok(()) => break,
                    Err(e) if attempt < 3 && self.manager == Manager::Launchd => {
                        attempt += 1;
                        tracing::debug!("{e:#}; retrying");
                        std::thread::sleep(std::time::Duration::from_secs(1));
                    }
                    Err(e) => return Err(e),
                }
            }
        }
        if self.manager == Manager::Systemd {
            match linger_step(&current_user(), false) {
                LingerStep::AlreadyOn => {
                    println!("{} lingering is on: maple-runner keeps running after you log out and starts at boot.", crate::style::ok("Linger:"))
                }
                LingerStep::Plan(LingerPlan::Run(_)) => {
                    println!("{} turned lingering on: maple-runner keeps running after you log out and starts at boot.", crate::style::ok("Linger:"))
                }
                LingerStep::Plan(LingerPlan::Print(cmd)) => {
                    println!(
                        "{} lingering is off, so the runner stops when you log out and won't start at boot. Run:\n    {cmd}",
                        crate::style::warn("Linger:")
                    )
                }
                LingerStep::Failed(cmd, e) => println!("{} couldn't turn lingering on ({e}). Run:\n    {cmd}", crate::style::warn("Linger:")),
            }
        }
        println!("{} maple-runner starts at login and restarts if it stops.", crate::style::ok("Installed:"));
        println!("{} {}", crate::style::dim("Logs:"), crate::style::accent(self.logs()));
        Ok(())
    }

    /// The installed binary, and the `~/.local/bin/maple-runner` link install.sh points at it.
    fn installed_files(&self) -> (PathBuf, PathBuf) {
        (installed_exe_in(&self.home), self.home.join(".local/bin/maple-runner"))
    }

    /// What `uninstall --dry-run` prints: every command and file a real uninstall touches.
    pub fn uninstall_plan(&self) -> String {
        let (exe, link) = self.installed_files();
        let mut out = String::from("Would run:\n");
        for cmd in &self.unload_commands() {
            out += &format!("  {}\n", cmd.join(" "));
        }
        if self.manager == Manager::Systemd {
            out += "  systemctl --user daemon-reload\n";
        }
        out += &format!("Would remove {}\n", self.file.display());
        out += &format!("Would remove {}\n", exe.display());
        out += &format!("Would remove {} (if it links to the installed copy)\n", link.display());
        out += &format!("Would keep {} (repos and worktrees, so no work is lost)\n", self.home.join(".local/share/maple/repos").display());
        out
    }

    pub fn uninstall(&self, dry_run: bool) -> Result<()> {
        if dry_run {
            print!("{}", self.uninstall_plan());
            return Ok(());
        }
        for cmd in &self.unload_commands() {
            let _ = run(cmd);
        }
        match std::fs::remove_file(&self.file) {
            Ok(()) => println!("{} {}", crate::style::ok("Removed"), crate::style::accent(self.file.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => println!("No service file at {}", self.file.display()),
            Err(e) => return Err(e).with_context(|| format!("removing {}", self.file.display())),
        }
        if self.manager == Manager::Systemd {
            let _ = run(&args(&["systemctl", "--user", "daemon-reload"]));
        }
        for removed in self.remove_installed()? {
            println!("{} {}", crate::style::ok("Removed"), crate::style::accent(removed.display()));
        }
        println!("{} The service and the installed maple-runner are gone.", crate::style::ok("Uninstalled."));
        println!(
            "{} ~/.local/share/maple/repos (repos and worktrees) is kept. This machine is still enrolled; run `maple-runner unenroll` to remove it from the factory and delete ~/.config/maple/runner.json.",
            crate::style::dim("Next:")
        );
        Ok(())
    }

    /// Removes the installed binary, its bin/ directory once empty, and the `~/.local/bin`
    /// link if it points at that binary. Never touches repos/. Returns what was removed.
    fn remove_installed(&self) -> Result<Vec<PathBuf>> {
        let (exe, link) = self.installed_files();
        let mut removed = Vec::new();
        if std::fs::read_link(&link).is_ok_and(|target| target == exe) {
            std::fs::remove_file(&link).with_context(|| format!("removing {}", link.display()))?;
            removed.push(link);
        }
        match std::fs::remove_file(&exe) {
            Ok(()) => removed.push(exe.clone()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e).with_context(|| format!("removing {}", exe.display())),
        }
        if let Some(bin) = exe.parent() {
            // Only if empty: remove_dir refuses a directory with anything left in it.
            let _ = std::fs::remove_dir(bin);
        }
        Ok(removed)
    }

    /// A one-line description of whether the service is installed and running.
    pub fn status(&self) -> String {
        if !self.file.exists() {
            return crate::style::warn("not installed (run `maple-runner install`)");
        }
        let loaded = match self.manager {
            Manager::Launchd => {
                let target = format!("{}/{LAUNCHD_LABEL}", self.domain);
                match quiet(&["launchctl", "print", &target]) {
                    Some(out) => out.lines().find_map(|l| l.trim().strip_prefix("state = ")).map(|s| format!("loaded, {s}")).unwrap_or_else(|| "loaded".into()),
                    None => "not loaded".into(),
                }
            }
            Manager::Systemd => {
                quiet(&["systemctl", "--user", "is-active", "maple-runner"]).map(|s| s.trim().to_string()).unwrap_or_else(|| "not running".into())
            }
        };
        let loaded = if matches!(loaded.as_str(), "loaded, running" | "active") { crate::style::ok(loaded) } else { crate::style::warn(loaded) };
        let mut out = format!("installed ({}), {loaded}", crate::style::accent(self.file.display()));
        if self.manager == Manager::Systemd {
            let user = current_user();
            if linger_enabled(&user) == Some(false) {
                out += &format!("\n{:11}{}", "", crate::style::warn(linger_warning(&user)));
            }
        }
        out
    }

    /// The process id of the running service, or `None` if it isn't installed, isn't
    /// running, or its manager doesn't say which process it is.
    pub fn running_pid(&self) -> Option<u32> {
        if !self.file.exists() {
            return None;
        }
        match self.manager {
            Manager::Launchd => launchd_pid(&quiet(&["launchctl", "print", &format!("{}/{LAUNCHD_LABEL}", self.domain)])?),
            Manager::Systemd => systemd_pid(&quiet(&["systemctl", "--user", "show", "-p", "ActiveState", "-p", "MainPID", "maple-runner"])?),
        }
    }

    /// Whether the service manager has the service loaded: launchd has the job (running, or
    /// waiting to be relaunched by KeepAlive), or systemd's unit is active or restarting.
    fn loaded(&self) -> bool {
        if !self.file.exists() {
            return false;
        }
        match self.manager {
            Manager::Launchd => quiet(&["launchctl", "print", &format!("{}/{LAUNCHD_LABEL}", self.domain)]).is_some(),
            Manager::Systemd => {
                let show = quiet(&["systemctl", "--user", "show", "-p", "ActiveState", "maple-runner"]).unwrap_or_default();
                systemd_loaded(&show)
            }
        }
    }

    /// The commands that stop the service so nothing relaunches it until `start` (or the next
    /// login). Killing the process or `launchctl stop` isn't enough: KeepAlive starts it again.
    fn stop_commands(&self) -> Vec<Vec<String>> {
        match self.manager {
            Manager::Launchd => vec![args(&["launchctl", "bootout", &format!("{}/{LAUNCHD_LABEL}", self.domain)])],
            Manager::Systemd => vec![args(&["systemctl", "--user", "stop", "maple-runner"])],
        }
    }

    /// The commands that start a stopped service: launchd loads the job again (or kicks one
    /// that's loaded but not running); systemd starts the unit, which stays enabled for login.
    fn start_commands(&self, loaded: bool) -> Vec<Vec<String>> {
        let file = self.file.to_string_lossy().into_owned();
        match self.manager {
            Manager::Launchd if loaded => vec![args(&["launchctl", "kickstart", &format!("{}/{LAUNCHD_LABEL}", self.domain)])],
            Manager::Launchd => vec![args(&["launchctl", "bootstrap", &self.domain, &file])],
            Manager::Systemd => vec![args(&["systemctl", "--user", "start", "maple-runner"])],
        }
    }

    /// Stops the service and waits for its runner to exit. Returns false if it was already
    /// stopped.
    pub fn stop(&self, dry_run: bool) -> Result<bool> {
        if !self.file.exists() {
            bail!("the service isn't installed (run `maple-runner install`)");
        }
        let commands = self.stop_commands();
        if dry_run {
            println!("Would run:");
            for cmd in &commands {
                println!("  {}", cmd.join(" "));
            }
            return Ok(true);
        }
        // A crash-looping runner is loaded but often between runs, so "stopped" means unloaded.
        if !self.loaded() {
            return Ok(false);
        }
        for cmd in &commands {
            run(cmd)?;
        }
        let start = Instant::now();
        while self.loaded() || self.running_pid().is_some() {
            if start.elapsed() >= Duration::from_secs(5) {
                bail!("asked {} to stop the service, but it's still running after 5s", self.manager_name());
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        Ok(true)
    }

    /// Starts the service and waits up to `wait` for it to connect. `Ok(None)` when it's
    /// already running (or a dry run), else the runner id it connected as, if it did in time.
    pub fn start(&self, wait: Duration, dry_run: bool) -> Result<Start> {
        if !self.file.exists() {
            bail!("the service isn't installed (run `maple-runner install`)");
        }
        let loaded = self.loaded();
        let commands = self.start_commands(loaded);
        if dry_run {
            println!("Would run:");
            for cmd in &commands {
                println!("  {}", cmd.join(" "));
            }
            return Ok(Start::DryRun);
        }
        if let Some(pid) = self.running_pid() {
            return Ok(Start::AlreadyRunning(pid));
        }
        let mark = self.log_mark()?;
        for cmd in &commands {
            // launchd can still be tearing the job down right after a `stop`.
            let mut attempt = 0;
            loop {
                match run(cmd) {
                    Ok(()) => break,
                    Err(e) if attempt < 3 && self.manager == Manager::Launchd => {
                        attempt += 1;
                        tracing::debug!("{e:#}; retrying");
                        std::thread::sleep(Duration::from_secs(1));
                    }
                    Err(e) => return Err(e),
                }
            }
        }
        Ok(Start::Started(self.wait_connected(&mark, wait)))
    }

    /// Where the service's log is now, so only what it gains afterwards counts.
    fn log_mark(&self) -> Result<LogMark> {
        Ok(LogMark {
            offset: std::fs::metadata(self.log_file()).map(|m| m.len()).unwrap_or(0),
            since: format!("@{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs()),
        })
    }

    /// Waits up to `wait` for the service's log, after `mark`, to say it connected, and
    /// returns the runner id it connected as.
    fn wait_connected(&self, mark: &LogMark, wait: Duration) -> Option<String> {
        let start = Instant::now();
        loop {
            let text = match self.manager {
                Manager::Launchd => log_since(&self.log_file(), mark.offset),
                Manager::Systemd => {
                    quiet(&["journalctl", "--user", "-u", "maple-runner", "--since", &mark.since, "-o", "cat", "--no-pager"]).unwrap_or_default()
                }
            };
            if let Some(id) = connected_as(&text) {
                return Some(id);
            }
            if start.elapsed() >= wait {
                return None;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    }

    /// The command that restarts the service: it stops the running runner and starts it
    /// again (and starts it if it had stopped).
    fn restart_command(&self) -> Vec<String> {
        match self.manager {
            Manager::Launchd => args(&["launchctl", "kickstart", "-k", &format!("{}/{LAUNCHD_LABEL}", self.domain)]),
            Manager::Systemd => args(&["systemctl", "--user", "restart", "maple-runner"]),
        }
    }

    /// Restarts the service and waits up to `wait` for it to connect. Returns the runner id it
    /// connected as, or `None` if its log doesn't say it connected in time.
    pub fn restart(&self, wait: Duration) -> Result<Option<String>> {
        if !self.file.exists() {
            bail!("the service isn't installed (run `maple-runner install`)");
        }
        let mark = self.log_mark()?;
        run(&self.restart_command())?;
        Ok(self.wait_connected(&mark, wait))
    }
}

/// What `Service::start` did.
pub enum Start {
    /// Started it; the runner id it connected as, if it did in time.
    Started(Option<String>),
    /// It was already running, with this pid.
    AlreadyRunning(u32),
    DryRun,
}

/// A place in the service's log: a byte offset in launchd's file, a `--since` for journalctl.
struct LogMark {
    offset: u64,
    since: String,
}

/// How to turn on systemd lingering, without which a user service stops when the last
/// session (an SSH login, say) ends and doesn't start until someone logs in again.
#[derive(Debug, PartialEq)]
pub enum LingerPlan {
    /// A command that can run here without a password.
    Run(Vec<String>),
    /// The command for the user to run themselves.
    Print(String),
}

pub fn linger_plan(is_root: bool, sudo_nopasswd: bool, user: &str) -> LingerPlan {
    if is_root {
        LingerPlan::Run(args(&["loginctl", "enable-linger", user]))
    } else if sudo_nopasswd {
        LingerPlan::Run(args(&["sudo", "-n", "loginctl", "enable-linger", user]))
    } else {
        LingerPlan::Print(linger_command(user))
    }
}

/// The exact command that turns lingering on for `user`.
pub fn linger_command(user: &str) -> String {
    format!("sudo loginctl enable-linger {user}")
}

/// What `status` says when lingering is off.
pub fn linger_warning(user: &str) -> String {
    format!("lingering is off: the runner stops when you log out and won't start at boot; run {}", linger_command(user))
}

/// `Linger=` from `loginctl show-user <user> -p Linger`.
pub fn parse_linger(show: &str) -> Option<bool> {
    match show.lines().find_map(|l| l.trim().strip_prefix("Linger="))? {
        "yes" => Some(true),
        "no" => Some(false),
        _ => None,
    }
}

/// Whether lingering is on for `user`; `None` when loginctl can't say (no logind, say).
/// A user with no session and no lingering isn't known to logind at all, which is "off".
pub fn linger_enabled(user: &str) -> Option<bool> {
    if let Some(out) = quiet(&["loginctl", "show-user", user, "-p", "Linger"]) {
        return parse_linger(&out);
    }
    // logind lists lingering users as files here, session or not.
    if Path::new("/var/lib/systemd/linger").is_dir() {
        return Some(Path::new("/var/lib/systemd/linger").join(user).exists());
    }
    None
}

pub enum LingerStep {
    AlreadyOn,
    Plan(LingerPlan),
    /// Running it failed: the command to run by hand, and why.
    Failed(String, String),
}

/// Turns lingering on if it's off and that can be done without a password (or, with
/// `dry_run`, says what would happen). Never fails: the worst case is a command to print.
pub fn linger_step(user: &str, dry_run: bool) -> LingerStep {
    if linger_enabled(user) == Some(true) {
        return LingerStep::AlreadyOn;
    }
    let plan = linger_plan(is_root(), sudo_nopasswd(), user);
    if let (LingerPlan::Run(cmd), false) = (&plan, dry_run)
        && let Err(e) = run(cmd)
    {
        return LingerStep::Failed(linger_command(user), format!("{e:#}"));
    }
    LingerStep::Plan(plan)
}

pub fn current_user() -> String {
    std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .ok()
        .filter(|u| !u.is_empty())
        .or_else(|| quiet(&["id", "-un"]).map(|s| s.trim().to_string()))
        .unwrap_or_default()
}

pub fn is_root() -> bool {
    quiet(&["id", "-u"]).is_some_and(|s| s.trim() == "0")
}

/// Whether `sudo` is here and works without a password.
pub fn sudo_nopasswd() -> bool {
    Command::new("sudo")
        .args(["-n", "true"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Whether `systemctl show -p ActiveState` says the unit is up or coming up (including
/// waiting to be restarted after a crash).
fn systemd_loaded(show: &str) -> bool {
    show.lines().find_map(|l| l.trim().strip_prefix("ActiveState=")).is_some_and(|s| !matches!(s, "inactive" | "failed" | ""))
}

/// The service's pid from `launchctl print`, if it says the job is running.
pub fn launchd_pid(print: &str) -> Option<u32> {
    let field = |name: &str| print.lines().find_map(|l| l.trim().strip_prefix(name).map(str::trim));
    if field("state = ")? != "running" {
        return None;
    }
    field("pid = ")?.parse().ok()
}

/// The service's pid from `systemctl show -p ActiveState -p MainPID`, if it's active.
pub fn systemd_pid(show: &str) -> Option<u32> {
    let field = |name: &str| show.lines().find_map(|l| l.trim().strip_prefix(name));
    if field("ActiveState=")? != "active" {
        return None;
    }
    field("MainPID=")?.parse().ok().filter(|&pid| pid != 0)
}

/// The log file's text after `offset` bytes (all of it if it has since been truncated).
fn log_since(log: &Path, offset: u64) -> String {
    let Ok(bytes) = std::fs::read(log) else { return String::new() };
    let start = if (bytes.len() as u64) < offset { 0 } else { offset as usize };
    String::from_utf8_lossy(&bytes[start..]).into_owned()
}

/// The runner id from the last "connected to <url> as <id>" line in a runner's log, with
/// or without tracing's timestamp and level in front ("disconnected" doesn't count).
pub fn connected_as(log: &str) -> Option<String> {
    log.lines().rev().find_map(|line| {
        let rest = line.strip_prefix("connected to ").or_else(|| line.split_once(" connected to ").map(|(_, r)| r))?;
        let (_, id) = rest.rsplit_once(" as ")?;
        let id = id.trim();
        (!id.is_empty()).then(|| id.to_string())
    })
}

/// The current user's id, for launchd's `gui/<uid>` domain.
fn uid() -> Result<u32> {
    let out = Command::new("id").arg("-u").output().context("running `id -u`")?;
    String::from_utf8_lossy(&out.stdout).trim().parse().context("reading the user id")
}

fn args(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| s.to_string()).collect()
}

fn run(cmd: &[String]) -> Result<()> {
    let out = Command::new(&cmd[0]).args(&cmd[1..]).output().with_context(|| format!("running {}", cmd[0]))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        bail!("`{}` failed: {}", cmd.join(" "), err.trim());
    }
    Ok(())
}

/// Stdout of a command that succeeded, or `None`.
fn quiet(cmd: &[&str]) -> Option<String> {
    let out = Command::new(cmd[0]).args(&cmd[1..]).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The service's PATH: the installing shell's absolute entries (so agents installed with
/// nvm, cargo and the like are found), then the usual places, without duplicates.
/// Per-shell and temporary directories are left out; they won't exist after a reboot.
pub fn service_path(home: &Path, current: Option<&str>) -> String {
    let mut out: Vec<String> = Vec::new();
    let defaults = DEFAULT_PATH.iter().map(|p| match p.strip_prefix("~/") {
        Some(rest) => home.join(rest).to_string_lossy().into_owned(),
        None => p.to_string(),
    });
    for entry in current.unwrap_or("").split(':').map(str::to_string).chain(defaults) {
        if entry.starts_with('/') && !ephemeral(&entry) && !out.contains(&entry) {
            out.push(entry);
        }
    }
    out.join(":")
}

fn ephemeral(dir: &str) -> bool {
    const PREFIXES: &[&str] = &["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", "/var/run/"];
    PREFIXES.iter().any(|p| dir.starts_with(p)) || dir.contains("/fnm_multishells/")
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// A launchd user agent: started at login, restarted whenever it exits with a failure
/// status, which includes the 75 a runner exits with after updating itself. A clean exit
/// (status 0, a runner replaced by another with its name) leaves it stopped.
pub fn launchd_plist(exe: &Path, home: &Path, log: &Path, path: &str) -> String {
    let exe = xml_escape(&exe.to_string_lossy());
    let home = xml_escape(&home.to_string_lossy());
    let log = xml_escape(&log.to_string_lossy());
    let path = xml_escape(path);
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>{LAUNCHD_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>{exe}</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>WorkingDirectory</key>
	<string>{home}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>{home}</string>
		<key>PATH</key>
		<string>{path}</string>
		<key>LANG</key>
		<string>en_US.UTF-8</string>
	</dict>
	<key>StandardOutPath</key>
	<string>{log}</string>
	<key>StandardErrorPath</key>
	<string>{log}</string>
</dict>
</plist>
"#
    )
}

/// Quotes a value for a systemd unit file (`%` is a specifier there).
fn systemd_quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"").replace('%', "%%"))
}

/// A systemd user unit: started with the user's session, restarted after any non-zero exit
/// (a crash, or the 75 a runner exits with after updating itself).
pub fn systemd_unit(exe: &Path, home: &Path, path: &str) -> String {
    let exe = systemd_quote(&exe.to_string_lossy());
    let home_env = systemd_quote(&format!("HOME={}", home.to_string_lossy()));
    let path_env = systemd_quote(&format!("PATH={path}"));
    format!(
        "[Unit]
Description=maple-runner: runs agent sessions for your Maple Factory
After=network-online.target

[Service]
ExecStart={exe} run
Restart=on-failure
RestartSec=5
Environment={home_env}
Environment={path_env}
Environment=\"LANG=C.UTF-8\"

[Install]
WantedBy=default.target
"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plist() {
        let text = launchd_plist(
            Path::new("/Users/a/bin/maple-runner"),
            Path::new("/Users/a"),
            Path::new("/Users/a/Library/Logs/maple-runner.log"),
            "/opt/homebrew/bin:/usr/bin:/bin",
        );
        assert!(text.contains("<string>dev.maplefactory.runner</string>"));
        assert!(text.contains("<array>\n\t\t<string>/Users/a/bin/maple-runner</string>\n\t\t<string>run</string>\n\t</array>"), "{text}");
        assert!(text.contains("<key>RunAtLoad</key>\n\t<true/>"));
        // Restart after a crash, not after a clean exit (a runner replaced by another with its name).
        assert!(text.contains("<key>KeepAlive</key>\n\t<dict>\n\t\t<key>SuccessfulExit</key>\n\t\t<false/>"), "{text}");
        assert!(text.contains("<key>HOME</key>\n\t\t<string>/Users/a</string>"));
        assert!(text.contains("<key>PATH</key>\n\t\t<string>/opt/homebrew/bin:/usr/bin:/bin</string>"));
        assert!(text.contains("<key>StandardOutPath</key>\n\t<string>/Users/a/Library/Logs/maple-runner.log</string>"));
        assert!(text.contains("<key>StandardErrorPath</key>\n\t<string>/Users/a/Library/Logs/maple-runner.log</string>"));
        // Only `run`: everything else comes from runner.json.
        assert_eq!(text.matches("<string>/Users/a/bin/maple-runner</string>").count(), 1);
        assert!(!text.contains("--"));
    }

    #[test]
    fn plist_escapes_paths() {
        let text = launchd_plist(Path::new("/Users/a&b/<x>"), Path::new("/Users/a&b"), Path::new("/l"), "/bin");
        assert!(text.contains("<string>/Users/a&amp;b/&lt;x&gt;</string>"));
        assert!(!text.contains("a&b"));
    }

    #[test]
    fn unit() {
        let text = systemd_unit(Path::new("/home/a/.cargo/bin/maple-runner"), Path::new("/home/a"), "/usr/bin:/bin");
        assert!(text.contains("\nExecStart=\"/home/a/.cargo/bin/maple-runner\" run\n"), "{text}");
        assert!(text.contains("\nDescription=maple-runner: runs agent sessions for your Maple Factory\n"));
        assert!(text.contains("\nRestart=on-failure\n"));
        assert!(text.contains("\nEnvironment=\"HOME=/home/a\"\n"));
        assert!(text.contains("\nEnvironment=\"PATH=/usr/bin:/bin\"\n"));
        assert!(text.contains("[Install]\nWantedBy=default.target\n"));
    }

    #[test]
    fn unit_quotes_odd_paths() {
        let text = systemd_unit(Path::new("/home/a b/100%/maple\"runner"), Path::new("/home/a b"), "/bin");
        assert!(text.contains("ExecStart=\"/home/a b/100%%/maple\\\"runner\" run\n"), "{text}");
    }

    #[test]
    fn installs_a_copy() {
        let dir = std::env::temp_dir().join(format!("maple-install-test-{}", uuid::Uuid::new_v4()));
        let home = dir.join("home");
        let dest = installed_exe_in(&home);
        assert!(dest.ends_with(".local/share/maple/bin/maple-runner"));
        assert!(dest.starts_with(&home));

        let src = dir.join("build/maple-runner");
        std::fs::create_dir_all(src.parent().unwrap()).unwrap();
        std::fs::write(&src, b"first").unwrap();
        assert!(!is_installed_copy(&src, &dest));
        copy_binary(&src, &dest).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"first");
        assert_eq!(std::fs::metadata(&dest).unwrap().permissions().mode() & 0o777, 0o755);
        assert!(is_installed_copy(&dest, &dest));
        assert!(is_installed_copy(&dest.parent().unwrap().join("../bin/maple-runner"), &dest));
        assert!(!is_installed_copy(&src, &dest));

        // Reinstalling replaces it, leaving no temporary file behind.
        std::fs::write(&src, b"second").unwrap();
        copy_binary(&src, &dest).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"second");
        assert_eq!(std::fs::read_dir(dest.parent().unwrap()).unwrap().count(), 1);

        assert!(copy_binary(&dir.join("missing"), &dest).is_err());
        assert_eq!(std::fs::read(&dest).unwrap(), b"second");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn restart_commands() {
        let mac = Service::new(Manager::Launchd, PathBuf::from("/Users/a"), 501);
        assert_eq!(mac.restart_command(), ["launchctl", "kickstart", "-k", "gui/501/dev.maplefactory.runner"]);
        assert_eq!(mac.manager_name(), "launchd");
        assert_eq!(mac.file, Path::new("/Users/a/Library/LaunchAgents/dev.maplefactory.runner.plist"));
        let linux = Service::new(Manager::Systemd, PathBuf::from("/home/a"), 0);
        assert_eq!(linux.restart_command(), ["systemctl", "--user", "restart", "maple-runner"]);
        assert_eq!(linux.manager_name(), "systemd");
    }

    #[test]
    fn start_stop_commands() {
        let mac = Service::new(Manager::Launchd, PathBuf::from("/Users/a"), 501);
        assert_eq!(mac.stop_commands(), [["launchctl", "bootout", "gui/501/dev.maplefactory.runner"]]);
        assert_eq!(mac.start_commands(false), [["launchctl", "bootstrap", "gui/501", "/Users/a/Library/LaunchAgents/dev.maplefactory.runner.plist"]]);
        assert_eq!(mac.start_commands(true), [["launchctl", "kickstart", "gui/501/dev.maplefactory.runner"]]);
        let linux = Service::new(Manager::Systemd, PathBuf::from("/home/a"), 0);
        assert_eq!(linux.stop_commands(), [["systemctl", "--user", "stop", "maple-runner"]]);
        assert_eq!(linux.start_commands(false), [["systemctl", "--user", "start", "maple-runner"]]);
        assert_eq!(linux.start_commands(true), [["systemctl", "--user", "start", "maple-runner"]]);
    }

    #[test]
    fn systemd_load_states() {
        assert!(systemd_loaded("ActiveState=active\n"));
        assert!(systemd_loaded("ActiveState=activating\n"));
        assert!(!systemd_loaded("ActiveState=inactive\n"));
        assert!(!systemd_loaded("ActiveState=failed\n"));
        assert!(!systemd_loaded(""));
    }

    #[test]
    fn not_installed_says_install() {
        let svc = Service::new(Manager::Launchd, std::env::temp_dir().join(format!("maple-svc-test-{}", uuid::Uuid::new_v4())), 501);
        let stop = svc.stop(false).err().unwrap().to_string();
        assert!(stop.contains("maple-runner install"), "{stop}");
        let start = svc.start(Duration::from_secs(1), false).err().unwrap().to_string();
        assert!(start.contains("maple-runner install"), "{start}");
    }

    #[test]
    fn uninstall_plan_lists_everything() {
        let svc = Service::new(Manager::Launchd, PathBuf::from("/Users/a"), 501);
        let plan = svc.uninstall_plan();
        assert!(plan.contains("launchctl bootout gui/501/dev.maplefactory.runner"), "{plan}");
        assert!(plan.contains("Would remove /Users/a/Library/LaunchAgents/dev.maplefactory.runner.plist"), "{plan}");
        assert!(plan.contains("Would remove /Users/a/.local/share/maple/bin/maple-runner\n"), "{plan}");
        assert!(plan.contains("Would keep /Users/a/.local/share/maple/repos"), "{plan}");
        let svc = Service::new(Manager::Systemd, PathBuf::from("/home/a"), 0);
        let plan = svc.uninstall_plan();
        assert!(plan.contains("systemctl --user disable --now maple-runner"), "{plan}");
        assert!(plan.contains("systemctl --user daemon-reload"), "{plan}");
        assert!(plan.contains("Would remove /home/a/.config/systemd/user/maple-runner.service"), "{plan}");
        assert!(plan.contains("Would remove /home/a/.local/share/maple/bin/maple-runner"), "{plan}");
    }

    #[test]
    fn removes_the_installed_copy_but_keeps_repos() {
        let home = std::env::temp_dir().join(format!("maple-uninstall-test-{}", uuid::Uuid::new_v4()));
        let svc = Service::new(Manager::Systemd, home.clone(), 0);
        let (exe, link) = svc.installed_files();
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        std::fs::write(&exe, "bin").unwrap();
        std::fs::create_dir_all(link.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&exe, &link).unwrap();
        let repo = home.join(".local/share/maple/repos/acme/app/README.md");
        std::fs::create_dir_all(repo.parent().unwrap()).unwrap();
        std::fs::write(&repo, "work").unwrap();

        let removed = svc.remove_installed().unwrap();
        assert_eq!(removed, vec![link.clone(), exe.clone()]);
        assert!(!exe.exists() && !exe.parent().unwrap().exists() && std::fs::symlink_metadata(&link).is_err());
        assert_eq!(std::fs::read_to_string(&repo).unwrap(), "work");
        // Again: nothing left to remove, and that's fine.
        assert!(svc.remove_installed().unwrap().is_empty());

        // A ~/.local/bin/maple-runner that isn't our link stays.
        std::fs::write(&link, "someone else's").unwrap();
        assert!(svc.remove_installed().unwrap().is_empty());
        assert!(link.exists());
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn linger_plans() {
        assert_eq!(linger_plan(true, false, "maple"), LingerPlan::Run(args(&["loginctl", "enable-linger", "maple"])));
        assert_eq!(linger_plan(false, true, "maple"), LingerPlan::Run(args(&["sudo", "-n", "loginctl", "enable-linger", "maple"])));
        assert_eq!(linger_plan(false, false, "maple"), LingerPlan::Print("sudo loginctl enable-linger maple".into()));
        assert!(linger_warning("maple").ends_with("run sudo loginctl enable-linger maple"));
    }

    #[test]
    fn parses_linger() {
        assert_eq!(parse_linger("Linger=yes\n"), Some(true));
        assert_eq!(parse_linger("Linger=no\n"), Some(false));
        assert_eq!(parse_linger(""), None);
        assert_eq!(parse_linger("Linger=maybe"), None);
    }

    #[test]
    fn running_pids() {
        let print = "gui/501/dev.maplefactory.runner = {\n\tactive count = 1\n\tpath = /Users/a/Library/LaunchAgents/dev.maplefactory.runner.plist\n\ttype = LaunchAgent\n\tstate = running\n\n\tprogram = /Users/a/.local/share/maple/bin/maple-runner\n\tpid = 4121\n}";
        assert_eq!(launchd_pid(print), Some(4121));
        assert_eq!(launchd_pid(&print.replace("state = running", "state = not running")), None);
        assert_eq!(launchd_pid("state = running\n"), None);
        assert_eq!(systemd_pid("ActiveState=active\nMainPID=4121\n"), Some(4121));
        assert_eq!(systemd_pid("MainPID=0\nActiveState=inactive\n"), None);
        assert_eq!(systemd_pid("ActiveState=active\nMainPID=0\n"), None);
    }

    #[test]
    fn reads_connected_runner_from_log() {
        let log = "\x1b[2m2026-10-21T10:00:00Z\x1b[0m \x1b[32m INFO\x1b[0m maple-runner 0.6.0\n\
                   \x1b[2m2026-10-21T10:00:01Z\x1b[0m \x1b[32m INFO\x1b[0m connected to wss://factory.acme.dev/runner/connect as mbp-14\n";
        assert_eq!(connected_as(log).as_deref(), Some("mbp-14"));
        // journalctl -o cat prints the message alone.
        assert_eq!(connected_as("connected to ws://box:8787/runner/connect as box\n").as_deref(), Some("box"));
        assert_eq!(connected_as("INFO disconnected\nINFO reconnecting in 1s\n"), None);
        assert_eq!(connected_as(""), None);
    }

    #[test]
    fn reads_only_new_log_text() {
        let dir = std::env::temp_dir().join(format!("maple-log-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("maple-runner.log");
        assert_eq!(log_since(&log, 0), "");
        std::fs::write(&log, "connected to x as a\nnew\n").unwrap();
        assert_eq!(log_since(&log, 20), "new\n");
        assert_eq!(log_since(&log, 1000), "connected to x as a\nnew\n");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn paths() {
        let home = Path::new("/Users/a");
        assert_eq!(
            service_path(home, Some("/Users/a/.nvm/bin:/usr/bin:relative::/opt/homebrew/bin:/private/tmp/x:/Users/a/.local/state/fnm_multishells/1_2/bin")),
            "/Users/a/.nvm/bin:/usr/bin:/opt/homebrew/bin:/Users/a/.local/bin:/usr/local/bin:/bin"
        );
        assert_eq!(service_path(home, None), "/Users/a/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin");
    }
}
