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
    /// The repo's checks, one command per line: each must pass before anything is committed.
    #[serde(default)]
    pub checks: Option<String>,
    /// The same checks with their `[tag] ` prefixes kept, so ones this machine can't run are skipped
    /// with why. Older hubs send only `checks`.
    #[serde(default)]
    pub check_lines: Option<String>,
}

/// What a check that's really the commit's own git hooks (lefthook, husky) is called.
pub const HOOK_CHECK: &str = "git commit (pre-commit hook)";

/// What the dry-run merge of the branch into its base, before a push, is called as a check.
pub const MERGE_CHECK: &str = "git merge-tree origin/<base> (does it merge?)";

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
    /// owner/name, for its secrets when its scripts run.
    #[serde(default)]
    pub repo: Option<String>,
    /// The repo's worktree scripts: teardown runs first, and archive replaces the removal.
    #[serde(default)]
    pub scripts: Option<crate::worktree_scripts::WorktreeScripts>,
    /// Merged, and its branch may still be on origin: delete it there too, when that's safe.
    #[serde(default)]
    pub delete_remote: bool,
}

/// `task.diff` from the hub: what a task's branch changes against its base, for the apps' Changes tab.
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

/// Answers with `task.diff`: per-file line counts and the unified patch (cut at `MAX_PATCH`), and
/// the branch's commits, each with its own.
pub async fn run_diff(sessions: Sessions, d: DiffRequest) {
    sessions.emit(match diff_report(&expand_home(&d.cwd), &d.base).await {
        Ok(r) => Outbound::Wire(crate::wire::RunnerMessage::TaskDiff {
            task_id: d.task_id,
            ok: true,
            files: r.files,
            patch: r.patch,
            truncated: r.truncated,
            message: None,
            commits: Some(r.commits),
        }),
        Err(e) => Outbound::Wire(crate::wire::RunnerMessage::TaskDiff {
            task_id: d.task_id,
            ok: false,
            files: vec![],
            patch: String::new(),
            truncated: false,
            message: Some(format!("{e:#}")),
            commits: None,
        }),
    });
}

struct DiffReport {
    files: Vec<crate::wire::DiffStat>,
    patch: String,
    truncated: bool,
    commits: Vec<crate::wire::DiffCommit>,
}

async fn diff_report(dir: &Path, base: &str) -> Result<DiffReport> {
    if base.starts_with('-') {
        bail!("{base} isn't a branch name.");
    }
    let range = format!("origin/{base}...HEAD");
    let files = numstat(&git(dir, &["diff", "--numstat", "--no-renames", &range], None).await?);
    let (patch, truncated) = cut_patch(git(dir, &["diff", "--no-color", "--no-ext-diff", "--no-renames", &range], None).await?, MAX_PATCH);

    // Fields split by US, commits by RS: neither turns up in a commit message.
    let log = git(dir, &["log", "--reverse", "--format=%H%x1f%an%x1f%ct%x1f%s%x1f%b%x1e", &format!("origin/{base}..HEAD")], None).await?;
    let mut commits = Vec::new();
    // The commits share what's left of one message after the whole-branch patch; once a commit's
    // patch doesn't fit, it and every later one come without theirs.
    let mut room = (crate::protocol::MAX_MESSAGE - crate::protocol::ENVELOPE)
        .saturating_sub(crate::protocol::json_len(&patch) + files.iter().map(|f| f.path.len() + 48).sum::<usize>());
    for record in log.split('\x1e').map(|r| r.trim_start_matches('\n')).filter(|r| !r.is_empty()) {
        let mut f = record.splitn(5, '\x1f');
        let (Some(sha), Some(author), Some(at), Some(subject)) = (f.next(), f.next(), f.next(), f.next()) else { continue };
        let body = f.next().map(str::trim).filter(|b| !b.is_empty()).map(str::to_string);
        // A merge commit shows what it brought in from its first parent.
        let show = ["show", "--no-color", "--no-ext-diff", "--no-renames", "--diff-merges=first-parent", "--format="];
        let files = numstat(&git(dir, &[&show[..], &["--numstat", sha]].concat(), None).await?);
        let meta = 128
            + sha.len()
            + crate::protocol::json_len(subject)
            + body.as_deref().map_or(0, crate::protocol::json_len)
            + author.len()
            + files.iter().map(|f| f.path.len() + 48).sum::<usize>();
        if meta > room {
            break;
        }
        room -= meta;
        let (patch, truncated) = match room {
            0 => (String::new(), true),
            _ => {
                let (patch, cut) = cut_patch(git(dir, &[&show[..], &[sha]].concat(), None).await?, MAX_PATCH);
                match crate::protocol::json_len(&patch) {
                    n if n <= room => {
                        room -= n;
                        (patch, cut)
                    }
                    _ => {
                        room = 0;
                        (String::new(), true)
                    }
                }
            }
        };
        commits.push(crate::wire::DiffCommit {
            sha: sha.to_string(),
            subject: subject.to_string(),
            body,
            author: author.to_string(),
            at: at.parse::<u64>().unwrap_or(0) * 1000,
            added: files.iter().map(|f| f.added).sum(),
            removed: files.iter().map(|f| f.removed).sum(),
            files,
            patch,
            truncated,
        });
    }
    Ok(DiffReport { files, patch, truncated, commits })
}

/// `git diff --numstat` lines as line counts per file; binary files count as "-": no lines.
fn numstat(out: &str) -> Vec<crate::wire::DiffStat> {
    out.lines()
        .filter_map(|l| {
            let mut parts = l.splitn(3, '\t');
            let (added, removed, path) = (parts.next()?, parts.next()?, parts.next()?);
            Some(crate::wire::DiffStat { path: path.to_string(), added: added.parse().unwrap_or(0), removed: removed.parse().unwrap_or(0) })
        })
        .collect()
}

/// The patch cut to at most `max` bytes (on a character boundary), and whether it was.
fn cut_patch(mut patch: String, max: usize) -> (String, bool) {
    let truncated = patch.len() > max;
    if truncated {
        let mut cut = max;
        while !patch.is_char_boundary(cut) {
            cut -= 1;
        }
        patch.truncate(cut);
    }
    (patch, truncated)
}

/// `task.merge_check` from the hub: would the task's branch still merge into its base, now that
/// something else merged there?
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MergeCheck {
    pub task_id: String,
    /// The worktree, `~`-abbreviated.
    pub cwd: String,
    pub base: String,
}

/// Answers with `task.merge_check`: clean, or the paths that conflict.
pub async fn run_merge_check(sessions: Sessions, c: MergeCheck) {
    let checked = merge_check(&expand_home(&c.cwd), &c.base).await;
    sessions.emit(Outbound::Wire(match checked {
        Ok(conflicts) => crate::wire::RunnerMessage::TaskMergeCheck { task_id: c.task_id, ok: true, clean: conflicts.is_empty(), conflicts, message: None },
        Err(e) => {
            crate::wire::RunnerMessage::TaskMergeCheck { task_id: c.task_id, ok: false, clean: false, conflicts: vec![], message: Some(format!("{e:#}")) }
        }
    }));
}

/// Fetches `origin/<base>` and dry-runs merging HEAD into it with `git merge-tree`, which writes
/// only objects: the index, the checkout and HEAD are left as they are. The conflicting paths, or none.
async fn merge_check(dir: &Path, base: &str) -> Result<Vec<String>> {
    if base.starts_with('-') || valid_name(base).is_err() {
        bail!("{base} isn't a branch name.");
    }
    git(dir, &["fetch", "--quiet", "origin", base], None).await?;
    let theirs = format!("origin/{base}");
    let mut cmd = Command::new("git");
    cmd.arg("-C").arg(dir).args(["merge-tree", "--write-tree", "--name-only", "--no-messages", &theirs, "HEAD"]);
    cmd.env("GIT_TERMINAL_PROMPT", "0").stdin(Stdio::null()).kill_on_drop(true);
    let out = tokio::time::timeout(GIT_TIMEOUT, cmd.output()).await.map_err(|_| anyhow!("git merge-tree timed out"))??;
    match out.status.code() {
        Some(0) => Ok(vec![]),
        // The tree's id, then each conflicted path.
        Some(1) => {
            let mut paths: Vec<String> = Vec::new();
            for l in String::from_utf8_lossy(&out.stdout).lines().skip(1).map(str::trim).filter(|l| !l.is_empty()) {
                if !paths.iter().any(|p| p == l) {
                    paths.push(l.to_string());
                }
            }
            Ok(paths)
        }
        _ => bail!("git merge-tree failed: {}", String::from_utf8_lossy(&out.stderr).trim().trim_start_matches("fatal: ")),
    }
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
    let merged = merge_and_switch_back(&expand_home(&m.cwd), &m).await;
    sessions.emit(match merged {
        Ok((commit, branch)) => Outbound::TaskMerged { task_id: m.task_id, ok: true, commit: Some(commit), message: None, branch: Some(branch.note()) },
        Err(e) => Outbound::TaskMerged { task_id: m.task_id, ok: false, commit: None, message: Some(format!("{e:#}")), branch: None },
    });
}

/// `merge`, then the worktree back on the task's branch, so a Retry doesn't find it detached.
async fn merge_and_switch_back(dir: &Path, m: &Merge) -> Result<(String, BranchDeletion)> {
    let merged = merge(dir, m).await;
    // A conflicted merge blocks the checkout until it's aborted.
    if merged.is_err() {
        let _ = git(dir, &["merge", "--abort"], None).await;
    }
    if let Err(e) = git(dir, &["checkout", "--quiet", &m.branch], None).await {
        tracing::warn!("task {}: couldn't switch {} back to {} after the merge ({e:#}); resetting and trying again", m.task_id, m.cwd, m.branch);
        let _ = git(dir, &["reset", "--quiet", "--merge"], None).await;
        if let Err(e) = git(dir, &["checkout", "--quiet", &m.branch], None).await {
            tracing::warn!("task {}: {} is left detached, not on {}: {e:#}", m.task_id, m.cwd, m.branch);
        }
    }
    merged
}

async fn merge(dir: &Path, m: &Merge) -> Result<(String, BranchDeletion)> {
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
    let commit = git(dir, &["rev-parse", "HEAD"], None).await?.trim().to_string();
    let branch = delete_merged_branch(dir, m).await;
    Ok((commit, branch))
}

/// What became of a merged task's branch on origin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BranchDeletion {
    Deleted,
    /// It wasn't on origin any more.
    Gone,
    /// It has commits that didn't merge, so it was kept.
    Moved,
    Failed(String),
}

impl BranchDeletion {
    /// For `task.merged`'s `branch`: `deleted`, `gone`, `moved`, or `failed: <why>`.
    pub fn note(&self) -> String {
        match self {
            Self::Deleted => "deleted".into(),
            Self::Gone => "gone".into(),
            Self::Moved => "moved".into(),
            Self::Failed(why) => format!("failed: {why}"),
        }
    }
}

/// The merged branch off origin, but only while it's still the tip that merged: one that moved is kept.
/// Best-effort: the merge stands whatever happens here.
async fn delete_merged_branch(dir: &Path, m: &Merge) -> BranchDeletion {
    let deleted = async {
        let tip = git(dir, &["rev-parse", "--verify", &format!("refs/heads/{}", m.branch)], None).await?;
        let tip = tip.trim();
        let on_origin = git(dir, &["ls-remote", "origin", &format!("refs/heads/{}", m.branch)], None).await?;
        let Some(theirs) = on_origin.split_whitespace().next() else { return Ok(BranchDeletion::Gone) };
        if theirs != tip {
            return Ok(BranchDeletion::Moved);
        }
        let lease = format!("--force-with-lease=refs/heads/{}:{tip}", m.branch);
        match git(dir, &["push", "--quiet", &lease, "origin", "--delete", &m.branch], None).await {
            Ok(_) => Ok(BranchDeletion::Deleted),
            // It moved between the look and the push.
            Err(e) if format!("{e:#}").contains("stale info") => Ok(BranchDeletion::Moved),
            Err(e) => Err(e),
        }
    };
    let outcome = deleted.await.unwrap_or_else(|e: anyhow::Error| BranchDeletion::Failed(format!("{e:#}")));
    match &outcome {
        BranchDeletion::Deleted => tracing::info!("task {}: deleted branch {} on origin", m.task_id, m.branch),
        BranchDeletion::Gone => tracing::info!("task {}: branch {} was already gone on origin", m.task_id, m.branch),
        BranchDeletion::Moved => tracing::warn!("task {}: kept branch {} on origin: it moved after the merge", m.task_id, m.branch),
        BranchDeletion::Failed(e) => tracing::warn!("task {}: couldn't delete branch {} on origin: {e}", m.task_id, m.branch),
    }
    outcome
}

/// Runs a cleanup and answers with `task.cleaned`.
pub async fn run_cleanup(sessions: Sessions, c: Cleanup) {
    let cwds: Vec<String> = sessions.list().into_iter().map(|s| s.cwd).collect();
    let emit = |m: Outbound| sessions.emit(m);
    let path = match c.scripts {
        Some(_) => crate::proof::login_path().await,
        None => None,
    };
    let msg = cleanup(&emit, &cwds, &c, path.as_deref()).await;
    sessions.emit(msg);
}

/// A finished task's cleanup: the repo's teardown script first (if it has one), then its archive
/// script in place of `worktrees::remove_task` (if it has one), else that. A script that fails stops
/// it there, with the script's output as the reason.
async fn cleanup(emit: Emit<'_>, cwds: &[String], c: &Cleanup, path: Option<&str>) -> Outbound {
    use crate::worktree_scripts::{Phase, command};
    let cleaned =
        |ok: bool, branch_deleted: bool, message: String| Outbound::TaskCleaned { task_id: c.task_id.clone(), ok, branch_deleted, message: Some(message) };
    let scripts = c.scripts.as_ref();
    let dir = expand_home(&c.cwd);
    let archive = command(scripts, Phase::Archive);
    let mut done = Vec::new();
    // Nothing to tear down or archive once the folder's gone: remove_task forgets it and its branch.
    if dir.is_dir() && (archive.is_some() || command(scripts, Phase::Teardown).is_some()) {
        match cleanup_scripts(emit, cwds, c, &dir, path).await {
            Ok((ran, branch_deleted)) if archive.is_some() => {
                tracing::info!("task {}: {}", c.task_id, ran.join(", "));
                forget_proof(c);
                crate::worktrees::poke(true);
                return cleaned(true, branch_deleted, format!("{}; the archive script took the worktree and branch from there", ran.join(", ")));
            }
            Ok((ran, _)) => done = ran,
            Err(e) => {
                tracing::warn!("task {}: cleanup stopped: {e:#}", c.task_id);
                crate::worktrees::poke(true);
                return cleaned(false, false, format!("{e:#}"));
            }
        }
    }
    let work =
        crate::worktrees::TaskWork { cwd: &c.cwd, repo_dir: &c.repo_dir, branch: &c.branch, merged: c.merged, heads: &c.heads, delete_remote: c.delete_remote };
    match crate::worktrees::remove_task(cwds, work).await {
        Ok(removed) => {
            tracing::info!("task {}: {}", c.task_id, removed.message);
            forget_proof(c);
            done.push(removed.message);
            cleaned(true, removed.branch_deleted, done.join(", then "))
        }
        Err(e) => {
            tracing::warn!("task {}: cleanup refused: {e:#}", c.task_id);
            done.push(format!("{e:#}"));
            cleaned(false, false, done.join(", but "))
        }
    }
}

/// Runs the repo's teardown and archive scripts (each if it has one) in its main checkout: their
/// timeline lines, and whether the task's branch is gone afterwards.
async fn cleanup_scripts(emit: Emit<'_>, cwds: &[String], c: &Cleanup, dir: &Path, path: Option<&str>) -> Result<(Vec<String>, bool)> {
    use crate::worktree_scripts::{Phase, run};
    let target = crate::worktrees::canonical(dir);
    if cwds.iter().any(|w| crate::worktrees::canonical(&expand_home(w)).starts_with(&target)) {
        bail!("A session is still using {}. End it first.", c.cwd);
    }
    let root = match crate::worktrees::main_root(dir).await {
        Ok(root) => root,
        Err(_) => crate::worktrees::main_root(&expand_home(&c.repo_dir)).await.map_err(|e| anyhow!("{} isn't a git repository any more ({e}).", c.repo_dir))?,
    };
    if crate::worktrees::canonical(&root) == target {
        bail!("{} is the repository's main checkout; only a task's worktree is cleaned up.", c.cwd);
    }
    // Its secrets, as for the owner's own checkout: the task itself is finished.
    let env = match c.repo.as_deref().filter(|r| r.contains('/')) {
        Some(repo) => match crate::secrets::request(emit, repo, None).await {
            Ok(values) => values.into_iter().collect(),
            Err(e) => {
                tracing::warn!("task {}: its cleanup scripts run without {repo}'s secrets: {e:#}", c.task_id);
                vec![]
            }
        },
        None => vec![],
    };
    let scripts = crate::worktree_scripts::ForTask {
        scripts: c.scripts.as_ref().expect("cleanup_scripts runs with scripts"),
        task_id: &c.task_id,
        repo: c.repo.as_deref(),
        base: None,
        env: &env,
        emit: Some(emit),
        path,
    };
    let ctx = scripts.context(&root, dir, &c.branch);
    let mut ran = Vec::new();
    for phase in [Phase::Teardown, Phase::Archive] {
        if phase == Phase::Archive {
            // Nothing left running in it when the archive script takes it (remove_task does this otherwise).
            ran.extend(crate::worktrees::stopped_line(&crate::worktrees::stop_leftovers(&target).await));
        }
        if let Some(r) = run(Some(scripts.scripts), phase, &ctx).await? {
            ran.push(r.line());
        }
    }
    let branch_gone = git(&root, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{}", c.branch)], None).await.is_err();
    Ok((ran, branch_gone))
}

/// Its evidence was uploaded long ago: the proof folder goes with the worktree.
fn forget_proof(c: &Cleanup) {
    if let Some(home) = std::env::var_os("HOME").map(std::path::PathBuf::from) {
        match crate::proof::forget_folder(&home, &c.branch) {
            Ok(true) => tracing::info!("task {}: removed its proof folder", c.task_id),
            Ok(false) => {}
            Err(e) => tracing::warn!("task {}: couldn't remove its proof folder: {e}", c.task_id),
        }
    }
}

/// The hub's answer to a token request.
pub struct TokenReply {
    pub token: Option<String>,
    pub error: Option<String>,
    pub code: Option<String>,
    /// The app's permissions page on GitHub (push tokens), to link to when GitHub refuses a push.
    pub settings_url: Option<String>,
}

/// An app token, and where its permissions are changed.
struct AppToken {
    token: String,
    settings_url: Option<String>,
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

async fn token(emit: Emit<'_>, task_id: &str, owner: &str, repo: &str, purpose: Option<&'static str>) -> Result<std::result::Result<AppToken, NoApp>> {
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
        (Some(t), None, _) if !t.is_empty() => Ok(Ok(AppToken { token: t, settings_url: reply.settings_url })),
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
                checks: None,
                not_run: vec![],
            }
        }
    };
    sessions.emit(msg);
}

async fn finish(emit: Emit<'_>, f: &Finish) -> Result<Outbound> {
    let dir = task_dir(&f.cwd, &f.branch, f.base.as_deref())?;

    // 0. The repo's checks, in the worktree as the builder left it: the first that fails stops here.
    let (mut checks, not_run) = run_checks(emit, f, &dir).await?;
    if checks.last().is_some_and(|c| !crate::worktree_scripts::passed(c)) {
        return Ok(with_not_run(checks_failed(f, checks), not_run));
    }

    // 1. Commit what's left uncommitted, as the user (their git config), with the title as the message.
    // Its own git hooks run; one that fails is a failed check, with nothing committed.
    if !git(&dir, &["status", "--porcelain"], None).await?.trim().is_empty() {
        git(&dir, &["add", "-A"], None).await?;
        if let Some(hook) = commit_with_hooks(&dir, &f.title).await? {
            checks.push(hook);
            return Ok(with_not_run(checks_failed(f, checks), not_run));
        }
    }
    let commit = git(&dir, &["rev-parse", "HEAD"], None).await?.trim().to_string();

    // 2. The branch the PR goes into: the task's, else what the repo folder has checked out.
    let base = match f.base.as_deref() {
        Some(b) => b.to_string(),
        None => git(&expand_home(&f.repo_dir), &["symbolic-ref", "--quiet", "--short", "HEAD"], None).await.map(|b| b.trim().to_string()).map_err(|_| {
            anyhow!("{} has no branch checked out, so there's nothing to open a pull request against. Give the task a base branch.", f.repo_dir)
        })?,
    };
    // The branch must merge into origin/<base>: a conflict goes back to the builder, unpushed. One that
    // can't be checked (offline, no origin) goes ahead; the hub's dry run before a merge still catches it.
    match merge_check(&dir, &base).await {
        Ok(conflicts) if !conflicts.is_empty() => {
            checks.push(merge_conflicts(&base, &conflicts));
            let mut out = with_not_run(checks_failed(f, checks), not_run);
            if let Outbound::TaskFinished { message, .. } = &mut out {
                *message = Some(format!("The branch doesn't merge into {base} (conflicts in {}), so nothing was pushed.", conflicts.join(", ")));
            }
            return Ok(out);
        }
        Ok(_) => {}
        Err(e) => tracing::warn!("task {}: couldn't check that it merges into {base}, so pushing anyway: {e:#}", f.task_id),
    }
    if let Some(n) = ahead_of(&dir, &base).await
        && n == 0
    {
        bail!("The agent didn't change anything (no commits beyond {base}), so there's nothing to push.");
    }

    // 3 and 4. Push: the app, else the fallback.
    let p = push(emit, &f.task_id, &dir, &f.branch, f.fallback, None).await?;
    let mut done = finished(f, p.how, p.owner, p.repo, base, commit, p.reason);
    if let Outbound::TaskFinished { checks: c, .. } = &mut done
        && !checks.is_empty()
    {
        *c = Some(checks);
    }
    Ok(with_not_run(done, not_run))
}

/// `task.finished` with the checks it didn't run, and why.
fn with_not_run(mut out: Outbound, skipped: Vec<crate::wire::NotRunCheck>) -> Outbound {
    if let Outbound::TaskFinished { not_run, .. } = &mut out {
        *not_run = skipped;
    }
    out
}

/// Runs the repo's checks (if `task.finish` brought any) in the task's worktree, with the MAPLE_*
/// variables, its secrets and the login shell's PATH.
async fn run_checks(emit: Emit<'_>, f: &Finish, dir: &Path) -> Result<(Vec<crate::wire::CheckRun>, Vec<crate::wire::NotRunCheck>)> {
    let scripts = crate::worktree_scripts::WorktreeScripts {
        create: None,
        preflight: None,
        preflight_watch: None,
        setup: None,
        checks: f.check_lines.clone().or_else(|| f.checks.clone()),
        teardown: None,
        archive: None,
        timeout_secs: None,
        require_paths: None,
    };
    if crate::worktree_scripts::check_commands(Some(&scripts)).is_empty() {
        return Ok((vec![], vec![]));
    }
    let root = crate::worktrees::main_root(dir).await.unwrap_or_else(|_| expand_home(&f.repo_dir));
    let origin = git(dir, &["config", "--get", "remote.origin.url"], None).await.ok().and_then(|u| parse_github(u.trim()));
    let repo = origin.map(|(owner, name)| format!("{owner}/{name}"));
    let env: Vec<(String, String)> = match repo.as_deref() {
        Some(r) => match crate::secrets::request(emit, r, Some(&f.task_id)).await {
            Ok(values) => values.into_iter().collect(),
            Err(e) => {
                tracing::warn!("task {}: its checks run without {r}'s secrets: {e:#}", f.task_id);
                vec![]
            }
        },
        None => vec![],
    };
    let path = crate::proof::login_path().await;
    let t = crate::worktree_scripts::ForTask {
        scripts: &scripts,
        task_id: &f.task_id,
        repo: repo.as_deref(),
        base: f.base.as_deref(),
        env: &env,
        emit: Some(emit),
        path: path.as_deref(),
    };
    Ok(crate::worktree_scripts::checks(Some(&scripts), &t.context(&root, dir, &f.branch)).await)
}

/// Commits what's staged with `title`, its git hooks and all. None: committed. A failure that's the
/// hooks' (the same commit goes through without them) comes back as a failed check with what they
/// printed, and the index as it was; any other failure is an error.
async fn commit_with_hooks(dir: &Path, title: &str) -> Result<Option<crate::wire::CheckRun>> {
    let began = std::time::Instant::now();
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["commit", "--quiet", "-m", title])
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(GIT_TIMEOUT, out).await.map_err(|_| anyhow!("git commit timed out"))??;
    if out.status.success() {
        return Ok(None);
    }
    let printed = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    if git(dir, &["commit", "--quiet", "--dry-run", "--no-verify", "-m", title], None).await.is_err() {
        let why = printed
            .lines()
            .map(|l| l.trim_start_matches("fatal: ").trim_start_matches("error: "))
            .filter(|l| !l.trim().is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        bail!("Couldn't commit: {}", if why.is_empty() { "git commit failed" } else { why.trim() });
    }
    // Unstaged again, so the worktree is as the builder left it.
    let _ = git(dir, &["reset", "--quiet"], None).await;
    let lines: Vec<String> = crate::secrets::scrub(&printed).lines().map(str::to_string).collect();
    let output = lines[lines.len().saturating_sub(40)..].join("\n");
    Ok(Some(crate::wire::CheckRun { command: HOOK_CHECK.into(), code: out.status.code(), timed_out: false, ms: began.elapsed().as_millis() as u64, output }))
}

/// The failed check for a branch that doesn't merge into `origin/<base>`: the conflicting paths, and what to do.
fn merge_conflicts(base: &str, conflicts: &[String]) -> crate::wire::CheckRun {
    let output = format!(
        "Conflicts with origin/{base} in:\n{}\n\nFetch origin/{base}, merge it into the branch, resolve every conflict, keep the tests passing, then call finish again.",
        conflicts.iter().map(|c| format!("  {c}")).collect::<Vec<_>>().join("\n")
    );
    crate::wire::CheckRun { command: MERGE_CHECK.into(), code: Some(1), timed_out: false, ms: 0, output }
}

/// `task.finished` for a finish a check stopped: nothing committed or pushed. (A merge check that
/// fails comes after the commit, so `finish` words its message itself.)
fn checks_failed(f: &Finish, checks: Vec<crate::wire::CheckRun>) -> Outbound {
    let last = checks.last().expect("a failed check");
    let how = match (last.timed_out, last.code) {
        (true, _) => "timed out".to_string(),
        (false, Some(code)) => format!("exited {code}"),
        (false, None) => "was killed".to_string(),
    };
    tracing::info!("task {}: check `{}` {how}; nothing pushed", f.task_id, last.command);
    Outbound::TaskFinished {
        task_id: f.task_id.clone(),
        ok: false,
        pushed: None,
        owner: None,
        repo: None,
        branch: f.branch.clone(),
        base: f.base.clone(),
        commit: None,
        reason: None,
        message: Some(format!("The check `{}` {how}, so nothing was committed or pushed.", last.command)),
        checks: Some(checks),
        not_run: vec![],
    }
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
            Ok(AppToken { token, settings_url }) => {
                let url = push_url(&owner, &repo, &token, std::env::var(PUSH_URL_ENV).ok().as_deref());
                git(dir, &["-c", "credential.helper=", "push", "--quiet", &url, &refspec], Some(&token))
                    .await
                    .map_err(|e| app_push_error(branch, &owner, &repo, &format!("{e:#}"), settings_url.as_deref()))?;
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

/// A failed app push as the task's error: GitHub refusing a workflow change because the app lacks Workflows: write says so,
/// with where to approve it; anything else is the plain "Couldn't push".
fn app_push_error(branch: &str, owner: &str, repo: &str, stderr: &str, settings_url: Option<&str>) -> anyhow::Error {
    // "refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission"
    if stderr.contains("without `workflows` permission") {
        let at = settings_url.map(|u| format!(" ({u})")).unwrap_or_default();
        return anyhow!(
            "GitHub refused to push {branch} to {owner}/{repo} because it changes .github/workflows and the Maple GitHub App doesn't \
             have the Workflows: write permission. Approve it in the app's settings{at} and on the installation, then retry."
        );
    }
    anyhow!("Couldn't push {branch} to {owner}/{repo}: {stderr}")
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
        checks: None,
        not_run: vec![],
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

pub(crate) fn valid_part(s: &str) -> bool {
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

/// `text` with `secret` and every repo secret the runner was given (`secrets::scrub`) replaced, for
/// anything that might reach a log or the UI.
pub fn scrub(text: &str, secret: Option<&str>) -> String {
    let text = crate::secrets::scrub(text);
    match secret.filter(|s| s.len() >= 8) {
        Some(s) => text.replace(s, "***"),
        None => text,
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
/// Its repo's secrets come back too, for the session's environment (see `secrets`).
pub async fn open(
    sessions: &Sessions,
    task: &crate::factory::TaskStart,
    cwd: &str,
    req: Option<&crate::worktrees::Request>,
    prompt: Option<&str>,
    images: &[String],
) -> Result<Opened> {
    let req = req.ok_or_else(|| anyhow!("A task runs in its own worktree."))?;
    let emit = |m: Outbound| sessions.emit(m);
    if req.existing {
        // Its builder again: the worktree as it is, and the prompt with its project's settings as before.
        let worktree = existing(cwd, req).await?;
        crate::trust::trust_worktree(&expand_home(&worktree));
        let p = crate::factory::prepare(&expand_home(&worktree), prompt, &task.projects).await;
        let repo = task.repo.clone().or(p.repo.clone());
        let env = crate::secrets::for_task(&emit, &task.id, repo.as_deref()).await;
        let (prompt, images) = crate::images::hand(&task.id, images, p.prompt).await;
        return Ok(Opened { worktree, prompt, images, secrets: repo.map(|r| (r, env)) });
    }
    // The repo's create, preflight and setup scripts run with its secrets, so they're fetched first then.
    let scripts = task.scripts.as_ref().filter(|s| {
        use crate::worktree_scripts::{Phase, command};
        [Phase::Create, Phase::Preflight, Phase::Setup].into_iter().any(|p| command(Some(s), p).is_some())
    });
    let early = match scripts {
        Some(_) => Some(crate::secrets::for_task(&emit, &task.id, task.repo.as_deref()).await),
        None => None,
    };
    let path = match scripts {
        Some(_) => crate::proof::login_path().await,
        None => None,
    };
    let with = scripts.map(|s| Scripts { scripts: s, env: early.as_deref().unwrap_or_default(), path: path.as_deref() });
    let started = start(&emit, &task.id, cwd, task.repo.as_deref(), req, &Places::here(), with.as_ref()).await?;
    // A worktree the runner just made: Claude Code shouldn't stop to ask whether to trust it.
    crate::trust::trust_worktree(&expand_home(&started.worktree));
    let p = crate::factory::prepare(&expand_home(&started.worktree), prompt, &task.projects).await;
    let repo = task.repo.clone().or(p.repo.clone());
    let env = match early {
        Some(env) => env,
        None => crate::secrets::for_task(&emit, &task.id, repo.as_deref()).await,
    };
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
    Ok(Opened { worktree: started.worktree, prompt, images, secrets: repo.map(|r| (r, env)) })
}

/// What a task's session opens with.
pub struct Opened {
    /// `~`-abbreviated.
    pub worktree: String,
    pub prompt: Option<String>,
    pub images: Vec<String>,
    /// Its repo and that repo's secrets, for the session's pane only.
    pub secrets: Option<(String, Vec<(String, String)>)>,
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
/// A task's worktree scripts for `start`, with the secrets and PATH they run with.
pub struct Scripts<'a> {
    pub scripts: &'a crate::worktree_scripts::WorktreeScripts,
    pub env: &'a [(String, String)],
    pub path: Option<&'a str>,
}

pub async fn start(
    emit: Emit<'_>,
    task_id: &str,
    cwd: &str,
    repo: Option<&str>,
    req: &crate::worktrees::Request,
    at: &Places,
    scripts: Option<&Scripts<'_>>,
) -> Result<Started> {
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
    let for_task = scripts.map(|s| crate::worktree_scripts::ForTask {
        scripts: s.scripts,
        task_id,
        repo,
        base: Some(base.as_str()),
        env: s.env,
        emit: Some(emit),
        path: s.path,
    });
    let worktree = crate::worktrees::create_with(&root, &req.name, &format!("origin/{base}"), for_task.as_ref()).await?;
    Ok(Started { worktree, repo_dir: crate::worktrees::abbreviate(&root), base })
}

/// Clones owner/name into `~/.local/share/maple/repos/<owner>/<name>`: an empty repository whose origin
/// is the plain GitHub URL, then the base fetched into it with a token (`fetch_base`). Nothing is
/// checked out there; tasks work in worktrees. A clone that fails leaves nothing behind.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn clone(
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
        if let Ok(AppToken { token: t, .. }) = token(emit, task_id, &owner, &repo, Some("fetch")).await? {
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
pub(crate) async fn git(dir: &Path, args: &[&str], secret: Option<&str>) -> Result<String> {
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
    fn a_push_refused_for_workflows_names_the_permission() {
        let url = "https://github.com/organizations/acme/settings/apps/maple/permissions";
        let refused = "! [remote rejected] HEAD -> mf-1 (refusing to allow a GitHub App to create or update workflow \
                       `.github/workflows/ci.yml` without `workflows` permission) failed to push some refs to 'https://github.com/acme/widgets.git'";
        let msg = format!("{:#}", app_push_error("mf-1", "acme", "widgets", refused, Some(url)));
        assert!(msg.contains("Workflows: write") && msg.contains(url) && msg.contains(".github/workflows"), "{msg}");
        assert!(!msg.contains("Couldn't push"), "{msg}");
        // Without the link it still names the permission.
        let msg = format!("{:#}", app_push_error("mf-1", "acme", "widgets", refused, None));
        assert!(msg.contains("Workflows: write") && !msg.contains("()"), "{msg}");
        // Anything else stays the generic failure.
        let msg = format!("{:#}", app_push_error("mf-1", "acme", "widgets", "Could not resolve host: github.com", Some(url)));
        assert_eq!(msg, "Couldn't push mf-1 to acme/widgets: Could not resolve host: github.com");
    }

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
            checks: None,
            check_lines: None,
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

    /// A work tree on agent/fix-1a2b, one change ahead of main and uncommitted, with a bare origin.
    fn finish_fixture(tag: &str) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf, Finish) {
        let root = tmp(tag);
        let (bare, work) = (root.join("origin.git"), root.join("work"));
        std::fs::create_dir_all(&work).unwrap();
        sh(&root, &["init", "--quiet", "--bare", "--initial-branch=main", bare.to_str().unwrap()]);
        sh(&work, &["init", "--quiet", "-b", "main"]);
        for (k, v) in [("user.name", "Test Person"), ("user.email", "test@example.com"), ("commit.gpgsign", "false")] {
            sh(&work, &["config", k, v]);
        }
        commit(&work, "a.txt", "one\n", "first");
        sh(&work, &["remote", "add", "origin", bare.to_str().unwrap()]);
        sh(&work, &["checkout", "--quiet", "-b", "agent/fix-1a2b"]);
        std::fs::write(work.join("a.txt"), "two\n").unwrap();
        let f = Finish {
            task_id: "t1".into(),
            cwd: work.to_string_lossy().into_owned(),
            repo_dir: work.to_string_lossy().into_owned(),
            branch: "agent/fix-1a2b".into(),
            base: Some("main".into()),
            title: "Fix the flaky test".into(),
            fallback: true,
            checks: None,
            check_lines: None,
        };
        (root, bare, work, f)
    }

    fn checks_of(out: &Outbound) -> (bool, Vec<crate::wire::CheckRun>) {
        let Outbound::TaskFinished { ok, checks, .. } = out else { panic!("{out:?}") };
        (*ok, checks.clone().unwrap_or_default())
    }

    /// Checks that pass: they run in the worktree with the MAPLE_* variables, then the commit and push.
    /// The first that fails stops the finish there, with nothing committed or pushed.
    #[tokio::test]
    async fn checks_run_before_the_commit_and_a_failing_one_stops_the_finish() {
        let (root, bare, work, f) = finish_fixture("checks");
        let lines = Mutex::new(Vec::new());
        let emit = |m: Outbound| match m {
            Outbound::TaskProgress { text, .. } => lines.lock().unwrap().push(text),
            m => panic!("unexpected message {m:?}"),
        };
        let emit: Emit = &emit;
        let head = sh(&work, &["rev-parse", "HEAD"]);

        let failing = Finish { checks: Some("  echo linting\n\n  echo \"a.txt:1 offence ($MAPLE_PHASE)\"; exit 3\necho never".into()), ..f.clone() };
        let out = finish(emit, &failing).await.unwrap();
        let (ok, checks) = checks_of(&out);
        assert!(!ok);
        assert_eq!(
            checks.iter().map(|c| (c.command.as_str(), c.code)).collect::<Vec<_>>(),
            [("echo linting", Some(0)), ("echo \"a.txt:1 offence ($MAPLE_PHASE)\"; exit 3", Some(3))]
        );
        assert_eq!(checks[1].output.trim(), "a.txt:1 offence (checks)");
        let Outbound::TaskFinished { message, commit, .. } = &out else { unreachable!() };
        assert!(message.as_deref().unwrap().contains("exited 3"), "{message:?}");
        assert_eq!(*commit, None);
        assert_eq!(sh(&work, &["rev-parse", "HEAD"]), head, "nothing committed");
        assert_eq!(sh(&work, &["status", "--porcelain"]).trim(), "M a.txt");
        assert!(sh(&bare, &["branch", "--list"]).is_empty(), "nothing pushed");
        assert!(lines.lock().unwrap().iter().any(|l| l.contains("failed with exit code 3")), "{lines:?}");
        let Outbound::TaskFinished { not_run, .. } = &out else { unreachable!() };
        assert_eq!(not_run.iter().map(|n| (n.command.as_str(), n.reason.as_str())).collect::<Vec<_>>(), [("echo never", "skipped after an earlier failure")]);

        // `checkLines` keeps the tags: a check for what this machine lacks isn't run, and doesn't stop the finish.
        let tagged = Finish { checks: Some("touch tag-ran\ntrue".into()), check_lines: Some("[no-such-tag] touch tag-ran\ntrue".into()), ..f.clone() };
        let out = finish(emit, &tagged).await.unwrap();
        let (ok, checks) = checks_of(&out);
        assert!(ok, "{out:?}");
        assert_eq!(checks.iter().map(|c| c.command.as_str()).collect::<Vec<_>>(), ["true"]);
        assert!(!work.join("tag-ran").exists(), "a check this machine can't run never runs");
        let Outbound::TaskFinished { not_run, .. } = &out else { unreachable!() };
        assert_eq!(not_run.iter().map(|n| (n.command.as_str(), n.reason.as_str())).collect::<Vec<_>>(), [("touch tag-ran", "needs no-such-tag")]);
        let wire = serde_json::to_value(&out).unwrap();
        assert_eq!(wire["notRun"], serde_json::json!([{"command":"touch tag-ran","reason":"needs no-such-tag","kind":"requirement"}]));
        assert!(lines.lock().unwrap().iter().any(|l| l.contains("not run here: needs no-such-tag")), "{lines:?}");
        sh(&work, &["reset", "--quiet", "--hard", &head]);
        sh(&work, &["push", "--quiet", "--delete", bare.to_str().unwrap(), "agent/fix-1a2b"]);
        std::fs::write(work.join("a.txt"), "two\n").unwrap();

        let passing = Finish { checks: Some("test \"$MAPLE_WORKTREE\" = \"$PWD\"\ngrep -q two a.txt".into()), ..f.clone() };
        let out = finish(emit, &passing).await.unwrap();
        let (ok, checks) = checks_of(&out);
        assert!(ok, "{out:?}");
        assert_eq!(checks.len(), 2);
        assert!(checks.iter().all(crate::worktree_scripts::passed));
        assert_eq!(sh(&bare, &["log", "-1", "--format=%B", "agent/fix-1a2b"]), "Fix the flaky test");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// A commit its pre-commit hook (lefthook, husky) refuses is a failed check with the hook's output:
    /// nothing committed, pushed or left staged. Once the hook passes, the finish goes through.
    #[tokio::test]
    async fn a_failing_pre_commit_hook_is_a_failed_check_not_a_push_failure() {
        let (root, bare, work, f) = finish_fixture("hook");
        let hook = work.join(".git/hooks/pre-commit");
        std::fs::write(&hook, "#!/bin/sh\necho 'lefthook: rubocop: 1 offense'\necho 'a.txt: trailing whitespace' >&2\nexit 1\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
        let emit = |m: Outbound| panic!("unexpected message {m:?}");
        let head = sh(&work, &["rev-parse", "HEAD"]);

        let out = finish(&emit, &f).await.unwrap();
        let (ok, checks) = checks_of(&out);
        assert!(!ok);
        assert_eq!(checks.len(), 1);
        assert_eq!((checks[0].command.as_str(), checks[0].code), (HOOK_CHECK, Some(1)));
        assert!(checks[0].output.contains("1 offense") && checks[0].output.contains("trailing whitespace"), "{:?}", checks[0].output);
        assert_eq!(sh(&work, &["rev-parse", "HEAD"]), head);
        assert_eq!(sh(&work, &["diff", "--cached", "--name-only"]), "");
        assert!(sh(&bare, &["branch", "--list"]).is_empty());

        std::fs::write(&hook, "#!/bin/sh\nexit 0\n").unwrap();
        let (ok, _) = checks_of(&finish(&emit, &f).await.unwrap());
        assert!(ok);
        assert_eq!(sh(&bare, &["log", "-1", "--format=%B", "agent/fix-1a2b"]), "Fix the flaky test");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// main, pushed to the fixture's origin, then moved on there by another clone with `file` changed.
    fn main_moves_on(root: &Path, bare: &Path, work: &Path, file: &str) {
        sh(work, &["push", "--quiet", "origin", "main"]);
        let other = root.join("other");
        sh(root, &["clone", "--quiet", bare.to_str().unwrap(), other.to_str().unwrap()]);
        for (k, v) in [("user.name", "Other"), ("user.email", "other@example.com"), ("commit.gpgsign", "false")] {
            sh(&other, &["config", k, v]);
        }
        commit(&other, file, "main's line\n", "another task merges");
        sh(&other, &["push", "--quiet", "origin", "main"]);
    }

    /// A branch that doesn't merge into origin/<base> is a failed MERGE_CHECK naming the files: committed
    /// but not pushed, and the worktree clean, not left mid-merge. Once main is merged in, it pushes.
    #[tokio::test]
    async fn a_finish_that_conflicts_with_its_base_goes_back_unpushed() {
        let (root, bare, work, f) = finish_fixture("merge-conflict");
        main_moves_on(&root, &bare, &work, "a.txt");
        let emit = |m: Outbound| panic!("unexpected message {m:?}");

        let out = finish(&emit, &f).await.unwrap();
        let (ok, checks) = checks_of(&out);
        assert!(!ok, "{out:?}");
        let last = checks.last().unwrap();
        assert_eq!((last.command.as_str(), last.code), (MERGE_CHECK, Some(1)));
        assert!(last.output.contains("a.txt") && last.output.contains("merge it into the branch"), "{:?}", last.output);
        let Outbound::TaskFinished { message, pushed, .. } = &out else { unreachable!() };
        let message = message.as_deref().unwrap();
        assert!(message.contains("doesn't merge into main (conflicts in a.txt)") && message.contains("nothing was pushed"), "{message}");
        assert_eq!(*pushed, None);
        assert!(sh(&bare, &["branch", "--list", "agent/fix-1a2b"]).is_empty(), "nothing pushed");
        assert_eq!(sh(&work, &["log", "-1", "--format=%B"]), "Fix the flaky test", "committed");
        assert_eq!(sh(&work, &["status", "--porcelain"]), "");
        assert!(!work.join(".git/MERGE_HEAD").exists(), "not mid-merge");

        // The builder merges main and resolves the conflict, then finishes again.
        let _ = Command::new("git").arg("-C").arg(&work).args(["merge", "--quiet", "origin/main"]).output().await;
        std::fs::write(work.join("a.txt"), "two, and main's line\n").unwrap();
        sh(&work, &["commit", "--quiet", "-am", "Merge origin/main"]);
        let (ok, checks) = checks_of(&finish(&emit, &f).await.unwrap());
        assert!(ok && checks.is_empty(), "{checks:?}");
        assert!(!sh(&bare, &["branch", "--list", "agent/fix-1a2b"]).is_empty());
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// main moving on in other files doesn't stop a finish, and no check is reported for it.
    #[tokio::test]
    async fn a_finish_that_merges_cleanly_pushes() {
        let (root, bare, work, f) = finish_fixture("merge-clean");
        main_moves_on(&root, &bare, &work, "c.txt");
        let emit = |m: Outbound| panic!("unexpected message {m:?}");
        let out = finish(&emit, &f).await.unwrap();
        let (ok, checks) = checks_of(&out);
        assert!(ok && checks.is_empty(), "{out:?}");
        assert_eq!(sh(&bare, &["log", "-1", "--format=%B", "agent/fix-1a2b"]), "Fix the flaky test");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// An origin/<base> that can't be fetched (here origin has no main) doesn't hold the finish up.
    #[tokio::test]
    async fn a_finish_whose_base_cant_be_fetched_still_pushes() {
        let (root, bare, work, f) = finish_fixture("merge-unfetchable");
        assert!(merge_check(&work, "main").await.is_err());
        let emit = |m: Outbound| panic!("unexpected message {m:?}");
        let (ok, _) = checks_of(&finish(&emit, &f).await.unwrap());
        assert!(ok);
        assert_eq!(sh(&bare, &["log", "-1", "--format=%B", "agent/fix-1a2b"]), "Fix the flaky test");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The finish path by hand, on a real worktree: MAPLE_FINISH_DIR (on an agent/ branch, with an
    /// origin) and MAPLE_FINISH_CHECKS, pushed with the machine's credentials.
    /// `MAPLE_FINISH_DIR=… MAPLE_FINISH_CHECKS=… cargo test finish_by_hand -- --ignored --nocapture`
    #[tokio::test]
    #[ignore]
    async fn finish_by_hand() {
        let dir = std::env::var("MAPLE_FINISH_DIR").expect("MAPLE_FINISH_DIR");
        let branch = sh(Path::new(&dir), &["branch", "--show-current"]);
        let emit = |m: Outbound| {
            if let Outbound::TaskProgress { text, .. } = m {
                println!("progress: {text}");
            }
        };
        let f = Finish {
            task_id: "SCRATCH-1".into(),
            cwd: dir.clone(),
            repo_dir: dir,
            branch,
            base: Some("main".into()),
            title: "Scratch: finish by hand".into(),
            fallback: true,
            checks: std::env::var("MAPLE_FINISH_CHECKS").ok(),
            check_lines: None,
        };
        match finish(&emit, &f).await {
            Ok(out) => println!("task.finished: {}", serde_json::to_string_pretty(&out).unwrap()),
            Err(e) => println!("finish failed: {e:#}"),
        }
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
        let s = start(&emit, "t1", checkout.to_str().unwrap(), None, &req("fix-1a2b"), &places(&root, None), None).await.unwrap();
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

    /// A task worktree for `fix-1a2b` with one commit of the builder's work, its identity set for the merges.
    async fn worktree(root: &Path, bare: &Path) -> (String, std::path::PathBuf) {
        remote(bare, "a.txt");
        let checkout = root.join("Projects/widgets");
        sh(root, &["clone", "--quiet", bare.to_str().unwrap(), checkout.to_str().unwrap()]);
        let emit = |m: Outbound| panic!("unexpected message {m:?}");
        let s = start(&emit, "t1", checkout.to_str().unwrap(), None, &req("fix-1a2b"), &places(root, None), None).await.unwrap();
        let wt = expand_home(&s.worktree);
        for (k, v) in [("user.name", "T"), ("user.email", "t@example.com"), ("commit.gpgsign", "false")] {
            sh(&wt, &["config", k, v]);
        }
        commit(&wt, "b.txt", "fixed\n", "the builder's work");
        (s.worktree, wt)
    }

    /// Retry after a merge that left the worktree detached: it goes back on the task's branch when
    /// nothing would be lost, and is refused (and left alone) when HEAD holds work of its own.
    #[tokio::test]
    async fn a_detached_worktree_is_put_back_on_its_branch() {
        let root = tmp("detached");
        let (cwd, wt) = worktree(&root, &root.join("remotes/widgets.git")).await;
        let again = Request { existing: true, ..req("fix-1a2b") };
        let tip = sh(&wt, &["rev-parse", "HEAD"]);

        // Detached at the branch's tip.
        sh(&wt, &["checkout", "--quiet", "--detach"]);
        assert_eq!(existing(&cwd, &again).await.unwrap(), cwd);
        assert_eq!(sh(&wt, &["branch", "--show-current"]).trim(), "agent/fix-1a2b");

        // Left on the factory's merge commit, whose push failed.
        sh(&wt, &["checkout", "--quiet", "--detach", "origin/main"]);
        sh(&wt, &["merge", "--no-ff", "--quiet", "-m", "Fix it", "agent/fix-1a2b"]);
        existing(&cwd, &again).await.unwrap();
        assert_eq!(sh(&wt, &["branch", "--show-current"]).trim(), "agent/fix-1a2b");
        assert_eq!(sh(&wt, &["rev-parse", "HEAD"]), tip);

        // Detached with a commit only HEAD holds: refused, and still detached there.
        sh(&wt, &["checkout", "--quiet", "--detach"]);
        commit(&wt, "c.txt", "mine\n", "work only HEAD has");
        let mine = sh(&wt, &["rev-parse", "HEAD"]);
        let err = format!("{:#}", existing(&cwd, &again).await.unwrap_err());
        assert!(
            err.contains("is detached at") && err.contains("not on the task's branch agent/fix-1a2b") && err.contains("1 commit not on the branch"),
            "{err}"
        );
        assert_eq!(sh(&wt, &["branch", "--show-current"]).trim(), "");
        assert_eq!(sh(&wt, &["rev-parse", "HEAD"]), mine);

        // On another branch: refused as before.
        sh(&wt, &["checkout", "--quiet", "-b", "side"]);
        let err = format!("{:#}", existing(&cwd, &again).await.unwrap_err());
        assert!(err.contains("is on side, not the task's branch agent/fix-1a2b"), "{err}");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// A merge whose push is rejected still leaves the worktree on the task's branch.
    #[tokio::test]
    async fn a_merge_whose_push_fails_switches_back_to_the_branch() {
        let root = tmp("merge-rejected");
        let bare = root.join("remotes/widgets.git");
        let (cwd, wt) = worktree(&root, &bare).await;
        let hook = bare.join("hooks/pre-receive");
        std::fs::write(&hook, "#!/bin/sh\necho rejected >&2\nexit 1\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
        let m = Merge { task_id: "t1".into(), cwd: cwd.clone(), branch: "agent/fix-1a2b".into(), base: "main".into(), title: "Fix it".into() };
        let err = format!("{:#}", merge_and_switch_back(&wt, &m).await.unwrap_err());
        assert!(err.contains("rejected"), "{err}");
        assert_eq!(sh(&wt, &["branch", "--show-current"]).trim(), "agent/fix-1a2b");
        assert_eq!(sh(&wt, &["status", "--porcelain"]), "");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The no-App merge deletes the merged branch on origin, but keeps one that moved after it was merged.
    #[tokio::test]
    async fn a_merge_deletes_the_branch_on_origin_unless_it_moved() {
        let root = tmp("merge-deletes");
        let bare = root.join("remotes/widgets.git");
        let (cwd, wt) = worktree(&root, &bare).await;
        sh(&wt, &["push", "--quiet", "origin", "agent/fix-1a2b"]);
        let m = Merge { task_id: "t1".into(), cwd: cwd.clone(), branch: "agent/fix-1a2b".into(), base: "main".into(), title: "Fix it".into() };
        let (merged, branch) = merge_and_switch_back(&wt, &m).await.unwrap();
        assert_eq!(sh(&bare, &["rev-parse", "main"]), merged);
        assert_eq!(sh(&bare, &["branch", "--list", "agent/*"]), "");
        assert_eq!(branch, BranchDeletion::Deleted);
        assert_eq!(branch.note(), "deleted");

        // Someone pushes to the branch after the runner last saw it: the merge stands, the branch stays.
        sh(&wt, &["push", "--quiet", "origin", "agent/fix-1a2b"]);
        commit_on(&bare, "agent/fix-1a2b");
        let moved = sh(&bare, &["rev-parse", "agent/fix-1a2b"]);
        commit(&wt, "c.txt", "more\n", "more of the builder's work");
        let m = Merge { title: "Fix it again".into(), ..m };
        let (merged, branch) = merge_and_switch_back(&wt, &m).await.unwrap();
        assert_eq!(sh(&bare, &["rev-parse", "main"]), merged);
        assert_eq!(sh(&bare, &["rev-parse", "agent/fix-1a2b"]), moved);
        assert_eq!(branch.note(), "moved");

        // Never pushed: nothing to delete.
        commit(&wt, "d.txt", "local\n", "work that never went to origin");
        sh(&bare, &["update-ref", "-d", "refs/heads/agent/fix-1a2b"]);
        let (_, branch) = merge_and_switch_back(&wt, &Merge { title: "Fix it once more".into(), ..m }).await.unwrap();
        assert_eq!(branch, BranchDeletion::Gone);
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The dry-run merge: clean while main hasn't touched the task's files, the conflicting path once
    /// it has, and the worktree (HEAD, index, files) exactly as it was both times.
    #[tokio::test]
    async fn a_merge_check_reports_conflicts_and_touches_nothing() {
        let root = tmp("merge-check");
        let bare = root.join("remotes/widgets.git");
        let (_cwd, wt) = worktree(&root, &bare).await;
        commit(&wt, "a.txt", "the task's line\n", "the builder changes a.txt");
        let head = sh(&wt, &["rev-parse", "HEAD"]);

        // main moves on elsewhere, in a file the task didn't touch.
        let other = root.join("other");
        sh(&root, &["clone", "--quiet", bare.to_str().unwrap(), other.to_str().unwrap()]);
        commit(&other, "c.txt", "unrelated\n", "another task merges");
        sh(&other, &["push", "--quiet", "origin", "main"]);
        assert_eq!(merge_check(&wt, "main").await.unwrap(), Vec::<String>::new());
        assert_eq!((sh(&wt, &["rev-parse", "HEAD"]), sh(&wt, &["status", "--porcelain"])), (head.clone(), String::new()));

        // Then in the same line of a.txt.
        commit(&other, "a.txt", "main's line\n", "another task changes a.txt");
        sh(&other, &["push", "--quiet", "origin", "main"]);
        assert_eq!(merge_check(&wt, "main").await.unwrap(), vec!["a.txt".to_string()]);
        assert_eq!((sh(&wt, &["rev-parse", "HEAD"]), sh(&wt, &["status", "--porcelain"])), (head, String::new()));
        assert_eq!(std::fs::read_to_string(wt.join("a.txt")).unwrap(), "the task's line\n");
        assert!(merge_check(&wt, "--upload-pack=x").await.is_err());
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The Changes tab's commits: two on the branch (the builder's b.txt, then c.txt and more of
    /// b.txt), oldest first, each with its own counts and patch, and the whole-branch diff as before.
    #[tokio::test]
    async fn a_diff_lists_the_branchs_commits_with_their_own_patches() {
        let root = tmp("diff-commits");
        let bare = root.join("remotes/widgets.git");
        let (_cwd, wt) = worktree(&root, &bare).await;
        std::fs::write(wt.join("b.txt"), "fixed\nand again\n").unwrap();
        commit(&wt, "c.txt", "two\nthree\n", "Add c.txt\n\nWith a body.");
        let whole = sh(&wt, &["diff", "--no-color", "--no-renames", "origin/main...HEAD"]);

        let r = diff_report(&wt, "main").await.unwrap();
        assert_eq!((r.patch.trim_end(), r.truncated), (whole.trim_end(), false));
        assert_eq!(r.files.iter().map(|f| (f.path.as_str(), f.added)).collect::<Vec<_>>(), vec![("b.txt", 2), ("c.txt", 2)]);
        assert_eq!(r.commits.iter().map(|c| c.subject.as_str()).collect::<Vec<_>>(), vec!["the builder's work", "Add c.txt"]);
        let (first, second) = (&r.commits[0], &r.commits[1]);
        assert_eq!(second.sha, sh(&wt, &["rev-parse", "HEAD"]).trim());
        assert_eq!((first.body.as_deref(), second.body.as_deref()), (None, Some("With a body.")));
        assert_eq!(first.files.iter().map(|f| (f.path.as_str(), f.added, f.removed)).collect::<Vec<_>>(), vec![("b.txt", 1, 0)]);
        assert_eq!(second.files.iter().map(|f| (f.path.as_str(), f.added, f.removed)).collect::<Vec<_>>(), vec![("b.txt", 1, 0), ("c.txt", 2, 0)]);
        assert_eq!((second.added, second.removed, second.truncated), (3, 0, false));
        assert!(first.patch.contains("+++ b/b.txt") && first.patch.contains("+fixed") && !first.patch.contains("c.txt"));
        assert!(second.patch.contains("+and again") && second.patch.contains("+three") && !second.patch.contains("+fixed"));
        assert!(first.at > 1_000_000_000_000);
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// A commit on `branch` in the bare repo `bare`, as another machine's push would make.
    fn commit_on(bare: &Path, branch: &str) {
        let tip = sh(bare, &["rev-parse", branch]);
        let c = sh(
            bare,
            &["-c", "user.name=O", "-c", "user.email=o@example.com", "commit-tree", &format!("{tip}^{{tree}}"), "-p", &tip, "-m", "someone else's push"],
        );
        sh(bare, &["update-ref", &format!("refs/heads/{branch}"), &c]);
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
        let s = start(&emit, "t1", studio.to_str().unwrap(), None, &req("fix-1a2b"), &places(&root, None), None).await.unwrap();
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
        let l = start(&emit, "t1", laptop.to_str().unwrap(), None, &req("fix-1a2b"), &places(&root, None), None).await.unwrap();
        let lwt = expand_home(&l.worktree);
        assert_eq!((l.base.as_str(), sh(&lwt, &["rev-parse", "HEAD"])), ("main", head.clone()));
        assert_eq!(std::fs::read_to_string(lwt.join("c.txt")).unwrap(), "not committed yet\n");
        assert_eq!(sh(&lwt, &["rev-parse", "--abbrev-ref", "HEAD"]), "agent/fix-1a2b");
        // Another task there, whose branch GitHub doesn't have, starts from main as before.
        let other = start(&emit, "t2", laptop.to_str().unwrap(), None, &req("other-0000"), &places(&root, None), None).await.unwrap();
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
        let s = start(&emit, "t1", checkout.to_str().unwrap(), None, &req("fix-1a2b"), &places(&root, None), None).await.unwrap();
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
        let err = format!("{:#}", start(&emit, "t2", checkout.to_str().unwrap(), None, &req("other-0000"), &places(&root, None), None).await.unwrap_err());
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
                resolve(&req_id, TokenReply { token: Some(token.into()), error: None, code: None, settings_url: None });
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

        let s = start(&emit, "t1", "", Some("acme/widgets"), &req("fix-1a2b"), &at, None).await.unwrap();
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
        let again = start(&emit, "t2", "", Some("acme/widgets"), &req("next-0000"), &at, None).await.unwrap();
        assert_eq!(again.repo_dir, s.repo_dir);

        // A repo the token can't reach: a clear error with the token scrubbed, and nothing left behind.
        let err = format!("{:#}", start(&emit, "t3", "", Some("acme/missing"), &req("fix-1a2b"), &at, None).await.unwrap_err());
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
        let s = start(&emit, "t1", "", Some("acme/widgets"), &req("a-0000"), &at, None).await.unwrap();
        assert_eq!(expand_home(&s.repo_dir), fresh);

        // Once the runner has its own clone, that one.
        let managed = root.join("managed/acme/widgets");
        sh(&root, &["clone", "--quiet", bare.to_str().unwrap(), managed.to_str().unwrap()]);
        sh(&managed, &["remote", "set-url", "origin", "https://github.com/acme/widgets.git"]);
        let s = start(&emit, "t2", "", Some("acme/widgets"), &req("b-0000"), &at, None).await.unwrap();
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

    /// A repo with a finished task's worktree on agent/mf-20 (its HEAD is the PR's head), and that head.
    fn finished_task(tag: &str) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf, String) {
        let root = tmp(tag);
        let repo = root.join("app");
        std::fs::create_dir_all(&repo).unwrap();
        let sh = |dir: &Path, args: &[&str]| {
            let out = std::process::Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
            assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        };
        sh(&repo, &["init", "--quiet", "-b", "main"]);
        sh(&repo, &["config", "user.name", "Test"]);
        sh(&repo, &["config", "user.email", "t@example.com"]);
        sh(&repo, &["config", "commit.gpgsign", "false"]);
        std::fs::write(repo.join("a.txt"), "one\n").unwrap();
        sh(&repo, &["add", "-A"]);
        sh(&repo, &["commit", "--quiet", "-m", "first"]);
        let wt = crate::worktrees::worktree_path(&repo, "mf-20").unwrap();
        sh(&repo, &["worktree", "add", "--quiet", "-b", "agent/mf-20", wt.to_str().unwrap()]);
        std::fs::write(wt.join("a.txt"), "two\n").unwrap();
        sh(&wt, &["commit", "--quiet", "-am", "the change"]);
        let head = sh(&wt, &["rev-parse", "HEAD"]);
        (root, repo, wt, head)
    }

    fn cleanup_of(repo: &Path, wt: &Path, head: &str, teardown: Option<&str>, archive: Option<&str>) -> Cleanup {
        Cleanup {
            task_id: "MF-20".into(),
            cwd: wt.to_string_lossy().into_owned(),
            repo_dir: repo.to_string_lossy().into_owned(),
            branch: "agent/mf-20".into(),
            merged: false,
            heads: vec![head.to_string()],
            repo: None,
            delete_remote: false,
            scripts: Some(crate::worktree_scripts::WorktreeScripts {
                create: None,
                preflight: None,
                preflight_watch: None,
                setup: None,
                checks: None,
                teardown: teardown.map(String::from),
                archive: archive.map(String::from),
                timeout_secs: Some(30),
                require_paths: None,
            }),
        }
    }

    fn cleaned(m: &Outbound) -> (bool, bool, String) {
        match m {
            Outbound::TaskCleaned { ok, branch_deleted, message, .. } => (*ok, *branch_deleted, message.clone().unwrap_or_default()),
            other => panic!("not task.cleaned: {other:?}"),
        }
    }

    /// Teardown runs while the worktree is still there, then the runner removes it as usual.
    #[tokio::test]
    async fn teardown_runs_before_the_worktree_is_removed() {
        let (root, repo, wt, head) = finished_task("teardown");
        let lines = Mutex::new(Vec::new());
        let emit = |m: Outbound| lines.lock().unwrap().push(m);
        let c = cleanup_of(&repo, &wt, &head, Some(r#"test -f "$MAPLE_WORKTREE/a.txt" && echo "$MAPLE_PHASE $MAPLE_BRANCH" > ../teardown.log"#), None);
        let (ok, branch_deleted, message) = cleaned(&cleanup(&emit, &[], &c, None).await);
        assert!(ok, "{message}");
        assert_eq!(std::fs::read_to_string(root.join("teardown.log")).unwrap(), "teardown agent/mf-20\n");
        assert!(!wt.exists());
        assert!(branch_deleted);
        assert!(message.starts_with("ran the teardown script (`test -f"), "{message}");
        assert!(message.contains(", then Removed "), "{message}");
        assert!(matches!(&lines.lock().unwrap()[..], [Outbound::TaskProgress { text, .. }] if text.starts_with("ran the teardown script")));
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The archive script owns the worktree and branch: the runner removes neither.
    #[tokio::test]
    async fn archive_replaces_the_removal() {
        let (root, repo, wt, head) = finished_task("archive");
        let emit = |_: Outbound| {};
        let c = cleanup_of(&repo, &wt, &head, None, Some(r#"mkdir -p ../archive && git worktree move "$MAPLE_WORKTREE" "../archive/$MAPLE_TASK_ID""#));
        let (ok, branch_deleted, message) = cleaned(&cleanup(&emit, &[], &c, None).await);
        assert!(ok, "{message}");
        assert!(!wt.exists());
        let archived = root.join("archive/MF-20");
        assert_eq!(std::fs::read_to_string(archived.join("a.txt")).unwrap(), "two\n");
        // The branch is the script's to keep.
        assert!(!branch_deleted);
        assert!(git(&repo, &["rev-parse", "--verify", "--quiet", "refs/heads/agent/mf-20"], None).await.is_ok());
        assert!(message.contains("archive script took the worktree and branch from there"), "{message}");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// A teardown that fails stops the cleanup, with its output, and leaves the worktree alone.
    #[tokio::test]
    async fn a_failing_teardown_stops_the_cleanup() {
        let (root, repo, wt, head) = finished_task("teardown-fail");
        let emit = |_: Outbound| {};
        let c = cleanup_of(&repo, &wt, &head, Some("echo 'docker compose down: no such project'; exit 1"), Some("echo never"));
        let (ok, _, message) = cleaned(&cleanup(&emit, &[], &c, None).await);
        assert!(!ok);
        assert!(
            message.contains(
                "teardown script (`echo 'docker compose down: no such project'; exit 1`) failed with exit code 1:\ndocker compose down: no such project"
            ),
            "{message}"
        );
        assert!(wt.join("a.txt").exists());
        // A session still in it: nothing runs.
        let c = cleanup_of(&repo, &wt, &head, Some("touch ../ran"), None);
        let (ok, _, message) = cleaned(&cleanup(&emit, &[wt.to_string_lossy().into_owned()], &c, None).await);
        assert!(!ok && message.contains("A session is still using"), "{message}");
        assert!(!root.join("ran").exists());
        std::fs::remove_dir_all(&root).unwrap();
    }
}
