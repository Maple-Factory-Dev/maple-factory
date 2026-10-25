//! Git state of each session's directory: branch, changes, ahead/behind, worktree.

use std::path::Path;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde::Serialize;
use tokio::process::Command;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GitState {
    pub branch: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    pub changed: u32,
    pub worktree: bool,
}

static RESEND: AtomicBool = AtomicBool::new(false);

/// Send everything on the next check (a new connection: reports sent while away were dropped).
pub fn resend() {
    RESEND.store(true, Ordering::SeqCst);
}

/// Checks each session's directory every 5 seconds and reports what changed. Everything is
/// re-sent each minute and after a reconnect, so a hub that missed a report catches up.
pub async fn report(sessions: crate::sessions::Sessions) {
    use std::collections::HashMap;
    let mut last: HashMap<uuid::Uuid, GitState> = HashMap::new();
    let mut tick = tokio::time::interval(Duration::from_secs(5));
    let mut n: u64 = 0;
    loop {
        tick.tick().await;
        n += 1;
        let full = RESEND.swap(false, Ordering::SeqCst) || n.is_multiple_of(12);
        let mut changed = Vec::new();
        let list = sessions.list();
        for s in &list {
            let Some(git) = status(&crate::sessions::expand_home(&s.cwd)).await else { continue };
            if full || last.get(&s.id) != Some(&git) {
                last.insert(s.id, git.clone());
                changed.push(crate::protocol::GitReport { id: s.id, git });
            }
        }
        last.retain(|id, _| list.iter().any(|s| &s.id == id));
        if !changed.is_empty() {
            sessions.emit(crate::protocol::Outbound::Git { sessions: changed });
        }
    }
}

/// None when `dir` isn't inside a git repository (or git isn't installed).
pub async fn status(dir: &Path) -> Option<GitState> {
    // One cheap call: porcelain v2 gives branch, upstream counts and changed files.
    let out = git(dir, &["status", "--porcelain=v2", "--branch", "--untracked-files=normal"]).await?;
    let mut state = parse_status(&out);
    // A linked worktree's git dir lives under the main repo's .git/worktrees/.
    if let (Some(git_dir), Some(common)) = (git(dir, &["rev-parse", "--git-dir"]).await, git(dir, &["rev-parse", "--git-common-dir"]).await) {
        state.worktree = dir.join(git_dir.trim()) != dir.join(common.trim());
    }
    Some(state)
}

fn parse_status(out: &str) -> GitState {
    let mut state = GitState { branch: None, ahead: 0, behind: 0, changed: 0, worktree: false };
    for line in out.lines() {
        if let Some(head) = line.strip_prefix("# branch.head ") {
            state.branch = (head != "(detached)").then(|| head.to_string());
        } else if let Some(ab) = line.strip_prefix("# branch.ab ") {
            // "+2 -0"
            for part in ab.split_whitespace() {
                if let Some(n) = part.strip_prefix('+') {
                    state.ahead = n.parse().unwrap_or(0);
                } else if let Some(n) = part.strip_prefix('-') {
                    state.behind = n.parse().unwrap_or(0);
                }
            }
        } else if !line.starts_with('#') && !line.is_empty() {
            state.changed += 1;
        }
    }
    state
}

async fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let mut cmd = Command::new("git");
    cmd.arg("-C")
        .arg(dir)
        .args(args)
        // Never prompt, never take locks a running agent might trip over.
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(5), cmd.output()).await.ok()?.ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_porcelain_v2() {
        let out = "# branch.oid abc\n# branch.head agent/health-endpoint\n# branch.upstream origin/agent/health-endpoint\n# branch.ab +2 -1\n1 .M N... 100644 100644 100644 a b src/a.rs\n? new.txt\n";
        let s = parse_status(out);
        assert_eq!((s.branch.as_deref(), s.ahead, s.behind, s.changed), (Some("agent/health-endpoint"), 2, 1, 2));
        let detached = parse_status("# branch.oid abc\n# branch.head (detached)\n");
        assert_eq!((detached.branch, detached.changed), (None, 0));
    }
}
