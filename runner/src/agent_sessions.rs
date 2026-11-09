//! Each Maple session's agent conversation id (Claude Code's hook `session_id`, Codex's rollout id),
//! saved under `~/.config/maple/sessions/<maple-session>.json` so it outlives tmux and the machine.
//! When the factory restarts a task's session after tmux died (`session.open`'s `resumeFrom`), the
//! new session picks the old conversation up with `claude --resume <id>` / `codex resume <id>`.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};
use uuid::Uuid;

/// How long a record is kept: a task restarted later than this starts afresh anyway.
pub const KEEP: Duration = Duration::from_secs(14 * 24 * 3600);

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub agent: String,
    pub conversation_id: String,
    pub cwd: String,
    pub updated_at: u64,
}

pub fn dir() -> Result<PathBuf> {
    Ok(crate::config::dir()?.join("sessions"))
}

/// Only UUID-shaped ids are kept, so nothing odd ever reaches an agent's argv.
pub fn valid_id(id: &str) -> Option<String> {
    Uuid::parse_str(id).ok().filter(|_| id.len() == 36).map(|u| u.hyphenated().to_string())
}

/// A Codex rollout file's conversation id: the uuid that ends its name (`rollout-<time>-<uuid>.jsonl`).
pub fn rollout_id(path: &Path) -> Option<String> {
    let stem = path.file_stem()?.to_str()?;
    valid_id(stem.get(stem.len().checked_sub(36)?..)?)
}

/// Saves (or replaces: the newest conversation wins, after /clear or /compact) `session`'s record.
/// Unchanged records aren't rewritten, so a hook firing on every turn costs only a read.
pub fn save_in(dir: &Path, session: Uuid, agent: &str, conversation_id: &str, cwd: &str) -> Result<bool> {
    let Some(conversation_id) = valid_id(conversation_id) else { return Ok(false) };
    if load_in(dir, session).is_some_and(|r| r.agent == agent && r.conversation_id == conversation_id && r.cwd == cwd) {
        return Ok(false);
    }
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    let record = Record { agent: agent.into(), conversation_id, cwd: cwd.into(), updated_at: now_ms() };
    let path = dir.join(format!("{session}.json"));
    let tmp = dir.join(format!(".{session}.{}.tmp", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec(&record)?).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::rename(&tmp, &path).with_context(|| format!("saving {}", path.display()))?;
    Ok(true)
}

pub fn load_in(dir: &Path, session: Uuid) -> Option<Record> {
    let record: Record = serde_json::from_slice(&std::fs::read(dir.join(format!("{session}.json"))).ok()?).ok()?;
    valid_id(&record.conversation_id).is_some().then_some(record)
}

/// The conversation to resume for `session`: only one by the same agent in the same folder.
pub fn resumable_in(dir: &Path, session: Uuid, agent: &str, cwd: &str) -> Option<String> {
    load_in(dir, session).filter(|r| r.agent == agent && same_dir(&r.cwd, cwd)).map(|r| r.conversation_id)
}

/// Removes records older than `KEEP`, and (with `cwd`) every record for that folder: its worktree is gone.
pub fn sweep_in(dir: &Path, cwd: Option<&str>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let old = entry.metadata().and_then(|m| m.modified()).ok().and_then(|t| SystemTime::now().duration_since(t).ok()).is_some_and(|age| age > KEEP);
        let gone = cwd.is_some_and(|cwd| {
            std::fs::read(&path).ok().and_then(|b| serde_json::from_slice::<Record>(&b).ok()).is_some_and(|r| same_dir(&r.cwd, cwd))
        });
        if old || gone {
            let _ = std::fs::remove_file(&path);
        }
    }
}

pub fn save(session: Uuid, agent: &str, conversation_id: &str, cwd: &str) {
    match dir().and_then(|d| save_in(&d, session, agent, conversation_id, cwd)) {
        Ok(true) => tracing::info!("session {session}: saved its {agent} conversation {conversation_id}"),
        Ok(false) => {}
        Err(e) => tracing::warn!("session {session}: could not save its {agent} conversation: {e:#}"),
    }
}

pub fn resumable(session: Uuid, agent: &str, cwd: &str) -> Option<String> {
    resumable_in(&dir().ok()?, session, agent, cwd)
}

pub fn sweep(cwd: Option<&str>) {
    if let Ok(d) = dir() {
        sweep_in(&d, cwd);
    }
}

fn same_dir(a: &str, b: &str) -> bool {
    let canon = |p: &str| {
        let p = crate::sessions::expand_home(p);
        std::fs::canonicalize(&p).unwrap_or(p)
    };
    a == b || canon(a) == canon(b)
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONV: &str = "0b9d8c7e-1f2a-4b3c-9d4e-5f6a7b8c9d0e";

    fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!("maple-agent-sessions-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn ids_round_trip_through_the_sessions_dir() {
        let dir = tmp().join("sessions");
        let s = Uuid::new_v4();
        assert!(save_in(&dir, s, "claude", CONV, "/work/a").unwrap());
        assert!(!save_in(&dir, s, "claude", CONV, "/work/a").unwrap(), "unchanged: not rewritten");
        let r = load_in(&dir, s).unwrap();
        assert_eq!((r.agent.as_str(), r.conversation_id.as_str(), r.cwd.as_str()), ("claude", CONV, "/work/a"));
        assert_eq!(resumable_in(&dir, s, "claude", "/work/a").as_deref(), Some(CONV));
        // A newer conversation (after /clear) replaces it.
        let newer = "11111111-2222-4333-8444-555555555555";
        assert!(save_in(&dir, s, "claude", newer, "/work/a").unwrap());
        assert_eq!(resumable_in(&dir, s, "claude", "/work/a").as_deref(), Some(newer));
        // No temp files left behind.
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
    }

    #[test]
    fn a_missing_or_mismatched_record_resumes_nothing() {
        let dir = tmp();
        let s = Uuid::new_v4();
        assert_eq!(resumable_in(&dir, s, "claude", "/work/a"), None);
        save_in(&dir, s, "claude", CONV, "/work/a").unwrap();
        assert_eq!(resumable_in(&dir, s, "codex", "/work/a"), None, "another agent");
        assert_eq!(resumable_in(&dir, s, "claude", "/work/b"), None, "another folder");
        assert_eq!(resumable_in(&dir, Uuid::new_v4(), "claude", "/work/a"), None, "another session");
    }

    #[test]
    fn only_uuid_shaped_ids_are_kept() {
        let dir = tmp();
        let s = Uuid::new_v4();
        for bad in ["", "--dangerously-skip-permissions", "abc", "0b9d8c7e1f2a4b3c9d4e5f6a7b8c9d0e", "{0b9d8c7e-1f2a-4b3c-9d4e-5f6a7b8c9d0e}"] {
            assert!(!save_in(&dir, s, "claude", bad, "/w").unwrap(), "{bad:?}");
        }
        assert_eq!(load_in(&dir, s), None);
        // A hand-edited record with a bad id is ignored too.
        std::fs::write(dir.join(format!("{s}.json")), r#"{"agent":"claude","conversationId":"-rf","cwd":"/w","updatedAt":1}"#).unwrap();
        assert_eq!(resumable_in(&dir, s, "claude", "/w"), None);
    }

    #[test]
    fn codex_rollout_names_give_their_id() {
        let p = Path::new("/h/.codex/sessions/2026/11/09/rollout-2026-11-09T10-00-00-0b9d8c7e-1f2a-4b3c-9d4e-5f6a7b8c9d0e.jsonl");
        assert_eq!(rollout_id(p).as_deref(), Some(CONV));
        assert_eq!(rollout_id(Path::new("/x/rollout-a.jsonl")), None);
    }

    #[test]
    fn sweeping_a_worktree_removes_its_records() {
        let dir = tmp();
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        save_in(&dir, a, "claude", CONV, "/work/a").unwrap();
        save_in(&dir, b, "codex", CONV, "/work/b").unwrap();
        sweep_in(&dir, Some("/work/a"));
        assert_eq!(load_in(&dir, a), None);
        assert!(load_in(&dir, b).is_some());
        sweep_in(&dir, None);
        assert!(load_in(&dir, b).is_some(), "recent records stay");
    }
}
