//! Git worktrees: one checkout per agent, so two agents in one repo don't trip over
//! each other's changes.
//!
//! New session can start in a fresh worktree at `<repo's parent>/.worktrees/<repo>/<name>`
//! on branch `agent/<name>`. Outside the repo so tools that walk the tree (tests, linters,
//! file watchers) don't see the copies, and grouped by repo so `ls` makes sense.
//!
//! The runner reports every worktree of every repo a session has used (plus repos found
//! through `.worktrees/` folders next to them), and removes one on request, but only
//! when nothing would be lost: no session or program running in it, no uncommitted changes, no
//! commits that exist nowhere else. It checks that itself; the UI's say-so isn't enough. Force
//! remove of a merged worktree throws away its changes and ends what's running in it. Removing
//! moves the folder aside and lets git forget it at once; the folder itself is deleted in the
//! background.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tokio::sync::Notify;
use uuid::Uuid;

use crate::fs_browse;
use crate::protocol::{Outbound, SessionInfo};
use crate::sessions::{Sessions, expand_home};

/// Branches for agent worktrees live under this prefix.
pub const BRANCH_PREFIX: &str = "agent/";

/// `session.open`'s optional `worktree`.
#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    /// The part after `agent/`; may contain slashes.
    pub name: String,
    /// Branch or commit to start from. Defaults to what the directory has checked out.
    #[serde(default)]
    pub base: Option<String>,
    /// A task's worktree that's already there (its builder again, after a review asked for changes):
    /// the session opens in it as it is, with no fetch and no new branch (`tasks::open`).
    #[serde(default)]
    pub existing: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Repo {
    /// The main checkout, `~`-abbreviated.
    pub root: String,
    pub default_branch: Option<String>,
    pub worktrees: Vec<Worktree>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Worktree {
    pub path: String,
    /// None when detached.
    pub branch: Option<String>,
    pub head: String,
    pub changed: u32,
    /// Commits that aren't on any remote or on the default branch (for the main checkout:
    /// ahead of its upstream).
    pub ahead: u32,
    /// The branch tip is part of the default branch, so deleting the branch loses nothing.
    pub merged: bool,
    pub main: bool,
}

/// Repo roots seen during this runner's lifetime.
static REPOS: Mutex<BTreeSet<PathBuf>> = Mutex::new(BTreeSet::new());
static POKE: Notify = Notify::const_new();
/// Send the next report even if nothing changed (a hub just connected).
static FORCE: AtomicBool = AtomicBool::new(false);

/// Rescan now, and send the result even if nothing changed.
pub fn poke(force: bool) {
    if force {
        FORCE.store(true, Ordering::Relaxed);
    }
    POKE.notify_one();
}

// ---- names and paths ----

/// Names become branch `agent/<name>` and a folder under `.worktrees/<repo>/`, so they
/// must be safe as both: git's ref rules, plus nothing that climbs out of the folder.
pub fn valid_name(name: &str) -> Result<()> {
    let bad = |why: &str| Err(anyhow!("`{name}` can't be a worktree name: {why}."));
    if name.is_empty() {
        return bad("it's empty");
    }
    if name.len() > 100 {
        return bad("it's longer than 100 characters");
    }
    if !name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'/')) {
        return bad("use letters, digits, `-`, `_`, `.` and `/`");
    }
    if name.starts_with('/') || name.ends_with('/') {
        return bad("it can't start or end with `/`");
    }
    if name.contains("..") || name.contains("//") {
        return bad("it can't contain `..` or `//`");
    }
    for part in name.split('/') {
        if part.starts_with('.') || part.ends_with('.') || part.ends_with(".lock") || part.starts_with('-') {
            return bad("no part can start with `.` or `-`, or end with `.` or `.lock`");
        }
    }
    Ok(())
}

/// `<parent of root>/.worktrees/<repo name>/<name>`.
pub fn worktree_path(root: &Path, name: &str) -> Result<PathBuf> {
    let (Some(parent), Some(repo)) = (root.parent(), root.file_name()) else {
        bail!("{} has no parent folder to put worktrees in", root.display());
    };
    Ok(parent.join(".worktrees").join(repo).join(name))
}

pub(crate) fn abbreviate(path: &Path) -> String {
    let Ok(home) = fs_browse::home() else { return path.display().to_string() };
    // git reports real paths; $HOME may be a symlink (/tmp → /private/tmp on macOS).
    match std::fs::canonicalize(&home) {
        Ok(real) if path.starts_with(&real) && !path.starts_with(&home) => fs_browse::abbreviate(path, &real),
        _ => fs_browse::abbreviate(path, &home),
    }
}

pub(crate) fn canonical(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

// ---- git ----

/// Runs git, returning stdout, or stderr (minus `fatal: `) as the error.
async fn git(dir: &Path, args: &[&str]) -> Result<String> {
    git_within(dir, args, Duration::from_secs(20)).await
}

/// `git` killed after `limit` (the error is then a `TimedOut`).
async fn git_within(dir: &Path, args: &[&str], limit: Duration) -> Result<String> {
    let mut cmd = Command::new("git");
    cmd.arg("-C").arg(dir).args(args).env("GIT_OPTIONAL_LOCKS", "0").env("GIT_TERMINAL_PROMPT", "0").stdin(Stdio::null()).kill_on_drop(true);
    let out = tokio::time::timeout(limit, cmd.output()).await.map_err(|_| TimedOut(format!("git {} timed out", args.first().unwrap_or(&""))))??;
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    let err = String::from_utf8_lossy(&out.stderr);
    let msg = err.lines().map(|l| l.trim_start_matches("fatal: ").trim_start_matches("error: ")).collect::<Vec<_>>().join(" ");
    Err(anyhow!("{}", if msg.trim().is_empty() { format!("git {} failed", args.join(" ")) } else { msg.trim().to_string() }))
}

#[derive(Debug)]
struct TimedOut(String);

impl std::fmt::Display for TimedOut {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for TimedOut {}

#[derive(Debug, Clone, PartialEq)]
struct Listed {
    path: PathBuf,
    head: String,
    branch: Option<String>,
    bare: bool,
    /// `git worktree lock`ed, with its reason (empty when none was given).
    locked: Option<String>,
}

/// `git worktree list --porcelain`. The first entry is the main worktree.
fn parse_list(out: &str) -> Vec<Listed> {
    let mut list = Vec::new();
    for block in out.split("\n\n") {
        let mut entry = Listed { path: PathBuf::new(), head: String::new(), branch: None, bare: false, locked: None };
        for line in block.lines() {
            if let Some(p) = line.strip_prefix("worktree ") {
                entry.path = PathBuf::from(p);
            } else if let Some(h) = line.strip_prefix("HEAD ") {
                entry.head = h.into();
            } else if let Some(b) = line.strip_prefix("branch ") {
                entry.branch = Some(b.strip_prefix("refs/heads/").unwrap_or(b).into());
            } else if line == "bare" {
                entry.bare = true;
            } else if line == "locked" {
                entry.locked = Some(String::new());
            } else if let Some(reason) = line.strip_prefix("locked ") {
                entry.locked = Some(reason.into());
            }
        }
        if !entry.path.as_os_str().is_empty() {
            list.push(entry);
        }
    }
    list
}

async fn list(dir: &Path) -> Result<Vec<Listed>> {
    Ok(parse_list(&git(dir, &["worktree", "list", "--porcelain"]).await?))
}

/// The repo the runner's layout puts the worktree folder `target` (canonical) under, `<parent>/.worktrees/<repo>/<name>`
/// → `<parent>/<repo>`, but only if that repo's worktree list still has exactly `target`.
async fn layout_root(target: &Path) -> Option<PathBuf> {
    let mut below = target;
    let repo = loop {
        let up = below.parent()?;
        if below != target && up.file_name().is_some_and(|n| n == ".worktrees") {
            break up.parent()?.join(below.file_name()?);
        }
        below = up;
    };
    let root = main_root(&repo).await.ok()?;
    let listed = list(&root).await.ok()?;
    listed.iter().any(|w| canonical(&w.path) == target).then_some(root)
}

/// The main checkout of the repository `dir` is in (also from inside a linked worktree).
pub(crate) async fn main_root(dir: &Path) -> Result<PathBuf> {
    let first = list(dir).await?.into_iter().next().ok_or_else(|| anyhow!("no worktrees"))?;
    if first.bare {
        bail!("bare repositories aren't supported");
    }
    Ok(first.path)
}

async fn has_branch(root: &Path, branch: &str) -> bool {
    git(root, &["show-ref", "--verify", "--quiet", &format!("refs/heads/{branch}")]).await.is_ok()
}

/// The default branch's name, and the ref to compare against (local if it exists).
async fn default_branch(root: &Path, main: &Listed) -> Option<(String, String)> {
    if let Ok(remote_head) = git(root, &["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]).await {
        let remote_head = remote_head.trim();
        let name = remote_head.strip_prefix("origin/").unwrap_or(remote_head).to_string();
        let r#ref = if has_branch(root, &name).await { name.clone() } else { remote_head.to_string() };
        return Some((name, r#ref));
    }
    for name in ["main", "master"] {
        if has_branch(root, name).await {
            return Some((name.into(), name.into()));
        }
    }
    main.branch.clone().map(|b| (b.clone(), b))
}

// ---- creating ----

/// Creates (or reuses) the worktree for a new session and returns its path, `~`-abbreviated.
pub async fn create(cwd: &str, req: &Request) -> Result<String> {
    valid_name(&req.name)?;
    let dir = expand_home(cwd);
    if !dir.is_dir() {
        bail!("{cwd} is not a directory");
    }
    let root = main_root(&dir).await.map_err(|_| anyhow!("{cwd} isn't in a git repository, so there's no worktree to make."))?;
    let path = worktree_path(&root, &req.name)?;
    let branch = format!("{BRANCH_PREFIX}{}", req.name);
    git(&root, &["check-ref-format", "--branch", &branch]).await.map_err(|_| anyhow!("`{branch}` isn't a valid branch name."))?;
    REPOS.lock().unwrap().insert(root.clone());

    if path.exists() {
        // Starting a second session in an existing agent worktree is fine.
        let existing = list(&root).await?;
        if existing.iter().any(|w| canonical(&w.path) == canonical(&path) && w.branch.as_deref() == Some(branch.as_str())) {
            return Ok(abbreviate(&path));
        }
        bail!("{} already exists. Pick another name.", abbreviate(&path));
    }
    let path_str = path.to_string_lossy().into_owned();
    let mut args = vec!["worktree", "add"];
    if has_branch(&root, &branch).await {
        // Pick up where an earlier agent left off on this branch.
        args.extend([path_str.as_str(), branch.as_str()]);
    } else {
        args.extend(["-b", branch.as_str(), path_str.as_str()]);
        if let Some(base) = req.base.as_deref().map(str::trim).filter(|b| !b.is_empty()) {
            if base.starts_with('-') {
                bail!("`{base}` isn't a branch or commit.");
            }
            git(&root, &["rev-parse", "--verify", "--quiet", &format!("{base}^{{commit}}")])
                .await
                .map_err(|_| anyhow!("There's no branch or commit called `{base}`."))?;
            args.push(base);
        }
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // From `dir`, not the main checkout: with no base, the new branch starts from whatever
    // the chosen directory has checked out (it may itself be a worktree on another branch).
    git(&dir, &args).await.map_err(|e| anyhow!("Couldn't create the worktree: {e}"))?;
    poke(false);
    Ok(abbreviate(&path))
}

/// A task's worktree in the repository at `root`: branch `agent/<name>` from `start` (the
/// `origin/<base>` just fetched from GitHub, never what the checkout has), with no upstream. An
/// existing branch is picked up where an earlier attempt left off; one that's only on origin
/// (`origin/agent/<name>`, pushed by the machine the task ran on before Retry moved it here) is
/// branched from that. A local branch that origin's has moved past (the task went away and came
/// back) is moved up to it first. Returns its path, `~`-abbreviated.
#[cfg(test)]
pub async fn create_from(root: &Path, name: &str, start: &str) -> Result<String> {
    create_with(root, name, start, None).await
}

/// `create_from` with the repo's worktree scripts (see `worktree_scripts`): its `create` script makes
/// the worktree in place of `git worktree add` (and must leave a git worktree on `agent/<name>` at
/// the path), its `preflight` script runs in it when this checkout needs it (`worktree_scripts::preflight`),
/// and its `setup` script runs once it's there. When any fails, the half-made worktree
/// goes (and the branch, if this made it) and the error has the script's output.
pub async fn create_with(root: &Path, name: &str, start: &str, scripts: Option<&crate::worktree_scripts::ForTask<'_>>) -> Result<String> {
    use crate::worktree_scripts::{Phase, command, preflight, run};
    valid_name(name)?;
    if start.starts_with('-') {
        bail!("`{start}` isn't a branch or commit.");
    }
    let path = worktree_path(root, name)?;
    let branch = format!("{BRANCH_PREFIX}{name}");
    git(root, &["check-ref-format", "--branch", &branch]).await.map_err(|_| anyhow!("`{branch}` isn't a valid branch name."))?;
    REPOS.lock().unwrap().insert(root.to_path_buf());
    if path.exists() {
        let existing = list(root).await?;
        if existing.iter().any(|w| canonical(&w.path) == canonical(&path) && w.branch.as_deref() == Some(branch.as_str())) {
            return Ok(abbreviate(&path));
        }
        bail!("{} already exists. Pick another name.", abbreviate(&path));
    }
    let had_branch = has_branch(root, &branch).await;
    let custom = scripts.and_then(|s| command(Some(s.scripts), Phase::Create));
    if let (Some(s), Some(custom)) = (scripts, custom) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        if let Err(e) = run(Some(s.scripts), Phase::Create, &s.context(root, &path, &branch)).await {
            undo(root, &path, &branch, had_branch).await;
            return Err(e);
        }
        let made = list(root).await?.iter().any(|w| canonical(&w.path) == canonical(&path) && w.branch.as_deref() == Some(branch.as_str()));
        if !made {
            undo(root, &path, &branch, had_branch).await;
            bail!("The repo's create script (`{custom}`) finished, but there's no git worktree on {branch} at {} (MAPLE_WORKTREE).", abbreviate(&path));
        }
    } else {
        add(root, &path, &branch, start, had_branch).await?;
    }
    poke(false);
    if let Some(s) = scripts
        && let Err(e) = async {
            let ctx = s.context(root, &path, &branch);
            preflight(s.scripts, &ctx).await?;
            run(Some(s.scripts), Phase::Setup, &ctx).await
        }
        .await
    {
        undo(root, &path, &branch, had_branch).await;
        poke(false);
        return Err(e);
    }
    Ok(abbreviate(&path))
}

/// `git worktree add` for `create_with`: an existing branch, else one from origin's copy, else from `start`.
async fn add(root: &Path, path: &Path, branch: &str, start: &str, had_branch: bool) -> Result<()> {
    let path_str = path.to_string_lossy().into_owned();
    let remote = format!("refs/remotes/origin/{branch}");
    let on_origin = git(root, &["show-ref", "--verify", "--quiet", &remote]).await.is_ok();
    let args: Vec<&str> = if had_branch {
        if on_origin && git(root, &["merge-base", "--is-ancestor", branch, &remote]).await.is_ok() {
            // Not checked out anywhere (its worktree isn't there), so this only moves the ref.
            let _ = git(root, &["branch", "--force", "--no-track", branch, &remote]).await;
        }
        vec!["worktree", "add", &path_str, branch]
    } else if on_origin {
        vec!["worktree", "add", "--no-track", "-b", branch, &path_str, &remote]
    } else {
        vec!["worktree", "add", "--no-track", "-b", branch, &path_str, start]
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    git(root, &args).await.map_err(|e| anyhow!("Couldn't create the worktree: {e}"))?;
    Ok(())
}

/// Takes away a worktree a script failed on: git's worktree at `path` if there is one, and the branch
/// if it wasn't there before. A folder git doesn't list is left alone. Best-effort.
async fn undo(root: &Path, path: &Path, branch: &str, had_branch: bool) {
    let listed = list(root).await.map(|l| l.iter().any(|w| canonical(&w.path) == canonical(path))).unwrap_or(false);
    if listed {
        let p = path.to_string_lossy();
        if let Err(e) = git(root, &["worktree", "remove", "--force", "--force", &p]).await {
            tracing::warn!("couldn't remove the half-made worktree {}: {e}", abbreviate(path));
        }
    }
    let _ = git(root, &["worktree", "prune"]).await;
    if !had_branch && has_branch(root, branch).await {
        let _ = git(root, &["branch", "-D", branch]).await;
    }
    tidy(root, path);
}

// ---- reporting ----

/// Scans every 10 seconds (and right after anything changes) and sends a report when it
/// differs from the last one, and every minute regardless, so a hub that missed one catches up.
pub async fn report(sessions: Sessions) {
    let mut last: Option<Vec<Repo>> = None;
    let mut last_sent = Instant::now();
    loop {
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(10)) => {}
            _ = POKE.notified() => {}
        }
        let repos = scan(&sessions).await;
        let force = FORCE.swap(false, Ordering::Relaxed) || last_sent.elapsed() >= Duration::from_secs(60);
        if force || last.as_ref() != Some(&repos) {
            sessions.emit(Outbound::Worktrees { repos: repos.clone() });
            last = Some(repos);
            last_sent = Instant::now();
        }
    }
}

async fn scan(sessions: &Sessions) -> Vec<Repo> {
    let mut found = Vec::new();
    for s in sessions.list() {
        if let Ok(root) = main_root(&expand_home(&s.cwd)).await {
            found.push(root);
        }
    }
    let known: Vec<PathBuf> = {
        let mut repos = REPOS.lock().unwrap();
        repos.extend(found);
        repos.retain(|r| r.is_dir());
        repos.iter().cloned().collect()
    };
    // Worktrees left in `.worktrees/` next to known repos lead to their repos too
    // (say, after a runner restart, when no session uses them any more).
    let parents: BTreeSet<PathBuf> = known.iter().filter_map(|r| r.parent().map(Path::to_path_buf)).collect();
    for parent in parents {
        for dir in checkouts_under(&parent.join(".worktrees"), 4) {
            if let Ok(root) = main_root(&dir).await {
                REPOS.lock().unwrap().insert(root);
            }
        }
    }
    let roots: Vec<PathBuf> = REPOS.lock().unwrap().iter().cloned().collect();
    let mut repos = Vec::new();
    for root in roots {
        if let Ok(repo) = repo_report(&root).await {
            repos.push(repo);
        }
    }
    // The hub sends this inside every state update, beside the session list; keep it a small part of a message.
    if crate::protocol::fit_items(&mut repos, REPORT_BUDGET) {
        tracing::warn!("the worktree report is over {REPORT_BUDGET} bytes; sending the first {} repos", repos.len());
    }
    repos
}

/// The most the worktree report may take as JSON.
const REPORT_BUDGET: usize = crate::protocol::MAX_MESSAGE / 4;

/// Folders below `dir` that are git checkouts (have a `.git`), up to `depth` levels down.
fn checkouts_under(dir: &Path, depth: u32) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(read) = std::fs::read_dir(dir) else { return out };
    for entry in read.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        if path.join(".git").exists() {
            out.push(path);
        } else if depth > 1 {
            out.extend(checkouts_under(&path, depth - 1));
        }
    }
    out
}

async fn repo_report(root: &Path) -> Result<Repo> {
    let listed = list(root).await?;
    let main = listed.first().ok_or_else(|| anyhow!("no worktrees"))?.clone();
    let default = default_branch(root, &main).await;
    let mut worktrees = Vec::new();
    for (i, w) in listed.iter().enumerate() {
        // A worktree whose folder was deleted by hand; `git worktree prune` tidies those.
        if !w.path.is_dir() {
            continue;
        }
        worktrees.push(inspect(root, w, i == 0, default.as_ref().map(|d| d.1.as_str())).await);
    }
    Ok(Repo { root: abbreviate(root), default_branch: default.map(|d| d.0), worktrees })
}

async fn inspect(root: &Path, w: &Listed, main: bool, default_ref: Option<&str>) -> Worktree {
    let status = crate::git::status(&w.path).await;
    inspect_with(root, w, main, default_ref, status).await
}

/// `inspect` with the worktree's `git status` already read (None: it couldn't be).
async fn inspect_with(root: &Path, w: &Listed, main: bool, default_ref: Option<&str>, status: Option<crate::git::GitState>) -> Worktree {
    #[cfg(test)]
    tests::INSPECTED.lock().unwrap().push(w.path.clone());
    let changed = status.as_ref().map(|s| s.changed).unwrap_or(0);
    let (ahead, merged) = if main {
        (status.as_ref().map(|s| s.ahead).unwrap_or(0), true)
    } else {
        let mut args = vec!["rev-list", "--count", w.head.as_str(), "--not", "--remotes"];
        args.extend(default_ref);
        let ahead = git(root, &args).await.ok().and_then(|n| n.trim().parse().ok()).unwrap_or(0);
        let merged = match default_ref {
            Some(d) => git(root, &["merge-base", "--is-ancestor", &w.head, d]).await.is_ok(),
            None => false,
        };
        (ahead, merged)
    };
    Worktree { path: abbreviate(&w.path), branch: w.branch.clone(), head: w.head.clone(), changed, ahead, merged, main }
}

// ---- removing ----

/// One removal at a time: bulk cleanup sends one `worktree.remove` per worktree, and git's
/// worktree and ref locks don't like company. Held for the checks, the move aside, the prune and the
/// branch, not for deleting the folder.
static REMOVING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Removes a linked worktree, and its branch if it's merged. Refuses if anything would be lost.
/// `force` throws away uncommitted changes, but only in a merged worktree with nothing unpushed,
/// so the working tree is all that can go; it also ends the sessions and stops the programs still
/// running in it.
pub async fn remove(sessions: &Sessions, path: &str, force: bool) -> Result<String> {
    // The folder's own delete carries on in the background; the row is gone from the next report.
    remove_checked(sessions, path, force).await.map(|(done, _)| done)
}

/// The sessions a removal looks for in the worktree, and how it ends one: `Sessions` in the
/// runner, a fake in tests.
pub(crate) trait Occupants {
    fn sessions(&self) -> Vec<SessionInfo>;
    fn end(&self, id: Uuid) -> impl Future<Output = ()> + Send;
}

impl Occupants for Sessions {
    fn sessions(&self) -> Vec<SessionInfo> {
        self.list()
    }

    fn end(&self, id: Uuid) -> impl Future<Output = ()> + Send {
        self.kill(id)
    }
}

/// How long ended sessions get to leave the list (tmux exits are seen once a second).
const SESSIONS_WAIT: Duration = Duration::from_secs(if cfg!(test) { 1 } else { 10 });
/// How long a program gets after SIGTERM before SIGKILL.
const PROGRAMS_WAIT: Duration = Duration::from_secs(5);

/// `remove`, also handing back the background delete of the folder (if it was moved aside).
async fn remove_checked(sessions: &impl Occupants, path: &str, force: bool) -> Result<(String, Option<Deleting>)> {
    let _one = REMOVING.lock().await;
    let dir = expand_home(path);
    if !dir.exists() && !still_listed(&dir).await {
        // Removed already (say, by Force remove, before the session it ended cleaned up after itself).
        return Ok((format!("{path} was already gone"), None));
    }
    let target = canonical(&dir);
    // No `.git`: a removal cut off after git deleted it. Git's record of it is still in the repo.
    let gone = dir.is_dir() && !dir.join(".git").exists();
    let root = match if gone { layout_root(&target).await } else { None } {
        Some(root) => root,
        None => main_root(&dir).await.map_err(|e| anyhow!("{path} isn't a worktree ({e})."))?,
    };
    REPOS.lock().unwrap().insert(root.clone());
    let listed = list(&root).await?;
    let (i, w) =
        listed.iter().enumerate().find(|(_, w)| canonical(&w.path) == target).ok_or_else(|| anyhow!("{path} isn't a worktree of {}.", abbreviate(&root)))?;
    if i == 0 {
        bail!("{path} is the repository's main checkout; only extra worktrees can be removed.");
    }
    if let Some(reason) = &w.locked {
        let why = if reason.is_empty() { String::new() } else { format!(" ({reason})") };
        bail!("{path} is locked{why}. Unlock it with `git worktree unlock {}` first if it can go.", w.path.display());
    }
    if !w.path.is_dir() {
        bail!("{path} is missing.");
    }
    // Only this worktree: bulk cleanup removes them one by one, so its siblings wait on each check.
    // Without `.git` its changes can't be read; force throws them away, and the branch checks still hold.
    let status = match gone {
        true => None,
        false => Some(crate::git::status(&w.path).await.ok_or_else(|| anyhow!("Couldn't read the status of {path}."))?),
    };
    let default = default_branch(&root, &listed[0]).await;
    let report = inspect_with(&root, w, false, default.as_ref().map(|d| d.1.as_str()), status).await;
    if (force || gone) && !report.merged {
        bail!("{path} isn't merged, so it can't be force-removed.");
    }
    if report.changed > 0 && !force {
        bail!("{path} has {} uncommitted change{}.", report.changed, if report.changed == 1 { "" } else { "s" });
    }
    if report.ahead > 0 {
        let (s, verb) = if report.ahead == 1 { ("", "isn't") } else { ("s", "aren't") };
        bail!("{path} has {} commit{s} that {verb} pushed or merged.", report.ahead);
    }
    if gone && !force {
        bail!("{path} was partly deleted by a removal that was cut off. Force remove will finish it.");
    }
    // Nothing would be lost; what's still running in it is all that's left. Force ends it.
    let then = if report.merged { "Force remove will end" } else { "End" };
    let inside = sessions_in(sessions, &target);
    if !inside.is_empty() {
        let names = and_list(&inside.iter().map(session_label).collect::<Vec<_>>());
        if !force {
            let (verb, it) = if inside.len() == 1 { ("is", "it") } else { ("are", "them") };
            bail!("{names} {verb} still running in {path}. {then} {it}{}.", if report.merged { "" } else { " first" });
        }
        for s in &inside {
            sessions.end(s.id).await;
        }
        let deadline = Instant::now() + SESSIONS_WAIT;
        let mut left = inside.clone();
        loop {
            let live: Vec<Uuid> = sessions.sessions().into_iter().map(|s| s.id).collect();
            left.retain(|s| live.contains(&s.id));
            if left.is_empty() || Instant::now() >= deadline {
                break;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        if !left.is_empty() {
            bail!("Couldn't end {} in {path}.", and_list(&left.iter().map(session_label).collect::<Vec<_>>()));
        }
    }
    let programs = programs_in(&target).await;
    if !programs.is_empty() {
        if !force {
            let mut named: Vec<String> = programs.iter().take(3).map(|p| format!("{} (pid {})", p.command, p.pid)).collect();
            if programs.len() > 3 {
                named.push(format!("{} more", programs.len() - 3));
            }
            let it = if programs.len() == 1 { "it" } else { "them" };
            bail!("{path} has {} still running in it. {then} {it}{}.", and_list(&named), if report.merged { "" } else { " first" });
        }
        stop(&programs, PROGRAMS_WAIT).await;
    }
    let deleting = take_away(&root, &w.path, force, path, REMOVE_LIMIT).await?;
    let mut done = format!("Removed {path}");
    if let (true, Some(branch)) = (report.merged, &w.branch) {
        // `-d`, not `-D`: git double-checks that it's merged.
        match git(&root, &["branch", "-d", branch]).await {
            Ok(_) => done.push_str(&format!(" and branch {branch}")),
            Err(e) => tracing::warn!("kept branch {branch}: {e}"),
        }
    }
    poke(true);
    Ok((done, deleting))
}

/// Whether a known repository still lists the (missing) folder `dir` as one of its worktrees.
async fn still_listed(dir: &Path) -> bool {
    let target = canonical_missing(dir);
    let roots: Vec<PathBuf> = REPOS.lock().unwrap().iter().cloned().collect();
    for root in roots {
        if let Ok(listed) = list(&root).await
            && listed.iter().any(|w| canonical_missing(&w.path) == target)
        {
            return true;
        }
    }
    false
}

/// `canonical` for a path that may not exist: its nearest existing folder made canonical, plus the rest.
fn canonical_missing(path: &Path) -> PathBuf {
    let mut rest = Vec::new();
    let mut at = path;
    while !at.exists() {
        let (Some(parent), Some(name)) = (at.parent(), at.file_name()) else { return path.to_path_buf() };
        rest.push(name);
        at = parent;
    }
    let mut out = canonical(at);
    out.extend(rest.iter().rev());
    out
}

/// The sessions whose folder is inside the worktree at `target` (canonical).
fn sessions_in(sessions: &impl Occupants, target: &Path) -> Vec<SessionInfo> {
    sessions.sessions().into_iter().filter(|s| canonical(&expand_home(&s.cwd)).starts_with(target)).collect()
}

/// "Claude Code (1a2b3c4d)".
fn session_label(s: &SessionInfo) -> String {
    let label = crate::agent_config::find(&s.agent).map(|a| a.label).unwrap_or_else(|| s.agent.clone());
    format!("{label} ({})", &s.id.simple().to_string()[..8])
}

/// "a", "a and b", "a, b and c".
fn and_list(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [one] => one.clone(),
        [init @ .., last] => format!("{} and {last}", init.join(", ")),
    }
}

/// A program whose working folder is inside a worktree.
#[derive(Debug, Clone, PartialEq)]
struct Program {
    pid: i32,
    command: String,
}

/// The programs whose working folder is inside `target` (canonical), from `lsof`. Never this runner,
/// the program that started it, or tmux (ending its server would end every session). Empty, with a
/// warning, when `lsof` isn't there or doesn't answer.
async fn programs_in(target: &Path) -> Vec<Program> {
    let mut cmd = Command::new("lsof");
    cmd.args(["-a", "-d", "cwd", "-Fpcn"]).stdin(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true);
    let out = match tokio::time::timeout(Duration::from_secs(10), cmd.output()).await {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => {
            tracing::warn!("couldn't look for programs running in {} (lsof: {e})", target.display());
            return Vec::new();
        }
        Err(_) => {
            tracing::warn!("couldn't look for programs running in {} (lsof timed out)", target.display());
            return Vec::new();
        }
    };
    // lsof exits 1 when it couldn't read some processes; what it could read is still there.
    let ours = [std::process::id() as i32, unsafe { libc::getppid() }];
    parse_lsof(&String::from_utf8_lossy(&out.stdout), target).into_iter().filter(|p| !ours.contains(&p.pid) && p.command != "tmux").collect()
}

/// `lsof -Fpcn` output: a `p<pid>` line per process, then its `c<command>`, then `f`/`n<path>` per file.
fn parse_lsof(out: &str, target: &Path) -> Vec<Program> {
    let mut found: Vec<Program> = Vec::new();
    let (mut pid, mut command) = (None, String::new());
    for line in out.lines() {
        let Some((kind, rest)) = line.split_at_checked(1) else { continue };
        match kind {
            "p" => {
                pid = rest.parse::<i32>().ok();
                command.clear();
            }
            "c" => command = rest.to_string(),
            "n" => {
                let Some(p) = pid else { continue };
                let path = Path::new(rest);
                if (path.starts_with(target) || canonical(path).starts_with(target)) && !found.iter().any(|f| f.pid == p) {
                    found.push(Program { pid: p, command: command.clone() });
                }
            }
            _ => {}
        }
    }
    found
}

/// SIGTERM, then SIGKILL for whatever is still there after `grace`.
async fn stop(programs: &[Program], grace: Duration) {
    let alive = |pid: i32| unsafe { libc::kill(pid, 0) == 0 };
    for p in programs.iter().filter(|p| p.pid > 1) {
        tracing::info!("stopping {} (pid {})", p.command, p.pid);
        unsafe { libc::kill(p.pid, libc::SIGTERM) };
    }
    let deadline = Instant::now() + grace;
    while Instant::now() < deadline && programs.iter().any(|p| p.pid > 1 && alive(p.pid)) {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    for p in programs.iter().filter(|p| p.pid > 1 && alive(p.pid)) {
        tracing::warn!("{} (pid {}) didn't stop; killing it", p.command, p.pid);
        unsafe { libc::kill(p.pid, libc::SIGKILL) };
    }
}

/// The background delete of a worktree's folder, moved aside by `take_away`.
pub type Deleting = tokio::task::JoinHandle<()>;

/// How long `git worktree remove` may take when the folder can't be moved aside.
const REMOVE_LIMIT: Duration = Duration::from_secs(600);
/// Looking at, fetching from or pushing to origin.
const REMOTE_LIMIT: Duration = Duration::from_secs(60);

/// Marks a worktree folder moved aside to be deleted: `<name>.maple-removing-<hex>`.
const ASIDE: &str = ".maple-removing-";

/// Takes the (checked) worktree at `path` out of git's list: moves its folder aside, which is
/// instant, lets `git worktree prune` forget it, and deletes the folder in the background with no
/// time limit, since node_modules or target/ can take minutes. If it can't be moved (another
/// filesystem, or busy), `git worktree remove [--force]` deletes it in place, for up to `limit`.
async fn take_away(root: &Path, path: &Path, force: bool, shown: &str, limit: Duration) -> Result<Option<Deleting>> {
    match move_aside(path) {
        Ok(aside) => {
            if let Err(e) = git(root, &["worktree", "prune"]).await {
                // Put it back as it was, so git still knows it.
                let _ = std::fs::rename(&aside, path);
                bail!("Couldn't remove {shown}: {e}");
            }
            Ok(Some(delete_in_background(root, path)))
        }
        Err(e) if !path.join(".git").exists() => {
            // Partly deleted already, so `git worktree remove` won't take it: delete what's left, then let git forget it.
            tracing::warn!("couldn't move {} aside ({e}); deleting what's left of it in place", path.display());
            let folder = path.to_path_buf();
            tokio::task::spawn_blocking(move || std::fs::remove_dir_all(folder)).await?.map_err(|e| anyhow!("Couldn't remove {shown}: {e}"))?;
            git(root, &["worktree", "prune"]).await.map_err(|e| anyhow!("Couldn't remove {shown}: {e}"))?;
            tidy(root, path);
            Ok(None)
        }
        Err(e) => {
            tracing::warn!("couldn't move {} aside ({e}); removing it in place", path.display());
            let path_str = path.to_string_lossy().into_owned();
            let mut args = vec!["worktree", "remove"];
            if force {
                args.push("--force");
            }
            args.push(&path_str);
            git_within(root, &args, limit).await.map_err(|e| match e.downcast_ref::<TimedOut>() {
                Some(_) => anyhow!("Removing {shown} timed out, so its folder may be partly deleted. Force remove will finish it."),
                None => anyhow!("Couldn't remove {shown}: {e}"),
            })?;
            tidy(root, path);
            Ok(None)
        }
    }
}

/// Renames `path` to a sibling `<name>.maple-removing-<hex>` (same folder, so same filesystem).
fn move_aside(path: &Path) -> std::io::Result<PathBuf> {
    #[cfg(test)]
    if tests::NO_RENAME.lock().unwrap().iter().any(|p| *p == canonical(path)) {
        return Err(std::io::Error::other("renaming is off for this test"));
    }
    let name = path.file_name().ok_or_else(|| std::io::Error::other("no folder name"))?;
    let hex = &uuid::Uuid::new_v4().simple().to_string()[..4];
    let aside = path.with_file_name(format!("{}{ASIDE}{hex}", name.to_string_lossy()));
    std::fs::rename(path, &aside)?;
    Ok(aside)
}

/// Deletes every folder moved aside next to `removed` (this one, and any left by a runner that
/// stopped mid-delete), then the empty folders above it.
fn delete_in_background(root: &Path, removed: &Path) -> Deleting {
    let (root, removed) = (root.to_path_buf(), removed.to_path_buf());
    tokio::task::spawn_blocking(move || {
        let Some(parent) = removed.parent() else { return };
        let Ok(read) = std::fs::read_dir(parent) else { return };
        for entry in read.flatten() {
            let name = entry.file_name();
            let aside = name
                .to_str()
                .and_then(|n| n.rsplit_once(ASIDE))
                .is_some_and(|(n, hex)| !n.is_empty() && !hex.is_empty() && hex.bytes().all(|b| b.is_ascii_hexdigit()));
            if !aside || !entry.file_type().is_ok_and(|t| t.is_dir()) {
                continue;
            }
            // Another removal may be deleting the same leftover.
            if let Err(e) = std::fs::remove_dir_all(entry.path())
                && e.kind() != std::io::ErrorKind::NotFound
            {
                tracing::warn!("couldn't delete {}: {e}", entry.path().display());
            }
        }
        tidy(&root, &removed);
    })
}

// ---- after a task's pull request is merged or closed ----

/// What `remove_task` did.
#[derive(Debug)]
pub struct Removed {
    pub message: String,
    pub branch_deleted: bool,
    /// The worktree folder's delete, still running in the background (it finishes on its own;
    /// tests wait for it).
    #[cfg_attr(not(test), allow(dead_code))]
    pub deleting: Option<Deleting>,
}

/// What a task's cleanup knows about the work (`task.cleanup`).
#[derive(Debug, Clone, Copy)]
pub struct TaskWork<'a> {
    /// The worktree, as the hub has it (`~`-abbreviated).
    pub cwd: &'a str,
    /// The repo folder the task was queued for (finds the repo when the worktree is already gone).
    pub repo_dir: &'a str,
    /// `agent/<name>`.
    pub branch: &'a str,
    /// The PR was merged (else closed without merging).
    pub merged: bool,
    /// The PR's head commit and the commit the task last pushed.
    pub heads: &'a [String],
    /// Merged, and its branch may still be on origin: delete it there too (see `delete_remote`).
    pub delete_remote: bool,
}

fn is_sha(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn short(sha: &str) -> &str {
    &sha[..sha.len().min(7)]
}

/// Removes a merged or closed task's worktree and its local branch, refusing if anything would be
/// lost: a session in it (`session_cwds`), uncommitted changes, or commits that aren't in the pull
/// request. HEAD must be one of `heads` (the PR's head, the commit the task pushed) or an ancestor of
/// one; for a merged PR it's also enough that every commit is on a remote or the default branch.
/// The branch goes with `git branch -d`, or `-D` only when HEAD matched what's on GitHub, and with it
/// its `origin/` tracking ref. A worktree that's already gone is fine (the branch still goes). The
/// branch on origin is left alone, unless `delete_remote` asks for it (see `delete_remote`).
pub async fn remove_task(session_cwds: &[String], w: TaskWork<'_>) -> Result<Removed> {
    let name = w.branch.strip_prefix(BRANCH_PREFIX).ok_or_else(|| anyhow!("`{}` isn't a task branch.", w.branch))?;
    valid_name(name)?;
    if let Some(h) = w.heads.iter().find(|h| !is_sha(h)) {
        bail!("`{h}` isn't a commit id.");
    }
    let dir = expand_home(w.cwd);
    let target = canonical(&dir);
    let root = match main_root(&dir).await {
        Ok(root) => root,
        Err(_) => main_root(&expand_home(w.repo_dir))
            .await
            .map_err(|e| anyhow!("{} isn't a git repository any more ({e}), so there's nothing to clean up there.", w.repo_dir))?,
    };
    let listed = list(&root).await?;
    let main = listed.first().ok_or_else(|| anyhow!("no worktrees"))?.clone();
    let found = listed.iter().enumerate().find(|(_, l)| canonical(&l.path) == target);
    // The worktree that's there (to remove), and the commit whose safety decides it all.
    let (worktree, tip) = match found {
        Some((0, _)) => bail!("{} is the repository's main checkout; only a task's worktree is removed.", w.cwd),
        Some((_, l)) if !l.path.is_dir() => {
            // Its folder was deleted by hand: let git forget it, then it's only the branch.
            let _ = git(&root, &["worktree", "prune"]).await;
            (None, None)
        }
        Some((_, l)) => {
            if l.branch.as_deref() != Some(w.branch) {
                bail!("{} has {} checked out, not {}, so it was left alone.", w.cwd, l.branch.as_deref().unwrap_or("a detached HEAD"), w.branch);
            }
            if session_cwds.iter().any(|c| canonical(&expand_home(c)).starts_with(&target)) {
                bail!("A session is still using {}. End it first.", w.cwd);
            }
            let changed = crate::git::status(&l.path).await.map(|s| s.changed).ok_or_else(|| anyhow!("Couldn't read the status of {}.", w.cwd))?;
            if changed > 0 {
                bail!("{} has {changed} uncommitted change{}, so it was left alone.", w.cwd, if changed == 1 { "" } else { "s" });
            }
            (Some(l.path.clone()), Some(l.head.clone()))
        }
        None if dir.exists() => bail!("{} isn't a worktree of {}, so it was left alone.", w.cwd, abbreviate(&root)),
        None => (None, None),
    };
    let branch_ref = format!("refs/heads/{}", w.branch);
    let tip = match tip {
        Some(t) => Some(t),
        None => git(&root, &["rev-parse", "--verify", "--quiet", &branch_ref]).await.ok().map(|s| s.trim().to_string()),
    };
    let Some(tip) = tip else {
        let mut message = format!("{} and {} were already gone", w.cwd, w.branch);
        if let Some(dropped) = drop_tracking_ref(&root, w.branch).await {
            message = format!("{message}, {dropped}");
        }
        if w.merged && w.delete_remote {
            message = format!("{message}, {}", delete_remote(&root, &main, &w).await);
        }
        poke(true);
        return Ok(Removed { message, branch_deleted: false, deleting: None });
    };

    // Is everything at `tip` on GitHub? It's the PR's head (or the push), or behind it.
    let mut on_github = false;
    for h in w.heads {
        if *h == tip || git(&root, &["merge-base", "--is-ancestor", &tip, h]).await.is_ok() {
            on_github = true;
            break;
        }
    }
    // A merged PR: also fine when nothing at `tip` is only here (a merge that brought it into the default branch).
    let only_here = if on_github || !w.merged {
        None
    } else {
        let mut args = vec!["rev-list", "--count", tip.as_str(), "--not", "--remotes"];
        let default = default_branch(&root, &main).await;
        if let Some((_, r)) = &default {
            args.push(r.as_str());
        }
        git(&root, &args).await.ok().and_then(|n| n.trim().parse::<u32>().ok())
    };
    if !on_github && only_here != Some(0) {
        let what = if worktree.is_some() { w.cwd.to_string() } else { w.branch.to_string() };
        let pr_head = w.heads.first().map(|h| short(h)).unwrap_or("unknown");
        bail!(
            "{what} has commits that aren't in the pull request (HEAD {} isn't the PR's head {pr_head} or behind it), so it was left alone. \
             Push them, or remove it yourself from Worktrees.",
            short(&tip)
        );
    }

    let mut done = Vec::new();
    let mut deleting = None;
    if let Some(path) = &worktree {
        deleting = take_away(&root, path, false, w.cwd, REMOVE_LIMIT).await?;
        done.push(format!("Removed {}", w.cwd));
    }
    let mut branch_deleted = false;
    if git(&root, &["show-ref", "--verify", "--quiet", &branch_ref]).await.is_ok() {
        // `-d` lets git double-check it's merged; `-D` only when HEAD was exactly what GitHub has.
        let deleted = match git(&root, &["branch", "-d", w.branch]).await {
            Ok(_) => Ok(()),
            Err(_) if on_github => git(&root, &["branch", "-D", w.branch]).await.map(|_| ()),
            Err(e) => Err(e),
        };
        match deleted {
            Ok(()) => {
                branch_deleted = true;
                done.push(format!("deleted branch {}", w.branch));
                done.extend(drop_tracking_ref(&root, w.branch).await);
            }
            Err(e) => {
                tracing::warn!("kept branch {}: {e}", w.branch);
                done.push(format!("kept branch {} ({e})", w.branch));
            }
        }
    }
    if done.is_empty() {
        done.push(format!("{} was already gone", w.cwd));
    }
    if w.merged && w.delete_remote {
        done.push(delete_remote(&root, &main, &w).await);
    }
    poke(true);
    Ok(Removed { message: done.join(", "), branch_deleted, deleting })
}

/// A merged task's branch off origin, for a merge whose own delete didn't happen (the hub asks with
/// `deleteRemote`): only while its tip there is one of `heads` or already in the default branch, and
/// with a lease on that tip, so a branch with work that didn't merge is kept. Says what it did.
async fn delete_remote(root: &Path, main: &Listed, w: &TaskWork<'_>) -> String {
    let branch_ref = format!("refs/heads/{}", w.branch);
    let listed = match git_within(root, &["ls-remote", "origin", &branch_ref], REMOTE_LIMIT).await {
        Ok(listed) => listed,
        Err(e) => return format!("couldn't look for {} on origin ({e})", w.branch),
    };
    let Some(tip) = listed.split_whitespace().next() else { return format!("{} was already gone on origin", w.branch) };
    let mut merged = w.heads.iter().any(|h| h == tip);
    let mut into = "the pull request".to_string();
    if !merged && let Some((name, _)) = default_branch(root, main).await {
        let _ = git_within(root, &["fetch", "--quiet", "origin", &name], REMOTE_LIMIT).await;
        merged = git(root, &["merge-base", "--is-ancestor", tip, &format!("refs/remotes/origin/{name}")]).await.is_ok();
        into = format!("the pull request or {name}");
    }
    if !merged {
        return format!("kept branch {} on origin (its tip {} isn't in {into})", w.branch, short(tip));
    }
    let lease = format!("--force-with-lease={branch_ref}:{tip}");
    match git_within(root, &["push", "--quiet", &lease, "origin", "--delete", w.branch], REMOTE_LIMIT).await {
        Ok(_) => format!("deleted branch {} on origin", w.branch),
        Err(e) => format!("couldn't delete branch {} on origin ({e})", w.branch),
    }
}

/// Deletes the stale `origin/<branch>` ref a deleted task branch leaves behind, if it's there.
/// Best-effort: says what it did, or nothing.
async fn drop_tracking_ref(root: &Path, branch: &str) -> Option<String> {
    let tracking = format!("refs/remotes/origin/{branch}");
    git(root, &["show-ref", "--verify", "--quiet", &tracking]).await.ok()?;
    match git(root, &["update-ref", "-d", &tracking]).await {
        Ok(_) => Some(format!("dropped origin/{branch}")),
        Err(e) => {
            tracing::warn!("kept origin/{branch}: {e}");
            None
        }
    }
}

/// Deletes empty folders from a removed worktree's up to `.worktrees/<repo>`.
fn tidy(root: &Path, removed: &Path) {
    let Ok(Some(base)) = worktree_path(root, "x").map(|p| p.parent().map(Path::to_path_buf)) else { return };
    let mut parent = removed.parent().map(Path::to_path_buf);
    while let Some(p) = parent {
        if !p.starts_with(&base) || std::fs::remove_dir(&p).is_err() {
            break;
        }
        parent = p.parent().map(Path::to_path_buf);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every worktree `inspect` looked at (tests run in parallel: filter by your own temp folder).
    pub(super) static INSPECTED: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());
    /// Worktrees (canonical paths) that `move_aside` refuses to rename.
    pub(super) static NO_RENAME: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

    /// What's been moved aside next to `wt`.
    fn asides(wt: &Path) -> Vec<String> {
        let Ok(read) = std::fs::read_dir(wt.parent().unwrap()) else { return Vec::new() };
        read.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| n.contains(ASIDE)).collect()
    }

    async fn finish(deleting: Option<Deleting>) {
        deleting.expect("the folder was moved aside").await.unwrap();
    }

    /// A repo with a task worktree on agent/fix, its PR "pushed" (the commit id is the PR head).
    fn repo_with_task(tag: &str) -> (PathBuf, PathBuf, PathBuf, String) {
        let root = std::env::temp_dir().join(format!("maple-cleanup-{tag}-{}", uuid::Uuid::new_v4()));
        let repo = root.join("app");
        std::fs::create_dir_all(&repo).unwrap();
        let sh = |dir: &Path, args: &[&str]| sh(dir, args);
        sh(&repo, &["init", "--quiet", "-b", "main"]);
        sh(&repo, &["config", "user.name", "Test"]);
        sh(&repo, &["config", "user.email", "t@example.com"]);
        sh(&repo, &["config", "commit.gpgsign", "false"]);
        std::fs::write(repo.join("a.txt"), "one\n").unwrap();
        sh(&repo, &["add", "-A"]);
        sh(&repo, &["commit", "--quiet", "-m", "first"]);
        let wt = worktree_path(&repo, "fix").unwrap();
        sh(&repo, &["worktree", "add", "--quiet", "-b", "agent/fix", wt.to_str().unwrap()]);
        std::fs::write(wt.join("a.txt"), "two\n").unwrap();
        sh(&wt, &["commit", "--quiet", "-am", "Fix it"]);
        let head = sh(&wt, &["rev-parse", "HEAD"]);
        (root, repo, wt, head)
    }

    fn sh(dir: &Path, args: &[&str]) -> String {
        let out = std::process::Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn work<'a>(wt: &'a str, repo: &'a str, merged: bool, heads: &'a [String]) -> TaskWork<'a> {
        TaskWork { cwd: wt, repo_dir: repo, branch: "agent/fix", merged, heads, delete_remote: false }
    }

    #[tokio::test]
    async fn removes_a_closed_tasks_worktree_when_head_is_the_prs() {
        let (root, repo, wt, head) = repo_with_task("closed");
        let (wts, repos) = (wt.to_string_lossy().into_owned(), repo.to_string_lossy().into_owned());
        let heads = [head];
        // A session in it: refused.
        let err = remove_task(std::slice::from_ref(&wts), work(&wts, &repos, false, &heads)).await.unwrap_err().to_string();
        assert!(err.contains("session is still using"), "{err}");
        // Uncommitted changes: refused.
        std::fs::write(wt.join("b.txt"), "new\n").unwrap();
        let err = remove_task(&[], work(&wts, &repos, false, &heads)).await.unwrap_err().to_string();
        assert!(err.contains("uncommitted"), "{err}");
        std::fs::remove_file(wt.join("b.txt")).unwrap();
        // HEAD is the PR's head: removed, and the unmerged branch goes with -D.
        let done = remove_task(&[], work(&wts, &repos, false, &heads)).await.unwrap();
        assert!(done.branch_deleted, "{}", done.message);
        assert!(!wt.exists());
        assert!(sh(&repo, &["branch", "--list", "agent/fix"]).is_empty());
        // Moved aside and pruned, then deleted in the background.
        assert!(!sh(&repo, &["worktree", "list"]).contains("/fix"));
        finish(done.deleting).await;
        assert!(!wt.parent().unwrap().exists(), "{:?}", wt.parent());
        // Again: nothing left, still fine.
        let again = remove_task(&[], work(&wts, &repos, false, &heads)).await.unwrap();
        assert!(again.message.contains("already gone"), "{}", again.message);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn refuses_commits_that_arent_in_the_pr() {
        let (root, repo, wt, head) = repo_with_task("extra");
        let (wts, repos) = (wt.to_string_lossy().into_owned(), repo.to_string_lossy().into_owned());
        std::fs::write(wt.join("a.txt"), "three\n").unwrap();
        sh(&wt, &["commit", "--quiet", "-am", "More after the PR"]);
        let heads = [head.clone()];
        for merged in [false, true] {
            let err = remove_task(&[], work(&wts, &repos, merged, &heads)).await.unwrap_err().to_string();
            assert!(err.contains("aren't in the pull request") && err.contains(&head[..7]), "{err}");
            assert!(wt.exists());
        }
        // No PR head known at all: refused too.
        assert!(remove_task(&[], work(&wts, &repos, false, &[])).await.is_err());
        // Behind the PR's head (someone pushed more to the PR, and we have it): fine.
        sh(&wt, &["reset", "--quiet", "--hard", "HEAD~1"]);
        std::fs::write(wt.join("a.txt"), "four\n").unwrap();
        sh(&wt, &["commit", "--quiet", "-am", "Pushed by someone else"]);
        let newer = sh(&wt, &["rev-parse", "HEAD"]);
        sh(&wt, &["reset", "--quiet", "--hard", "HEAD~1"]);
        let done = remove_task(&[], work(&wts, &repos, false, &[newer])).await.unwrap();
        assert!(done.branch_deleted && !wt.exists(), "{}", done.message);
        finish(done.deleting).await;
        // Bad input never reaches git.
        assert!(remove_task(&[], TaskWork { branch: "main", ..work(&wts, &repos, true, &[]) }).await.is_err());
        assert!(remove_task(&[], work(&wts, &repos, true, &["HEAD".into()])).await.is_err());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn a_merged_pr_without_the_head_is_fine_once_merged_locally() {
        let (root, repo, wt, _) = repo_with_task("merged");
        let (wts, repos) = (wt.to_string_lossy().into_owned(), repo.to_string_lossy().into_owned());
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        let done = remove_task(&[], work(&wts, &repos, true, &[])).await.unwrap();
        assert!(done.branch_deleted && !wt.exists(), "{}", done.message);
        finish(done.deleting).await;
        assert!(asides(&repo.join("x")).is_empty());
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// `delete_remote` after a merge whose own delete didn't happen: a branch on origin with work that
    /// didn't merge is kept; once that work is in the default branch it's deleted; then it's gone.
    #[tokio::test]
    async fn cleanup_deletes_a_merged_leftover_on_origin_but_never_unmerged_work() {
        let (root, repo, wt, head) = repo_with_task("remote");
        let (wts, repos) = (wt.to_string_lossy().into_owned(), repo.to_string_lossy().into_owned());
        let bare = root.join("origin.git");
        sh(&root, &["init", "--quiet", "--bare", "-b", "main", bare.to_str().unwrap()]);
        sh(&repo, &["remote", "add", "origin", bare.to_str().unwrap()]);
        sh(&repo, &["push", "--quiet", "origin", "main", "agent/fix"]);
        sh(&repo, &["remote", "set-head", "origin", "main"]);
        // Someone else pushed to the branch: that commit isn't in the PR or in main.
        let other = sh(
            &bare,
            &["-c", "user.name=O", "-c", "user.email=o@example.com", "commit-tree", "agent/fix^{tree}", "-p", "agent/fix", "-m", "someone else's push"],
        );
        sh(&bare, &["update-ref", "refs/heads/agent/fix", &other]);
        let heads = [head];
        let w = TaskWork { delete_remote: true, ..work(&wts, &repos, true, &heads) };

        let done = remove_task(&[], w).await.unwrap();
        assert!(done.branch_deleted && !wt.exists(), "{}", done.message);
        finish(done.deleting).await;
        assert!(
            done.message.ends_with(&format!("kept branch agent/fix on origin (its tip {} isn't in the pull request or main)", &other[..7])),
            "{}",
            done.message
        );
        assert_eq!(sh(&bare, &["rev-parse", "agent/fix"]), other);

        // That commit merged into main after all: now the leftover goes (the local branch already has).
        sh(&bare, &["update-ref", "refs/heads/main", &other]);
        let done = remove_task(&[], w).await.unwrap();
        assert!(done.message.ends_with("deleted branch agent/fix on origin"), "{}", done.message);
        assert_eq!(sh(&bare, &["branch", "--list", "agent/*"]), "");

        let done = remove_task(&[], w).await.unwrap();
        assert!(done.message.ends_with("agent/fix was already gone on origin"), "{}", done.message);
        // Without delete_remote (or for a closed PR), origin isn't asked at all.
        sh(&bare, &["update-ref", "refs/heads/agent/fix", &other]);
        for w in [work(&wts, &repos, true, &heads), TaskWork { delete_remote: true, ..work(&wts, &repos, false, &heads) }] {
            let done = remove_task(&[], w).await.unwrap();
            assert!(!done.message.contains("on origin"), "{}", done.message);
        }
        assert_eq!(sh(&bare, &["rev-parse", "agent/fix"]), other);
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// After a merge: the worktree, the local branch and the stale origin/agent/… ref all go.
    #[tokio::test]
    async fn cleanup_after_a_merge_drops_the_tracking_ref_too() {
        let (root, repo, wt, head) = repo_with_task("tracking");
        let (wts, repos) = (wt.to_string_lossy().into_owned(), repo.to_string_lossy().into_owned());
        let bare = root.join("origin.git");
        sh(&root, &["init", "--quiet", "--bare", bare.to_str().unwrap()]);
        sh(&repo, &["remote", "add", "origin", bare.to_str().unwrap()]);
        sh(&repo, &["push", "--quiet", "origin", "main", "agent/fix"]);
        sh(&repo, &["fetch", "--quiet", "origin"]);
        assert_eq!(sh(&repo, &["rev-parse", "refs/remotes/origin/agent/fix"]), head);
        // The factory merged it and deleted the branch on GitHub; this checkout still tracks it.
        sh(&bare, &["branch", "-D", "agent/fix"]);
        let heads = [head];
        let done = remove_task(&[], work(&wts, &repos, true, &heads)).await.unwrap();
        assert!(done.branch_deleted && done.message.contains("dropped origin/agent/fix"), "{}", done.message);
        finish(done.deleting).await;
        assert!(!wt.exists());
        assert!(!sh(&repo, &["worktree", "list"]).contains("/fix"));
        assert_eq!(sh(&repo, &["branch", "-a", "--list", "*agent/fix"]), "");
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn force_removes_a_merged_worktree_with_changes_and_nothing_else() {
        let (root, repo, wt, _) = repo_with_task("force");
        let (wts, repos) = (wt.to_string_lossy().into_owned(), repo.to_string_lossy().into_owned());
        // Unmerged (a commit off main): refused, force or not.
        for force in [false, true] {
            let err = remove_checked(&nobody(), &wts, force).await.unwrap_err().to_string();
            assert!(err.contains("merged"), "{err}");
        }
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        std::fs::write(wt.join("a.txt"), "dirty\n").unwrap();
        std::fs::write(wt.join("new.txt"), "untracked\n").unwrap();
        // Merged with changes: refused without force.
        let err = remove_checked(&nobody(), &wts, false).await.unwrap_err().to_string();
        assert!(err.contains("uncommitted"), "{err}");
        // The main checkout and a worktree in use: refused with force too.
        let err = remove_checked(&nobody(), &repos, true).await.unwrap_err().to_string();
        assert!(err.contains("main checkout"), "{err}");
        // A commit that isn't pushed or merged: refused with force.
        std::fs::write(wt.join("c.txt"), "later\n").unwrap();
        sh(&wt, &["add", "c.txt"]);
        sh(&wt, &["commit", "--quiet", "-m", "After the merge"]);
        let err = remove_checked(&nobody(), &wts, true).await.unwrap_err().to_string();
        assert!(err.contains("merged"), "{err}");
        sh(&wt, &["reset", "--quiet", "HEAD~1"]);
        // Force: removed, changes and all, and the merged branch goes.
        let (done, deleting) = remove_checked(&nobody(), &wts, true).await.unwrap();
        assert!(done.contains("branch agent/fix"), "{done}");
        assert!(!wt.exists());
        assert!(sh(&repo, &["branch", "--list", "agent/fix"]).is_empty());
        finish(deleting).await;
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn removes_a_clean_merged_worktree_without_force() {
        let (root, repo, wt, _) = repo_with_task("clean");
        let wts = wt.to_string_lossy().into_owned();
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        // Leftovers from a runner that stopped mid-delete go too; other folders stay.
        let parent = wt.parent().unwrap().to_path_buf();
        std::fs::create_dir_all(parent.join("old.maple-removing-be3f/node_modules")).unwrap();
        std::fs::write(parent.join("old.maple-removing-be3f/node_modules/x.js"), "x").unwrap();
        std::fs::create_dir_all(parent.join("keep.maple-removing-later")).unwrap();
        let (done, deleting) = remove_checked(&nobody(), &wts, false).await.unwrap();
        assert!(done.contains("branch agent/fix") && !wt.exists(), "{done}");
        // Git has forgotten it and the branch is gone as soon as it returns; the folder was moved aside.
        assert!(!sh(&repo, &["worktree", "list", "--porcelain"]).contains("/fix"));
        assert!(sh(&repo, &["branch", "--list", "agent/fix"]).is_empty());
        finish(deleting).await;
        assert_eq!(asides(&wt), ["keep.maple-removing-later"]);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn a_half_deleted_worktree_needs_force() {
        let (root, repo, wt, _) = repo_with_task("half");
        let wts = wt.to_string_lossy().into_owned();
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        // What a killed `git worktree remove` leaves: some tracked files already gone.
        std::fs::write(wt.join("b.txt"), "two\n").unwrap();
        sh(&wt, &["add", "b.txt"]);
        sh(&wt, &["commit", "--quiet", "-m", "b"]);
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        std::fs::remove_file(wt.join("a.txt")).unwrap();
        std::fs::remove_file(wt.join("b.txt")).unwrap();
        let err = remove_checked(&nobody(), &wts, false).await.unwrap_err().to_string();
        assert!(err.contains("2 uncommitted changes"), "{err}");
        let (_, deleting) = remove_checked(&nobody(), &wts, true).await.unwrap();
        finish(deleting).await;
        assert!(!wt.exists() && asides(&wt).is_empty());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn removes_in_place_when_the_folder_cant_be_moved() {
        let (root, repo, wt, _) = repo_with_task("inplace");
        let wts = wt.to_string_lossy().into_owned();
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        std::fs::write(wt.join("new.txt"), "untracked\n").unwrap();
        NO_RENAME.lock().unwrap().push(canonical(&wt));
        // Out of time: killed partway, and the message says Force remove finishes it.
        let err = take_away(&repo, &wt, true, &wts, Duration::from_nanos(1)).await.unwrap_err().to_string();
        assert!(err.contains("may be partly deleted") && err.contains("Force remove will finish it"), "{err}");
        // `git worktree remove --force`, with time to finish: no background delete.
        let (done, deleting) = remove_checked(&nobody(), &wts, true).await.unwrap();
        assert!(done.contains("branch agent/fix") && deleting.is_none(), "{done}");
        assert!(!wt.exists() && !sh(&repo, &["worktree", "list"]).contains("/fix"));
        NO_RENAME.lock().unwrap().retain(|p| *p != canonical(&wt));
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// What a removal cut off after git deleted the worktree's `.git` leaves: some files, and git's record of it.
    fn lose_git_file(wt: &Path) {
        std::fs::remove_file(wt.join(".git")).unwrap();
        std::fs::remove_file(wt.join("a.txt")).unwrap();
    }

    #[tokio::test]
    async fn force_finishes_a_removal_that_lost_its_git_file() {
        let (root, repo, wt, _) = repo_with_task("nogit");
        let wts = wt.to_string_lossy().into_owned();
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        std::fs::create_dir_all(wt.join("node_modules")).unwrap();
        std::fs::write(wt.join("node_modules/x.js"), "x").unwrap();
        lose_git_file(&wt);
        // Without force: refused, and left as it was.
        let err = remove_checked(&nobody(), &wts, false).await.unwrap_err().to_string();
        assert_eq!(err, format!("{wts} was partly deleted by a removal that was cut off. Force remove will finish it."));
        assert!(wt.join("node_modules/x.js").exists() && sh(&repo, &["worktree", "list"]).contains("/fix"));
        // Force: moved aside, forgotten, deleted, and the merged branch goes.
        let (done, deleting) = remove_checked(&nobody(), &wts, true).await.unwrap();
        assert!(done.contains("branch agent/fix"), "{done}");
        finish(deleting).await;
        assert!(!wt.exists() && asides(&wt).is_empty());
        assert!(!sh(&repo, &["worktree", "list"]).contains("/fix"));
        assert!(sh(&repo, &["branch", "--list", "agent/fix"]).is_empty());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn force_finishes_a_removal_that_lost_its_git_file_in_place() {
        let (root, repo, wt, _) = repo_with_task("nogit-inplace");
        let wts = wt.to_string_lossy().into_owned();
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        NO_RENAME.lock().unwrap().push(canonical(&wt));
        lose_git_file(&wt);
        let (done, deleting) = remove_checked(&nobody(), &wts, true).await.unwrap();
        assert!(done.contains("branch agent/fix") && deleting.is_none(), "{done}");
        assert!(!wt.exists() && asides(&wt).is_empty());
        assert!(!sh(&repo, &["worktree", "list"]).contains("/fix"));
        assert!(sh(&repo, &["branch", "--list", "agent/fix"]).is_empty());
        NO_RENAME.lock().unwrap().retain(|p| *p != canonical(&wt));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn a_worktree_without_its_git_file_is_still_checked() {
        let (root, repo, wt, _) = repo_with_task("nogit-checks");
        let wts = wt.to_string_lossy().into_owned();
        lose_git_file(&wt);
        // Unmerged: refused, force or not.
        for force in [false, true] {
            let err = remove_checked(&nobody(), &wts, force).await.unwrap_err().to_string();
            assert!(err.contains("isn't merged"), "{err}");
        }
        // A commit after the merge that isn't pushed or merged (the branch moved on, as from the folder).
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        let tip = sh(&repo, &["rev-parse", "agent/fix"]);
        let after = sh(&repo, &["commit-tree", "-p", &tip, "-m", "After the merge", &format!("{tip}^{{tree}}")]);
        sh(&repo, &["update-ref", "refs/heads/agent/fix", &after]);
        let err = remove_checked(&nobody(), &wts, true).await.unwrap_err().to_string();
        assert!(err.contains("merged"), "{err}");
        sh(&repo, &["update-ref", "refs/heads/agent/fix", &tip]);
        // A session in it that won't end, and a locked entry.
        let stuck = Fake { live: Mutex::new(vec![session(&wt)]), stubborn: true, ..Fake::default() };
        let err = remove_checked(&stuck, &wts, true).await.unwrap_err().to_string();
        assert!(err.starts_with("Couldn't end Claude Code ("), "{err}");
        std::fs::write(repo.join(".git/worktrees/fix/locked"), "on a usb stick").unwrap();
        let err = remove_checked(&nobody(), &wts, true).await.unwrap_err().to_string();
        assert!(err.contains("locked (on a usb stick)"), "{err}");
        assert!(wt.is_dir() && sh(&repo, &["worktree", "list"]).contains("/fix"));
        std::fs::remove_file(repo.join(".git/worktrees/fix/locked")).unwrap();
        let (_, deleting) = remove_checked(&nobody(), &wts, true).await.unwrap();
        finish(deleting).await;
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn a_folder_no_repo_lists_is_never_deleted() {
        let (root, repo, wt, _) = repo_with_task("stray");
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        let stray = worktree_path(&repo, "stray").unwrap();
        std::fs::create_dir_all(&stray).unwrap();
        std::fs::write(stray.join("keep.txt"), "mine\n").unwrap();
        let strays = stray.to_string_lossy().into_owned();
        for force in [false, true] {
            let err = remove_checked(&nobody(), &strays, force).await.unwrap_err().to_string();
            assert!(err.contains("isn't a worktree"), "{err}");
        }
        assert!(stray.join("keep.txt").exists() && wt.join(".git").exists());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn checks_only_the_worktree_being_removed() {
        let (root, repo, wt, _) = repo_with_task("only");
        let wts = wt.to_string_lossy().into_owned();
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        for name in ["one", "two"] {
            let other = worktree_path(&repo, name).unwrap();
            sh(&repo, &["worktree", "add", "--quiet", "-b", &format!("agent/{name}"), other.to_str().unwrap()]);
        }
        let (_, deleting) = remove_checked(&nobody(), &wts, false).await.unwrap();
        finish(deleting).await;
        let mine = canonical(&root);
        let seen: Vec<PathBuf> = INSPECTED.lock().unwrap().iter().map(|p| canonical(p)).filter(|p| p.starts_with(&mine)).collect();
        assert_eq!(seen, [canonical(&repo).parent().unwrap().join(".worktrees/app/fix")]);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn refuses_when_status_cant_be_read() {
        let (root, repo, wt, _) = repo_with_task("status");
        let wts = wt.to_string_lossy().into_owned();
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        // A broken index: `git status` fails, which mustn't read as "no changes".
        std::fs::write(repo.join(".git/worktrees/fix/index"), "not an index").unwrap();
        for force in [false, true] {
            let err = remove_checked(&nobody(), &wts, force).await.unwrap_err().to_string();
            assert_eq!(err, format!("Couldn't read the status of {wts}."));
        }
        assert!(wt.exists());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn refuses_a_locked_worktree_even_with_force() {
        let (root, repo, wt, _) = repo_with_task("locked");
        let wts = wt.to_string_lossy().into_owned();
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        sh(&repo, &["worktree", "lock", "--reason", "on a usb stick", &wts]);
        for force in [false, true] {
            let err = remove_checked(&nobody(), &wts, force).await.unwrap_err().to_string();
            assert!(err.contains("locked (on a usb stick)") && err.contains("git worktree unlock "), "{err}");
        }
        sh(&repo, &["worktree", "unlock", &wts]);
        sh(&repo, &["worktree", "lock", &wts]);
        let err = remove_checked(&nobody(), &wts, true).await.unwrap_err().to_string();
        assert!(err.contains("is locked.") && err.contains("git worktree unlock "), "{err}");
        assert!(wt.exists());
        sh(&repo, &["worktree", "unlock", &wts]);
        let (_, deleting) = remove_checked(&nobody(), &wts, false).await.unwrap();
        finish(deleting).await;
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Sessions for `remove_checked`: `end` takes one off the list, unless it's `stubborn`.
    #[derive(Default)]
    struct Fake {
        live: Mutex<Vec<SessionInfo>>,
        ended: Mutex<Vec<Uuid>>,
        stubborn: bool,
    }

    impl Occupants for Fake {
        fn sessions(&self) -> Vec<SessionInfo> {
            self.live.lock().unwrap().clone()
        }

        fn end(&self, id: Uuid) -> impl Future<Output = ()> + Send {
            self.ended.lock().unwrap().push(id);
            if !self.stubborn {
                self.live.lock().unwrap().retain(|s| s.id != id);
            }
            async {}
        }
    }

    fn nobody() -> Fake {
        Fake::default()
    }

    fn session(cwd: &Path) -> SessionInfo {
        SessionInfo { id: Uuid::new_v4(), agent: "claude".into(), cwd: cwd.to_string_lossy().into_owned(), pid: None, started_at: 0 }
    }

    #[tokio::test]
    async fn force_ends_the_sessions_in_a_merged_worktree() {
        let (root, repo, wt, _) = repo_with_task("sessions");
        let wts = wt.to_string_lossy().into_owned();
        let (inside, elsewhere) = (session(&wt.join("sub")), session(&repo));
        std::fs::create_dir_all(wt.join("sub")).unwrap();
        let fake = Fake { live: Mutex::new(vec![inside.clone(), elsewhere.clone()]), ..Fake::default() };
        let name = format!("Claude Code ({})", &inside.id.simple().to_string()[..8]);
        // Not merged: refused, force or not, and nothing is ended.
        for force in [false, true] {
            let err = remove_checked(&fake, &wts, force).await.unwrap_err().to_string();
            assert!(err.contains("merged"), "{err}");
        }
        assert!(fake.ended.lock().unwrap().is_empty());
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        // Without force: names the session and says Force remove will end it.
        let err = remove_checked(&fake, &wts, false).await.unwrap_err().to_string();
        assert_eq!(err, format!("{name} is still running in {wts}. Force remove will end it."));
        // Changes still come first without force.
        std::fs::write(wt.join("new.txt"), "untracked\n").unwrap();
        let err = remove_checked(&fake, &wts, false).await.unwrap_err().to_string();
        assert!(err.contains("uncommitted"), "{err}");
        assert!(fake.ended.lock().unwrap().is_empty() && wt.exists());
        // Force: the session in it is ended, the one elsewhere isn't, and it's removed.
        let (done, deleting) = remove_checked(&fake, &wts, true).await.unwrap();
        assert!(done.contains("branch agent/fix") && !wt.exists(), "{done}");
        assert_eq!(*fake.ended.lock().unwrap(), [inside.id]);
        assert_eq!(fake.sessions().len(), 1);
        finish(deleting).await;
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn refuses_when_a_session_wont_end() {
        let (root, repo, wt, _) = repo_with_task("stubborn");
        let wts = wt.to_string_lossy().into_owned();
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        let (one, two) = (session(&wt), session(&wt));
        let fake = Fake { live: Mutex::new(vec![one.clone(), two.clone()]), stubborn: true, ..Fake::default() };
        let label = |s: &SessionInfo| format!("Claude Code ({})", &s.id.simple().to_string()[..8]);
        let err = remove_checked(&fake, &wts, false).await.unwrap_err().to_string();
        assert_eq!(err, format!("{} and {} are still running in {wts}. Force remove will end them.", label(&one), label(&two)));
        let err = remove_checked(&fake, &wts, true).await.unwrap_err().to_string();
        assert_eq!(err, format!("Couldn't end {} and {} in {wts}.", label(&one), label(&two)));
        assert_eq!(fake.ended.lock().unwrap().len(), 2);
        assert!(wt.exists() && sh(&repo, &["worktree", "list"]).contains("/fix"));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn force_stops_programs_running_in_the_worktree() {
        if std::process::Command::new("lsof").arg("-v").output().is_err() {
            eprintln!("no lsof here; skipping");
            return;
        }
        let (root, repo, wt, _) = repo_with_task("programs");
        let wts = wt.to_string_lossy().into_owned();
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        // Started from a shell that exits at once, so it isn't this test's child (nothing here reaps it).
        let out = std::process::Command::new("sh").args(["-c", "sleep 300 >/dev/null 2>&1 & echo $!"]).current_dir(&wt).output().unwrap();
        let pid: i32 = String::from_utf8_lossy(&out.stdout).trim().parse().unwrap();
        let alive = |pid: i32| unsafe { libc::kill(pid, 0) == 0 };
        let found = programs_in(&canonical(&wt)).await;
        assert_eq!(found, [Program { pid, command: "sleep".into() }]);
        // Without force: refused, naming it, and it keeps running.
        let err = remove_checked(&nobody(), &wts, false).await.unwrap_err().to_string();
        assert_eq!(err, format!("{wts} has sleep (pid {pid}) still running in it. Force remove will end it."));
        assert!(alive(pid) && wt.exists());
        // Force: stopped, then removed.
        let (_, deleting) = remove_checked(&nobody(), &wts, true).await.unwrap();
        assert!(!wt.exists());
        let gone = Instant::now() + Duration::from_secs(5);
        while alive(pid) && Instant::now() < gone {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        let still = alive(pid);
        unsafe { libc::kill(pid, libc::SIGKILL) };
        assert!(!still, "sleep (pid {pid}) is still running");
        finish(deleting).await;
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn parses_lsof() {
        let out = "p100\ncnode\nfcwd\nn/w/app/fix\np200\nczsh\nfcwd\nn/w/app/fixed\np300\ncvite\nfcwd\nn/w/app/fix/web\np400\ncbash\nfcwd\nn/\n";
        let found = parse_lsof(out, Path::new("/w/app/fix"));
        assert_eq!(found, [Program { pid: 100, command: "node".into() }, Program { pid: 300, command: "vite".into() }]);
        // This runner is never in the list, even when it runs inside the worktree.
        let me = canonical(&std::env::current_dir().unwrap());
        assert!(!block_on(programs_in(&me)).iter().any(|p| p.pid == std::process::id() as i32));
    }

    fn block_on<F: Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    #[test]
    fn lists_with_and() {
        let s = |v: &[&str]| and_list(&v.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        assert_eq!((s(&["a"]).as_str(), s(&["a", "b"]).as_str(), s(&["a", "b", "c"]).as_str()), ("a", "a and b", "a, b and c"));
    }

    #[tokio::test]
    async fn a_worktree_thats_already_gone_counts_as_removed() {
        let (root, repo, wt, _) = repo_with_task("gone");
        let wts = wt.to_string_lossy().into_owned();
        sh(&repo, &["merge", "--quiet", "--ff-only", "agent/fix"]);
        let (_, deleting) = remove_checked(&nobody(), &wts, true).await.unwrap();
        finish(deleting).await;
        // A session's exit cleanup after Force remove ended it: already gone, and git doesn't list it.
        let (done, deleting) = remove_checked(&nobody(), &wts, false).await.unwrap();
        assert!(done.contains("already gone") && deleting.is_none(), "{done}");
        // A folder deleted by hand that git still lists isn't "gone".
        let other = worktree_path(&repo, "other").unwrap();
        sh(&repo, &["worktree", "add", "--quiet", "-b", "agent/other", other.to_str().unwrap()]);
        std::fs::remove_dir_all(&other).unwrap();
        assert!(remove_checked(&nobody(), other.to_str().unwrap(), true).await.is_err());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn names() {
        for ok in ["fix-tests", "health/endpoint", "v2.1", "a_b"] {
            assert!(valid_name(ok).is_ok(), "{ok}");
        }
        for bad in ["", "/x", "x/", "a..b", "a//b", ".hidden", "a/.b", "x.lock", "x.", "-x", "has space", "a~b", "a:b", "a^b", "a@{b", &"x".repeat(101)] {
            assert!(valid_name(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn paths() {
        assert_eq!(worktree_path(Path::new("/home/me/Projects/app"), "fix/tests").unwrap(), PathBuf::from("/home/me/Projects/.worktrees/app/fix/tests"));
        assert!(worktree_path(Path::new("/"), "x").is_err());
    }

    #[test]
    fn parses_worktree_list() {
        let out = "worktree /p/app\nHEAD aaa\nbranch refs/heads/main\n\nworktree /p/.worktrees/app/x\nHEAD bbb\nbranch refs/heads/agent/x\n\nworktree /p/.worktrees/app/d\nHEAD ccc\ndetached\n\n";
        let l = parse_list(out);
        assert_eq!(l.len(), 3);
        assert_eq!((l[0].path.to_str(), l[0].branch.as_deref()), (Some("/p/app"), Some("main")));
        assert_eq!((l[1].head.as_str(), l[1].branch.as_deref()), ("bbb", Some("agent/x")));
        assert_eq!(l[2].branch, None);
        assert!(parse_list("worktree /r\nbare\n")[0].bare);
        let locked = parse_list(
            "worktree /r\nHEAD a\nbranch refs/heads/main\n\nworktree /w\nHEAD b\ndetached\nlocked\n\nworktree /v\nHEAD c\ndetached\nlocked on a usb stick\n",
        );
        assert_eq!((locked[0].locked.as_deref(), locked[1].locked.as_deref(), locked[2].locked.as_deref()), (None, Some(""), Some("on a usb stick")));
    }

    /// A commit on its own on top of `parent` in `repo`, without moving any branch; returns its id.
    fn loose_commit(repo: &Path, parent: &str, file: &str, msg: &str) -> String {
        sh(repo, &["switch", "--quiet", "--detach", parent]);
        std::fs::write(repo.join(file), msg).unwrap();
        sh(repo, &["add", "-A"]);
        sh(repo, &["commit", "--quiet", "-m", msg]);
        let id = sh(repo, &["rev-parse", "HEAD"]);
        sh(repo, &["switch", "--quiet", "main"]);
        id
    }

    /// Retry on another machine: the task's branch is only on origin (the old machine pushed it), so
    /// the worktree carries on from there, not from the base; with nothing on origin it starts from
    /// the base; a local branch origin has moved past is moved up, and one with work of its own isn't.
    #[tokio::test]
    async fn create_from_carries_on_from_the_branch_on_origin() {
        let (root, repo, _, _) = repo_with_task("carry");
        let main = sh(&repo, &["rev-parse", "main"]);
        let pushed = loose_commit(&repo, &main, "studio.txt", "WIP: on studio-mac");
        sh(&repo, &["update-ref", "refs/remotes/origin/agent/carry-0001", &pushed]);

        let wt = expand_home(&create_from(&repo, "carry-0001", "main").await.unwrap());
        assert_eq!(sh(&wt, &["rev-parse", "HEAD"]), pushed);
        assert_eq!(sh(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]), "agent/carry-0001");
        assert_eq!(std::fs::read_to_string(wt.join("studio.txt")).unwrap(), "WIP: on studio-mac");
        // No upstream: pushes always name the branch.
        assert!(!std::process::Command::new("git").arg("-C").arg(&wt).args(["rev-parse", "@{u}"]).output().unwrap().status.success());

        // Nothing on origin: from the base.
        let fresh = expand_home(&create_from(&repo, "fresh-0002", "main").await.unwrap());
        assert_eq!(sh(&fresh, &["rev-parse", "HEAD"]), main);

        // The task went away and came back: its local branch (worktree gone) is behind origin's.
        sh(&repo, &["worktree", "remove", "--force", wt.to_str().unwrap()]);
        let later = loose_commit(&repo, &pushed, "laptop.txt", "on laptop");
        sh(&repo, &["update-ref", "refs/remotes/origin/agent/carry-0001", &later]);
        let wt = expand_home(&create_from(&repo, "carry-0001", "main").await.unwrap());
        assert_eq!(sh(&wt, &["rev-parse", "HEAD"]), later);

        // A local branch with commits origin doesn't have stays as it is.
        sh(&repo, &["worktree", "remove", "--force", wt.to_str().unwrap()]);
        let mine = loose_commit(&repo, &later, "local.txt", "local only");
        sh(&repo, &["update-ref", "refs/heads/agent/carry-0001", &mine]);
        let other = loose_commit(&repo, &later, "other.txt", "elsewhere");
        sh(&repo, &["update-ref", "refs/remotes/origin/agent/carry-0001", &other]);
        let wt = expand_home(&create_from(&repo, "carry-0001", "main").await.unwrap());
        assert_eq!(sh(&wt, &["rev-parse", "HEAD"]), mine);
        std::fs::remove_dir_all(&root).unwrap();
    }

    fn scripts(create: Option<&str>, setup: Option<&str>) -> crate::worktree_scripts::WorktreeScripts {
        crate::worktree_scripts::WorktreeScripts {
            create: create.map(String::from),
            preflight: None,
            preflight_watch: None,
            setup: setup.map(String::from),
            checks: None,
            teardown: None,
            archive: None,
            timeout_secs: Some(30),
        }
    }

    fn for_task<'a>(s: &'a crate::worktree_scripts::WorktreeScripts, env: &'a [(String, String)]) -> crate::worktree_scripts::ForTask<'a> {
        crate::worktree_scripts::ForTask { scripts: s, task_id: "MF-9", repo: Some("acme/app"), base: Some("main"), env, emit: None, path: None }
    }

    /// The repo's create script makes the worktree (here with its own `git worktree add`, plus a file of
    /// its own), and setup then runs with MAPLE_WORKTREE pointing at it.
    #[tokio::test]
    async fn a_create_script_makes_the_worktree_and_setup_runs_in_it() {
        let (root, repo, _, _) = repo_with_task("script-create");
        let s = scripts(
            Some(r#"git worktree add --quiet -b "$MAPLE_BRANCH" "$MAPLE_WORKTREE" "$MAPLE_BASE" && echo made-by-script > "$MAPLE_WORKTREE/marker""#),
            Some(r#"echo "$MAPLE_PHASE for $MAPLE_TASK_ID in $PWD" > "$MAPLE_WORKTREE/setup.txt""#),
        );
        let env = vec![];
        let wt = expand_home(&create_with(&repo, "mf-9", "main", Some(&for_task(&s, &env))).await.unwrap());
        assert_eq!(wt, worktree_path(&repo, "mf-9").unwrap());
        assert_eq!(sh(&wt, &["rev-parse", "--abbrev-ref", "HEAD"]), "agent/mf-9");
        assert_eq!(std::fs::read_to_string(wt.join("marker")).unwrap(), "made-by-script\n");
        assert_eq!(std::fs::read_to_string(wt.join("setup.txt")).unwrap(), format!("setup for MF-9 in {}\n", canonical(&repo).display()));
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Without a create script maple makes the worktree itself, and setup still runs.
    #[tokio::test]
    async fn setup_runs_after_maples_own_worktree_add() {
        let (root, repo, _, _) = repo_with_task("script-setup");
        let s = scripts(None, Some(r#"touch "$MAPLE_WORKTREE/.setup-done""#));
        let wt = expand_home(&create_with(&repo, "mf-10", "main", Some(&for_task(&s, &[]))).await.unwrap());
        assert!(wt.join(".setup-done").exists());
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// A failing setup takes the new worktree and branch away and fails with its (scrubbed) output.
    #[tokio::test]
    async fn a_failing_setup_removes_the_worktree_with_its_output() {
        let (root, repo, _, _) = repo_with_task("script-fail");
        let s = scripts(None, Some(r#"echo "bundle install failed (token $GEM_TOKEN)"; exit 3"#));
        let env = vec![("GEM_TOKEN".to_string(), "ghp_abcdef123456".to_string())];
        let e = format!("{:#}", create_with(&repo, "mf-11", "main", Some(&for_task(&s, &env))).await.unwrap_err());
        assert!(e.contains("setup script"), "{e}");
        assert!(e.contains("failed with exit code 3:\nbundle install failed (token ***)"), "{e}");
        let wt = worktree_path(&repo, "mf-11").unwrap();
        assert!(!wt.exists(), "the half-made worktree is still there");
        assert!(!has_branch(&repo, "agent/mf-11").await, "the branch it made is still there");
        assert!(!list(&repo).await.unwrap().iter().any(|w| w.branch.as_deref() == Some("agent/mf-11")));
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Preflight with its timeline lines collected: what `$MAPLE_PHASE` it ran as and where goes in
    /// `<root>/preflight.log`, one line a run.
    async fn start_with_preflight(repo: &Path, name: &str, s: &crate::worktree_scripts::WorktreeScripts) -> (Result<String>, Vec<String>) {
        let lines = std::sync::Mutex::new(Vec::new());
        let emit = |m: crate::protocol::Outbound| {
            if let crate::protocol::Outbound::TaskProgress { text, .. } = m {
                lines.lock().unwrap().push(text);
            }
        };
        let t = crate::worktree_scripts::ForTask {
            scripts: s,
            task_id: "MF-12",
            repo: Some("acme/app"),
            base: Some("main"),
            env: &[],
            emit: Some(&emit),
            path: None,
        };
        let r = create_with(repo, name, "main", Some(&t)).await;
        (r, lines.into_inner().unwrap())
    }

    fn preflight(command: &str, watch: Option<&str>) -> crate::worktree_scripts::WorktreeScripts {
        crate::worktree_scripts::WorktreeScripts { preflight: Some(command.into()), preflight_watch: watch.map(String::from), ..scripts(None, Some("true")) }
    }

    fn runs(root: &Path) -> Vec<String> {
        std::fs::read_to_string(root.join("preflight.log")).unwrap_or_default().lines().map(String::from).collect()
    }

    /// Preflight runs in the first worktree of a checkout, not again while nothing it watches changes,
    /// again when .ruby-version changes on the base or its command does, and stamps only a run that passed.
    #[tokio::test]
    async fn preflight_runs_once_per_checkout_and_again_when_a_watched_file_changes() {
        let (root, repo, _, _) = repo_with_task("preflight");
        std::fs::write(repo.join(".ruby-version"), "3.3.0\n").unwrap();
        sh(&repo, &["add", "-A"]);
        sh(&repo, &["commit", "--quiet", "-m", "ruby"]);
        let log = root.join("preflight.log");
        let cmd = format!(r#"echo "$MAPLE_PHASE in $PWD with ruby $(cat .ruby-version)" >> {}"#, log.display());
        let s = preflight(&cmd, None);
        let stamp = std::path::PathBuf::from(sh(&repo, &["rev-parse", "--path-format=absolute", "--git-common-dir"])).join("maple/preflight.json");

        // A fresh checkout: it runs, in the worktree, and says why.
        let (wt, lines) = start_with_preflight(&repo, "mf-12", &s).await;
        let wt = expand_home(&wt.unwrap());
        assert_eq!(runs(&root), [format!("preflight in {} with ruby 3.3.0", canonical(&wt).display())]);
        assert_eq!(lines.len(), 2, "{lines:?}");
        assert!(lines[0].starts_with("ran the preflight script (`echo"), "{lines:?}");
        assert!(lines[0].ends_with("(first run on this checkout)"), "{lines:?}");
        assert!(lines[1].starts_with("ran the setup script"), "{lines:?}");
        assert!(stamp.exists());

        // The next task: nothing changed, so it doesn't run.
        let (r, lines) = start_with_preflight(&repo, "mf-13", &s).await;
        r.unwrap();
        assert_eq!(runs(&root).len(), 1);
        assert!(!lines.iter().any(|l| l.contains("preflight")), "{lines:?}");

        // .ruby-version bumped on main: the next task runs it again, saying which file changed.
        std::fs::write(repo.join(".ruby-version"), "3.4.1\n").unwrap();
        sh(&repo, &["commit", "--quiet", "-am", "Bump ruby"]);
        let (r, lines) = start_with_preflight(&repo, "mf-14", &s).await;
        r.unwrap();
        assert_eq!(runs(&root).len(), 2);
        assert!(runs(&root)[1].ends_with("with ruby 3.4.1"));
        assert!(lines[0].ends_with("(changed: .ruby-version)"), "{lines:?}");
        let (_, lines) = start_with_preflight(&repo, "mf-15", &s).await;
        assert_eq!(runs(&root).len(), 2, "{lines:?}");

        // A file outside the default list doesn't count, unless the repo watches it.
        std::fs::write(repo.join("deps.txt"), "pg\n").unwrap();
        sh(&repo, &["add", "-A"]);
        sh(&repo, &["commit", "--quiet", "-m", "deps"]);
        start_with_preflight(&repo, "mf-16", &s).await.0.unwrap();
        assert_eq!(runs(&root).len(), 2);
        let watching = preflight(&cmd, Some("deps.txt\n.ruby-version"));
        let (_, lines) = start_with_preflight(&repo, "mf-17", &watching).await;
        assert_eq!(runs(&root).len(), 3);
        assert!(lines[0].ends_with("(changed: deps.txt)"), "{lines:?}");

        // A new command runs it again.
        let changed = preflight(&format!("{cmd}; true"), Some("deps.txt\n.ruby-version"));
        let (_, lines) = start_with_preflight(&repo, "mf-18", &changed).await;
        assert_eq!(runs(&root).len(), 4);
        assert!(lines[0].ends_with("(the command changed)"), "{lines:?}");

        // One that fails stops the start, removes its worktree and leaves the old stamp, so the next task tries again.
        let before = std::fs::read(&stamp).unwrap();
        let failing = preflight(&format!("{cmd}; echo brew is missing; exit 4"), None);
        let (r, _) = start_with_preflight(&repo, "mf-19", &failing).await;
        let e = format!("{:#}", r.unwrap_err());
        assert!(e.contains("preflight script") && e.contains("failed with exit code 4:\nbrew is missing"), "{e}");
        assert!(!worktree_path(&repo, "mf-19").unwrap().exists());
        assert_eq!(std::fs::read(&stamp).unwrap(), before, "a failed run left a stamp");
        start_with_preflight(&repo, "mf-20", &failing).await.0.unwrap_err();
        assert_eq!(runs(&root).len(), 6, "the failed preflight wasn't tried again");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// No stamp at first: a failed first run leaves none, so the next task's run is still the first.
    #[tokio::test]
    async fn a_failed_first_preflight_leaves_no_stamp() {
        let (root, repo, _, _) = repo_with_task("preflight-fail");
        let stamp = std::path::PathBuf::from(sh(&repo, &["rev-parse", "--path-format=absolute", "--git-common-dir"])).join("maple/preflight.json");
        start_with_preflight(&repo, "mf-21", &preflight("exit 1", None)).await.0.unwrap_err();
        assert!(!stamp.exists());
        let (r, lines) = start_with_preflight(&repo, "mf-22", &preflight("true", None)).await;
        r.unwrap();
        assert!(lines[0].ends_with("(first run on this checkout)"), "{lines:?}");
        assert!(stamp.exists());
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Two tasks starting together on a fresh checkout: one runs preflight, the other waits for it and
    /// then finds it done.
    #[tokio::test]
    async fn concurrent_starts_run_preflight_once() {
        let (root, repo, _, _) = repo_with_task("preflight-race");
        let s = preflight(&format!("echo start >> {0}; sleep 1; echo end >> {0}", root.join("preflight.log").display()), None);
        let ((a, la), (b, lb)) = tokio::join!(start_with_preflight(&repo, "mf-23", &s), start_with_preflight(&repo, "mf-24", &s));
        a.unwrap();
        b.unwrap();
        assert_eq!(runs(&root), ["start", "end"]);
        let ran = |l: &[String]| l.iter().any(|l| l.starts_with("ran the preflight script"));
        assert!(ran(&la) != ran(&lb), "{la:?} {lb:?}");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// A create script that doesn't leave a worktree on the task's branch at MAPLE_WORKTREE fails the start.
    #[tokio::test]
    async fn a_create_script_that_makes_no_worktree_fails() {
        let (root, repo, _, _) = repo_with_task("script-none");
        let s = scripts(Some(r#"mkdir -p "$MAPLE_WORKTREE""#), None);
        let e = format!("{:#}", create_with(&repo, "mf-12", "main", Some(&for_task(&s, &[]))).await.unwrap_err());
        assert!(e.contains("there's no git worktree on agent/mf-12"), "{e}");
        std::fs::remove_dir_all(&root).unwrap();
    }
}
