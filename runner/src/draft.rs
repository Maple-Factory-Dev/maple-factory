//! Draft with AI (`draft.run`): the hub's drafter, run once and unable to change anything.
//!
//! With a repo or folder, the agent works in a throwaway worktree made the way a task's is (from
//! GitHub's copy of the base branch, see `tasks::start`), which is removed afterwards; without one
//! (picking a goal) it runs in an empty folder with no tools at all. Claude Code gets only its read
//! tools (`--tools Read,Grep,Glob`); Codex runs with `--sandbox read-only`. What it's doing goes to
//! the hub as `draft.progress` ("Reading lib/session.ts"), and its last message as `draft.done`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use serde::Deserialize;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::Notify;

use crate::protocol::Outbound;
use crate::sessions::{Sessions, expand_home};

/// A draft that runs longer than this is stopped.
const TIMEOUT: Duration = Duration::from_secs(8 * 60);

/// `draft.run` from the hub.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Run {
    /// `draft-<uuid>`: also the id its token requests go by.
    pub id: String,
    pub agent: String,
    pub prompt: String,
    #[serde(default)]
    pub repo: Option<String>,
    #[serde(default)]
    pub folder: Option<String>,
    #[serde(default)]
    pub base: Option<String>,
}

static RUNNING: LazyLock<Mutex<HashMap<String, Arc<Notify>>>> = LazyLock::new(Default::default);

pub fn cancel(id: &str) {
    if let Some(stop) = RUNNING.lock().unwrap().remove(id) {
        stop.notify_one();
    }
}

pub async fn run(sessions: Sessions, r: Run) {
    let stop = Arc::new(Notify::new());
    RUNNING.lock().unwrap().insert(r.id.clone(), stop.clone());
    let emit = |m: Outbound| sessions.emit(m);
    let say = |text: &str| sessions.emit(Outbound::DraftProgress { id: r.id.clone(), text: text.to_string() });
    let mut worktree: Option<PathBuf> = None;
    let work = async {
        let cwd = if r.repo.is_some() || r.folder.is_some() {
            say(&format!("Fetching {}…", r.repo.as_deref().or(r.folder.as_deref()).unwrap_or("the code")));
            let req = crate::worktrees::Request { name: worktree_name(&r.id)?, base: r.base.clone(), existing: false };
            let started = crate::tasks::start(&emit, &r.id, r.folder.as_deref().unwrap_or(""), r.repo.as_deref(), &req, &crate::tasks::Places::here()).await?;
            let dir = expand_home(&started.worktree);
            worktree = Some(dir.clone());
            dir
        } else {
            let dir = std::env::temp_dir().join(format!("maple-{}", r.id));
            std::fs::create_dir_all(&dir)?;
            dir
        };
        say("Thinking…");
        tokio::time::timeout(TIMEOUT, ask(&r, &cwd, worktree.is_some(), &say)).await.map_err(|_| anyhow!("It took longer than 8 minutes, so it was stopped."))?
    };
    let result = tokio::select! {
        r = work => r,
        _ = stop.notified() => Err(anyhow!("Cancelled.")),
    };
    RUNNING.lock().unwrap().remove(&r.id);
    if let Some(dir) = &worktree {
        remove(dir, &worktree_name(&r.id).unwrap_or_default()).await;
    } else {
        let _ = std::fs::remove_dir_all(std::env::temp_dir().join(format!("maple-{}", r.id)));
    }
    let (output, error) = match result {
        Ok(text) => (Some(text), None),
        Err(e) => (None, Some(crate::tasks::scrub(&e.to_string(), None))),
    };
    sessions.emit(Outbound::DraftDone { id: r.id.clone(), output, error });
}

/// `draft-<uuid>` → `draft-<first 8 of the uuid>`, under `agent/` like a task's.
fn worktree_name(id: &str) -> Result<String> {
    let short: String = id.strip_prefix("draft-").unwrap_or(id).chars().filter(|c| c.is_ascii_alphanumeric()).take(8).collect();
    let name = format!("draft-{short}");
    crate::worktrees::valid_name(&name)?;
    Ok(name)
}

/// Removes the draft's worktree and its branch: nothing in them is anyone's work.
async fn remove(dir: &Path, name: &str) {
    let Ok(root) = crate::worktrees::main_root(dir).await else { return };
    let git = |args: Vec<String>| Command::new("git").arg("-C").arg(&root).args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status();
    let _ = git(vec!["worktree".into(), "remove".into(), "--force".into(), dir.to_string_lossy().into_owned()]).await;
    let _ = git(vec!["branch".into(), "-D".into(), format!("{}{name}", crate::worktrees::BRANCH_PREFIX)]).await;
    crate::worktrees::poke(true);
}

/// Runs the agent once in `cwd` and returns its last message.
async fn ask(r: &Run, cwd: &Path, read: bool, say: &(dyn Fn(&str) + Sync)) -> Result<String> {
    let agent = crate::agent_config::find(&r.agent).ok_or_else(|| anyhow!("This machine doesn't know the agent {}.", r.agent))?;
    let args: Vec<String> = match r.agent.as_str() {
        "claude" => {
            let tools = if read { "Read,Grep,Glob" } else { "" };
            // `--tools` takes a list, so `--` ends it before the prompt.
            ["-p", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--strict-mcp-config", "--tools", tools, "--"]
                .into_iter()
                .map(str::to_string)
                .chain([r.prompt.clone()])
                .collect()
        }
        "codex" => {
            // Codex writes its last message to a file; outside the worktree, so it can't be read as code.
            ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--json", "-o"]
                .into_iter()
                .map(str::to_string)
                .chain([answer_file(&r.id).to_string_lossy().into_owned(), r.prompt.clone()])
                .collect()
        }
        other => bail!("Draft with AI works with Claude Code or Codex, not {other}."),
    };
    let script = format!("exec {} \"$@\"", if agent.command.is_empty() { r.agent.as_str() } else { agent.command.as_str() });
    let mut child = Command::new(crate::agents::login_shell())
        .args(["-l", "-i", "-c", &script, "maple-draft"])
        .args(&args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()?;
    let mut stderr = child.stderr.take().ok_or_else(|| anyhow!("no stderr"))?;
    let errors = tokio::spawn(async move {
        let mut text = String::new();
        let _ = stderr.read_to_string(&mut text).await;
        text
    });
    let mut lines = BufReader::new(child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?).lines();
    let mut answer: Option<String> = None;
    let mut failed: Option<String> = None;
    let mut said = String::new();
    while let Some(line) = lines.next_line().await? {
        let Ok(event) = serde_json::from_str::<Value>(&line) else { continue };
        if let Some(text) = progress(&event, cwd).filter(|t| *t != said) {
            say(&text);
            said = text;
        }
        // Claude Code's last event says how it went.
        if event["type"] == "result" {
            if event["is_error"] == true {
                failed = Some(event["result"].as_str().unwrap_or("Claude Code stopped with an error.").to_string());
            } else {
                answer = event["result"].as_str().map(str::to_string);
            }
        }
    }
    let status = child.wait().await?;
    let errors = errors.await.unwrap_or_default();
    if r.agent == "codex" {
        let file = answer_file(&r.id);
        answer = std::fs::read_to_string(&file).ok().filter(|t| !t.trim().is_empty());
        let _ = std::fs::remove_file(&file);
    }
    if let Some(e) = failed {
        bail!("{e}");
    }
    match answer {
        Some(a) => Ok(a),
        None if !status.success() => bail!("{} stopped: {}", agent.label, errors.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("no reason given").trim()),
        None => bail!("{} didn't answer.", agent.label),
    }
}

fn answer_file(id: &str) -> PathBuf {
    std::env::temp_dir().join(format!("maple-{id}-answer.txt"))
}

/// A line about what the agent is doing, from one of its JSON events: Claude Code's tool uses, or
/// the commands Codex runs.
fn progress(event: &Value, cwd: &Path) -> Option<String> {
    let rel = |p: &str| p.strip_prefix(&*cwd.to_string_lossy()).map(|r| r.trim_start_matches('/').to_string()).unwrap_or_else(|| p.to_string());
    if event["type"] == "assistant" {
        let uses = event["message"]["content"].as_array()?;
        let last = uses.iter().rev().find(|c| c["type"] == "tool_use")?;
        let input = &last["input"];
        return Some(match last["name"].as_str()? {
            "Read" => format!("Reading {}", rel(input["file_path"].as_str()?)),
            "Grep" => format!("Searching for “{}”", input["pattern"].as_str()?),
            "Glob" => format!("Looking for {}", input["pattern"].as_str()?),
            other => format!("Using {other}"),
        });
    }
    let command = event["item"]["command"].as_str().or_else(|| event["msg"]["command"].as_str())?;
    let short: String = command.chars().take(80).collect();
    Some(format!("Running `{short}`"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_the_worktree_from_the_id() {
        assert_eq!(worktree_name("draft-0b7c1e2a-9f00-4a1b-8c3d-1234567890ab").unwrap(), "draft-0b7c1e2a");
    }

    #[test]
    fn says_what_its_reading() {
        let cwd = Path::new("/w/app");
        let read = serde_json::json!({"type": "assistant", "message": {"content": [{"type": "text", "text": "Let me look"}, {"type": "tool_use", "name": "Read", "input": {"file_path": "/w/app/lib/session.ts"}}]}});
        assert_eq!(progress(&read, cwd).unwrap(), "Reading lib/session.ts");
        let grep = serde_json::json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Grep", "input": {"pattern": "refreshToken"}}]}});
        assert_eq!(progress(&grep, cwd).unwrap(), "Searching for “refreshToken”");
        let codex = serde_json::json!({"type": "item.started", "item": {"type": "command_execution", "command": "rg -n session lib"}});
        assert_eq!(progress(&codex, cwd).unwrap(), "Running `rg -n session lib`");
        assert!(progress(&serde_json::json!({"type": "result", "result": "{}"}), cwd).is_none());
    }
}
