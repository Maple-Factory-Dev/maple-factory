//! Agent status hooks.
//!
//! Agents report what they're doing through their own hook mechanisms, which run
//! `maple-runner hook …` inside the session. That process forwards the event over a
//! local socket to the running runner, which turns it into a session activity.
//! Nothing in the user's own agent config is changed: Claude Code gets its hooks
//! from `--settings`, Codex from a `-c notify=…` override.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use uuid::Uuid;

use crate::protocol::AgentState;
use crate::sessions::Sessions;
use crate::wire::{McpConnector, McpTransport};

pub const SOCKET_ENV: &str = "MAPLE_HOOK_SOCKET";
pub const SESSION_ENV: &str = "MAPLE_SESSION_ID";

/// Paths the agents need to reach the runner.
pub struct Hooks {
    pub exe: String,
    pub socket: PathBuf,
    pub claude_settings: PathBuf,
    /// Claude Code's `--mcp-config` file for the `agents` MCP server (`maple-runner mcp`).
    pub mcp_config: PathBuf,
    /// Where the files above live, and each session's own MCP config (`session_mcp_config`).
    pub dir: PathBuf,
}

/// The factory's MCP connectors in Claude Code's `--mcp-config` format.
fn connectors_config(connectors: &[McpConnector]) -> Value {
    let servers: serde_json::Map<String, Value> = connectors
        .iter()
        .filter_map(|c| {
            let server = match c.transport {
                McpTransport::Stdio => json!({ "type": "stdio", "command": c.command.as_deref()?, "args": c.args, "env": c.env }),
                McpTransport::Http => json!({ "type": "http", "url": c.url.as_deref()?, "headers": c.headers }),
                McpTransport::Other => return None,
            };
            Some((c.name.clone(), server))
        })
        .collect();
    json!({ "mcpServers": servers })
}

/// The `agents` MCP server, as Claude Code's `--mcp-config` file has it.
fn mcp_config(exe: &str) -> Value {
    json!({ "mcpServers": { "maple": { "command": exe, "args": ["mcp"] } } })
}

impl Hooks {
    pub fn prepare(dir: &Path, name: &str) -> Result<Self> {
        let exe = std::env::current_exe().context("finding the runner binary")?.to_string_lossy().into_owned();
        // Per tmux server, like the MCP config: a second runner on this machine (a dev one) mustn't point the
        // first one's sessions at its own binary.
        let claude_settings = dir.join(format!("claude-settings-{name}.json"));
        let command = format!("{} hook claude", shell_quote(&exe));
        let hook = |matcher: Option<&str>| {
            let mut entry = json!({ "hooks": [{ "type": "command", "command": command, "timeout": 5 }] });
            if let Some(m) = matcher {
                entry["matcher"] = json!(m);
            }
            json!([entry])
        };
        let settings = json!({
            "hooks": {
                "UserPromptSubmit": hook(None),
                "PreToolUse": hook(Some("*")),
                "PostToolUse": hook(Some("*")),
                // Says which tool and input a permission prompt is about; prints nothing, so Claude still asks.
                "PermissionRequest": hook(Some("*")),
                "Notification": hook(None),
                "Stop": hook(None),
            },
            // Plan usage in every session's status line, and to the web app (statusline.rs).
            "statusLine": { "type": "command", "command": format!("{} statusline", shell_quote(&exe)), "padding": 0 },
        });
        std::fs::write(&claude_settings, serde_json::to_vec_pretty(&settings)?)?;
        let mcp = dir.join(format!("mcp-{name}.json"));
        std::fs::write(&mcp, serde_json::to_vec_pretty(&mcp_config(&exe))?)?;
        Ok(Self { exe, socket: dir.join(format!("runner-{name}.sock")), claude_settings, mcp_config: mcp, dir: dir.to_path_buf() })
    }

    /// A session's own `--mcp-config` file, for the factory's connectors: their secrets are in it, so
    /// only this user can read it, and it's removed when the session ends (`remove_session_mcp_config`).
    pub fn session_mcp_config_path(&self, id: Uuid) -> PathBuf {
        self.dir.join(format!("mcp-session-{id}.json"))
    }

    /// Writes the session's connectors file (0600) for Claude Code; none without connectors.
    pub fn write_session_mcp_config(&self, id: Uuid, connectors: &[McpConnector]) -> Result<Option<PathBuf>> {
        if connectors.is_empty() {
            return Ok(None);
        }
        use std::os::unix::fs::OpenOptionsExt;
        let path = self.session_mcp_config_path(id);
        let mut file = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&path)?;
        file.write_all(&serde_json::to_vec_pretty(&connectors_config(connectors))?)?;
        Ok(Some(path))
    }

    pub fn remove_session_mcp_config(&self, id: Uuid) {
        let _ = std::fs::remove_file(self.session_mcp_config_path(id));
    }

    /// Removes every session's connectors file but `live` ones'; returns how many went.
    pub fn sweep_session_mcp_configs(&self, live: &std::collections::HashSet<Uuid>) -> usize {
        let Ok(entries) = std::fs::read_dir(&self.dir) else { return 0 };
        let mut removed = 0;
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(id) = name.to_str().and_then(|n| n.strip_prefix("mcp-session-")?.strip_suffix(".json")).and_then(|s| Uuid::parse_str(s).ok()) else {
                continue;
            };
            if !live.contains(&id) && std::fs::remove_file(entry.path()).is_ok() {
                removed += 1;
            }
        }
        removed
    }

    /// Extra arguments that switch on status hooks and the `agents` MCP server for an agent.
    /// Neither replaces the user's own config: Claude Code merges `--settings` and adds
    /// `--mcp-config` servers to the user's (no `--strict-mcp-config`); Codex's `-c` overrides
    /// only the keys given.
    pub fn agent_args(&self, agent: &str) -> Vec<String> {
        match agent {
            "claude" => vec![
                "--settings".into(),
                self.claude_settings.to_string_lossy().into_owned(),
                // One argument with `=`: `--mcp-config` takes several values, and in the
                // two-argument form it would swallow a positional prompt after it.
                format!("--mcp-config={}", self.mcp_config.to_string_lossy()),
            ],
            "codex" => {
                // TOML values; JSON string quoting is valid TOML for these paths.
                let exe = Value::String(self.exe.clone());
                vec![
                    "-c".into(),
                    format!("notify=[{exe},\"hook\",\"codex\"]"),
                    "-c".into(),
                    format!("mcp_servers.maple.command={exe}"),
                    "-c".into(),
                    "mcp_servers.maple.args=[\"mcp\"]".into(),
                    // Codex starts MCP servers with a minimal environment; these say which session is asking.
                    "-c".into(),
                    format!("mcp_servers.maple.env_vars=[\"{SESSION_ENV}\",\"{SOCKET_ENV}\"]"),
                    // wait_for can take up to 10 minutes; Codex's default tool timeout is 60s.
                    "-c".into(),
                    "mcp_servers.maple.tool_timeout_sec=660".into(),
                ]
            }
            _ => vec![],
        }
    }
}

/// What an agent is doing right now, as shown in the UI.
pub enum Activity {
    /// Working, optionally on a described step ("Editing hub.ts").
    Working(Option<String>),
    /// A new prompt: the session's current task.
    Started(String),
    Waiting(Option<String>),
    Done(Option<String>),
}

#[derive(Clone)]
pub struct ActivityUpdate {
    pub state: &'static str,
    pub message: Option<String>,
    pub task: Option<String>,
}

impl Activity {
    pub fn update(self) -> ActivityUpdate {
        let (state, message, task) = match self {
            Activity::Working(m) => ("working", m, None),
            Activity::Started(t) => ("working", None, Some(t)),
            Activity::Waiting(m) => ("waiting", m, None),
            Activity::Done(m) => ("done", m, None),
        };
        ActivityUpdate { state, message, task }
    }
}

/// The session's agent state after an update, kept so a `hello` can say it again. The same rules
/// the hub applies to each `session.activity` (`applyActivity` in control/src/activity.ts):
/// a bare "working" keeps the step it was on; Claude's generic "needs your permission" after a
/// question keeps the question's text; the question goes once it isn't waiting; the task and the
/// summary stay until there's a new one. `tool` is a PreToolUse's `permission` payload, kept so a
/// permission notification without a PermissionRequest hook before it can say what it's about.
pub fn next_state(prev: Option<&AgentState>, u: ActivityUpdate, summary: Option<String>, question: Option<Value>, tool: Option<Value>, at: u64) -> AgentState {
    let was = |state: &str| prev.is_some_and(|p| p.state == state);
    let prev_message = prev.and_then(|p| p.message.clone());
    let keep_step = u.state == "working" && u.message.is_none() && u.task.is_none() && was("working");
    let generic = |m: &str| {
        let m = m.trim_end_matches('.').to_lowercase();
        m.ends_with("needs your permission") || m.ends_with("needs your attention")
    };
    let keep_question = u.state == "waiting" && was("waiting") && prev_message.is_some() && u.message.as_deref().is_none_or(generic);
    let prev_tool = prev.and_then(|p| p.pending_tool.clone());
    // Without the PermissionRequest hook, Claude's "needs your permission to use Bash" is about the
    // tool its last PreToolUse was about to use.
    let asks_permission = u.message.as_deref().is_some_and(|m| m.to_lowercase().contains("needs your permission"));
    let fallback = || asks_permission.then(|| prev_tool.clone().map(|p| json!({ "permission": p }))).flatten();
    AgentState {
        state: u.state,
        message: if keep_step || keep_question { prev_message } else { u.message },
        question: match u.state {
            "waiting" => question.or_else(|| prev.and_then(|p| p.question.clone())).or_else(fallback),
            _ => None,
        },
        task: u.task.or_else(|| prev.and_then(|p| p.task.clone())),
        summary: summary.filter(|s| !s.trim().is_empty()).or_else(|| prev.and_then(|p| p.summary.clone())),
        at,
        pending_tool: match (tool, u.state) {
            (Some(t), _) => Some(t),
            (None, "waiting") => prev_tool,
            _ => None,
        },
    }
}

/// `<task-notification>…`, `<command-name>…` and similar: generated by Claude Code, not typed by you.
fn is_injected(prompt: &str) -> bool {
    let p = prompt.trim_start();
    p.starts_with('<') && p[1..].chars().take_while(|c| *c != '>').all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Text the factory types into a session arrives as a bracketed paste, which Claude Code wraps in
/// `<pasted_content id="…">…</pasted_content>` (sometimes written `<\pasted_content …>` /
/// `<\/pasted_content>`). Drop the tags, keep what was pasted and anything around it. A block whose
/// closing tag is missing still unwraps. Line breaks inside are kept; see [`unwrap_pasted`].
pub(crate) fn strip_pasted(prompt: &str) -> String {
    const TAG: &str = "pasted_content";
    let mut out = String::with_capacity(prompt.len());
    let mut rest = prompt;
    while let Some(lt) = rest.find('<') {
        out.push_str(&rest[..lt]);
        let after = &rest[lt + 1..];
        let name = after.trim_start_matches(['\\', '/']);
        let is_tag = name.starts_with(TAG) && name[TAG.len()..].chars().next().is_none_or(|c| c == '>' || c.is_whitespace());
        match (is_tag, after.find('>')) {
            (true, Some(gt)) => {
                // Two tags back to back stay apart; a newline only pads the paste, so it goes.
                rest = after[gt + 1..].strip_prefix('\n').unwrap_or(&after[gt + 1..]);
                if !out.is_empty() && !out.ends_with(char::is_whitespace) && !rest.starts_with(char::is_whitespace) {
                    out.push(' ');
                }
            }
            (true, None) => rest = "",
            _ => {
                out.push('<');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out.trim().to_string()
}

/// [`strip_pasted`] on one line, for the session's step.
pub(crate) fn unwrap_pasted(prompt: &str) -> String {
    strip_pasted(prompt).split_whitespace().collect::<Vec<_>>().join(" ")
}

fn tool_name(payload: &Value) -> Option<&str> {
    payload.get("tool_name").and_then(Value::as_str)
}

/// "PB&J or Grilled Cheese?" (and "+1 more" when Claude asks several questions at once).
fn describe_question(payload: &Value) -> String {
    let questions = payload.pointer("/tool_input/questions").and_then(Value::as_array);
    let first = questions.and_then(|q| q.first()).and_then(|q| q.get("question")).and_then(Value::as_str);
    match (first, questions.map(Vec::len).unwrap_or(0)) {
        (Some(q), n) if n > 1 => truncate(&format!("{q} (+{} more)", n - 1), 160),
        (Some(q), _) => truncate(q, 160),
        (None, _) => "Has a question for you".into(),
    }
}

/// Claude Code's AskUserQuestion, as the dashboard's cards answer it: `{questions: [{question,
/// header, multiSelect, options: [{label, description}]}]}`, with lengths capped so it stays small
/// in the hub's state. Only on its PreToolUse; any later activity (its PostToolUse, a new prompt,
/// Stop) clears it at the hub.
fn pending_question(payload: &Value) -> Option<Value> {
    if payload.get("hook_event_name").and_then(Value::as_str) != Some("PreToolUse") || tool_name(payload) != Some("AskUserQuestion") {
        return None;
    }
    let text = |v: &Value, k: &str, max: usize| v.get(k).and_then(Value::as_str).map(|s| truncate(s, max)).filter(|s| !s.is_empty());
    let questions: Vec<Value> = payload
        .pointer("/tool_input/questions")?
        .as_array()?
        .iter()
        .take(4)
        .filter_map(|q| {
            let options: Vec<Value> = q
                .get("options")?
                .as_array()?
                .iter()
                .take(8)
                .filter_map(|o| {
                    let label = text(o, "label", 80)?;
                    Some(json!({ "label": label, "description": text(o, "description", 160) }))
                })
                .collect();
            if options.is_empty() {
                return None;
            }
            Some(json!({
                "question": text(q, "question", 300)?,
                "header": text(q, "header", 40),
                "multiSelect": q.get("multiSelect").and_then(Value::as_bool).unwrap_or(false),
                "options": options,
            }))
        })
        .collect();
    (!questions.is_empty()).then(|| json!({ "questions": questions }))
}

const MAX_DETAIL: usize = 1_200;

/// What a tool call would do, for a permission prompt's card: `{tool, summary, detail, warning?}`.
/// The detail is the Bash command, the file, the URL or the search; other tools get their input as JSON.
pub fn permission(payload: &Value) -> Option<Value> {
    let tool = tool_name(payload)?;
    if matches!(tool, "AskUserQuestion" | "ExitPlanMode") {
        return None;
    }
    let input = payload.get("tool_input").cloned().unwrap_or(Value::Null);
    let field = |k: &str| input.get(k).and_then(Value::as_str).map(str::to_string).filter(|s| !s.trim().is_empty());
    let detail = match tool {
        "Bash" => field("command"),
        "Edit" | "MultiEdit" | "Write" | "Read" | "NotebookEdit" => field("file_path").or_else(|| field("notebook_path")),
        "WebFetch" => field("url"),
        "WebSearch" => field("query"),
        "Grep" | "Glob" => field("pattern"),
        _ => None,
    }
    .or_else(|| input.as_object().filter(|o| !o.is_empty()).map(|_| input.to_string()));
    let warning = ["warning", "reason"].iter().find_map(|k| payload.get(*k).and_then(Value::as_str)).map(|w| truncate(w, 280)).filter(|w| !w.is_empty());
    Some(json!({
        "tool": tool,
        "summary": describe_tool(payload).unwrap_or_else(|| tool.to_string()),
        "detail": detail.map(|d| truncate(&d, MAX_DETAIL)),
        "warning": warning,
    }))
}

/// A short description of a tool call: "Editing hub.ts", "Running npm test".
fn describe_tool(payload: &Value) -> Option<String> {
    let name = payload.get("tool_name")?.as_str()?;
    let input = payload.get("tool_input").cloned().unwrap_or(Value::Null);
    let field = |k: &str| input.get(k).and_then(Value::as_str).map(str::to_string);
    let file = || field("file_path").or_else(|| field("notebook_path")).map(|p| p.rsplit('/').next().unwrap_or(&p).to_string());
    let text = match name {
        // Claude's descriptions already read as a step ("Run the tests").
        "Bash" => field("description").unwrap_or_else(|| format!("Running {}", field("command").unwrap_or_default())),
        "Edit" | "MultiEdit" | "NotebookEdit" => format!("Editing {}", file()?),
        "Write" => format!("Writing {}", file()?),
        "Read" => format!("Reading {}", file()?),
        "Grep" => format!("Searching for {}", field("pattern")?),
        "Glob" => format!("Finding {}", field("pattern")?),
        "WebSearch" => format!("Searching the web for {}", field("query")?),
        "WebFetch" => format!("Reading {}", field("url")?),
        "Task" | "Agent" => format!("Running a subagent: {}", field("description").unwrap_or_default()),
        "TodoWrite" => "Updating its todo list".to_string(),
        other => other.replace("mcp__", "").replace("__", " · "),
    };
    Some(truncate(text.trim_end_matches(": ").trim(), 120))
}

fn classify(agent: &str, payload: &Value) -> Option<Activity> {
    let text = |key: &str| payload.get(key).and_then(Value::as_str).map(|s| truncate(s, 280));
    match agent {
        "claude" => match payload.get("hook_event_name")?.as_str()? {
            "UserPromptSubmit" => Some(match payload.get("prompt").and_then(Value::as_str).map(unwrap_pasted) {
                // Claude also "submits" things you didn't type: background task results,
                // slash-command expansions, reminders. They start with a tag; they're not a task.
                Some(prompt) if !prompt.is_empty() && !is_injected(&prompt) => Activity::Started(truncate(&prompt, 160)),
                _ => Activity::Working(None),
            }),
            // Tools that stop and wait for you: say what they're asking, not that "permission" is needed.
            "PreToolUse" if tool_name(payload) == Some("AskUserQuestion") => Some(Activity::Waiting(Some(describe_question(payload)))),
            "PreToolUse" if tool_name(payload) == Some("ExitPlanMode") => Some(Activity::Waiting(Some("Wants you to review a plan".into()))),
            "PreToolUse" | "PostToolUse" => Some(Activity::Working(describe_tool(payload))),
            "PermissionRequest" => Some(Activity::Waiting(Some(format!("Claude needs your permission to use {}", tool_name(payload)?)))),
            // The idle reminder comes a minute after Claude finished; it's still just done.
            "Notification" if payload.get("notification_type").and_then(Value::as_str) == Some("idle_prompt") => None,
            "Notification" => Some(Activity::Waiting(text("message"))),
            "Stop" => Some(Activity::Done(None)),
            _ => None,
        },
        "codex" => match payload.get("type")?.as_str()? {
            "agent-turn-complete" => Some(Activity::Done(text("last-assistant-message"))),
            _ => None,
        },
        _ => None,
    }
}

const MAX_SUMMARY: usize = 4_000;

/// What the agent said at the end of its turn, for a task's pull request. Codex sends it with
/// the event; Claude Code's Stop hook has `last_assistant_message` in newer versions, else the
/// last assistant text in its transcript.
fn summary(agent: &str, payload: &Value) -> Option<String> {
    let text = match agent {
        "codex" => payload.get("last-assistant-message").and_then(Value::as_str).map(str::to_string),
        "claude" => payload
            .get("last_assistant_message")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| payload.get("transcript_path").and_then(Value::as_str).and_then(|p| last_assistant_text(Path::new(p)))),
        _ => None,
    }?;
    let text = text.trim();
    (!text.is_empty()).then(|| truncate(text, MAX_SUMMARY))
}

/// The last assistant message's text in a Claude Code transcript (JSON lines). Reads only the end.
fn last_assistant_text(path: &Path) -> Option<String> {
    use std::io::{Seek, SeekFrom};
    let mut f = std::fs::File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    f.seek(SeekFrom::Start(len.saturating_sub(512 * 1024))).ok()?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf);
    text.lines().rev().find_map(|line| {
        let v: Value = serde_json::from_str(line).ok()?;
        if v.get("type").and_then(Value::as_str) != Some("assistant") {
            return None;
        }
        let content = v.pointer("/message/content")?;
        let joined = match content {
            Value::String(s) => s.clone(),
            Value::Array(parts) => parts
                .iter()
                .filter(|p| p.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|p| p.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n"),
            _ => return None,
        };
        (!joined.trim().is_empty()).then_some(joined)
    })
}

/// Accepts hook events and MCP requests from sessions. A hook event is one JSON message,
/// then EOF. An MCP request is one line, `{"mcp":{…}}`, and gets one line back; so does the
/// `secrets` CLI's `{"secrets":{…}}`.
pub async fn listen(socket: PathBuf, sessions: Sessions) -> Result<()> {
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).with_context(|| format!("listening on {}", socket.display()))?;
    loop {
        let (mut stream, _) = listener.accept().await?;
        let sessions = sessions.clone();
        let peer = stream.peer_cred().ok().and_then(|c| c.pid()).and_then(|p| u32::try_from(p).ok());
        tokio::spawn(async move {
            let (read, mut write) = stream.split();
            let mut buf = Vec::new();
            if BufReader::new(read.take(1 << 20)).read_until(b'\n', &mut buf).await.is_err() {
                return;
            }
            let Ok(event) = serde_json::from_slice::<Value>(&buf) else { return };
            if let Some(usage) = event.get("usage") {
                crate::usage::observe_claude(usage);
                crate::costs::observe_claude(usage);
                return;
            }
            if let Some(request) = event.get("secrets") {
                let mut line = serde_json::to_vec(&crate::secrets::serve(&sessions, peer, request).await).unwrap_or_default();
                line.push(b'\n');
                let _ = write.write_all(&line).await;
                return;
            }
            if let Some(request) = event.get("mcp") {
                let mut line = serde_json::to_vec(&crate::mcp::forward(&sessions, request).await).unwrap_or_default();
                line.push(b'\n');
                let _ = write.write_all(&line).await;
                return;
            }
            let (Some(id), Some(agent)) =
                (event.get("session").and_then(Value::as_str).and_then(|s| Uuid::parse_str(s).ok()), event.get("agent").and_then(Value::as_str))
            else {
                return;
            };
            // Codex has just written its latest rate limits to its session file.
            if agent == "codex" {
                crate::usage::poke_codex();
                crate::costs::poke();
            }
            // The native view: learn (or follow) the transcript, and add what only hooks know.
            let payload = &event["payload"];
            if let Some(path) = payload.get("transcript_path").and_then(Value::as_str).filter(|p| !p.is_empty()) {
                sessions.set_transcript(id, agent, PathBuf::from(path));
            }
            let native = native_hooks(agent, payload, classify(agent, payload).as_ref());
            if !native.is_empty() {
                let sessions = sessions.clone();
                tokio::spawn(async move { sessions.push_hook_events(id, native).await });
            }
            if let Some(activity) = classify(agent, &event["payload"]) {
                let summary = matches!(activity, Activity::Done(_)).then(|| summary(agent, &event["payload"])).flatten();
                let payload = &event["payload"];
                let claude = |event: &str| agent == "claude" && payload.get("hook_event_name").and_then(Value::as_str) == Some(event);
                let question = if claude("PermissionRequest") {
                    permission(payload).map(|p| json!({ "permission": p }))
                } else {
                    (agent == "claude").then(|| pending_question(payload)).flatten()
                };
                let tool = claude("PreToolUse").then(|| permission(payload)).flatten();
                sessions.set_activity(id, activity, summary, question, tool);
            }
        });
    }
}

/// What a hook tells the native view that the transcript doesn't (docs/native-session-view.md).
#[derive(Debug, Clone, PartialEq)]
pub enum NativeHook {
    /// A turn is running; `call` is the tool a PreToolUse is about to run, in case it asks first.
    Running { call: Option<String> },
    /// A permission menu is showing; its options come from the pane.
    Permission { text: String },
    /// Whatever prompt was showing is answered or gone.
    Resolved,
}

pub fn native_hooks(agent: &str, payload: &Value, activity: Option<&Activity>) -> Vec<NativeHook> {
    let text = |key: &str| payload.get(key).and_then(Value::as_str).map(str::to_string);
    if agent == "claude" {
        return match payload.get("hook_event_name").and_then(Value::as_str).unwrap_or("") {
            "UserPromptSubmit" => vec![NativeHook::Resolved, NativeHook::Running { call: None }],
            "PreToolUse" => vec![NativeHook::Running { call: text("tool_use_id") }],
            "PostToolUse" | "PostToolUseFailure" | "Stop" => vec![NativeHook::Resolved],
            "Notification" => {
                let message = text("message").unwrap_or_default();
                let permission = payload.get("notification_type").and_then(Value::as_str) == Some("permission_prompt")
                    || (payload.get("notification_type").is_none() && message.contains("permission"));
                if permission { vec![NativeHook::Permission { text: message }] } else { vec![] }
            }
            _ => vec![],
        };
    }
    // Codex (and others): only the activity its hooks give.
    match activity {
        Some(Activity::Waiting(msg)) => vec![NativeHook::Permission { text: msg.clone().unwrap_or_else(|| "Codex is asking for approval".into()) }],
        Some(Activity::Working(_)) | Some(Activity::Started(_)) => vec![NativeHook::Resolved, NativeHook::Running { call: None }],
        Some(Activity::Done(_)) => vec![NativeHook::Resolved],
        None => vec![],
    }
}

/// The options of the menu at the bottom of a pane: its numbered lines ("❯ 1. Yes"), each picked
/// by its number, with the "No…" option picked by Escape (what `task.answerPrompt` presses to deny).
pub fn menu_options(lines: &[String]) -> Vec<crate::wire::PromptOption> {
    use crate::wire::{PromptChoice, PromptOption};
    let mut block: Vec<(String, String)> = vec![];
    for line in lines {
        let t = line.trim().trim_start_matches(['❯', '>', '›', '│', ' ']).trim();
        let parsed = t.split_once(". ").filter(|(n, _)| !n.is_empty() && n.len() <= 2 && n.chars().all(|c| c.is_ascii_digit()));
        if let Some((n, label)) = parsed {
            // A "1." starts a new menu: only the last one on screen counts.
            if n == "1" {
                block.clear();
            }
            block.push((n.to_string(), label.trim().to_string()));
        }
    }
    let mut out: Vec<PromptOption> = vec![];
    let mut has_no = false;
    for (n, label) in block {
        let plain = label.trim_end_matches("(esc)").trim().to_string();
        if plain == "No" || plain.starts_with("No,") || plain.starts_with("No ") {
            has_no = true;
            out.push(PromptOption { key: "Escape".into(), label: "No".into(), choice: Some(PromptChoice::No) });
        } else {
            let choice = (n == "1" && plain.starts_with("Yes")).then_some(PromptChoice::Yes);
            out.push(PromptOption { key: n, label: plain, choice });
        }
    }
    if !has_no {
        out.push(PromptOption { key: "Escape".into(), label: "No".into(), choice: Some(PromptChoice::No) });
    }
    out
}

/// `maple-runner hook <agent> [payload]`, run by an agent inside a session.
/// Never prints and always exits 0: a hook must not disturb the agent.
pub fn run_hook() {
    if let Err(e) = forward() {
        // stderr only reaches the agent's debug log.
        eprintln!("maple-runner hook: {e:#}");
    }
    std::process::exit(0);
}

fn forward() -> Result<()> {
    let (Ok(socket), Ok(session)) = (std::env::var(SOCKET_ENV), std::env::var(SESSION_ENV)) else {
        return Ok(()); // not inside a Maple Factory session
    };
    let mut args = std::env::args().skip(2);
    let agent = args.next().unwrap_or_default();
    // Codex passes the event as the last argument; Claude Code on stdin.
    let raw = match args.last() {
        Some(arg) => arg,
        None => {
            let mut s = String::new();
            std::io::stdin().take(1 << 20).read_to_string(&mut s)?;
            s
        }
    };
    let payload: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
    let mut stream = std::os::unix::net::UnixStream::connect(&socket).context("connecting to the runner")?;
    stream.write_all(&serde_json::to_vec(&json!({ "session": session, "agent": agent, "payload": payload }))?)?;
    Ok(())
}

fn truncate(s: &str, max: usize) -> String {
    let s = s.trim();
    match s.char_indices().nth(max) {
        Some((i, _)) => format!("{}…", &s[..i]),
        None => s.to_string(),
    }
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sessions_connectors_file_is_private_and_removable() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("maple-hooks-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let hooks = Hooks::prepare(&dir, "test").unwrap();
        let id = Uuid::new_v4();
        assert_eq!(hooks.write_session_mcp_config(id, &[]).unwrap(), None, "no connectors, no file");
        let jira = McpConnector {
            name: "jira".into(),
            transport: McpTransport::Stdio,
            command: Some("npx".into()),
            args: vec!["-y".into(), "mcp-atlassian".into()],
            url: None,
            env: [("JIRA_API_TOKEN".to_string(), "secret".to_string())].into(),
            headers: Default::default(),
            enabled: true,
            auto_allow: false,
        };
        let docs = McpConnector {
            name: "docs".into(),
            transport: McpTransport::Http,
            command: None,
            args: vec![],
            url: Some("https://mcp.example.com/mcp".into()),
            env: Default::default(),
            headers: [("Authorization".to_string(), "Bearer abc".to_string())].into(),
            enabled: true,
            auto_allow: true,
        };
        let path = hooks.write_session_mcp_config(id, &[jira, docs]).unwrap().unwrap();
        assert_eq!(path, dir.join(format!("mcp-session-{id}.json")));
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        let written: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(
            written,
            json!({ "mcpServers": {
                "jira": { "type": "stdio", "command": "npx", "args": ["-y", "mcp-atlassian"], "env": { "JIRA_API_TOKEN": "secret" } },
                "docs": { "type": "http", "url": "https://mcp.example.com/mcp", "headers": { "Authorization": "Bearer abc" } },
            } })
        );
        hooks.remove_session_mcp_config(id);
        assert!(!path.exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn startup_sweeps_connectors_files_of_sessions_that_are_gone() {
        let dir = std::env::temp_dir().join(format!("maple-hooks-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let hooks = Hooks::prepare(&dir, "test").unwrap();
        let jira = McpConnector {
            name: "jira".into(),
            transport: McpTransport::Stdio,
            command: Some("npx".into()),
            args: vec![],
            url: None,
            env: [("JIRA_API_TOKEN".to_string(), "secret".to_string())].into(),
            headers: Default::default(),
            enabled: true,
            auto_allow: false,
        };
        let (live, gone) = (Uuid::new_v4(), Uuid::new_v4());
        let kept = hooks.write_session_mcp_config(live, std::slice::from_ref(&jira)).unwrap().unwrap();
        let stale = hooks.write_session_mcp_config(gone, std::slice::from_ref(&jira)).unwrap().unwrap();
        assert_eq!(hooks.sweep_session_mcp_configs(&[live].into()), 1);
        assert!(kept.exists() && !stale.exists());
        assert!(hooks.mcp_config.exists(), "the runner's own maple config stays");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn state(agent: &str, payload: Value) -> Option<(&'static str, Option<String>)> {
        classify(agent, &payload).map(|a| {
            let u = a.update();
            (u.state, u.message.or(u.task))
        })
    }

    #[test]
    fn describes_what_claude_is_doing() {
        assert_eq!(
            state("claude", json!({ "hook_event_name": "UserPromptSubmit", "prompt": "fix the flaky test" })),
            Some(("working", Some("fix the flaky test".into())))
        );
        assert_eq!(
            state("claude", json!({ "hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": { "file_path": "/a/b/hub.ts" } })),
            Some(("working", Some("Editing hub.ts".into())))
        );
        assert_eq!(
            state(
                "claude",
                json!({ "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": { "command": "npm test", "description": "Run the tests" } })
            ),
            Some(("working", Some("Run the tests".into())))
        );
    }

    #[test]
    fn injected_prompts_are_not_tasks() {
        let injected = json!({ "hook_event_name": "UserPromptSubmit", "prompt": "<task-notification> <task-id>b1</task-id> …" });
        assert_eq!(state("claude", injected), Some(("working", None)));
        let real = json!({ "hook_event_name": "UserPromptSubmit", "prompt": "<- fix this arrow" });
        assert_eq!(state("claude", real), Some(("working", Some("<- fix this arrow".into()))));
    }

    #[test]
    fn pasted_answers_show_without_their_wrapper() {
        let prompt = |p: &str| state("claude", json!({ "hook_event_name": "UserPromptSubmit", "prompt": p }));
        let working = |s: &str| Some(("working", Some(s.to_string())));
        assert_eq!(prompt("<\\pasted_content id=\"a849\">\nUse option B\n<\\/pasted_content>"), working("Use option B"));
        assert_eq!(prompt("<pasted_content id=\"a849\">Use option B</pasted_content>"), working("Use option B"));
        assert_eq!(prompt("Answer: <pasted_content id=\"x\">B</pasted_content> thanks"), working("Answer: B thanks"));
        assert_eq!(prompt("<pasted_content id=\"a\">one</pasted_content>\n<pasted_content id=\"b\">two</pasted_content>"), working("one two"));
        // A paste past the truncation limit: the closing tag is far beyond it, and still goes.
        let long = "word ".repeat(200);
        let step = prompt(&format!("<\\pasted_content id=\"z\">\n{long}\n<\\/pasted_content>")).unwrap().1.unwrap();
        assert!(!step.contains("pasted_content") && step.starts_with("word word") && step.ends_with('…'), "{step}");
        // Unfinished block, empty paste, and other injected tags.
        assert_eq!(prompt("<pasted_content id=\"q\">half an answer"), working("half an answer"));
        assert_eq!(prompt("<pasted_content id=\"q\">\n</pasted_content>"), Some(("working", None)));
        assert_eq!(prompt("<pasted_content id=\"q\"><task-notification> b1</pasted_content>"), Some(("working", None)));
        assert_eq!(unwrap_pasted("a <pasted_contents> b"), "a <pasted_contents> b");
    }

    #[test]
    fn questions_are_waiting_with_the_question() {
        let ask = json!({ "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
            "tool_input": { "questions": [{ "question": "PB&J or Grilled Cheese?", "header": "Lunch" }] } });
        assert_eq!(state("claude", ask), Some(("waiting", Some("PB&J or Grilled Cheese?".into()))));
        let plan = json!({ "hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode", "tool_input": {} });
        assert_eq!(state("claude", plan), Some(("waiting", Some("Wants you to review a plan".into()))));
    }

    #[test]
    fn questions_are_kept_for_the_cards() {
        let long = "x".repeat(1000);
        let ask = json!({ "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": { "questions": [
            { "question": "Lunch?", "header": "Lunch", "multiSelect": false, "options": [
                { "label": "PB&J", "description": "Classic" }, { "label": "Grilled cheese" }, { "nolabel": true } ] },
            { "question": long, "multiSelect": true, "options": [{ "label": "A" }, { "label": "B" }] },
            { "question": "No options", "options": [] },
        ] } });
        let q = pending_question(&ask).unwrap();
        let qs = q["questions"].as_array().unwrap();
        assert_eq!(qs.len(), 2);
        assert_eq!(qs[0]["header"], "Lunch");
        assert_eq!(qs[0]["options"], json!([{ "label": "PB&J", "description": "Classic" }, { "label": "Grilled cheese", "description": null }]));
        assert_eq!(qs[1]["multiSelect"], true);
        assert!(qs[1]["question"].as_str().unwrap().chars().count() <= 301);
        // Only while it's asking.
        assert_eq!(pending_question(&json!({ "hook_event_name": "PostToolUse", "tool_name": "AskUserQuestion", "tool_input": ask["tool_input"] })), None);
        assert_eq!(pending_question(&json!({ "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {} })), None);
    }

    #[test]
    fn keeps_the_latest_state_like_the_hub() {
        let q = json!({ "questions": [{ "question": "Lunch?" }] });
        let s1 = next_state(None, Activity::Started("fix it".into()).update(), None, None, None, 1);
        assert_eq!((s1.state, s1.task.as_deref(), s1.message.as_deref()), ("working", Some("fix it"), None));
        let s2 = next_state(Some(&s1), Activity::Working(Some("Editing a.rs".into())).update(), None, None, None, 2);
        // A bare "working" keeps the step; the task stays.
        let s3 = next_state(Some(&s2), Activity::Working(None).update(), None, None, None, 3);
        assert_eq!((s3.message.as_deref(), s3.task.as_deref(), s3.at), (Some("Editing a.rs"), Some("fix it"), 3));
        // A question, then Claude's generic notification: the question and its text stay.
        let s4 = next_state(Some(&s3), Activity::Waiting(Some("Lunch?".into())).update(), None, Some(q.clone()), None, 4);
        let s5 = next_state(Some(&s4), Activity::Waiting(Some("Claude needs your permission".into())).update(), None, None, None, 5);
        assert_eq!((s5.state, s5.message.as_deref(), s5.question.as_ref()), ("waiting", Some("Lunch?"), Some(&q)));
        // A specific message replaces it.
        let s6 = next_state(Some(&s5), Activity::Waiting(Some("Claude needs your permission to use Bash".into())).update(), None, None, None, 6);
        assert_eq!(s6.message.as_deref(), Some("Claude needs your permission to use Bash"));
        // Anything but waiting drops the question; done keeps its summary.
        let s7 = next_state(Some(&s6), Activity::Done(None).update(), Some("All green.".into()), None, None, 7);
        assert_eq!((s7.state, s7.question.as_ref(), s7.summary.as_deref(), s7.message.as_deref()), ("done", None, Some("All green."), None));
        let s8 = next_state(Some(&s7), Activity::Started("next".into()).update(), Some("  ".into()), None, None, 8);
        assert_eq!((s8.task.as_deref(), s8.summary.as_deref()), (Some("next"), Some("All green.")));
    }

    #[test]
    fn notification_fixture_becomes_a_prompt_and_its_resolution() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../protocol/fixtures/session-events");
        let payload: Value = serde_json::from_str(&std::fs::read_to_string(format!("{dir}/claude.notification.json")).unwrap()).unwrap();
        let want: Value = serde_json::from_str(&std::fs::read_to_string(format!("{dir}/claude.notification.expected.json")).unwrap()).unwrap();
        let hooks = native_hooks("claude", &payload, None);
        let [NativeHook::Permission { text }] = hooks.as_slice() else { panic!("{hooks:?}") };
        // The pane as Claude Code draws its Bash permission menu.
        let pane: Vec<String> = [
            " Bash command",
            "   npm test",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. Yes, and don't ask again for this command",
            "   3. No, and tell Claude what to do differently (esc)",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let session = Uuid::parse_str(payload["session_id"].as_str().unwrap()).unwrap();
        let mut stream = crate::events::EventStream::new(session, "claude", None, None);
        // The transcript's 9 events came first.
        let transcript = std::fs::read_to_string(format!("{dir}/claude.jsonl")).unwrap();
        let mut st = crate::transcript::ClaudeState::new(session);
        stream.push(transcript.lines().flat_map(|l| crate::transcript::parse_claude(l, &mut st)).collect());
        let prompt = crate::wire::SessionEvent::Prompt {
            id: String::new(),
            session,
            seq: 0,
            at: 1792000000000,
            agent: "claude".into(),
            kind: crate::wire::PromptKind::Permission,
            text: text.clone(),
            options: menu_options(&pane),
            call_id: None,
        };
        let mut got = stream.open_prompt(prompt, None);
        got.extend(stream.resolve(Some("1".into())));
        let mut got = serde_json::to_value(&got).unwrap();
        got[1]["at"] = json!(1792000004000u64);
        assert_eq!(got, want);
        assert_eq!(native_hooks("claude", &json!({"hook_event_name": "Notification", "notification_type": "idle_prompt"}), None), vec![]);
    }

    #[test]
    fn permission_prompts_carry_the_tool_and_detail() {
        let request = json!({ "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": { "command": "rm -rf build && npm run build", "description": "Rebuild" }, "permission_suggestions": [] });
        assert_eq!(state("claude", request.clone()), Some(("waiting", Some("Claude needs your permission to use Bash".into()))));
        let p = permission(&request).unwrap();
        assert_eq!(p, json!({ "tool": "Bash", "summary": "Rebuild", "detail": "rm -rf build && npm run build", "warning": null }));
        let edit = permission(&json!({ "tool_name": "Write", "tool_input": { "file_path": "/a/b/hub.ts", "content": "x" } })).unwrap();
        assert_eq!((edit["summary"].as_str(), edit["detail"].as_str()), (Some("Writing hub.ts"), Some("/a/b/hub.ts")));
        let mcp = permission(&json!({ "tool_name": "mcp__github__create_issue", "tool_input": { "title": "Hi" } })).unwrap();
        assert_eq!(mcp["detail"], r#"{"title":"Hi"}"#);
        // Long commands are capped.
        let long = permission(&json!({ "tool_name": "Bash", "tool_input": { "command": "x".repeat(5000) } })).unwrap();
        assert!(long["detail"].as_str().unwrap().chars().count() <= MAX_DETAIL + 1);
        // Questions and plans have their own cards.
        assert_eq!(permission(&json!({ "tool_name": "AskUserQuestion", "tool_input": {} })), None);
    }

    #[test]
    fn permission_payload_clears_once_working_again() {
        let bash = json!({ "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": { "command": "npm test" } });
        let p = permission(&bash).unwrap();
        let s1 = next_state(None, Activity::Working(Some("Run the tests".into())).update(), None, None, None, 1);
        let s2 = next_state(Some(&s1), classify("claude", &bash).unwrap().update(), None, Some(json!({ "permission": p.clone() })), None, 2);
        assert_eq!((s2.state, s2.question.as_ref()), ("waiting", Some(&json!({ "permission": p.clone() }))));
        // Claude's own notification after it keeps the payload.
        let s3 = next_state(Some(&s2), Activity::Waiting(Some("Claude needs your permission to use Bash".into())).update(), None, None, None, 3);
        assert_eq!(s3.question, Some(json!({ "permission": p.clone() })));
        // Approved: its PostToolUse is working, and the payload goes.
        let s4 = next_state(Some(&s3), Activity::Working(Some("Run the tests".into())).update(), None, None, None, 4);
        assert_eq!((s4.state, s4.question.as_ref(), s4.pending_tool.as_ref()), ("working", None, None));
        let s5 = next_state(Some(&s3), Activity::Done(None).update(), None, None, None, 5);
        assert_eq!(s5.question, None);
    }

    #[test]
    fn permission_falls_back_to_the_last_tool() {
        let pre = json!({ "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": { "command": "git push --force" } });
        let tool = permission(&pre);
        let s1 = next_state(None, classify("claude", &pre).unwrap().update(), None, None, tool.clone(), 1);
        assert_eq!((s1.state, s1.question.as_ref()), ("working", None));
        let s2 = next_state(Some(&s1), Activity::Waiting(Some("Claude needs your permission to use Bash".into())).update(), None, None, None, 2);
        assert_eq!(s2.question, Some(json!({ "permission": tool.clone().unwrap() })));
        assert_eq!(s2.question.as_ref().unwrap()["permission"]["detail"], "git push --force");
        // Other waits aren't about the tool.
        let s3 = next_state(Some(&s1), Activity::Waiting(Some("Claude is waiting for your input".into())).update(), None, None, None, 3);
        assert_eq!(s3.question, None);
        // Once its PostToolUse is in, the tool is forgotten.
        let s4 = next_state(Some(&s1), Activity::Working(None).update(), None, None, None, 4);
        let s5 = next_state(Some(&s4), Activity::Waiting(Some("Claude needs your permission to use Bash".into())).update(), None, None, None, 5);
        assert_eq!(s5.question, None);
    }

    #[test]
    fn claude_events() {
        assert_eq!(
            state("claude", json!({ "hook_event_name": "Notification", "message": "Claude needs your permission to use Bash" })),
            Some(("waiting", Some("Claude needs your permission to use Bash".into())))
        );
        assert_eq!(state("claude", json!({ "hook_event_name": "Notification", "notification_type": "idle_prompt" })), None);
        assert_eq!(state("claude", json!({ "hook_event_name": "Stop" })), Some(("done", None)));
    }

    #[test]
    fn summaries_for_pull_requests() {
        assert_eq!(summary("codex", &json!({ "last-assistant-message": " Fixed it. " })), Some("Fixed it.".into()));
        assert_eq!(summary("claude", &json!({ "last_assistant_message": "All green." })), Some("All green.".into()));
        let path = std::env::temp_dir().join(format!("maple-transcript-{}.jsonl", Uuid::new_v4()));
        std::fs::write(
            &path,
            [
                json!({ "type": "assistant", "message": { "content": [{ "type": "text", "text": "Looking." }] } }).to_string(),
                json!({ "type": "assistant", "message": { "content": [{ "type": "tool_use", "name": "Edit" }, { "type": "text", "text": "Done: the test waits for the server." }] } }).to_string(),
                json!({ "type": "user", "message": { "content": "thanks" } }).to_string(),
            ]
            .join("\n"),
        )
        .unwrap();
        assert_eq!(summary("claude", &json!({ "transcript_path": path })), Some("Done: the test waits for the server.".into()));
        std::fs::remove_file(&path).unwrap();
        assert_eq!(summary("claude", &json!({})), None);
        assert_eq!(summary("shell", &json!({ "last_assistant_message": "x" })), None);
    }

    #[test]
    fn codex_turn_complete() {
        assert_eq!(
            state("codex", json!({ "type": "agent-turn-complete", "last-assistant-message": "All tests pass." })),
            Some(("done", Some("All tests pass.".into())))
        );
    }

    fn hooks(dir: &Path) -> Hooks {
        let mut h = Hooks::prepare(dir, "maple-test").unwrap();
        h.exe = "/Users/me/.local/share/maple/bin/maple-runner".into();
        h
    }

    #[test]
    fn claude_gets_the_mcp_config_file() {
        let dir = std::env::temp_dir().join(format!("maple-hooks-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let h = hooks(&dir);
        let path = dir.join("mcp-maple-test.json");
        assert_eq!(h.mcp_config, path);
        let written: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        let exe = std::env::current_exe().unwrap().to_string_lossy().into_owned();
        assert_eq!(written, json!({ "mcpServers": { "maple": { "command": exe, "args": ["mcp"] } } }));
        let args = h.agent_args("claude");
        assert_eq!(
            args,
            ["--settings".to_string(), dir.join("claude-settings-maple-test.json").to_string_lossy().into_owned(), format!("--mcp-config={}", path.display()),]
        );
        // The user's own MCP servers stay on.
        assert!(!args.iter().any(|a| a.contains("strict-mcp-config")));
        // The prompt after it stays a prompt.
        let claude = crate::agents::builtins().into_iter().find(|a| a.id == "claude").unwrap();
        let argv = crate::agents::argv("/bin/zsh", &claude, false, args, None, None, &[], Some("fix it"));
        assert_eq!(argv.last().unwrap(), "fix it");
        assert!(argv[argv.len() - 2].starts_with("--mcp-config="));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn claude_gets_the_status_line() {
        let dir = std::env::temp_dir().join(format!("maple-hooks-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        hooks(&dir);
        let written: Value = serde_json::from_slice(&std::fs::read(dir.join("claude-settings-maple-test.json")).unwrap()).unwrap();
        let exe = std::env::current_exe().unwrap().to_string_lossy().into_owned();
        assert_eq!(written["statusLine"], json!({ "type": "command", "command": format!("{} statusline", shell_quote(&exe)), "padding": 0 }));
        assert!(written["hooks"]["Stop"].is_array());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn codex_gets_mcp_overrides() {
        let dir = std::env::temp_dir().join(format!("maple-hooks-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let args = hooks(&dir).agent_args("codex");
        assert_eq!(
            args,
            [
                "-c",
                r#"notify=["/Users/me/.local/share/maple/bin/maple-runner","hook","codex"]"#,
                "-c",
                r#"mcp_servers.maple.command="/Users/me/.local/share/maple/bin/maple-runner""#,
                "-c",
                r#"mcp_servers.maple.args=["mcp"]"#,
                "-c",
                r#"mcp_servers.maple.env_vars=["MAPLE_SESSION_ID","MAPLE_HOOK_SOCKET"]"#,
                "-c",
                "mcp_servers.maple.tool_timeout_sec=660",
            ]
        );
        // Each -c value is valid TOML.
        for kv in args.iter().skip(1).step_by(2) {
            let (k, v) = kv.split_once('=').unwrap();
            toml::from_str::<toml::Table>(&format!("x = {v}")).unwrap_or_else(|e| panic!("{k}: {e}"));
        }
        assert!(hooks(&dir).agent_args("shell").is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn quotes_paths_for_the_shell() {
        assert_eq!(shell_quote("/a b/it's"), r"'/a b/it'\''s'");
    }
}
