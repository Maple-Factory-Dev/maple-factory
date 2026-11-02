//! A proof job (`task.prove_checks`): checks the machine that built a task couldn't run (they need
//! macos, xcode…), run here on exactly the head it pushed. No agent session: the branch is fetched,
//! a detached worktree is made at `head` in a temporary folder, only the handed-off checks run there
//! (with the MAPLE_* variables, the repo's secrets and the login PATH, as a finish's checks do), the
//! results go back as `task.checks_proved`, and the worktree is removed whatever happened.

use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow, bail};
use serde::Deserialize;

use crate::protocol::Outbound;
use crate::sessions::{Sessions, expand_home};
use crate::tasks::{Emit, Places, git};

/// `task.prove_checks` from the hub.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProveChecks {
    pub task_id: String,
    pub job_id: String,
    #[serde(default)]
    pub repo: Option<String>,
    #[serde(default)]
    pub repo_dir: Option<String>,
    pub branch: String,
    pub head: String,
    #[serde(default)]
    pub base: Option<String>,
    pub checks: String,
}

/// Runs the job and tells the hub how it went.
pub async fn run(sessions: Sessions, p: ProveChecks) {
    let emit = |m: Outbound| sessions.emit(m);
    let out = prove(&emit, &p, &Places::here(), &std::env::temp_dir()).await;
    sessions.emit(out);
}

/// The job, answered as `task.checks_proved`. `tmp` is where the temporary worktree goes.
pub async fn prove(emit: Emit<'_>, p: &ProveChecks, at: &Places, tmp: &Path) -> Outbound {
    let answer = |ok: bool, checks: Vec<crate::wire::CheckRun>, message: Option<String>| Outbound::TaskChecksProved {
        task_id: p.task_id.clone(),
        job_id: p.job_id.clone(),
        head: p.head.clone(),
        ok,
        checks,
        message,
    };
    let root = match checkout(emit, p, at).await {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("task {}: proof job couldn't get {}: {e:#}", p.task_id, p.branch);
            return answer(false, vec![], Some(format!("{e:#}")));
        }
    };
    let dir = tmp.join(format!("maple-prove-{}", sanitize(&p.job_id)));
    let ran = async {
        let made = git(&root, &["worktree", "add", "--detach", "--quiet", &dir.to_string_lossy(), &p.head], None).await;
        made.map_err(|e| anyhow!("Couldn't check out {} ({e}).", short(&p.head)))?;
        Ok::<_, anyhow::Error>(run_checks(emit, p, &root, &dir).await)
    }
    .await;
    remove(&root, &dir).await;
    match ran {
        Ok(checks) => {
            let ok = !checks.is_empty() && checks.iter().all(crate::worktree_scripts::passed);
            let message = checks.is_empty().then(|| "No checks to run.".to_string());
            answer(ok, checks, message)
        }
        Err(e) => answer(false, vec![], Some(format!("{e:#}"))),
    }
}

/// The repo's checkout here (the folder the hub named, else `repos::pick`, else a new clone), with
/// the task's branch fetched and `head` in it.
async fn checkout(emit: Emit<'_>, p: &ProveChecks, at: &Places) -> Result<PathBuf> {
    let fetch_override = at.fetch_url.as_deref();
    let own = Some(p.branch.as_str());
    let base = p.base.as_deref();
    let given = p.repo_dir.as_deref().map(expand_home).filter(|d| d.exists());
    let root = match given {
        Some(dir) => {
            let root = crate::worktrees::main_root(&dir).await?;
            crate::tasks::fetch_base(emit, &p.task_id, &root, base, own, fetch_override).await?;
            root
        }
        None => {
            let repo = p.repo.as_deref().ok_or_else(|| anyhow!("The job names neither a folder nor a repo."))?;
            let (owner, name) = repo.split_once('/').filter(|(o, n)| crate::tasks::valid_part(o) && crate::tasks::valid_part(n)).ok_or_else(|| anyhow!("`{repo}` isn't owner/name."))?;
            let _one = crate::tasks::CLONING.lock().await;
            match crate::repos::pick(&crate::repos::scan(&at.roots, &at.managed).await, repo) {
                Some(c) => {
                    let root = expand_home(&c.path);
                    crate::tasks::fetch_base(emit, &p.task_id, &root, base, own, fetch_override).await?;
                    root
                }
                None => crate::tasks::clone(emit, &p.task_id, &at.managed, owner, name, base, own, fetch_override).await?.0,
            }
        }
    };
    if git(&root, &["cat-file", "-e", &format!("{}^{{commit}}", p.head)], None).await.is_err() {
        bail!("{} isn't on {} as fetched; it was pushed over or never arrived.", short(&p.head), p.branch);
    }
    Ok(root)
}

/// Only the handed-off checks, with the MAPLE_* variables, the repo's secrets and the login PATH.
async fn run_checks(emit: Emit<'_>, p: &ProveChecks, root: &Path, dir: &Path) -> Vec<crate::wire::CheckRun> {
    let scripts = crate::worktree_scripts::WorktreeScripts {
        create: None,
        preflight: None,
        preflight_watch: None,
        setup: None,
        checks: Some(p.checks.clone()),
        teardown: None,
        archive: None,
        timeout_secs: None,
        require_paths: None,
    };
    let repo = match p.repo.clone() {
        Some(r) => Some(r),
        None => crate::repos::github_repo(root).await,
    };
    let env: Vec<(String, String)> = match repo.as_deref() {
        Some(r) => match crate::secrets::request(emit, r, Some(&p.task_id)).await {
            Ok(values) => values.into_iter().collect(),
            Err(e) => {
                tracing::warn!("task {}: its handed-off checks run without {r}'s secrets: {e:#}", p.task_id);
                vec![]
            }
        },
        None => vec![],
    };
    let path = crate::proof::login_path().await;
    let t = crate::worktree_scripts::ForTask {
        scripts: &scripts,
        task_id: &p.task_id,
        repo: repo.as_deref(),
        base: p.base.as_deref(),
        env: &env,
        emit: Some(emit),
        path: path.as_deref(),
    };
    crate::worktree_scripts::checks(Some(&scripts), &t.context(root, dir, &p.branch)).await
}

/// Removes the temporary worktree, and its folder and git's note of it even if `worktree remove` can't.
async fn remove(root: &Path, dir: &Path) {
    if let Err(e) = git(root, &["worktree", "remove", "--force", &dir.to_string_lossy()], None).await {
        tracing::debug!("proof job: worktree remove: {e:#}");
    }
    let _ = std::fs::remove_dir_all(dir);
    let _ = git(root, &["worktree", "prune"], None).await;
}

fn short(head: &str) -> &str {
    &head[..head.len().min(7)]
}

fn sanitize(id: &str) -> String {
    id.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).take(64).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;
    use std::sync::Mutex;

    fn sh(dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    /// An "origin" with the task's branch at two commits, and a checkout of it with nothing fetched.
    fn repo(tmp: &Path) -> (PathBuf, String, String) {
        let origin = tmp.join("origin");
        std::fs::create_dir_all(&origin).unwrap();
        sh(&origin, &["init", "--quiet", "-b", "main"]);
        sh(&origin, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "--allow-empty", "-m", "base"]);
        sh(&origin, &["checkout", "--quiet", "-b", "agent/mf-1"]);
        std::fs::write(origin.join("marker"), "one").unwrap();
        sh(&origin, &["add", "marker"]);
        sh(&origin, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "one"]);
        let first = sh(&origin, &["rev-parse", "HEAD"]);
        std::fs::write(origin.join("marker"), "two").unwrap();
        sh(&origin, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-am", "two"]);
        let second = sh(&origin, &["rev-parse", "HEAD"]);
        sh(&origin, &["checkout", "--quiet", "main"]);
        let checkout = tmp.join("checkout");
        std::fs::create_dir_all(&checkout).unwrap();
        sh(&checkout, &["init", "--quiet", "-b", "main"]);
        sh(&checkout, &["remote", "add", "origin", &origin.to_string_lossy()]);
        (checkout, first, second)
    }

    fn job(checkout: &Path, head: &str, checks: &str) -> ProveChecks {
        ProveChecks {
            task_id: "MF-1".into(),
            job_id: "job-1".into(),
            repo: None,
            repo_dir: Some(checkout.to_string_lossy().into()),
            branch: "agent/mf-1".into(),
            head: head.into(),
            base: Some("main".into()),
            checks: checks.into(),
        }
    }

    struct Tmp(PathBuf);
    impl Tmp {
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for Tmp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn tempdir() -> Tmp {
        let d = std::env::temp_dir().join(format!("maple-prove-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        Tmp(d)
    }

    fn places(tmp: &Path) -> Places {
        Places { roots: vec![], managed: tmp.join("managed"), fetch_url: None }
    }

    #[tokio::test]
    async fn runs_only_the_handed_off_checks_at_the_head_and_leaves_no_worktree() {
        let tmp = tempdir();
        let (checkout, first, _second) = repo(tmp.path());
        let before = sh(&checkout, &["worktree", "list"]);
        let sent = Mutex::new(vec![]);
        let emit = |m: Outbound| sent.lock().unwrap().push(m);
        // At the older head: the marker says "one", not the branch tip's "two".
        let out = prove(&emit, &job(&checkout, &first, "grep -qx one marker\necho \"$MAPLE_TASK_ID\""), &places(tmp.path()), tmp.path()).await;
        let Outbound::TaskChecksProved { ok, checks, head, job_id, message, .. } = out else { panic!("{out:?}") };
        assert!(ok, "{checks:?} {message:?}");
        assert_eq!((head.as_str(), job_id.as_str(), checks.len()), (first.as_str(), "job-1", 2));
        assert!(checks[1].output.contains("MF-1"), "{:?}", checks[1].output);
        assert_eq!(sh(&checkout, &["worktree", "list"]), before);
        assert!(!tmp.path().join("maple-prove-job-1").exists());
    }

    #[tokio::test]
    async fn a_failing_check_and_an_unknown_head_come_back_failed_and_cleaned_up() {
        let tmp = tempdir();
        let (checkout, _first, second) = repo(tmp.path());
        let before = sh(&checkout, &["worktree", "list"]);
        let emit = |_m: Outbound| {};
        let out = prove(&emit, &job(&checkout, &second, "grep -qx one marker"), &places(tmp.path()), tmp.path()).await;
        let Outbound::TaskChecksProved { ok, checks, .. } = out else { panic!() };
        assert!(!ok);
        assert_eq!(checks.len(), 1);
        let out = prove(&emit, &job(&checkout, "0123456789abcdef0123456789abcdef01234567", "true"), &places(tmp.path()), tmp.path()).await;
        let Outbound::TaskChecksProved { ok, message, .. } = out else { panic!() };
        assert!(!ok);
        assert!(message.unwrap().contains("isn't on agent/mf-1"));
        assert_eq!(sh(&checkout, &["worktree", "list"]), before);
    }
}
