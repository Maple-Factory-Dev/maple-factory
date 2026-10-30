//! A repo's worktree scripts (Settings › Repositories in the apps): its own commands to make a task's
//! worktree, set it up, tear it down or archive it, for teams that already have `bin/` scripts for
//! their worktrees. The hub sends them with `session.open`'s `task` and with `task.cleanup`.
//!
//! - `create` makes the worktree in place of `git worktree add`: it must leave a git worktree on
//!   `MAPLE_BRANCH` at `MAPLE_WORKTREE` (`worktrees::create_from` checks).
//! - `setup` runs once the worktree exists, whichever made it, before the agent starts.
//! - `teardown` runs before a finished task's worktree is removed.
//! - `archive` runs in place of the runner's own removal; the script owns the folder and the branch.
//!
//! Each runs with `sh -c` in the repo's main checkout, like a project check (`proof::run_check_env`:
//! its own process group, the login shell's PATH, stdout and stderr together and only their end
//! kept), with the MAPLE_* variables below and the repo's secrets in its environment. One that fails
//! or runs past its timeout (10 minutes unless the repo says) stops what it was part of, with its
//! output's end, secret values scrubbed out, as the reason.

use std::path::Path;
use std::time::Duration;

use anyhow::{Result, bail};

use crate::protocol::Outbound;
use crate::tasks::Emit;
pub use crate::wire::WorktreeScripts;

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(600);
/// The end of a failed script's output that goes into the error (and the app).
const ERROR_TAIL_LINES: usize = 40;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Create,
    Setup,
    Teardown,
    Archive,
}

impl Phase {
    pub fn name(self) -> &'static str {
        match self {
            Phase::Create => "create",
            Phase::Setup => "setup",
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

/// The command for `phase`, if the repo has one.
pub fn command(scripts: Option<&WorktreeScripts>, phase: Phase) -> Option<&str> {
    let s = scripts?;
    let c = match phase {
        Phase::Create => &s.create,
        Phase::Setup => &s.setup,
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
    /// The end of its output, scrubbed.
    pub tail: String,
}

impl Ran {
    /// Its line for the task's timeline.
    pub fn line(&self) -> String {
        format!("ran the {} script (`{}`) in {:.1}s", self.phase.name(), self.command, self.ms as f64 / 1000.0)
    }
}

/// Runs the repo's `phase` script, if it has one: None when it hasn't. An error says how it failed,
/// with the end of its output.
pub async fn run(scripts: Option<&WorktreeScripts>, phase: Phase, ctx: &Context<'_>) -> Result<Option<Ran>> {
    let Some(command) = command(scripts, phase) else { return Ok(None) };
    // Its secrets come out of anything it prints, here and in the runner's log.
    crate::secrets::remember(ctx.env.iter().map(|(_, v)| v));
    tracing::info!("task {}: running its {} script: {command}", ctx.task_id, phase.name());
    let limit = timeout(scripts);
    let r = crate::proof::run_check_env(ctx.root, command, ctx.path, &environment(phase, ctx), limit).await;
    let tail = scrub(&r.tail, ctx.env);
    let say = |text: String| {
        if let Some(emit) = ctx.emit {
            emit(Outbound::TaskProgress { task_id: ctx.task_id.to_string(), text });
        }
    };
    if r.passed() {
        let ran = Ran { phase, command: command.to_string(), ms: r.ms, tail };
        tracing::info!("task {}: {}", ctx.task_id, ran.line());
        say(ran.line());
        return Ok(Some(ran));
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

    fn scripts(setup: &str, timeout: Option<u32>) -> WorktreeScripts {
        WorktreeScripts { create: None, preflight: None, preflight_watch: None, setup: Some(setup.into()), teardown: None, archive: Some("  ".into()), timeout_secs: timeout }
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
    fn timeouts_and_blank_commands() {
        assert_eq!(timeout(None), DEFAULT_TIMEOUT);
        assert_eq!(timeout(Some(&scripts("x", Some(0)))), DEFAULT_TIMEOUT);
        assert_eq!(timeout(Some(&scripts("x", Some(90)))), Duration::from_secs(90));
        assert_eq!(command(Some(&scripts(" bin/setup ", None)), Phase::Setup), Some("bin/setup"));
        assert_eq!(command(Some(&scripts("x", None)), Phase::Archive), None);
        assert_eq!(command(Some(&scripts("x", None)), Phase::Create), None);
    }
}
