//! Draft with AI (`draft.run`): the hub's drafter, run once and unable to change anything.
//!
//! With a repo or folder, the agent works in a throwaway worktree made the way a task's is (from
//! GitHub's copy of the base branch, see `tasks::start`), which is removed afterwards; a folder that
//! isn't a git checkout, or has no origin to fetch, is read in place as it is; without either
//! (picking a goal) it runs in an empty folder with no tools at all. Claude Code gets only its read
//! tools (`--tools Read,Grep,Glob`); Codex runs with `--sandbox read-only`. What it's doing goes to
//! the hub as `draft.progress` ("Reading lib/session.ts"), as does what it says along the way (a
//! `text` line), and its last message as `draft.done`.

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
use crate::wire::DraftLineKind;

/// A draft that runs longer than this is stopped.
const TIMEOUT: Duration = Duration::from_secs(8 * 60);

/// The most of one thing the agent says that goes to the hub, in characters.
const MAX_TEXT: usize = 600;

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
    let say = |kind: DraftLineKind, text: &str| sessions.emit(Outbound::DraftProgress { id: r.id.clone(), text: text.to_string(), kind });
    let mut worktree: Option<PathBuf> = None;
    let work = async {
        let cwd = if let Some(dir) = in_place(r.folder.as_deref()).await? {
            say(DraftLineKind::Tool, &format!("Reading {} as it is on this machine…", r.folder.as_deref().unwrap_or_default()));
            dir
        } else if r.repo.is_some() || r.folder.is_some() {
            say(DraftLineKind::Tool, &format!("Fetching {}…", r.repo.as_deref().or(r.folder.as_deref()).unwrap_or("the code")));
            let req = crate::worktrees::Request { name: worktree_name(&r.id)?, base: r.base.clone(), existing: false };
            let started = crate::tasks::start(&emit, &r.id, r.folder.as_deref().unwrap_or(""), r.repo.as_deref(), &req, &crate::tasks::Places::here(), None).await?;
            let dir = expand_home(&started.worktree);
            worktree = Some(dir.clone());
            dir
        } else {
            let dir = std::env::temp_dir().join(format!("maple-{}", r.id));
            std::fs::create_dir_all(&dir)?;
            dir
        };
        say(DraftLineKind::Tool, "Thinking…");
        tokio::time::timeout(TIMEOUT, ask(&r, &cwd, r.repo.is_some() || r.folder.is_some(), &say)).await.map_err(|_| anyhow!("It took longer than 8 minutes, so it was stopped."))?
    };
    let result = tokio::select! {
        r = work => r,
        _ = stop.notified() => Err(anyhow!("Cancelled.")),
    };
    RUNNING.lock().unwrap().remove(&r.id);
    if let Some(dir) = &worktree {
        remove(dir, &worktree_name(&r.id).unwrap_or_default()).await;
    } else if r.folder.is_none() && r.repo.is_none() {
        let _ = std::fs::remove_dir_all(std::env::temp_dir().join(format!("maple-{}", r.id)));
    }
    let (output, error) = match result {
        Ok(text) => (Some(text), None),
        Err(e) => (None, Some(crate::tasks::scrub(&e.to_string(), None))),
    };
    sessions.emit(Outbound::DraftDone { id: r.id.clone(), output, error });
}

/// The folder to read as it is, when `folder` isn't in a git repository or its repository has no
/// origin: there's nothing to fetch a worktree from. None: make a worktree (or there's no folder).
async fn in_place(folder: Option<&str>) -> Result<Option<PathBuf>> {
    let Some(folder) = folder.filter(|f| !f.trim().is_empty()) else { return Ok(None) };
    let dir = expand_home(folder);
    if !dir.is_dir() {
        bail!("{folder} isn't a folder on this machine.");
    }
    let origin = Command::new("git")
        .arg("-C")
        .arg(&dir)
        .args(["remote", "get-url", "origin"])
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await?;
    // Outside a repository `git remote` fails as well, so one check covers both.
    Ok((!origin.success()).then_some(dir))
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

/// The agent's arguments: with `read`, only its read tools (Claude Code) or a read-only sandbox (Codex).
fn args(r: &Run, read: bool) -> Result<Vec<String>> {
    Ok(match r.agent.as_str() {
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
    })
}

/// Runs the agent once in `cwd` and returns its last message.
async fn ask(r: &Run, cwd: &Path, read: bool, say: &(dyn Fn(DraftLineKind, &str) + Sync)) -> Result<String> {
    let agent = crate::agent_config::find(&r.agent).ok_or_else(|| anyhow!("This machine doesn't know the agent {}.", r.agent))?;
    let args = args(r, read)?;
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
    let mut said: Option<(DraftLineKind, String)> = None;
    while let Some(line) = lines.next_line().await? {
        let Ok(event) = serde_json::from_str::<Value>(&line) else { continue };
        for next in progress(&event, cwd) {
            if said.as_ref() != Some(&next) {
                say(next.0, &next.1);
                said = Some(next);
            }
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

/// What the agent did and said in one of its JSON events, in order: Claude Code's tool uses, text
/// and thinking, or the commands Codex runs and its messages and reasoning.
fn progress(event: &Value, cwd: &Path) -> Vec<(DraftLineKind, String)> {
    let rel = |p: &str| p.strip_prefix(&*cwd.to_string_lossy()).map(|r| r.trim_start_matches('/').to_string()).unwrap_or_else(|| p.to_string());
    let tool = |name: &str, input: &Value| -> Option<String> {
        Some(match name {
            "Read" => format!("Reading {}", rel(input["file_path"].as_str()?)),
            "Grep" => format!("Searching for “{}”", input["pattern"].as_str()?),
            "Glob" => format!("Looking for {}", input["pattern"].as_str()?),
            other => format!("Using {other}"),
        })
    };
    let text = |t: Option<&str>| t.map(trim).filter(|t| !t.is_empty()).map(|t| (DraftLineKind::Text, t));
    if event["type"] == "assistant" {
        let Some(content) = event["message"]["content"].as_array() else { return vec![] };
        return content
            .iter()
            .filter_map(|c| match c["type"].as_str()? {
                "text" => text(c["text"].as_str()),
                "thinking" => text(c["thinking"].as_str()),
                "tool_use" => tool(c["name"].as_str()?, &c["input"]).map(|t| (DraftLineKind::Tool, t)),
                _ => None,
            })
            .collect();
    }
    // Codex: `item.*` events from `exec --json`, or the older `msg` ones.
    let item = if event["item"].is_object() { &event["item"] } else { &event["msg"] };
    match item["type"].as_str() {
        Some("agent_message") | Some("reasoning") | Some("agent_reasoning") if event["type"] != "item.started" => {
            return text(item["text"].as_str().or_else(|| item["message"].as_str())).into_iter().collect();
        }
        _ => {}
    }
    let Some(command) = item["command"].as_str() else { return vec![] };
    let short: String = command.chars().take(80).collect();
    vec![(DraftLineKind::Tool, format!("Running `{short}`"))]
}

/// `text` trimmed, and cut to about `MAX_TEXT` characters.
fn trim(text: &str) -> String {
    let text = text.trim();
    if text.chars().count() <= MAX_TEXT {
        return text.to_string();
    }
    let cut: String = text.chars().take(MAX_TEXT).collect();
    format!("{}…", cut.trim_end())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_on(folder: &Path, agent: &str) -> Run {
        Run { id: "draft-0b7c1e2a".into(), agent: agent.into(), prompt: "What's here?".into(), repo: None, folder: Some(folder.to_string_lossy().into_owned()), base: None }
    }

    fn git(dir: &Path, args: &[&str]) {
        assert!(std::process::Command::new("git").arg("-C").arg(dir).args(args).output().unwrap().status.success(), "git {args:?}");
    }

    /// Every file under `dir` and its contents.
    fn snapshot(dir: &Path) -> Vec<(PathBuf, Vec<u8>)> {
        let mut all = vec![];
        for e in std::fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                all.extend(snapshot(&p));
            } else {
                all.push((p.clone(), std::fs::read(&p).unwrap()));
            }
        }
        all.sort();
        all
    }

    #[tokio::test]
    async fn reads_a_plain_folder_in_place_with_read_tools() {
        let dir = std::env::temp_dir().join(format!("maple-draft-plain-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(dir.join("lib")).unwrap();
        std::fs::write(dir.join("lib/session.ts"), "export const ttl = 60;\n").unwrap();
        let before = snapshot(&dir);
        let r = run_on(&dir, "claude");
        assert_eq!(in_place(r.folder.as_deref()).await.unwrap(), Some(dir.clone()));
        let claude = args(&r, true).unwrap();
        let tools = claude.iter().position(|a| a == "--tools").unwrap();
        assert_eq!(claude[tools + 1], "Read,Grep,Glob");
        assert!(args(&run_on(&dir, "codex"), true).unwrap().windows(2).any(|w| w == ["--sandbox", "read-only"]));
        // Nothing was made or changed there: no repository, no worktree.
        assert_eq!(snapshot(&dir), before);
        assert!(!dir.join(".git").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn reads_a_checkout_without_origin_in_place_and_makes_a_worktree_with_one() {
        let dir = std::env::temp_dir().join(format!("maple-draft-git-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        git(&dir, &["init", "--quiet"]);
        let folder = Some(dir.to_string_lossy().into_owned());
        assert_eq!(in_place(folder.as_deref()).await.unwrap(), Some(dir.clone()));
        git(&dir, &["remote", "add", "origin", "https://github.com/acme/app.git"]);
        assert_eq!(in_place(folder.as_deref()).await.unwrap(), None);
        assert_eq!(in_place(None).await.unwrap(), None);
        assert!(in_place(Some("/no/such/maple/folder")).await.is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn names_the_worktree_from_the_id() {
        assert_eq!(worktree_name("draft-0b7c1e2a-9f00-4a1b-8c3d-1234567890ab").unwrap(), "draft-0b7c1e2a");
    }

    fn tool(t: &str) -> (DraftLineKind, String) {
        (DraftLineKind::Tool, t.to_string())
    }

    fn text(t: &str) -> (DraftLineKind, String) {
        (DraftLineKind::Text, t.to_string())
    }

    #[test]
    fn says_what_its_reading() {
        let cwd = Path::new("/w/app");
        let read = serde_json::json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read", "input": {"file_path": "/w/app/lib/session.ts"}}]}});
        assert_eq!(progress(&read, cwd), vec![tool("Reading lib/session.ts")]);
        let grep = serde_json::json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Grep", "input": {"pattern": "refreshToken"}}]}});
        assert_eq!(progress(&grep, cwd), vec![tool("Searching for “refreshToken”")]);
        let codex = serde_json::json!({"type": "item.started", "item": {"type": "command_execution", "command": "rg -n session lib"}});
        assert_eq!(progress(&codex, cwd), vec![tool("Running `rg -n session lib`")]);
        assert!(progress(&serde_json::json!({"type": "result", "result": "{}"}), cwd).is_empty());
    }

    #[test]
    fn says_what_claude_says_and_thinks() {
        let cwd = Path::new("/w/app");
        let event = serde_json::json!({"type": "assistant", "message": {"content": [
            {"type": "thinking", "thinking": "The session code is probably in lib."},
            {"type": "text", "text": "  Let me look at the session code.\n"},
            {"type": "tool_use", "name": "Read", "input": {"file_path": "/w/app/lib/session.ts"}},
            {"type": "text", "text": "   "},
        ]}});
        assert_eq!(
            progress(&event, cwd),
            vec![text("The session code is probably in lib."), text("Let me look at the session code."), tool("Reading lib/session.ts")]
        );
    }

    #[test]
    fn says_what_codex_says_and_reasons() {
        let cwd = Path::new("/w/app");
        let said = serde_json::json!({"type": "item.completed", "item": {"id": "item_3", "type": "agent_message", "text": "Sessions refresh in lib/session.ts."}});
        assert_eq!(progress(&said, cwd), vec![text("Sessions refresh in lib/session.ts.")]);
        let reasoned = serde_json::json!({"type": "item.completed", "item": {"id": "item_0", "type": "reasoning", "text": "**Looking for the refresh logic**"}});
        assert_eq!(progress(&reasoned, cwd), vec![text("**Looking for the refresh logic**")]);
        let older = serde_json::json!({"id": "0", "msg": {"type": "agent_message", "message": "Done."}});
        assert_eq!(progress(&older, cwd), vec![text("Done.")]);
        // A message that's still being written isn't said until it's done.
        assert!(progress(&serde_json::json!({"type": "item.started", "item": {"type": "agent_message", "text": ""}}), cwd).is_empty());
    }

    #[test]
    fn cuts_long_text() {
        let long = "word ".repeat(400);
        let cut = trim(&long);
        assert!(cut.ends_with('…'));
        assert!(cut.chars().count() <= MAX_TEXT + 1);
        assert_eq!(trim("  short  "), "short");
    }
}
