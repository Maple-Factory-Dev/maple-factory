//! Starting a task from GitHub's copy of its branch, and finishing it: commit what the agent left,
//! push its branch, and say how it went.
//!
//! When a task starts (`session.open` with `task`), the runner finds the checkout (the task's folder,
//! else this machine's checkout of its project's repo, else a fresh clone; see `start`), fetches the
//! base branch from GitHub and makes the worktree from `origin/<base>`, never from local state.
//!
//! The hub sends `task.finish` once the agent is done (for a task with Done when items, once the
//! project's checks have passed: `task.prove`, see `proof`). In the task's worktree the runner commits
//! any uncommitted changes with the task's title as the whole message (nothing added to it, and
//! with the machine's own git identity), works out the GitHub repository from `origin`, asks the hub
//! for a short-lived GitHub App token for that one repository (`task.token_request` / `task.token`),
//! and pushes with it:
//!
//! ```text
//! git -c credential.helper= push https://x-access-token:<token>@github.com/<owner>/<repo>.git HEAD:refs/heads/<branch>
//! ```
//!
//! The token only ever appears in that one command's arguments: never in git config, never in a
//! remote, never in a log or an error message (`scrub`), and `credential.helper=` keeps a keychain
//! helper from saving it. When origin isn't GitHub, or the app isn't installed there, the task fails
//! with a clear message, unless the user turned on the fallback: then the branch is pushed to origin
//! with the machine's own git credentials, and there's no pull request. The hub opens the PR.

use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use serde::Deserialize;
use tokio::process::Command;
use tokio::sync::oneshot;
use uuid::Uuid;

use crate::protocol::Outbound;
use crate::sessions::{Sessions, expand_home};
use crate::worktrees::{BRANCH_PREFIX, valid_name};

/// Testing only: push here instead of github.com, e.g. `/tmp/remotes/{owner}/{repo}.git`.
/// The token isn't used then.
pub const PUSH_URL_ENV: &str = "MAPLE_TASK_PUSH_URL";

const TOKEN_TIMEOUT: Duration = Duration::from_secs(60);
/// Commit hooks and pushes can take a while.
const GIT_TIMEOUT: Duration = Duration::from_secs(180);

/// `task.finish` from the hub.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Finish {
    pub task_id: String,
    /// The worktree, `~`-abbreviated.
    pub cwd: String,
    /// The repo folder the task was queued for.
    pub repo_dir: String,
    pub branch: String,
    #[serde(default)]
    pub base: Option<String>,
    pub title: String,
    /// Push with the machine's own credentials (and no PR) when the app can't.
    #[serde(default)]
    pub fallback: bool,
}

/// `task.cleanup` from the hub: the task's PR was merged or closed and its session has ended, so
/// remove the worktree and local branch if nothing would be lost (see `worktrees::remove_task`).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cleanup {
    pub task_id: String,
    /// The worktree, `~`-abbreviated.
    pub cwd: String,
    pub repo_dir: String,
    pub branch: String,
    #[serde(default)]
    pub merged: bool,
    /// The PR's head commit and the commit the task last pushed.
    #[serde(default)]
    pub heads: Vec<String>,
}

/// `task.diff` from the hub: what a task's branch changes against its base, for the apps' Diff tab.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffRequest {
    pub task_id: String,
    /// The worktree, `~`-abbreviated.
    pub cwd: String,
    pub base: String,
}

/// The longest patch sent; the server keeps it in a SQLite row.
const MAX_PATCH: usize = 1024 * 1024;

/// Answers with `task.diff`: per-file line counts and the unified patch (cut at `MAX_PATCH`).
pub async fn run_diff(sessions: Sessions, d: DiffRequest) {
    let dir = expand_home(&d.cwd);
    let range = format!("origin/{}...HEAD", d.base);
    let report = async {
        let numstat = git(&dir, &["diff", "--numstat", "--no-renames", &range], None).await?;
        let files = numstat
            .lines()
            .filter_map(|l| {
                let mut parts = l.splitn(3, '\t');
                let (added, removed, path) = (parts.next()?, parts.next()?, parts.next()?);
                // Binary files count as "-": no lines.
                Some(crate::wire::DiffStat { path: path.to_string(), added: added.parse().unwrap_or(0), removed: removed.parse().unwrap_or(0) })
            })
            .collect::<Vec<_>>();
        let mut patch = git(&dir, &["diff", "--no-color", "--no-ext-diff", "--no-renames", &range], None).await?;
        let truncated = patch.len() > MAX_PATCH;
        if truncated {
            let mut cut = MAX_PATCH;
            while !patch.is_char_boundary(cut) {
                cut -= 1;
            }
            patch.truncate(cut);
        }
        anyhow::Ok((files, patch, truncated))
    };
    sessions.emit(match report.await {
        Ok((files, patch, truncated)) => Outbound::Wire(crate::wire::RunnerMessage::TaskDiff {
            task_id: d.task_id,
            ok: true,
            files,
            patch,
            truncated,
            message: None,
        }),
        Err(e) => Outbound::Wire(crate::wire::RunnerMessage::TaskDiff {
            task_id: d.task_id,
            ok: false,
            files: vec![],
            patch: String::new(),
            truncated: false,
            message: Some(format!("{e:#}")),
        }),
    });
}

/// `task.merge` from the hub, for a repo with no GitHub App to merge its pull request: merge the
/// task's branch into its base on origin, with the machine's own credentials, as a merge commit.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Merge {
    pub task_id: String,
    /// The worktree, `~`-abbreviated.
    pub cwd: String,
    pub branch: String,
    pub base: String,
    /// The merge commit's message.
    pub title: String,
}

/// Runs a merge and answers with `task.merged`. The worktree goes back to the task's branch either way.
pub async fn run_merge(sessions: Sessions, m: Merge) {
    let dir = expand_home(&m.cwd);
    let merged = merge(&dir, &m).await;
    // A conflicted merge blocks the checkout until it's aborted.
    if merged.is_err() {
        let _ = git(&dir, &["merge", "--abort"], None).await;
    }
    let _ = git(&dir, &["checkout", "--quiet", &m.branch], None).await;
    sessions.emit(match merged {
        Ok(commit) => Outbound::TaskMerged { task_id: m.task_id, ok: true, commit: Some(commit), message: None },
        Err(e) => Outbound::TaskMerged { task_id: m.task_id, ok: false, commit: None, message: Some(format!("{e:#}")) },
    });
}

async fn merge(dir: &Path, m: &Merge) -> Result<String> {
    if !m.branch.starts_with(BRANCH_PREFIX) {
        bail!("{} isn't a task branch.", m.branch);
    }
    if !git(dir, &["status", "--porcelain"], None).await?.trim().is_empty() {
        bail!("The worktree has uncommitted changes.");
    }
    git(dir, &["fetch", "--quiet", "origin", &m.base], None).await?;
    git(dir, &["checkout", "--quiet", "--detach", &format!("origin/{}", m.base)], None).await?;
    git(dir, &["merge", "--no-ff", "--quiet", "-m", &m.title, &m.branch], None).await.map_err(|e| anyhow!("It doesn't merge cleanly into {}: {e}", m.base))?;
    git(dir, &["push", "--quiet", "origin", &format!("HEAD:refs/heads/{}", m.base)], None).await?;
    Ok(git(dir, &["rev-parse", "HEAD"], None).await?.trim().to_string())
}

/// Runs a cleanup and answers with `task.cleaned`.
pub async fn run_cleanup(sessions: Sessions, c: Cleanup) {
    let cwds: Vec<String> = sessions.list().into_iter().map(|s| s.cwd).collect();
    let work = crate::worktrees::TaskWork { cwd: &c.cwd, repo_dir: &c.repo_dir, branch: &c.branch, merged: c.merged, heads: &c.heads };
    let msg = match crate::worktrees::remove_task(&cwds, work).await {
        Ok(done) => {
            tracing::info!("task {}: {}", c.task_id, done.message);
            // Its evidence was uploaded long ago: the proof folder goes with the worktree.
            if let Some(home) = std::env::var_os("HOME").map(std::path::PathBuf::from) {
                match crate::proof::forget_folder(&home, &c.branch) {
                    Ok(true) => tracing::info!("task {}: removed its proof folder", c.task_id),
                    Ok(false) => {}
                    Err(e) => tracing::warn!("task {}: couldn't remove its proof folder: {e}", c.task_id),
                }
            }
            Outbound::TaskCleaned { task_id: c.task_id, ok: true, branch_deleted: done.branch_deleted, message: Some(done.message) }
        }
        Err(e) => {
            tracing::warn!("task {}: cleanup refused: {e:#}", c.task_id);
            Outbound::TaskCleaned { task_id: c.task_id, ok: false, branch_deleted: false, message: Some(format!("{e:#}")) }
        }
    };
    sessions.emit(msg);
}

/// The hub's answer to a token request.
pub struct TokenReply {
    pub token: Option<String>,
    pub error: Option<String>,
    pub code: Option<String>,
}

/// Sends a message to the hub (the session list's outbox, or a fake in tests).
pub(crate) type Emit<'a> = &'a (dyn Fn(Outbound) + Sync);

static PENDING: LazyLock<Mutex<HashMap<String, oneshot::Sender<TokenReply>>>> = LazyLock::new(Mutex::default);

/// The hub's `task.token`.
pub fn resolve(req_id: &str, reply: TokenReply) {
    if let Some(tx) = PENDING.lock().unwrap().remove(req_id) {
        let _ = tx.send(reply);
    }
}

/// Why the app can't push here (the fallback may still push).
enum NoApp {
    NotGitHub(String),
    NotInstalled(String),
}

async fn token(emit: Emit<'_>, task_id: &str, owner: &str, repo: &str, purpose: Option<&'static str>) -> Result<std::result::Result<String, NoApp>> {
    let req_id = Uuid::new_v4().to_string();
    let (tx, rx) = oneshot::channel();
    PENDING.lock().unwrap().insert(req_id.clone(), tx);
    emit(Outbound::TaskTokenRequest { req_id: req_id.clone(), task_id: task_id.into(), owner: owner.into(), repo: repo.into(), purpose });
    let reply = tokio::time::timeout(TOKEN_TIMEOUT, rx).await;
    PENDING.lock().unwrap().remove(&req_id);
    let reply = match reply {
        Ok(Ok(r)) => r,
        _ => bail!("The control plane didn't send a GitHub token in time."),
    };
    match (reply.token, reply.error, reply.code.as_deref()) {
        (Some(t), None, _) if !t.is_empty() => Ok(Ok(t)),
        (_, Some(e), Some("not_installed" | "no_app")) => Ok(Err(NoApp::NotInstalled(e))),
        (_, Some(e), _) => Err(anyhow!(e)),
        _ => bail!("The control plane sent back an empty token."),
    }
}

/// Runs `finish` and turns the outcome into `task.finished`.
pub async fn run(sessions: Sessions, f: Finish) {
    let task_id = f.task_id.clone();
    let emit = |m: Outbound| sessions.emit(m);
    let msg = match finish(&emit, &f).await {
        Ok(done) => done,
        Err(e) => {
            tracing::warn!("task {task_id}: {e:#}");
            Outbound::TaskFinished {
                task_id,
                ok: false,
                pushed: None,
                owner: None,
                repo: None,
                branch: f.branch.clone(),
                base: f.base.clone(),
                commit: None,
                reason: None,
                message: Some(format!("{e:#}")),
            }
        }
    };
    sessions.emit(msg);
}

async fn finish(emit: Emit<'_>, f: &Finish) -> Result<Outbound> {
    let dir = task_dir(&f.cwd, &f.branch, f.base.as_deref())?;

    // 1. Commit what's left uncommitted, as the user (their git config), with the title as the message.
    if !git(&dir, &["status", "--porcelain"], None).await?.trim().is_empty() {
        git(&dir, &["add", "-A"], None).await?;
        git(&dir, &["commit", "--quiet", "-m", &f.title], None).await.map_err(|e| anyhow!("Couldn't commit: {e}"))?;
    }
    let commit = git(&dir, &["rev-parse", "HEAD"], None).await?.trim().to_string();

    // 2. The branch the PR goes into: the task's, else what the repo folder has checked out.
    let base = match f.base.as_deref() {
        Some(b) => b.to_string(),
        None => git(&expand_home(&f.repo_dir), &["symbolic-ref", "--quiet", "--short", "HEAD"], None).await.map(|b| b.trim().to_string()).map_err(|_| {
            anyhow!("{} has no branch checked out, so there's nothing to open a pull request against. Give the task a base branch.", f.repo_dir)
        })?,
    };
    if let Some(n) = ahead_of(&dir, &base).await
        && n == 0
    {
        bail!("The agent didn't change anything (no commits beyond {base}), so there's nothing to push.");
    }

    // 3 and 4. Push: the app, else the fallback.
    let p = push(emit, &f.task_id, &dir, &f.branch, f.fallback, None).await?;
    Ok(finished(f, p.how, p.owner, p.repo, base, commit, p.reason))
}

/// The task's worktree, once its branch and base are known to be safe to hand to git.
fn task_dir(cwd: &str, branch: &str, base: Option<&str>) -> Result<std::path::PathBuf> {
    let name = branch.strip_prefix(BRANCH_PREFIX).ok_or_else(|| anyhow!("`{branch}` isn't a task branch."))?;
    valid_name(name)?;
    if let Some(b) = base
        && (b.starts_with('-') || b.trim().is_empty())
    {
        bail!("`{b}` isn't a branch.");
    }
    let dir = expand_home(cwd);
    if !dir.is_dir() {
        bail!("The task's worktree {cwd} is gone.");
    }
    Ok(dir)
}

/// How a branch was pushed.
struct Pushed {
    /// "app" or "fallback".
    how: &'static str,
    owner: Option<String>,
    repo: Option<String>,
    /// Why the app couldn't, when the fallback did.
    reason: Option<String>,
}

/// Pushes HEAD to `branch` on the GitHub repo behind origin with an app token, else (with `fallback`)
/// to origin with the machine's own credentials.
async fn push(emit: Emit<'_>, task_id: &str, dir: &Path, branch: &str, fallback: bool, purpose: Option<&'static str>) -> Result<Pushed> {
    let origin = git(dir, &["config", "--get", "remote.origin.url"], None).await.map(|u| u.trim().to_string()).ok();
    let target = match origin.as_deref() {
        None => Err(NoApp::NotGitHub("this repository has no origin remote".into())),
        Some(url) => match parse_github(url) {
            Some(r) => Ok(r),
            None => Err(NoApp::NotGitHub(format!("origin ({}) isn't on GitHub", redact_url(url)))),
        },
    };
    let refspec = format!("HEAD:refs/heads/{branch}");
    let no_app = match target {
        Ok((owner, repo)) => match token(emit, task_id, &owner, &repo, purpose).await? {
            Ok(token) => {
                let url = push_url(&owner, &repo, &token, std::env::var(PUSH_URL_ENV).ok().as_deref());
                git(dir, &["-c", "credential.helper=", "push", "--quiet", &url, &refspec], Some(&token))
                    .await
                    .map_err(|e| anyhow!("Couldn't push {branch} to {owner}/{repo}: {e}"))?;
                tracing::info!("task {task_id}: pushed {branch} to {owner}/{repo}");
                return Ok(Pushed { how: "app", owner: Some(owner), repo: Some(repo), reason: None });
            }
            Err(why) => why,
        },
        Err(why) => why,
    };
    let reason = match &no_app {
        NoApp::NotGitHub(r) => r.clone(),
        NoApp::NotInstalled(r) => r.trim_end_matches('.').to_string(),
    };
    if !fallback {
        bail!(
            "Can't push with the GitHub App: {reason}. To push such branches with this machine's own git credentials \
             (without a pull request), turn that on in Settings → Tasks."
        );
    }
    git(dir, &["push", "--quiet", "origin", &refspec], None).await.map_err(|e| anyhow!("Couldn't push {branch} to origin: {e}"))?;
    tracing::info!("task {task_id}: pushed {branch} to origin with this machine's credentials");
    Ok(Pushed { how: "fallback", owner: None, repo: None, reason: Some(reason) })
}

// ---- handing off ----

/// `task.handoff` from the hub: Retry is moving the task to another machine, which starts from the
/// branch as it is on GitHub, so push it first.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Handoff {
    pub task_id: String,
    /// The worktree, `~`-abbreviated.
    pub cwd: String,
    pub repo_dir: String,
    pub branch: String,
    #[serde(default)]
    pub base: Option<String>,
    pub title: String,
    #[serde(default)]
    pub fallback: bool,
}

/// Runs `handoff` and answers with `task.handed_off`.
pub async fn run_handoff(sessions: Sessions, h: Handoff) {
    let emit = |m: Outbound| sessions.emit(m);
    let msg = match handoff(&emit, &h).await {
        Ok((pushed, commit)) => Outbound::TaskHandedOff { task_id: h.task_id.clone(), ok: true, pushed: Some(pushed), commit: Some(commit), message: None },
        Err(e) => {
            tracing::warn!("task {}: hand-off failed: {e:#}", h.task_id);
            Outbound::TaskHandedOff { task_id: h.task_id.clone(), ok: false, pushed: None, commit: None, message: Some(format!("{e:#}")) }
        }
    };
    sessions.emit(msg);
}

/// Commits anything uncommitted as `WIP: <title>` (hooks skipped: it isn't the finished work) and
/// pushes the branch the way a finish does. Returns how it was pushed and the commit.
async fn handoff(emit: Emit<'_>, h: &Handoff) -> Result<(&'static str, String)> {
    let dir = task_dir(&h.cwd, &h.branch, h.base.as_deref())?;
    if !git(&dir, &["status", "--porcelain"], None).await?.trim().is_empty() {
        git(&dir, &["add", "-A"], None).await?;
        git(&dir, &["commit", "--quiet", "--no-verify", "-m", &format!("WIP: {}", h.title)], None).await.map_err(|e| anyhow!("Couldn't commit: {e}"))?;
    }
    let commit = git(&dir, &["rev-parse", "HEAD"], None).await?.trim().to_string();
    let base = match h.base.as_deref() {
        Some(b) => Some(b.to_string()),
        None => git(&expand_home(&h.repo_dir), &["symbolic-ref", "--quiet", "--short", "HEAD"], None).await.map(|b| b.trim().to_string()).ok(),
    };
    if let Some(base) = base
        && ahead_of(&dir, &base).await == Some(0)
    {
        bail!("it had no commits beyond {base}, so there was nothing to carry");
    }
    let p = push(emit, &h.task_id, &dir, &h.branch, h.fallback, Some("handoff")).await?;
    Ok((p.how, commit))
}

fn finished(f: &Finish, pushed: &'static str, owner: Option<String>, repo: Option<String>, base: String, commit: String, reason: Option<String>) -> Outbound {
    Outbound::TaskFinished {
        task_id: f.task_id.clone(),
        ok: true,
        pushed: Some(pushed),
        owner,
        repo,
        branch: f.branch.clone(),
        base: Some(base),
        commit: Some(commit),
        reason,
        message: None,
    }
}

/// Commits on HEAD that aren't on `base` (or `origin/<base>`); None if neither exists here.
async fn ahead_of(dir: &Path, base: &str) -> Option<u32> {
    for r in [base.to_string(), format!("origin/{base}")] {
        if let Ok(n) = git(dir, &["rev-list", "--count", &format!("{r}..HEAD")], None).await {
            return n.trim().parse().ok();
        }
    }
    None
}

/// `https://x-access-token:<token>@github.com/<owner>/<repo>.git`, or the test override.
pub fn push_url(owner: &str, repo: &str, token: &str, test_override: Option<&str>) -> String {
    match test_override.filter(|t| !t.is_empty()) {
        Some(t) => t.replace("{owner}", owner).replace("{repo}", repo),
        None => format!("https://x-access-token:{token}@github.com/{owner}/{repo}.git"),
    }
}

/// owner and repo from a GitHub remote URL, in any of its forms:
/// `git@github.com:o/r.git`, `ssh://git@github.com[:22]/o/r.git`, `https://[user@]github.com/o/r[.git]`,
/// `git://github.com/o/r.git`. None for anything else.
pub fn parse_github(url: &str) -> Option<(String, String)> {
    let url = url.trim();
    let path = if let Some(rest) = url.split_once("://").map(|(scheme, rest)| (scheme.to_ascii_lowercase(), rest)) {
        let (scheme, rest) = rest;
        if !matches!(scheme.as_str(), "https" | "http" | "ssh" | "git" | "git+ssh") {
            return None;
        }
        let (authority, path) = rest.split_once('/')?;
        let host = authority.rsplit('@').next()?;
        let host = host.split(':').next()?;
        if !is_github(host) {
            return None;
        }
        path
    } else {
        // scp-like: [user@]github.com:owner/repo.git
        let (host, path) = url.split_once(':')?;
        let host = host.rsplit('@').next()?;
        if !is_github(host) {
            return None;
        }
        path.trim_start_matches('/')
    };
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let mut parts = path.split('/');
    let (owner, repo) = (parts.next()?, parts.next()?);
    if parts.next().is_some() || !valid_part(owner) || !valid_part(repo) {
        return None;
    }
    Some((owner.to_string(), repo.to_string()))
}

fn is_github(host: &str) -> bool {
    host.eq_ignore_ascii_case("github.com") || host.eq_ignore_ascii_case("www.github.com")
}

fn valid_part(s: &str) -> bool {
    !s.is_empty() && s.len() <= 100 && s != "." && s != ".." && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// A URL with any password or token taken out, for messages.
fn redact_url(url: &str) -> String {
    match url.split_once("://") {
        Some((scheme, rest)) => match rest.split_once('@') {
            Some((creds, host)) if !creds.contains('/') => format!("{scheme}://***@{host}"),
            _ => url.to_string(),
        },
        None => url.to_string(),
    }
}

/// `text` with `secret` replaced, for anything that might reach a log or the UI.
pub fn scrub(text: &str, secret: Option<&str>) -> String {
    match secret.filter(|s| s.len() >= 8) {
        Some(s) => text.replace(s, "***"),
        None => text.to_string(),
    }
}

// ---- starting ----

/// Testing only: fetch and clone from here instead of github.com, e.g. `/tmp/remotes/{owner}/{repo}.git`.
/// `{token}` is replaced by the token, so a test can see where it goes.
pub const FETCH_URL_ENV: &str = "MAPLE_TASK_FETCH_URL";

/// One clone at a time, so two tasks in a repo this machine doesn't have don't both clone it. The
/// sweep of unused clones (`repos::sweep_once`) holds it too.
pub(crate) static CLONING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Where a starting task looks for its repo and gets it from.
pub struct Places {
    /// The folders `repos` scans, and the runner's own clones.
    pub roots: Vec<std::path::PathBuf>,
    pub managed: std::path::PathBuf,
    /// `FETCH_URL_ENV`.
    pub fetch_url: Option<String>,
}

impl Places {
    pub fn here() -> Places {
        Places { roots: crate::repos::roots(), managed: crate::repos::managed_dir(), fetch_url: std::env::var(FETCH_URL_ENV).ok() }
    }
}

/// Where a task's worktree came from.
#[derive(Debug, Clone, PartialEq)]
pub struct Started {
    /// The worktree, `~`-abbreviated.
    pub worktree: String,
    /// The checkout it was made from, `~`-abbreviated.
    pub repo_dir: String,
    /// The branch it started from, as it is on GitHub.
    pub base: String,
}

/// A task's `session.open`: its worktree, made from GitHub's copy of the base branch, and its prompt
/// with the project's settings in front (see `factory`) and its card's `images` as local files (see
/// `images`), whose paths come back for the agent's own flag. Tells the hub how that went (`task.started`).
pub async fn open(
    sessions: &Sessions,
    task: &crate::factory::TaskStart,
    cwd: &str,
    req: Option<&crate::worktrees::Request>,
    prompt: Option<&str>,
    images: &[String],
) -> Result<(String, Option<String>, Vec<String>)> {
    let req = req.ok_or_else(|| anyhow!("A task runs in its own worktree."))?;
    if req.existing {
        // Its builder again: the worktree as it is, and the prompt with its project's settings as before.
        let worktree = existing(cwd, req).await?;
        crate::trust::trust_worktree(&expand_home(&worktree));
        let p = crate::factory::prepare(&expand_home(&worktree), prompt, &task.projects).await;
        let (prompt, images) = crate::images::hand(&task.id, images, p.prompt).await;
        return Ok((worktree, prompt, images));
    }
    let emit = |m: Outbound| sessions.emit(m);
    let started = start(&emit, &task.id, cwd, task.repo.as_deref(), req, &Places::here()).await?;
    // A worktree the runner just made: Claude Code shouldn't stop to ask whether to trust it.
    crate::trust::trust_worktree(&expand_home(&started.worktree));
    let p = crate::factory::prepare(&expand_home(&started.worktree), prompt, &task.projects).await;
    sessions.emit(Outbound::TaskStarted {
        task_id: task.id.clone(),
        repo: p.repo,
        repo_dir: started.repo_dir,
        base: started.base,
        project: p.project,
        factory: p.factory,
        rules: p.rules,
    });
    let (prompt, images) = crate::images::hand(&task.id, images, p.prompt).await;
    Ok((started.worktree, prompt, images))
}

/// A task's worktree that's already there (`cwd`), for a new session in it: nothing is fetched or
/// branched, and it must still be on the task's branch, `agent/<name>`. One left on a detached HEAD
/// (a merge that didn't switch back) is put back on the branch first when nothing would be lost.
pub async fn existing(cwd: &str, req: &crate::worktrees::Request) -> Result<String> {
    valid_name(&req.name)?;
    let want = format!("{BRANCH_PREFIX}{}", req.name);
    let dir = expand_home(cwd);
    if !dir.is_dir() {
        bail!("The task's worktree {cwd} isn't there any more.");
    }
    let branch = git(&dir, &["rev-parse", "--abbrev-ref", "HEAD"], None).await.map_err(|_| anyhow!("{cwd} isn't a git worktree."))?;
    match branch.trim() {
        "HEAD" => reattach(&dir, cwd, &want).await?,
        b if b != want => bail!("{cwd} is on {b}, not the task's branch {want}."),
        _ => {}
    }
    Ok(cwd.to_string())
}

/// Puts a detached worktree back on `want`. A half-done merge is aborted, and a merge commit the push
/// never delivered may be dropped, but not a commit of real work that only HEAD holds.
async fn reattach(dir: &Path, cwd: &str, want: &str) -> Result<()> {
    let at = git(dir, &["rev-parse", "--short", "HEAD"], None).await.map(|s| s.trim().to_string()).unwrap_or_default();
    let stuck = |why: String| anyhow!("{cwd} is detached at {at}, not on the task's branch {want}: {why}");
    let local = format!("refs/heads/{want}");
    if git(dir, &["rev-parse", "--verify", "--quiet", &local], None).await.is_err() {
        return Err(stuck("the branch is gone.".into()));
    }
    let _ = git(dir, &["merge", "--abort"], None).await;
    let only_head = git(dir, &["rev-list", "--no-merges", "HEAD", "--not", &local, "--remotes"], None).await?;
    let n = only_head.lines().filter(|l| !l.trim().is_empty()).count();
    if n > 0 {
        return Err(stuck(format!("HEAD has {n} commit{} not on the branch, so it's left as it is.", if n == 1 { "" } else { "s" })));
    }
    git(dir, &["checkout", "--quiet", want], None).await.map_err(|e| stuck(format!("switching back failed ({e}).")))?;
    tracing::info!("{cwd} was detached at {at}: put it back on {want}");
    Ok(())
}

/// Makes a task's worktree. The checkout is the folder the task names, else this machine's checkout
/// of its repo (`repos::pick`), else a new clone in the runner's own folder. Either way the base
/// branch (the task's, else the repo's default branch on GitHub) is fetched first and the worktree
/// starts from `origin/<base>`, so nothing uncommitted or unpushed in the checkout ends up in it. A
/// fetch that fails fails the task: it never falls back to what the machine has. The task's own
/// branch is fetched too when GitHub has it (another machine pushed it before Retry moved the task
/// here): then the worktree carries on from it (`worktrees::create_from`).
pub async fn start(emit: Emit<'_>, task_id: &str, cwd: &str, repo: Option<&str>, req: &crate::worktrees::Request, at: &Places) -> Result<Started> {
    let fetch_override = at.fetch_url.as_deref();
    valid_name(&req.name)?;
    let base = req.base.as_deref().map(str::trim).filter(|b| !b.is_empty());
    let own = format!("{BRANCH_PREFIX}{}", req.name);
    let own = Some(own.as_str());
    let (root, base) = if !cwd.trim().is_empty() {
        let dir = expand_home(cwd);
        let root = crate::worktrees::main_root(&dir).await.map_err(|_| anyhow!("{cwd} isn't in a git repository, so there's no worktree to make."))?;
        let base = fetch_base(emit, task_id, &root, base, own, fetch_override).await?;
        (root, base)
    } else {
        let repo = repo.ok_or_else(|| anyhow!("The task names neither a folder nor a project."))?;
        let (owner, name) = repo.split_once('/').filter(|(o, n)| valid_part(o) && valid_part(n)).ok_or_else(|| anyhow!("`{repo}` isn't owner/name."))?;
        let _one = CLONING.lock().await;
        match crate::repos::pick(&crate::repos::scan(&at.roots, &at.managed).await, repo) {
            Some(c) => {
                let root = expand_home(&c.path);
                let base = fetch_base(emit, task_id, &root, base, own, fetch_override).await?;
                (root, base)
            }
            None => clone(emit, task_id, &at.managed, owner, name, base, own, fetch_override).await?,
        }
    };
    let worktree = crate::worktrees::create_from(&root, &req.name, &format!("origin/{base}")).await?;
    Ok(Started { worktree, repo_dir: crate::worktrees::abbreviate(&root), base })
}

/// Clones owner/name into `~/.local/share/maple/repos/<owner>/<name>`: an empty repository whose origin
/// is the plain GitHub URL, then the base fetched into it with a token (`fetch_base`). Nothing is
/// checked out there; tasks work in worktrees. A clone that fails leaves nothing behind.
#[allow(clippy::too_many_arguments)]
async fn clone(
    emit: Emit<'_>,
    task_id: &str,
    managed: &Path,
    owner: &str,
    name: &str,
    base: Option<&str>,
    own: Option<&str>,
    fetch_override: Option<&str>,
) -> Result<(std::path::PathBuf, String)> {
    let dest = managed.join(owner).join(name);
    if dest.exists() {
        bail!("{} is in the way of a clone of {owner}/{name}.", crate::worktrees::abbreviate(&dest));
    }
    // Dot folders aren't scanned, so a half-made clone is never reported.
    let partial = managed.join(".partial").join(Uuid::new_v4().to_string());
    std::fs::create_dir_all(&partial)?;
    let made = async {
        git(&partial, &["init", "--quiet"], None).await?;
        git(&partial, &["remote", "add", "origin", &format!("https://github.com/{owner}/{name}.git")], None).await?;
        fetch_base(emit, task_id, &partial, base, own, fetch_override).await
    }
    .await;
    let base = match made {
        Ok(base) => base,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&partial);
            return Err(e);
        }
    };
    std::fs::create_dir_all(dest.parent().unwrap_or(managed))?;
    std::fs::rename(&partial, &dest)?;
    tracing::info!("task {task_id}: cloned {owner}/{name} into {}", crate::worktrees::abbreviate(&dest));
    crate::repos::poke(false);
    Ok((dest, base))
}

/// Fetches `base` (default: the repo's default branch on GitHub) into `origin/<base>` and returns
/// its name. A GitHub repo is fetched with a read-only app token when the app is installed there
/// (the token only in this command's arguments, as for the push, and no FETCH_HEAD to keep the URL);
/// otherwise, or for another origin, from `origin` with the machine's own credentials. `own`, the
/// task's branch, comes along into `origin/<own>` when the remote has it (and a stale copy goes when
/// it doesn't); missing it isn't an error.
pub(crate) async fn fetch_base(
    emit: Emit<'_>,
    task_id: &str,
    root: &Path,
    base: Option<&str>,
    own: Option<&str>,
    fetch_override: Option<&str>,
) -> Result<String> {
    let origin = git(root, &["config", "--get", "remote.origin.url"], None).await.map(|u| u.trim().to_string()).ok();
    let origin = origin.ok_or_else(|| anyhow!("{} has no origin remote, so there's nothing to start the task from.", crate::worktrees::abbreviate(root)))?;
    let mut secret = None;
    let mut source = "origin".to_string();
    if let Some((owner, repo)) = parse_github(&origin) {
        // Without the app there (a public repo, or one this machine can reach itself): origin.
        if let Ok(t) = token(emit, task_id, &owner, &repo, Some("fetch")).await? {
            source = fetch_url(&owner, &repo, &t, fetch_override);
            secret = Some(t);
        }
    }
    let secret = secret.as_deref();
    let what = if source == "origin" { redact_url(&origin) } else { "GitHub".into() };
    let fail =
        |e: anyhow::Error| anyhow!("Couldn't fetch from {what}: {e}. A task starts only from the branch as it is there, never from this machine's copy.");
    let default = base.is_none();
    let base = match base {
        Some(b) => b.to_string(),
        None => {
            let head = git(root, &["-c", "credential.helper=", "ls-remote", "--symref", &source, "HEAD"], secret).await.map_err(fail)?;
            head.lines()
                .find_map(|l| l.strip_prefix("ref: refs/heads/").and_then(|r| r.strip_suffix("\tHEAD")))
                .map(str::to_string)
                .ok_or_else(|| anyhow!("{what} didn't say which branch is its default. Give the task a base branch."))?
        }
    };
    if base.starts_with('-') || git(root, &["check-ref-format", "--branch", &base], None).await.is_err() {
        bail!("`{base}` isn't a branch.");
    }
    let refspec = format!("+refs/heads/{base}:refs/remotes/origin/{base}");
    git(root, &["-c", "credential.helper=", "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", &source, &refspec], secret)
        .await
        .map_err(|e| anyhow!("Couldn't fetch {base} from {what}: {e}. A task starts only from the branch as it is there, never from this machine's copy."))?;
    if default {
        // Keep origin/HEAD naming GitHub's default branch: worktree reports and cleanups read it.
        let _ = git(root, &["symbolic-ref", "refs/remotes/origin/HEAD", &format!("refs/remotes/origin/{base}")], None).await;
    }
    if let Some(own) = own.filter(|b| b.starts_with(BRANCH_PREFIX) && *b != base) {
        let refspec = format!("+refs/heads/{own}:refs/remotes/origin/{own}");
        if git(root, &["-c", "credential.helper=", "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", &source, &refspec], secret).await.is_ok() {
            tracing::info!("task {task_id}: {what} has {own}, so it carries on from there");
        } else {
            let _ = git(root, &["update-ref", "-d", &format!("refs/remotes/origin/{own}")], None).await;
        }
    }
    Ok(base)
}

/// `https://x-access-token:<token>@github.com/<owner>/<repo>.git`, or the test override.
pub fn fetch_url(owner: &str, repo: &str, token: &str, test_override: Option<&str>) -> String {
    match test_override.filter(|t| !t.is_empty()) {
        Some(t) => t.replace("{owner}", owner).replace("{repo}", repo).replace("{token}", token),
        None => format!("https://x-access-token:{token}@github.com/{owner}/{repo}.git"),
    }
}

/// Runs git in `dir` without prompts; stdout, or stderr (scrubbed of `secret`) as the error.
async fn git(dir: &Path, args: &[&str], secret: Option<&str>) -> Result<String> {
    let mut cmd = Command::new("git");
    cmd.arg("-C").arg(dir).args(args).env("GIT_TERMINAL_PROMPT", "0").stdin(Stdio::null()).kill_on_drop(true);
    if secret.is_some() {
        // A fetch's reflog entries name what was fetched; with a token, say nothing about the URL.
        cmd.env("GIT_REFLOG_ACTION", "maple-runner fetch");
    }
    let out = tokio::time::timeout(GIT_TIMEOUT, cmd.output()).await.map_err(|_| anyhow!("git {} timed out", args.first().unwrap_or(&"")))??;
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    let err = scrub(&String::from_utf8_lossy(&out.stderr), secret);
    let err = err.lines().map(|l| l.trim_start_matches("fatal: ").trim_start_matches("error: ")).filter(|l| !l.trim().is_empty()).collect::<Vec<_>>().join(" ");
    // Only the subcommand: the arguments may hold the token.
    let what = args.iter().find(|a| !a.starts_with('-') && !a.contains('=')).unwrap_or(&"");
    Err(anyhow!("{}", if err.trim().is_empty() { format!("git {what} failed") } else { err.trim().to_string() }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_github_remotes() {
        let r = |owner: &str, repo: &str| Some((owner.to_string(), repo.to_string()));
        assert_eq!(parse_github("git@github.com:afomera/agents.git"), r("afomera", "agents"));
        assert_eq!(parse_github("git@github.com:afomera/agents"), r("afomera", "agents"));
        assert_eq!(parse_github("ssh://git@github.com/acme/widgets.git"), r("acme", "widgets"));
        assert_eq!(parse_github("ssh://git@github.com:22/acme/widgets.git/"), r("acme", "widgets"));
        assert_eq!(parse_github("https://github.com/acme/widgets.git"), r("acme", "widgets"));
        assert_eq!(parse_github("https://github.com/acme/widgets"), r("acme", "widgets"));
        assert_eq!(parse_github("https://someone:tok@github.com/acme/my.repo.git"), r("acme", "my.repo"));
        assert_eq!(parse_github("HTTPS://GitHub.com/Acme/Widgets.git"), r("Acme", "Widgets"));
        assert_eq!(parse_github("git://github.com/acme/widgets.git"), r("acme", "widgets"));
        for not in [
            "git@gitlab.com:acme/widgets.git",
            "https://github.com.evil.com/acme/widgets.git",
            "https://gitlab.com/acme/widgets.git",
            "/tmp/remotes/widgets.git",
            "file:///tmp/remotes/widgets.git",
            "../widgets.git",
            "https://github.com/acme",
            "https://github.com/acme/widgets/extra",
            "git@github.com:../x.git",
            "",
        ] {
            assert_eq!(parse_github(not), None, "{not}");
        }
    }

    #[test]
    fn push_url_carries_the_token_only_in_the_url() {
        assert_eq!(push_url("acme", "widgets", "ghs_abc123", None), "https://x-access-token:ghs_abc123@github.com/acme/widgets.git");
        assert_eq!(push_url("acme", "widgets", "ghs_abc123", Some("/tmp/r/{owner}/{repo}.git")), "/tmp/r/acme/widgets.git");
        assert_eq!(push_url("acme", "widgets", "ghs_abc123", Some("")), "https://x-access-token:ghs_abc123@github.com/acme/widgets.git");
    }

    #[test]
    fn scrubs_secrets() {
        let msg = "remote: denied to https://x-access-token:ghs_secret123@github.com/a/b.git";
        assert_eq!(scrub(msg, Some("ghs_secret123")), "remote: denied to https://x-access-token:***@github.com/a/b.git");
        assert_eq!(redact_url("https://user:pass@example.com/x.git"), "https://***@example.com/x.git");
        assert_eq!(redact_url("git@example.com:x.git"), "git@example.com:x.git");
    }

    #[test]
    fn finish_message_parses() {
        let f: Finish = serde_json::from_str(
            r#"{"taskId":"t1","session":"s","cwd":"~/x","repoDir":"~/r","branch":"agent/fix-1a2b","base":null,"title":"Fix it","fallback":true}"#,
        )
        .unwrap();
        assert_eq!((f.task_id.as_str(), f.base, f.fallback), ("t1", None, true));
    }

    /// The whole thing against local repos: commit with the title, then the fallback push to a bare origin.
    #[tokio::test]
    async fn commits_and_pushes_to_a_local_origin() {
        let root = std::env::temp_dir().join(format!("maple-task-{}", Uuid::new_v4()));
        let (bare, work) = (root.join("origin.git"), root.join("work"));
        std::fs::create_dir_all(&work).unwrap();
        let sh = |dir: &Path, args: &[&str]| {
            let out = std::process::Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
            assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        };
        sh(&root, &["init", "--quiet", "--bare", bare.to_str().unwrap()]);
        sh(&work, &["init", "--quiet", "-b", "main"]);
        sh(&work, &["config", "user.name", "Test Person"]);
        sh(&work, &["config", "user.email", "test@example.com"]);
        sh(&work, &["config", "commit.gpgsign", "false"]);
        std::fs::write(work.join("a.txt"), "one\n").unwrap();
        sh(&work, &["add", "-A"]);
        sh(&work, &["commit", "--quiet", "-m", "first"]);
        sh(&work, &["remote", "add", "origin", bare.to_str().unwrap()]);
        sh(&work, &["checkout", "--quiet", "-b", "agent/fix-1a2b"]);
        std::fs::write(work.join("a.txt"), "two\n").unwrap();

        // origin isn't GitHub, so no token is ever asked for.
        let emit = |m: Outbound| panic!("unexpected message {m:?}");
        let sessions: Emit = &emit;
        let f = Finish {
            task_id: "t1".into(),
            cwd: work.to_string_lossy().into_owned(),
            repo_dir: work.to_string_lossy().into_owned(),
            branch: "agent/fix-1a2b".into(),
            base: Some("main".into()),
            title: "Fix the flaky test".into(),
            fallback: false,
        };
        // Not GitHub, no fallback: a clear refusal, nothing pushed, but the commit is made.
        let err = format!("{:#}", finish(sessions, &f).await.unwrap_err());
        assert!(err.contains("isn't on GitHub") && err.contains("Settings → Tasks"), "{err}");
        assert_eq!(sh(&work, &["log", "-1", "--format=%B"]), "Fix the flaky test");
        assert_eq!(sh(&work, &["log", "-1", "--format=%an <%ae>"]), "Test Person <test@example.com>");
        assert!(sh(&bare, &["branch", "--list"]).is_empty());

        let pushed = finish(sessions, &Finish { fallback: true, ..f.clone() }).await.unwrap();
        let v = serde_json::to_value(&pushed).unwrap();
        assert_eq!((v["ok"].as_bool(), v["pushed"].as_str(), v["base"].as_str()), (Some(true), Some("fallback"), Some("main")));
        assert_eq!(sh(&bare, &["log", "-1", "--format=%B", "agent/fix-1a2b"]), "Fix the flaky test");

        // Nothing new: nothing to push.
        sh(&work, &["checkout", "--quiet", "-b", "agent/empty-0000", "main"]);
        let err = format!("{:#}", finish(sessions, &Finish { branch: "agent/empty-0000".into(), fallback: true, ..f.clone() }).await.unwrap_err());
        assert!(err.contains("didn't change anything"), "{err}");
        // A branch that isn't a task's is refused before git runs.
        assert!(finish(sessions, &Finish { branch: "--force".into(), ..f }).await.is_err());
        std::fs::remove_dir_all(&root).unwrap();
    }

    // ---- starting ----

    use crate::repos::tests::sh;
    use crate::worktrees::Request;

    fn tmp(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("maple-start-{tag}-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        // Real paths, so they compare with what git reports (/tmp is a symlink on macOS).
        std::fs::canonicalize(&dir).unwrap()
    }

    /// A bare "GitHub" repo at `bare` with one commit on main, made through a scratch clone; returns the commit.
    fn remote(bare: &Path, file: &str) -> String {
        std::fs::create_dir_all(bare).unwrap();
        sh(bare, &["init", "--quiet", "--bare", "-b", "main"]);
        let work = bare.with_extension("seed");
        std::fs::create_dir_all(&work).unwrap();
        sh(&work, &["init", "--quiet", "-b", "main"]);
        commit(&work, file, "one\n", "first");
        sh(&work, &["push", "--quiet", bare.to_str().unwrap(), "main"]);
        sh(&work, &["rev-parse", "HEAD"])
    }

    fn commit(dir: &Path, file: &str, text: &str, msg: &str) {
        std::fs::write(dir.join(file), text).unwrap();
        sh(dir, &["add", "-A"]);
        sh(dir, &["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", msg]);
    }

    fn places(root: &Path, fetch_url: Option<String>) -> Places {
        Places { roots: vec![root.join("Projects")], managed: root.join("managed"), fetch_url }
    }

    fn req(name: &str) -> Request {
        Request { name: name.into(), base: None, existing: false }
    }

    /// The builder again after a review: its worktree as it left it, with nothing fetched or branched,
    /// as long as it's still on the task's branch.
    #[tokio::test]
    async fn an_existing_worktree_is_opened_as_it_is() {
        let root = tmp("existing");
        let bare = root.join("remotes/widgets.git");
        remote(&bare, "a.txt");
        let checkout = root.join("Projects/widgets");
        sh(&root, &["clone", "--quiet", bare.to_str().unwrap(), checkout.to_str().unwrap()]);
        let emit = |m: Outbound| panic!("unexpected message {m:?}");
        let s = start(&emit, "t1", checkout.to_str().unwrap(), None, &req("fix-1a2b"), &places(&root, None)).await.unwrap();
        let wt = expand_home(&s.worktree);
        commit(&wt, "b.txt", "fixed\n", "the builder's work");
        std::fs::write(wt.join("b.txt"), "still editing\n").unwrap();
        let head = sh(&wt, &["rev-parse", "HEAD"]);
        let again = Request { existing: true, ..req("fix-1a2b") };
        assert_eq!(existing(&s.worktree, &again).await.unwrap(), s.worktree);
        // Nothing moved: same commit, same uncommitted change, no new branch.
        assert_eq!(sh(&wt, &["rev-parse", "HEAD"]), head);
        assert_eq!(std::fs::read_to_string(wt.join("b.txt")).unwrap(), "still editing\n");
        assert_eq!(sh(&checkout, &["branch", "--list", "agent/*"]).trim(), "+ agent/fix-1a2b");
        // Another task's branch, or a folder that's gone, is refused.
        let err = format!("{:#}", existing(&s.worktree, &Request { existing: true, ..req("other-0000") }).await.unwrap_err());
        assert!(err.contains("not the task's branch agent/other-0000"), "{err}");
        let gone = root.join("gone");
        assert!(format!("{:#}", existing(gone.to_str().unwrap(), &again).await.unwrap_err()).contains("isn't there any more"));
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Retry on another machine: studio-mac's runner commits what the builder left as WIP and pushes
    /// the branch (`task.handoff`), and laptop's worktree for the task carries on from it.
    #[tokio::test]
    async fn a_handoff_pushes_the_branch_and_the_next_machine_carries_on_from_it() {
        let root = tmp("handoff");
        let bare = root.join("remotes/widgets.git");
        let base = remote(&bare, "a.txt");
        let (studio, laptop) = (root.join("studio/widgets"), root.join("laptop/widgets"));
        for dir in [&studio, &laptop] {
            sh(&root, &["clone", "--quiet", bare.to_str().unwrap(), dir.to_str().unwrap()]);
        }
        // origin isn't GitHub, so no token is asked for.
        let emit = |m: Outbound| panic!("unexpected message {m:?}");
        let s = start(&emit, "t1", studio.to_str().unwrap(), None, &req("fix-1a2b"), &places(&root, None)).await.unwrap();
        let wt = expand_home(&s.worktree);
        commit(&wt, "b.txt", "half done\n", "the builder's first commit");
        std::fs::write(wt.join("c.txt"), "not committed yet\n").unwrap();
        sh(&wt, &["config", "user.name", "Studio"]);
        sh(&wt, &["config", "user.email", "studio@example.com"]);
        sh(&wt, &["config", "commit.gpgsign", "false"]);

        let h = Handoff {
            task_id: "t1".into(),
            cwd: s.worktree.clone(),
            repo_dir: s.repo_dir.clone(),
            branch: "agent/fix-1a2b".into(),
            base: Some("main".into()),
            title: "Fix it".into(),
            fallback: false,
        };
        // Without the app or the fallback: why, and nothing pushed (the WIP commit is made, which the next try reuses).
        let err = format!("{:#}", handoff(&emit, &h).await.unwrap_err());
        assert!(err.contains("isn't on GitHub"), "{err}");
        assert!(sh(&bare, &["branch", "--list", "agent/*"]).is_empty());
        let (pushed, head) = handoff(&emit, &Handoff { fallback: true, ..h.clone() }).await.unwrap();
        assert_eq!(pushed, "fallback");
        assert_eq!(sh(&bare, &["rev-parse", "agent/fix-1a2b"]), head);
        assert_eq!(sh(&bare, &["log", "--format=%s", &format!("{base}..agent/fix-1a2b")]), "WIP: Fix it\nthe builder's first commit");
        assert_eq!(sh(&wt, &["status", "--porcelain"]), "");

        // laptop starts the task: from the pushed branch, not main.
        let l = start(&emit, "t1", laptop.to_str().unwrap(), None, &req("fix-1a2b"), &places(&root, None)).await.unwrap();
        let lwt = expand_home(&l.worktree);
        assert_eq!((l.base.as_str(), sh(&lwt, &["rev-parse", "HEAD"])), ("main", head.clone()));
        assert_eq!(std::fs::read_to_string(lwt.join("c.txt")).unwrap(), "not committed yet\n");
        assert_eq!(sh(&lwt, &["rev-parse", "--abbrev-ref", "HEAD"]), "agent/fix-1a2b");
        // Another task there, whose branch GitHub doesn't have, starts from main as before.
        let other = start(&emit, "t2", laptop.to_str().unwrap(), None, &req("other-0000"), &places(&root, None)).await.unwrap();
        assert_eq!(sh(&expand_home(&other.worktree), &["rev-parse", "HEAD"]), base);

        // Nothing beyond the base: nothing to carry, and nothing pushed.
        let h2 = Handoff { task_id: "t2".into(), cwd: other.worktree.clone(), branch: "agent/other-0000".into(), fallback: true, ..h.clone() };
        let err = format!("{:#}", handoff(&emit, &h2).await.unwrap_err());
        assert!(err.contains("nothing to carry"), "{err}");
        assert!(sh(&bare, &["branch", "--list", "agent/other-0000"]).is_empty());
        // A branch that isn't a task's is refused before git runs.
        assert!(handoff(&emit, &Handoff { branch: "main".into(), ..h }).await.is_err());
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Every file under `dir` that contains `needle`.
    fn files_containing(dir: &Path, needle: &str) -> Vec<std::path::PathBuf> {
        let mut out = Vec::new();
        let mut stack = vec![dir.to_path_buf()];
        while let Some(d) = stack.pop() {
            for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
                let p = e.path();
                if p.is_dir() {
                    stack.push(p);
                } else if std::fs::read(&p).map(|b| String::from_utf8_lossy(&b).contains(needle)).unwrap_or(false) {
                    out.push(p);
                }
            }
        }
        out
    }

    /// The machine's checkout is behind GitHub, dirty, and has a commit it never pushed: none of that
    /// reaches the task, which starts from a fresh fetch of origin's default branch.
    #[tokio::test]
    async fn a_task_starts_from_the_remote_not_the_local_checkout() {
        let root = tmp("behind");
        let bare = root.join("remotes/widgets.git");
        remote(&bare, "a.txt");
        let checkout = root.join("Projects/widgets");
        sh(&root, &["clone", "--quiet", bare.to_str().unwrap(), checkout.to_str().unwrap()]);
        // GitHub moves on…
        let seed = bare.with_extension("seed");
        commit(&seed, "a.txt", "two\n", "second, on GitHub");
        sh(&seed, &["push", "--quiet", bare.to_str().unwrap(), "main"]);
        let upstream = sh(&seed, &["rev-parse", "HEAD"]);
        // …while the machine's copy has a commit of its own and uncommitted changes.
        commit(&checkout, "local.txt", "mine\n", "local only");
        std::fs::write(checkout.join("a.txt"), "dirty\n").unwrap();
        std::fs::write(checkout.join("untracked.txt"), "x\n").unwrap();

        // origin isn't GitHub, so no token is asked for: the machine's own credentials.
        let emit = |m: Outbound| panic!("unexpected message {m:?}");
        let s = start(&emit, "t1", checkout.to_str().unwrap(), None, &req("fix-1a2b"), &places(&root, None)).await.unwrap();
        assert_eq!(s.base, "main");
        let wt = expand_home(&s.worktree);
        assert_eq!(sh(&wt, &["rev-parse", "HEAD"]), upstream);
        assert_eq!(std::fs::read_to_string(wt.join("a.txt")).unwrap(), "two\n");
        assert!(!wt.join("local.txt").exists() && !wt.join("untracked.txt").exists());
        assert_eq!(sh(&wt, &["status", "--porcelain"]), "");
        assert_eq!(sh(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]), "agent/fix-1a2b");
        // No upstream on the task branch, and origin/HEAD now names the default branch.
        assert!(!std::process::Command::new("git").arg("-C").arg(&wt).args(["rev-parse", "@{u}"]).output().unwrap().stderr.is_empty());
        assert_eq!(sh(&checkout, &["symbolic-ref", "refs/remotes/origin/HEAD"]), "refs/remotes/origin/main");
        // The checkout itself is as it was.
        assert_eq!(std::fs::read_to_string(checkout.join("a.txt")).unwrap(), "dirty\n");

        // A fetch that fails fails the task, with no worktree from local state.
        sh(&checkout, &["remote", "set-url", "origin", root.join("remotes/gone.git").to_str().unwrap()]);
        let err = format!("{:#}", start(&emit, "t2", checkout.to_str().unwrap(), None, &req("other-0000"), &places(&root, None)).await.unwrap_err());
        assert!(err.contains("Couldn't fetch") && err.contains("never from this machine's copy"), "{err}");
        assert!(!crate::worktrees::worktree_path(&checkout, "other-0000").unwrap().exists());
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Answers fetch token requests with `token`, and keeps every message as JSON.
    fn token_hub<'a>(token: &'static str, sent: &'a Mutex<Vec<String>>) -> impl Fn(Outbound) + Sync + 'a {
        move |m: Outbound| {
            sent.lock().unwrap().push(serde_json::to_string(&m).unwrap());
            if let Outbound::TaskTokenRequest { req_id, purpose, .. } = m {
                assert_eq!(purpose, Some("fetch"));
                resolve(&req_id, TokenReply { token: Some(token.into()), error: None, code: None });
            }
        }
    }

    /// No checkout here: the runner clones into its own folder with a token that's only ever in the
    /// fetch's arguments, never in config, remotes, the repo's files, messages or errors.
    #[tokio::test]
    async fn a_machine_without_the_repo_clones_it_with_a_token() {
        const TOKEN: &str = "ghs_fetchtoken12345";
        let root = tmp("clone");
        let head = remote(&root.join(format!("remotes/{TOKEN}/acme/widgets.git")), "a.txt");
        let at = places(&root, Some(format!("{}/remotes/{{token}}/{{owner}}/{{repo}}.git", root.display())));
        let sent = Mutex::new(Vec::new());
        let emit = token_hub(TOKEN, &sent);

        let s = start(&emit, "t1", "", Some("acme/widgets"), &req("fix-1a2b"), &at).await.unwrap();
        let clone = root.join("managed/acme/widgets");
        assert_eq!(expand_home(&s.repo_dir), clone);
        assert_eq!((s.base.as_str(), sh(&expand_home(&s.worktree), &["rev-parse", "HEAD"])), ("main", head.clone()));
        assert_eq!(sh(&clone, &["remote", "-v"]), "origin\thttps://github.com/acme/widgets.git (fetch)\norigin\thttps://github.com/acme/widgets.git (push)");
        assert_eq!(files_containing(&root.join("managed"), TOKEN), Vec::<std::path::PathBuf>::new());
        assert!(!sent.lock().unwrap().iter().any(|m| m.contains(TOKEN)));
        assert_eq!(std::fs::read_dir(root.join("managed/.partial")).unwrap().count(), 0);
        // It's reported as managed now, and the next task uses it rather than cloning again.
        let found = crate::repos::scan(&at.roots, &at.managed).await;
        assert_eq!((found.len(), found[0].managed, found[0].repo.as_str()), (1, true, "acme/widgets"));
        let again = start(&emit, "t2", "", Some("acme/widgets"), &req("next-0000"), &at).await.unwrap();
        assert_eq!(again.repo_dir, s.repo_dir);

        // A repo the token can't reach: a clear error with the token scrubbed, and nothing left behind.
        let err = format!("{:#}", start(&emit, "t3", "", Some("acme/missing"), &req("fix-1a2b"), &at).await.unwrap_err());
        assert!(err.contains("Couldn't fetch from GitHub") && !err.contains(TOKEN), "{err}");
        assert!(!root.join("managed/acme/missing").exists());
        assert_eq!(std::fs::read_dir(root.join("managed/.partial")).unwrap().count(), 0);
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Two checkouts of one repo: the runner's own if it has one, else the one fetched most recently.
    #[tokio::test]
    async fn two_checkouts_use_the_managed_one_else_the_freshest() {
        const TOKEN: &str = "ghs_fetchtoken67890";
        let root = tmp("two");
        let bare = root.join(format!("remotes/{TOKEN}/acme/widgets.git"));
        remote(&bare, "a.txt");
        let at = places(&root, Some(format!("{}/remotes/{{token}}/{{owner}}/{{repo}}.git", root.display())));
        let sent = Mutex::new(Vec::new());
        let emit = token_hub(TOKEN, &sent);
        let (old, fresh) = (root.join("Projects/widgets"), root.join("Projects/clients/widgets"));
        for dir in [&old, &fresh] {
            sh(&root, &["clone", "--quiet", bare.to_str().unwrap(), dir.to_str().unwrap()]);
            sh(dir, &["remote", "set-url", "origin", "git@github.com:acme/widgets.git"]);
            let _ = std::fs::remove_file(dir.join(".git/FETCH_HEAD"));
            let _ = std::fs::remove_dir_all(dir.join(".git/logs/refs/remotes"));
        }
        sh(&fresh, &["fetch", "--quiet", bare.to_str().unwrap()]);
        let s = start(&emit, "t1", "", Some("acme/widgets"), &req("a-0000"), &at).await.unwrap();
        assert_eq!(expand_home(&s.repo_dir), fresh);

        // Once the runner has its own clone, that one.
        let managed = root.join("managed/acme/widgets");
        sh(&root, &["clone", "--quiet", bare.to_str().unwrap(), managed.to_str().unwrap()]);
        sh(&managed, &["remote", "set-url", "origin", "https://github.com/acme/widgets.git"]);
        let s = start(&emit, "t2", "", Some("acme/widgets"), &req("b-0000"), &at).await.unwrap();
        assert_eq!(expand_home(&s.repo_dir), managed);
        let found = crate::repos::scan(&at.roots, &at.managed).await;
        assert_eq!(found.iter().filter(|c| c.repo == "acme/widgets").count(), 3, "{found:?}");
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn fetch_url_carries_the_token_only_in_the_url() {
        assert_eq!(fetch_url("acme", "w", "ghs_x", None), "https://x-access-token:ghs_x@github.com/acme/w.git");
        assert_eq!(fetch_url("acme", "w", "ghs_x", Some("/r/{token}/{owner}/{repo}.git")), "/r/ghs_x/acme/w.git");
    }
}
