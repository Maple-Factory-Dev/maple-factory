//! Claude Code asks whether to trust a folder the first time it starts in one, and waits for an
//! answer. A task's worktree is one the runner made itself, from a repo the factory works in, so
//! (as its owner chose) the runner answers for those and only those: it marks the worktree trusted
//! in Claude Code's config (`~/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json`) just before the
//! task's session starts there. Nothing else in that file changes, and a missing or unreadable file
//! is left alone. If the prompt shows anyway, `watch` sees it and the hub raises a hand about it.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Map, Value};
use uuid::Uuid;

use crate::hooks::Activity;
use crate::sessions::Sessions;

/// What a task session says while Claude Code waits on its trust prompt; the hub raises a hand on it.
pub const PROMPT_WAITING: &str = "Claude Code is asking whether to trust this folder";

/// Whether a screen shows Claude Code's folder-trust prompt (its wording across versions).
pub fn is_trust_prompt(screen: &str) -> bool {
    let s = screen.to_lowercase();
    ["trust the files in this folder", "yes, i trust this folder", "a project you created or one you trust"].iter().any(|p| s.contains(p))
}

/// Watches a new task session's screen for a while: if Claude Code stops at the trust prompt (when
/// marking the worktree trusted didn't take), it says so, so the hub can ask a person.
pub fn watch(sessions: Sessions, id: Uuid) {
    tokio::spawn(async move {
        for _ in 0..40 {
            tokio::time::sleep(Duration::from_secs(3)).await;
            let Ok(screen) = sessions.capture(id, 40).await else { return };
            if is_trust_prompt(&screen) {
                sessions.set_activity(id, Activity::Waiting(Some(PROMPT_WAITING.into())), None, None);
                return;
            }
        }
    });
}

fn config_file() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("CLAUDE_CONFIG_DIR") {
        return Some(PathBuf::from(dir).join(".claude.json"));
    }
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".claude.json"))
}

/// Marks a task's worktree trusted for Claude Code. Errors are logged, never fatal.
pub fn trust_worktree(dir: &Path) {
    let Some(file) = config_file() else { return };
    if let Err(e) = trust_in(&file, dir) {
        tracing::warn!("couldn't mark {} trusted for Claude Code: {e}", dir.display());
    }
}

fn trust_in(file: &Path, dir: &Path) -> anyhow::Result<()> {
    let Ok(bytes) = std::fs::read(file) else { return Ok(()) };
    let mut config: Value = serde_json::from_slice(&bytes)?;
    let key = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf()).to_string_lossy().trim_end_matches('/').to_string();
    let Some(root) = config.as_object_mut() else { anyhow::bail!("it isn't a JSON object") };
    let projects = root.entry("projects").or_insert_with(|| Value::Object(Map::new()));
    let Some(projects) = projects.as_object_mut() else { anyhow::bail!("its projects aren't an object") };
    let project = projects.entry(key).or_insert_with(|| Value::Object(Map::new()));
    let Some(project) = project.as_object_mut() else { anyhow::bail!("the folder's entry isn't an object") };
    if project.get("hasTrustDialogAccepted") == Some(&Value::Bool(true)) {
        return Ok(());
    }
    project.insert("hasTrustDialogAccepted".into(), Value::Bool(true));
    // Written beside it and renamed over it, so Claude Code never reads half a file.
    let tmp = file.with_extension(format!("json.maple-{}", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec_pretty(&config)?)?;
    std::fs::rename(&tmp, file)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("maple-trust-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn marks_the_worktree_and_keeps_everything_else() {
        let home = temp("marks");
        let file = home.join(".claude.json");
        let work = home.join("work");
        std::fs::create_dir(&work).unwrap();
        std::fs::write(&file, r#"{"numStartups": 3, "projects": {"/elsewhere": {"hasTrustDialogAccepted": false, "x": 1}}}"#).unwrap();
        trust_in(&file, &work).unwrap();
        let v: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        let key = std::fs::canonicalize(&work).unwrap().to_string_lossy().to_string();
        assert_eq!(v["projects"][key.as_str()]["hasTrustDialogAccepted"], Value::Bool(true));
        assert_eq!(v["numStartups"], 3);
        assert_eq!(v["projects"]["/elsewhere"], serde_json::json!({"hasTrustDialogAccepted": false, "x": 1}));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn knows_the_prompt() {
        assert!(is_trust_prompt(" Do you trust the files in this folder?\n\n ❯ 1. Yes, proceed"));
        assert!(is_trust_prompt("Is this a project you created or one you trust?\n❯ 1. Yes, I trust this folder"));
        assert!(!is_trust_prompt("> Write a real README\n⏺ Reading README.md"));
    }

    #[test]
    fn leaves_a_missing_file_alone() {
        let home = temp("missing");
        trust_in(&home.join(".claude.json"), &home).unwrap();
        assert!(!home.join(".claude.json").exists());
        let _ = std::fs::remove_dir_all(&home);
    }
}
