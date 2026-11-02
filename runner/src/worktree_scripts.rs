//! A repo's worktree scripts (Settings › Repositories in the apps): its own commands to make a task's
//! worktree, set it up, tear it down or archive it, for teams that already have `bin/` scripts for
//! their worktrees. The hub sends them with `session.open`'s `task` and with `task.cleanup`.
//!
//! - `create` makes the worktree in place of `git worktree add`: it must leave a git worktree on
//!   `MAPLE_BRANCH` at `MAPLE_WORKTREE` (`worktrees::create_from` checks).
//! - `preflight` sets up the machine (runtimes, brew, services) for the repo: in the new worktree,
//!   before setup, the first time this checkout is used and again when the command or one of its
//!   watched files changes (`preflight`).
//! - `setup` runs once the worktree exists, whichever made it, before the agent starts.
//! - `teardown` runs before a finished task's worktree is removed.
//! - `archive` runs in place of the runner's own removal; the script owns the folder and the branch.
//! - `checks` (one command per line: linters, formatters, lefthook) run in the worktree when a builder
//!   finishes, before anything is committed; the first that fails stops the finish (`checks`).
//!
//! Each runs with `sh -c` in the repo's main checkout (preflight in the worktree: a managed clone's
//! main checkout has no files), like a project check (`proof::run_check_env`:
//! its own process group, the login shell's PATH, stdout and stderr together and only their end
//! kept), with the MAPLE_* variables below and the repo's secrets in its environment. One that fails
//! or runs past its timeout (10 minutes unless the repo says) stops what it was part of, with its
//! output's end, secret values scrubbed out, as the reason.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::protocol::Outbound;
use crate::tasks::Emit;
pub use crate::wire::{CheckRun, NotRunCheck, NotRunKind, WorktreeScripts};

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(600);
/// The end of a failed script's output that goes into the error (and the app).
const ERROR_TAIL_LINES: usize = 40;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Create,
    Preflight,
    Setup,
    Checks,
    Teardown,
    Archive,
}

impl Phase {
    pub fn name(self) -> &'static str {
        match self {
            Phase::Create => "create",
            Phase::Preflight => "preflight",
            Phase::Setup => "setup",
            Phase::Checks => "checks",
            Phase::Teardown => "teardown",
            Phase::Archive => "archive",
        }
    }
}

/// A task's scripts and what they run with, before its worktree's path is known.
pub struct ForTask<'a> {
    pub scripts: &'a WorktreeScripts,
    pub task_id: &'a str,
    pub repo: Option<&'a str>,
    pub base: Option<&'a str>,
    pub env: &'a [(String, String)],
    pub emit: Option<Emit<'a>>,
    pub path: Option<&'a str>,
}

impl<'a> ForTask<'a> {
    pub fn context(&self, root: &'a Path, worktree: &'a Path, branch: &'a str) -> Context<'a> {
        Context { task_id: self.task_id, repo: self.repo, root, worktree, branch, base: self.base, env: self.env, emit: self.emit, path: self.path }
    }
}

/// The task a script runs for, and where.
pub struct Context<'a> {
    pub task_id: &'a str,
    /// owner/name, when the task has one.
    pub repo: Option<&'a str>,
    /// The repo's main checkout: where the script runs.
    pub root: &'a Path,
    pub worktree: &'a Path,
    pub branch: &'a str,
    pub base: Option<&'a str>,
    /// The repo's secrets.
    pub env: &'a [(String, String)],
    /// Where its `task.progress` line goes.
    pub emit: Option<Emit<'a>>,
    /// The PATH it runs with (None: the runner's own).
    pub path: Option<&'a str>,
}

/// The command for `phase`, if the repo has one (checks are many: `check_commands`).
pub fn command(scripts: Option<&WorktreeScripts>, phase: Phase) -> Option<&str> {
    let s = scripts?;
    let c = match phase {
        Phase::Create => &s.create,
        Phase::Preflight => &s.preflight,
        Phase::Setup => &s.setup,
        Phase::Checks => return None,
        Phase::Teardown => &s.teardown,
        Phase::Archive => &s.archive,
    };
    c.as_deref().map(str::trim).filter(|c| !c.is_empty())
}

pub fn timeout(scripts: Option<&WorktreeScripts>) -> Duration {
    scripts.and_then(|s| s.timeout_secs).filter(|&t| t > 0).map(|t| Duration::from_secs(t.into())).unwrap_or(DEFAULT_TIMEOUT)
}

/// The MAPLE_* variables a script sees, then the repo's secrets.
pub fn environment(phase: Phase, ctx: &Context<'_>) -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> = [
        ("MAPLE_REPO", ctx.repo.unwrap_or("").to_string()),
        ("MAPLE_REPO_ROOT", ctx.root.to_string_lossy().into_owned()),
        ("MAPLE_WORKTREE", ctx.worktree.to_string_lossy().into_owned()),
        ("MAPLE_BRANCH", ctx.branch.to_string()),
        ("MAPLE_BASE", ctx.base.unwrap_or("").to_string()),
        ("MAPLE_TASK_ID", ctx.task_id.to_string()),
        ("MAPLE_PHASE", phase.name().to_string()),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    // A secret can't stand in for one of the runner's own.
    env.extend(ctx.env.iter().filter(|(k, _)| !k.starts_with("MAPLE_")).cloned());
    env
}

/// How a script that passed went.
#[derive(Debug, Clone)]
pub struct Ran {
    pub phase: Phase,
    pub command: String,
    pub ms: u64,
    /// The end of its output, scrubbed. Only the tests read it today.
    #[allow(dead_code)]
    pub tail: String,
    /// Why it ran, for preflight.
    pub why: Option<String>,
}

impl Ran {
    /// Its line for the task's timeline.
    pub fn line(&self) -> String {
        let why = self.why.as_deref().map(|w| format!(" ({w})")).unwrap_or_default();
        format!("ran the {} script (`{}`) in {:.1}s{why}", self.phase.name(), self.command, self.ms as f64 / 1000.0)
    }
}

/// Runs the repo's `phase` script, if it has one: None when it hasn't. An error says how it failed,
/// with the end of its output.
pub async fn run(scripts: Option<&WorktreeScripts>, phase: Phase, ctx: &Context<'_>) -> Result<Option<Ran>> {
    let Some(command) = command(scripts, phase) else { return Ok(None) };
    run_in(ctx.root, scripts, phase, command, None, ctx).await.map(Some)
}

/// Runs `command` for `phase` in `dir`; `why` goes on its timeline line.
async fn run_in(dir: &Path, scripts: Option<&WorktreeScripts>, phase: Phase, command: &str, why: Option<String>, ctx: &Context<'_>) -> Result<Ran> {
    // Its secrets come out of anything it prints, here and in the runner's log.
    crate::secrets::remember(ctx.env.iter().map(|(_, v)| v));
    tracing::info!("task {}: running its {} script: {command}", ctx.task_id, phase.name());
    let limit = timeout(scripts);
    let r = crate::proof::run_check_env(dir, command, ctx.path, &environment(phase, ctx), limit).await;
    let tail = scrub(&r.tail, ctx.env);
    let say = |text: String| {
        if let Some(emit) = ctx.emit {
            emit(Outbound::TaskProgress { task_id: ctx.task_id.to_string(), text });
        }
    };
    if r.passed() {
        let ran = Ran { phase, command: command.to_string(), ms: r.ms, tail, why };
        tracing::info!("task {}: {}", ctx.task_id, ran.line());
        say(ran.line());
        return Ok(ran);
    }
    let how = match (r.timed_out, r.code) {
        (true, _) => format!("was stopped after {}s", limit.as_secs()),
        (false, Some(code)) => format!("failed with exit code {code}"),
        (false, None) => "was killed".to_string(),
    };
    let lines: Vec<&str> = tail.lines().collect();
    let end = lines[lines.len().saturating_sub(ERROR_TAIL_LINES)..].join("\n");
    tracing::warn!("task {}: its {} script {how}: {end}", ctx.task_id, phase.name());
    say(format!("the {} script (`{command}`) {how}", phase.name()));
    if end.trim().is_empty() {
        bail!("The repo's {} script (`{command}`) {how}, with no output.", phase.name());
    }
    bail!("The repo's {} script (`{command}`) {how}:\n{end}", phase.name())
}

/// The repo's checks: one command per line, trimmed, blank lines skipped.
pub fn check_commands(scripts: Option<&WorktreeScripts>) -> Vec<&str> {
    scripts.and_then(|s| s.checks.as_deref()).unwrap_or("").lines().map(str::trim).filter(|c| !c.is_empty()).collect()
}

/// A check line split into the machine tags its `[macos, xcode] ` prefix asks for and its command.
/// A line with no prefix, or one that can't be read (the hub refuses those when they're saved), needs
/// nothing and runs as written, so it fails loudly instead of vanishing.
pub fn tagged(line: &str) -> (Vec<String>, &str) {
    let l = line.trim();
    let Some(rest) = l.strip_prefix('[') else { return (vec![], l) };
    let Some(close) = rest.find(']') else { return (vec![], l) };
    let tags: Vec<String> = rest[..close].split(',').map(|t| t.trim().to_string()).filter(|t| !t.is_empty()).collect();
    let command = rest[close + 1..].trim();
    if tags.is_empty() || command.is_empty() {
        return (vec![], l);
    }
    (tags, command)
}

/// The check this machine (with `have`) can't run, and why (`needs macos`); None: it can run it.
pub fn requirement_skip(line: &str, have: &[String]) -> Option<NotRunCheck> {
    let (tags, command) = tagged(line);
    let missing: Vec<&str> = tags.iter().filter(|t| !have.contains(t)).map(String::as_str).collect();
    (!missing.is_empty()).then(|| NotRunCheck {
        command: command.to_string(),
        reason: format!("needs {}", missing.join(", ")),
        kind: Some(NotRunKind::Requirement),
    })
}

/// The checks that weren't reached after one failed (`timed_out`: ran out of time).
pub fn not_reached<'a>(rest: impl IntoIterator<Item = &'a str>, timed_out: bool) -> Vec<NotRunCheck> {
    let (reason, kind) = if timed_out { ("timed out budget", NotRunKind::TimedOut) } else { ("skipped after an earlier failure", NotRunKind::AfterFailure) };
    rest.into_iter().map(|line| NotRunCheck { command: tagged(line).1.to_string(), reason: reason.into(), kind: Some(kind) }).collect()
}

/// Runs the repo's checks one after another in the worktree, stopping at the first that fails (exits
/// non-zero, is killed or runs past the timeout). Each comes back with its exit code and the scrubbed
/// end of its output; the last one failed when `passed` says not. A line tagged for what this machine
/// lacks (`[macos] xcodebuild test` on Linux) isn't run: it comes back in the second list with
/// `needs macos`, as do the checks after a failure, with why they weren't reached.
pub async fn checks(scripts: Option<&WorktreeScripts>, ctx: &Context<'_>) -> (Vec<CheckRun>, Vec<NotRunCheck>) {
    checks_with(scripts, ctx, &crate::capabilities::current()).await
}

/// `checks` for a machine with the tags `have`.
pub async fn checks_with(scripts: Option<&WorktreeScripts>, ctx: &Context<'_>, have: &[String]) -> (Vec<CheckRun>, Vec<NotRunCheck>) {
    crate::secrets::remember(ctx.env.iter().map(|(_, v)| v));
    let limit = timeout(scripts);
    let env = environment(Phase::Checks, ctx);
    let mut ran = Vec::new();
    let mut not_run = Vec::new();
    let all = check_commands(scripts);
    for (i, line) in all.iter().enumerate() {
        if let Some(skip) = requirement_skip(line, have) {
            let text = format!("check `{}` not run here: {}", skip.command, skip.reason);
            tracing::info!("task {}: {text}", ctx.task_id);
            if let Some(emit) = ctx.emit {
                emit(Outbound::TaskProgress { task_id: ctx.task_id.to_string(), text });
            }
            not_run.push(skip);
            continue;
        }
        let command = tagged(line).1;
        tracing::info!("task {}: running its check: {command}", ctx.task_id);
        let r = crate::proof::run_check_env(ctx.worktree, command, ctx.path, &env, limit).await;
        let lines: Vec<String> = scrub(&r.tail, ctx.env).lines().map(str::to_string).collect();
        let output = lines[lines.len().saturating_sub(ERROR_TAIL_LINES)..].join("\n");
        let run = CheckRun { command: command.to_string(), code: r.code, timed_out: r.timed_out, ms: r.ms, output };
        let line = match (passed(&run), run.timed_out, run.code) {
            (true, ..) => format!("check `{command}` passed in {:.1}s", run.ms as f64 / 1000.0),
            (false, true, _) => format!("check `{command}` was stopped after {}s", limit.as_secs()),
            (false, false, Some(code)) => format!("check `{command}` failed with exit code {code}"),
            (false, false, None) => format!("check `{command}` was killed"),
        };
        tracing::info!("task {}: {line}", ctx.task_id);
        if let Some(emit) = ctx.emit {
            emit(Outbound::TaskProgress { task_id: ctx.task_id.to_string(), text: line });
        }
        let ok = passed(&run);
        let timed_out = run.timed_out;
        ran.push(run);
        if !ok {
            not_run.extend(not_reached(all[i + 1..].iter().copied(), timed_out));
            break;
        }
    }
    (ran, not_run)
}

/// Whether a check exited 0.
pub fn passed(run: &CheckRun) -> bool {
    !run.timed_out && run.code == Some(0)
}

/// The files preflight watches when the repo doesn't say: the usual runtime and package pins.
pub const DEFAULT_WATCH: &[&str] = &[".ruby-version", ".tool-versions", ".node-version", ".nvmrc", ".python-version", "Brewfile", "mise.toml"];

/// The files that re-run preflight: the repo's list (one per line), else `DEFAULT_WATCH`. A path
/// outside the repo (absolute, or with `..`) is skipped; the hub refuses those anyway.
pub fn watched(scripts: &WorktreeScripts) -> Vec<String> {
    let mine: Vec<String> = scripts
        .preflight_watch
        .as_deref()
        .unwrap_or("")
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('/') && !l.starts_with('~') && !l.split(['/', '\\']).any(|p| p == ".."))
        .map(String::from)
        .collect();
    if mine.is_empty() { DEFAULT_WATCH.iter().map(|s| s.to_string()).collect() } else { mine }
}

/// What preflight last ran with on a checkout: its command's hash and each watched file's
/// (`absent` when it wasn't there). Kept in `<git-common-dir>/maple/preflight.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Stamp {
    command: String,
    files: BTreeMap<String, String>,
}

fn sha(bytes: &[u8]) -> String {
    crate::update::hex(&Sha256::digest(bytes))
}

impl Stamp {
    fn of(command: &str, worktree: &Path, files: &[String]) -> Stamp {
        let files = files.iter().map(|f| (f.clone(), std::fs::read(worktree.join(f)).map(|b| sha(&b)).unwrap_or_else(|_| "absent".into()))).collect();
        Stamp { command: sha(command.as_bytes()), files }
    }

    /// Why preflight runs again after `was`, or None when nothing it watches changed.
    fn why(&self, was: Option<&Stamp>) -> Option<String> {
        let Some(was) = was else { return Some("first run on this checkout".into()) };
        if was.command != self.command {
            return Some("the command changed".into());
        }
        let changed: Vec<&str> = self.files.iter().filter(|(f, h)| was.files.get(*f) != Some(*h)).map(|(f, _)| f.as_str()).collect();
        (!changed.is_empty()).then(|| format!("changed: {}", changed.join(", ")))
    }
}

/// One lock per checkout, so tasks starting together on a fresh clone run preflight once.
static LOCKS: LazyLock<Mutex<HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>>> = LazyLock::new(Default::default);

/// Where a checkout keeps its preflight stamp: its git common dir, shared by all its worktrees.
async fn stamp_path(worktree: &Path) -> Result<PathBuf> {
    let out = tokio::process::Command::new("git").arg("-C").arg(worktree).args(["rev-parse", "--path-format=absolute", "--git-common-dir"]).output().await?;
    if !out.status.success() {
        bail!("Couldn't find the git directory of {} for its preflight.", worktree.display());
    }
    let dir = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
    Ok(std::fs::canonicalize(&dir).unwrap_or(dir).join("maple").join("preflight.json"))
}

/// Runs the repo's preflight script in the new worktree when this checkout hasn't run it yet, or its
/// command or a watched file (as the worktree has it) changed since it last passed. None when there's
/// no preflight or nothing changed. Only a run that passes is stamped, so a failed one runs again on
/// the next task.
pub async fn preflight(scripts: &WorktreeScripts, ctx: &Context<'_>) -> Result<Option<Ran>> {
    let Some(command) = command(Some(scripts), Phase::Preflight) else { return Ok(None) };
    let at = stamp_path(ctx.worktree).await?;
    let lock = LOCKS.lock().unwrap().entry(at.clone()).or_default().clone();
    let _one = lock.lock().await;
    // Read under the lock: a task that waited sees the stamp the first one wrote.
    let was: Option<Stamp> = std::fs::read(&at).ok().and_then(|b| serde_json::from_slice(&b).ok());
    let now = Stamp::of(command, ctx.worktree, &watched(scripts));
    let Some(why) = now.why(was.as_ref()) else {
        tracing::info!("task {}: preflight is up to date on this checkout", ctx.task_id);
        return Ok(None);
    };
    let ran = run_in(ctx.worktree, Some(scripts), Phase::Preflight, command, Some(why), ctx).await?;
    if let Some(dir) = at.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(&at, serde_json::to_vec_pretty(&now)?)?;
    Ok(Some(ran))
}

/// `text` without the secret values in `env` (and every other one the runner was given).
fn scrub(text: &str, env: &[(String, String)]) -> String {
    let mut values: Vec<&str> = env.iter().map(|(_, v)| v.as_str()).filter(|v| v.len() >= 4).collect();
    values.sort_by_key(|v| std::cmp::Reverse(v.len()));
    let text = values.into_iter().fold(text.to_string(), |t, v| t.replace(v, "***"));
    crate::secrets::scrub(&text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::Mutex;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("maple-wts-{tag}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn sha_is_lowercase_hex_of_sha256() {
        // Stored preflight stamps hold these strings, so the format can't drift across sha2 bumps.
        assert_eq!(sha(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(sha(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    }

    fn scripts(setup: &str, timeout: Option<u32>) -> WorktreeScripts {
        WorktreeScripts {
            create: None,
            preflight: None,
            preflight_watch: None,
            setup: Some(setup.into()),
            checks: None,
            teardown: None,
            archive: Some("  ".into()),
            timeout_secs: timeout,
            require_paths: None,
        }
    }

    #[tokio::test]
    async fn runs_in_the_repo_root_with_the_maple_variables_and_secrets() {
        let root = tmp("env");
        let wt = root.join("wt");
        let env = vec![("API_KEY".to_string(), "sk-secret-value-123".to_string()), ("MAPLE_TASK_ID".to_string(), "spoofed".to_string())];
        let sent = Mutex::new(Vec::new());
        let emit = |m: Outbound| sent.lock().unwrap().push(serde_json::to_value(&m).unwrap());
        let ctx = Context {
            task_id: "MF-1",
            repo: Some("acme/web"),
            root: &root,
            worktree: &wt,
            branch: "agent/mf-1",
            base: Some("main"),
            env: &env,
            emit: Some(&emit),
            path: None,
        };
        let s = scripts("pwd > where; env | grep -E '^(MAPLE_|API_KEY)' | sort > vars; echo key is $API_KEY", None);
        let ran = run(Some(&s), Phase::Setup, &ctx).await.unwrap().unwrap();
        assert_eq!(std::fs::canonicalize(std::fs::read_to_string(root.join("where")).unwrap().trim()).unwrap(), std::fs::canonicalize(&root).unwrap());
        let vars = std::fs::read_to_string(root.join("vars")).unwrap();
        for want in [
            "API_KEY=sk-secret-value-123",
            "MAPLE_BASE=main",
            "MAPLE_BRANCH=agent/mf-1",
            "MAPLE_PHASE=setup",
            "MAPLE_REPO=acme/web",
            &format!("MAPLE_REPO_ROOT={}", root.display()),
            "MAPLE_TASK_ID=MF-1",
            &format!("MAPLE_WORKTREE={}", wt.display()),
        ] {
            assert!(vars.lines().any(|l| l == want), "{want} not in:\n{vars}");
        }
        // The output's end is kept, without the secret.
        assert_eq!(ran.tail, "key is ***");
        let lines = sent.lock().unwrap().clone();
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0]["type"], "task.progress");
        assert!(lines[0]["text"].as_str().unwrap().starts_with("ran the setup script (`pwd > where;"));
        // No archive command (blank), so nothing runs.
        assert!(run(Some(&s), Phase::Archive, &ctx).await.unwrap().is_none());
        assert!(run(None, Phase::Setup, &ctx).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn a_failure_says_how_with_the_scrubbed_end_of_its_output() {
        let root = tmp("fail");
        let env = vec![("DB_PASSWORD".to_string(), "hunter2-hunter2".to_string())];
        let ctx = Context { task_id: "MF-2", repo: None, root: &root, worktree: &root, branch: "agent/mf-2", base: None, env: &env, emit: None, path: None };
        let s = scripts("seq 1 100; echo \"can't reach db with $DB_PASSWORD\" >&2; exit 7", None);
        let e = format!("{:#}", run(Some(&s), Phase::Setup, &ctx).await.unwrap_err());
        assert!(e.starts_with("The repo's setup script (`seq 1 100;"), "{e}");
        assert!(e.contains("failed with exit code 7:\n"), "{e}");
        assert!(e.ends_with("100\ncan't reach db with ***"), "{e}");
        assert!(!e.contains("hunter2"), "{e}");
        // Only the end of a long output.
        assert!(!e.contains("\n50\n"), "{e}");
    }

    #[tokio::test]
    async fn a_script_past_its_timeout_is_stopped() {
        let root = tmp("slow");
        let ctx = Context { task_id: "MF-3", repo: None, root: &root, worktree: &root, branch: "agent/mf-3", base: None, env: &[], emit: None, path: None };
        let began = std::time::Instant::now();
        let e = format!("{:#}", run(Some(&scripts("echo waiting; sleep 30", Some(1))), Phase::Setup, &ctx).await.unwrap_err());
        assert!(began.elapsed() < Duration::from_secs(10));
        assert!(e.contains("setup script (`echo waiting; sleep 30`) was stopped after 1s"), "{e}");
        assert!(e.contains("waiting"), "{e}");
    }

    #[test]
    fn preflight_watches_the_repos_files_or_the_usual_pins() {
        let mut s = scripts("x", None);
        assert_eq!(watched(&s), DEFAULT_WATCH);
        s.preflight_watch = Some(" Gemfile.lock \n\n/etc/hosts\n../up\n~/.zshrc\nconfig/.tool-versions\n".into());
        assert_eq!(watched(&s), ["Gemfile.lock", "config/.tool-versions"]);
        s.preflight_watch = Some("/only/outside".into());
        assert_eq!(watched(&s), DEFAULT_WATCH);
        assert_eq!(command(Some(&s), Phase::Preflight), None);
        s.preflight = Some(" mise install ".into());
        assert_eq!(command(Some(&s), Phase::Preflight), Some("mise install"));
    }

    #[test]
    fn timeouts_and_blank_commands() {
        assert_eq!(timeout(None), DEFAULT_TIMEOUT);
        assert_eq!(timeout(Some(&scripts("x", Some(0)))), DEFAULT_TIMEOUT);
        assert_eq!(timeout(Some(&scripts("x", Some(90)))), Duration::from_secs(90));
        assert_eq!(command(Some(&scripts(" bin/setup ", None)), Phase::Setup), Some("bin/setup"));
        assert_eq!(command(Some(&scripts("x", None)), Phase::Archive), None);
        assert_eq!(command(Some(&scripts("x", None)), Phase::Create), None);
    }
}
