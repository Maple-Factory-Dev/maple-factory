//! The `agents` MCP server: lets an agent see and drive other sessions.
//!
//! Every Claude Code and Codex session the runner starts gets it (see `hooks::Hooks::agent_args`),
//! as `maple-runner mcp`: a small MCP server over stdio (JSON-RPC 2.0, one message per line). It runs
//! inside the session, so it inherits `MAPLE_SESSION_ID` and `MAPLE_HOOK_SOCKET`. Each tool call goes
//! over that socket to the runner as one request line, `{"mcp":{"session","tool","args"}}`, and the
//! runner forwards it to the hub (`mcp.request`), which checks the guardrails and runs it. The
//! answer comes back the same way as one line, `{"result":{"summary","data"}}` or `{"error":"…"}`.
//!
//! `wait_for` is a loop here, polling the session every couple of seconds, so the hub never holds
//! a long request open.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::oneshot;
use uuid::Uuid;

use crate::hooks::{SESSION_ENV, SOCKET_ENV};
use crate::protocol::Outbound;
use crate::sessions::Sessions;

pub const PROTOCOL_VERSION: &str = "2025-06-18";
/// Versions this server speaks; a client asking for one of these gets it back.
const SUPPORTED_VERSIONS: &[&str] = &["2025-06-18", "2025-03-26", "2024-11-05"];
const SERVER_NAME: &str = "agents";

const MAX_TEXT: usize = 16_000;
/// A Scratchpad note's markdown (the control plane's limit; the hook socket takes lines up to 1 MiB).
const MAX_NOTE: usize = 200_000;
const MAX_LINES: u64 = 2_000;
const MAX_WAIT_SECS: u64 = 600;
const POLL: Duration = Duration::from_secs(2);
/// How long the runner waits for the hub to answer one request.
const HUB_TIMEOUT: Duration = Duration::from_secs(60);

const NOT_IN_SESSION: &str = "The agents tools only work inside a session started by agents (the orchestrator). \
     This process has no MAPLE_SESSION_ID / MAPLE_HOOK_SOCKET in its environment.";

// ---------------------------------------------------------------------------
// The stdio server (`maple-runner mcp`)

/// Where tool calls go: the runner's socket, or a fake in tests.
pub trait Backend: Send + Sync {
    /// Runs a tool on the control plane. `Ok` holds `{summary, data}`.
    fn call(&self, tool: &str, args: &Value) -> Result<Value, String>;
    fn sleep(&self, d: Duration) {
        std::thread::sleep(d);
    }
}

/// Talks to the runner over its hook socket, as the session in `MAPLE_SESSION_ID`.
struct SocketBackend {
    socket: PathBuf,
    session: String,
}

impl Backend for SocketBackend {
    fn call(&self, tool: &str, args: &Value) -> Result<Value, String> {
        let unreachable = |e: std::io::Error| format!("Couldn't reach the agents runner on this machine: {e}");
        let mut stream = std::os::unix::net::UnixStream::connect(&self.socket).map_err(unreachable)?;
        stream.set_read_timeout(Some(HUB_TIMEOUT + Duration::from_secs(15))).map_err(unreachable)?;
        let mut line = serde_json::to_vec(&json!({ "mcp": { "session": self.session, "tool": tool, "args": args } })).map_err(|e| e.to_string())?;
        line.push(b'\n');
        stream.write_all(&line).map_err(unreachable)?;
        let mut reply = String::new();
        BufReader::new(stream).read_line(&mut reply).map_err(unreachable)?;
        let reply: Value = serde_json::from_str(&reply).map_err(|_| "The runner sent back something unexpected.".to_string())?;
        match (reply.get("result"), reply.get("error").and_then(Value::as_str)) {
            (_, Some(e)) => Err(e.to_string()),
            (Some(result), None) => Ok(result.clone()),
            (None, None) => Err("The runner sent back an empty answer.".into()),
        }
    }
}

/// Outside a session: every tool says so.
struct NoSession;

impl Backend for NoSession {
    fn call(&self, _: &str, _: &Value) -> Result<Value, String> {
        Err(NOT_IN_SESSION.into())
    }
}

/// `maple-runner mcp`. Reads JSON-RPC from stdin until it closes. Tool calls run on their own
/// threads, so a long `wait_for` doesn't hold up pings or other calls.
pub fn serve() -> ! {
    let backend: Arc<dyn Backend> = match (std::env::var(SOCKET_ENV), std::env::var(SESSION_ENV)) {
        (Ok(socket), Ok(session)) if !socket.is_empty() && !session.is_empty() => Arc::new(SocketBackend { socket: socket.into(), session }),
        _ => Arc::new(NoSession),
    };
    let out = Arc::new(Mutex::new(std::io::stdout()));
    let send = {
        let out = out.clone();
        move |msg: Value| {
            let mut out = out.lock().unwrap();
            let _ = writeln!(out, "{msg}");
            let _ = out.flush();
        }
    };
    let mut calls = Vec::new();
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        match handle(&line) {
            Handled::Nothing => {}
            Handled::Reply(msg) => send(msg),
            Handled::Call { id, name, args } => {
                let backend = backend.clone();
                let send = send.clone();
                calls.retain(|c: &std::thread::JoinHandle<()>| !c.is_finished());
                calls.push(std::thread::spawn(move || send(response(id, call_tool(backend.as_ref(), &name, &args)))));
            }
        }
    }
    // Input closed: answer what's still running, then go.
    for call in calls {
        let _ = call.join();
    }
    std::process::exit(0);
}

/// What one incoming line needs.
#[derive(Debug, PartialEq)]
pub enum Handled {
    /// A notification, or a response to us: no answer.
    Nothing,
    Reply(Value),
    /// A `tools/call` to run, then answer with `id`.
    Call {
        id: Value,
        name: String,
        args: Value,
    },
}

fn response(id: Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

fn rpc_error(id: Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

pub fn handle(line: &str) -> Handled {
    let line = line.trim();
    if line.is_empty() {
        return Handled::Nothing;
    }
    let Ok(msg) = serde_json::from_str::<Value>(line) else {
        return Handled::Reply(rpc_error(Value::Null, -32700, "Parse error"));
    };
    let Some(method) = msg.get("method").and_then(Value::as_str) else {
        // A response to a request we never send, or junk.
        return match msg.get("id") {
            Some(id) if msg.get("result").is_none() && msg.get("error").is_none() => Handled::Reply(rpc_error(id.clone(), -32600, "Invalid request")),
            _ => Handled::Nothing,
        };
    };
    // Notifications (no id) never get an answer, whatever they are.
    let Some(id) = msg.get("id").cloned() else { return Handled::Nothing };
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    match method {
        "initialize" => {
            let asked = params.get("protocolVersion").and_then(Value::as_str).unwrap_or(PROTOCOL_VERSION);
            let version = if SUPPORTED_VERSIONS.contains(&asked) { asked } else { PROTOCOL_VERSION };
            Handled::Reply(response(
                id,
                json!({
                    "protocolVersion": version,
                    "capabilities": { "tools": { "listChanged": false } },
                    "serverInfo": { "name": SERVER_NAME, "title": "agents orchestrator", "version": crate::update::VERSION },
                    "instructions": "Tools for seeing and driving the other agent sessions on your machines \
                        (the agents orchestrator), and for its tasks, projects, Scratchpad notes and factory cards. \
                        Machines are named by id; sessions and cards by uuid. \
                        What you may do is set by the user in Settings → Agents.",
                }),
            ))
        }
        "ping" => Handled::Reply(response(id, json!({}))),
        "tools/list" => Handled::Reply(response(id, json!({ "tools": tools() }))),
        "tools/call" => {
            let Some(name) = params.get("name").and_then(Value::as_str) else {
                return Handled::Reply(rpc_error(id, -32602, "tools/call needs a tool name"));
            };
            if !TOOL_NAMES.contains(&name) {
                return Handled::Reply(rpc_error(id, -32602, &format!("Unknown tool: {name}")));
            }
            let args = params.get("arguments").cloned().unwrap_or(Value::Null);
            Handled::Call { id, name: name.to_string(), args }
        }
        // Optional MCP lists we don't have: answer empty rather than "method not found".
        "resources/list" => Handled::Reply(response(id, json!({ "resources": [] }))),
        "prompts/list" => Handled::Reply(response(id, json!({ "prompts": [] }))),
        _ => Handled::Reply(rpc_error(id, -32601, &format!("Method not found: {method}"))),
    }
}

const TOOL_NAMES: &[&str] = &[
    "list_machines",
    "list_sessions",
    "get_session",
    "read_output",
    "start_session",
    "send_input",
    "stop_session",
    "wait_for",
    "create_task",
    "list_tasks",
    "list_notes",
    "read_note",
    "write_note",
    "append_note",
    "edit_note",
    "list_projects",
    "get_project",
    "save_project",
    "prove",
    "review",
    "list_cards",
    "get_card",
    "plan_card",
    "approve_card",
    "tweak_card",
    "split_card",
    "reject_card",
    "review_again",
    "recheck_ci",
    "propose_cards",
    "scout_now",
];
/// Where a factory card can be (`CARD_STATUSES` in control/src/protocol.ts).
const CARD_STATUSES: &[&str] = &["drafting", "review", "approved", "waiting", "rejected", "split", "closed"];
/// A card's one-liner (a note's title), a tweak's comment or a split's how, and a rejection's reason, in characters (control/src/cards.ts).
const MAX_ONE_LINER: usize = 200;
const MAX_CARD_COMMENT: usize = 4_000;
const MAX_REJECT_REASON: usize = 500;
/// What a project's tasks can be proven with (`PROOF_KINDS` in control/src/protocol.ts).
const PROOF_KINDS: &[&str] = &["test", "command", "terminal", "screen"];
/// A piece of evidence's text, in UTF-8 bytes, and its summary, in characters (control/src/proof.ts).
const MAX_PROOF_TEXT: usize = 64 * 1024;
const MAX_PROOF_SUMMARY: usize = 300;
/// A review's comments, how many and how long each, its summary and a risk raise's reason, in characters (control/src/review.ts).
const MAX_REVIEW_COMMENTS: usize = 20;
const MAX_REVIEW_COMMENT: usize = 1_000;
const MAX_REVIEW_SUMMARY: usize = 2_000;
const MAX_RAISE_RISK: usize = 500;
const TASK_STATUSES: &[&str] = &["queued", "running", "needs_input", "done", "pr_open", "merged", "closed", "failed", "cancelled"];

fn tools() -> Value {
    let machine = json!({ "type": "string", "description": "Machine id, from list_machines (its display name works too)." });
    let id = json!({ "type": "string", "description": "Session id (a uuid), from list_sessions." });
    let read = json!({ "readOnlyHint": true, "openWorldHint": false });
    let version = json!({ "type": "integer", "minimum": 1, "description": "The note's version from read_note (or your last change)." });
    let mut tools = json!([
        {
            "name": "list_machines",
            "title": "List machines",
            "description": "Lists your machines: id (what the other tools take), the name you gave it, whether it's online, runner version, how many sessions it has, and its Tailscale name.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": read,
        },
        {
            "name": "list_sessions",
            "title": "List sessions",
            "description": "Lists agent sessions across your machines (or one machine): agent, title, folder, status, \
                what it's doing (activity: working, waiting for its user, or done), git branch, and which session started it. \
                Your own session is marked you: true.",
            "inputSchema": { "type": "object", "properties": {
                "machine": { "type": "string", "description": "Only this machine." },
                "includeEnded": { "type": "boolean", "description": "Also list sessions that have ended. Default false." },
            } },
            "annotations": read,
        },
        {
            "name": "get_session",
            "title": "Get a session",
            "description": "One session's details, as in list_sessions.",
            "inputSchema": { "type": "object", "properties": { "machine": machine, "id": id }, "required": ["machine", "id"] },
            "annotations": read,
        },
        {
            "name": "read_output",
            "title": "Read a session's screen",
            "description": "The session's terminal as plain text: the last `lines` lines of history plus the screen.",
            "inputSchema": { "type": "object", "properties": {
                "machine": machine, "id": id,
                "lines": { "type": "integer", "minimum": 1, "maximum": MAX_LINES, "description": "Default 200." },
            }, "required": ["machine", "id"] },
            "annotations": read,
        },
        {
            "name": "start_session",
            "title": "Start a session",
            "description": "Starts an agent (e.g. claude, codex, shell) in a folder on a machine, optionally with a first prompt \
                and in a new git worktree. Returns the new session's id. The new session is recorded as started by you. \
                Needs \"Read and start sessions\" in Settings → Agents.",
            "inputSchema": { "type": "object", "properties": {
                "machine": machine,
                "cwd": { "type": "string", "description": "Folder to start in, e.g. ~/code/app." },
                "agent": { "type": "string", "description": "claude, codex, shell, or an agent from the machine's agents.toml." },
                "prompt": { "type": "string", "description": "First prompt for the agent." },
                "worktree": { "type": "object", "description": "Start in a new git worktree (branch agent/<name>) of cwd's repo.",
                    "properties": { "name": { "type": "string" } }, "required": ["name"] },
            }, "required": ["machine", "cwd", "agent"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false },
        },
        {
            "name": "send_input",
            "title": "Type into a session",
            "description": "Types text into another session's terminal, then presses Enter (unless enter is false). Not your own session.",
            "inputSchema": { "type": "object", "properties": {
                "machine": machine, "id": id,
                "text": { "type": "string" },
                "enter": { "type": "boolean", "description": "Press Enter after the text. Default true." },
            }, "required": ["machine", "id", "text"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": true, "openWorldHint": false },
        },
        {
            "name": "stop_session",
            "title": "Stop a session",
            "description": "Ends another session (kills its terminal). Not your own session.",
            "inputSchema": { "type": "object", "properties": { "machine": machine, "id": id }, "required": ["machine", "id"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": true, "openWorldHint": false },
        },
        {
            "name": "wait_for",
            "title": "Wait for a session",
            "description": "Waits until a session is done (its agent finished its turn), waiting (it needs input), or either \
                (until: \"any\"), or has ended; at most timeoutSeconds (default 300, max 600). Returns the session. \
                Returns at once if it's already in that state. Shells have no activity, so for them only ending counts.",
            "inputSchema": { "type": "object", "properties": {
                "machine": machine, "id": id,
                "until": { "type": "string", "enum": ["done", "waiting", "any"], "description": "Default done." },
                "timeoutSeconds": { "type": "integer", "minimum": 1, "maximum": MAX_WAIT_SECS },
            }, "required": ["machine", "id"] },
            "annotations": read,
        },
        {
            "name": "create_task",
            "title": "Queue a task",
            "description": "Queues a task: an agent works on `prompt` in a fresh git worktree (branch agent/<slug>) of the repository \
                at `cwd` on a machine, or of a `project` (owner/name, from list_projects: the machine uses its own checkout or clones it), \
                and when it's done the branch is committed, pushed and opened as a pull request. \
                It starts when the machine is online and has a free slot. The task's session can be watched and typed into \
                like any other. Needs \"Read and start sessions\" in Settings → Agents. A task's own session can't queue tasks.",
            "inputSchema": { "type": "object", "properties": {
                "machine": machine,
                "cwd": { "type": "string", "description": "The repository folder, e.g. ~/code/app. Give this or project." },
                "project": { "type": "string", "description": "A project's repo as owner/name, instead of cwd." },
                "title": { "type": "string", "description": "Short title; also the commit message and the pull request's title." },
                "prompt": { "type": "string", "description": "What the agent should do." },
                "agent": { "type": "string", "description": "claude (default), codex, or an agent from the machine's agents.toml that takes a prompt." },
                "base": { "type": "string", "description": "Branch to start from and open the pull request against. Default: the repo's default branch on GitHub." },
                "model": { "type": "string", "description": "Claude Code or Codex only: the model to run, e.g. claude-opus-4-1. Empty is the agent's own default; left out, the builder model from Settings → Factory." },
            }, "required": ["machine", "title", "prompt"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": true },
        },
        {
            "name": "list_tasks",
            "title": "List tasks",
            "description": "Lists recent tasks, newest first: title, machine, status (queued, running, needs_input, done, pr_open, \
                merged, closed (closed without merging), failed, cancelled), branch, session id, pull request URL and error, and \
                for merged or closed ones whether the worktree was cleaned up. For each open PR (pr_open) the summary says its CI \
                (green, red, running, absent, unknown or not read) and what its merge gate waits on, and the task has recheckCi: \
                true when CI is the only thing in the way, so recheck_ci is worth calling. Needs \"Read and start sessions\".",
            "inputSchema": { "type": "object", "properties": {
                "machine": { "type": "string", "description": "Only this machine." },
                "status": { "type": "string", "enum": TASK_STATUSES },
                "limit": { "type": "integer", "minimum": 1, "maximum": 100, "description": "Default 20." },
            } },
            "annotations": read,
        },
        {
            "name": "list_notes",
            "title": "List Scratchpad notes",
            "description": "Lists the user's Scratchpad notes (feature plans and other notes, in markdown), pinned first, then the most \
                recently changed: id, title, when it changed, and a snippet. `q` searches titles and text.",
            "inputSchema": { "type": "object", "properties": {
                "q": { "type": "string", "description": "Only notes whose title or text contains this." },
                "limit": { "type": "integer", "minimum": 1, "maximum": 200, "description": "Default 50." },
            } },
            "annotations": read,
        },
        {
            "name": "read_note",
            "title": "Read a Scratchpad note",
            "description": "Reads one Scratchpad note's markdown, by id or by title (an exact title, or the only one containing it). \
                The summary gives its version (pass it to edit_note, write_note or append_note) and lists its sections \
                (its `## ` headings, or its top-level `- [ ]` items when it has none); `section` returns just that one.",
            "inputSchema": { "type": "object", "properties": {
                "id": { "type": "string", "description": "Note id, from list_notes." },
                "title": { "type": "string", "description": "The note's title, when you don't have its id." },
                "section": { "type": "string", "description": "Only this section (its heading's text)." },
            } },
            "annotations": read,
        },
        {
            "name": "write_note",
            "title": "Write a Scratchpad note",
            "description": "Creates a Scratchpad note (leave out id), or replaces an existing note's text (and title, if given). \
                The user sees it in the web app's Scratchpad, maybe while editing it. For a small change use edit_note; \
                to add to the end, append_note. Pass the version you read, so a note the user changed meanwhile isn't overwritten. \
                Needs \"Read and start sessions\" in Settings → Agents, except on the note your session was started for.",
            "inputSchema": { "type": "object", "properties": {
                "id": { "type": "string", "description": "The note to replace. Leave out to create a new note." },
                "title": { "type": "string" },
                "body": { "type": "string", "description": "The whole note, in markdown." },
                "version": version,
            }, "required": ["body"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false },
        },
        {
            "name": "append_note",
            "title": "Add to a Scratchpad note",
            "description": "Adds text (markdown) to the end of a Scratchpad note, by id or title, after a blank line. \
                Pass the version you read. Needs \"Read and start sessions\" in Settings → Agents, except on the note \
                your session was started for.",
            "inputSchema": { "type": "object", "properties": {
                "id": { "type": "string", "description": "Note id, from list_notes." },
                "title": { "type": "string", "description": "The note's title, when you don't have its id." },
                "text": { "type": "string" },
                "version": version,
            }, "required": ["text"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false },
        },
        {
            "name": "edit_note",
            "title": "Edit a Scratchpad note",
            "description": "Replaces one piece of a Scratchpad note: `old` must appear exactly once in the note (copy it from \
                read_note, with enough around it to be unique), and becomes `new` (empty deletes it). Returns the new \
                version and the lines around the change. Pass the version you read: if the user changed the note since, \
                it's refused and you read it again. Needs \"Read and start sessions\" in Settings → Agents, except on \
                the note your session was started for.",
            "inputSchema": { "type": "object", "properties": {
                "id": { "type": "string", "description": "Note id, from list_notes or read_note." },
                "title": { "type": "string", "description": "The note's title, when you don't have its id." },
                "old": { "type": "string", "description": "The exact text to replace; it must match once." },
                "new": { "type": "string", "description": "What to put in its place." },
                "version": version,
            }, "required": ["old", "new"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false },
        },
        {
            "name": "list_projects",
            "title": "List projects",
            "description": "Lists the projects (Settings → Projects): GitHub repos by owner/name with factory settings that every \
                task in them gets in front of its prompt. Shows which settings each has and what the repo's .factory.toml overrides.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": read,
        },
        {
            "name": "get_project",
            "title": "Read a project",
            "description": "Reads one project's factory settings (setup, test, lint and dev commands, proof kinds, screens, \
                high-risk paths, max diff lines, areas, definition of done), which machines have a checkout of the repo and \
                where, and which keys the repo's .factory.toml sets (those win over the project's).",
            "inputSchema": { "type": "object", "properties": {
                "repo": { "type": "string", "description": "owner/name on GitHub." },
            }, "required": ["repo"] },
            "annotations": read,
        },
        {
            "name": "save_project",
            "title": "Save a project",
            "description": "Creates a project or replaces its settings: give all of them, since keys left out are cleared \
                (get_project shows the current ones). Checked like the web app's form; an open project page updates. \
                Needs \"Read and start sessions\" in Settings → Agents, except on the project your session was started to set up.",
            "inputSchema": { "type": "object", "properties": {
                "repo": { "type": "string", "description": "owner/name on GitHub." },
                "name": { "type": "string", "description": "Display name. Default: the current one, or the repo's name." },
                "settings": { "type": "object", "properties": {
                    "setup": { "type": "string", "description": "Commands to run once in a fresh worktree, one per line." },
                    "test": { "type": "string", "description": "Checks that must all pass, one per line." },
                    "lint": { "type": "string" },
                    "dev": { "type": "string", "description": "Starts the app, for screen proofs." },
                    "proofKinds": { "type": "array", "items": { "type": "string", "enum": PROOF_KINDS } },
                    "screens": { "type": "string", "description": "What to capture for a screen proof (routes, steps, widths)." },
                    "highRiskPaths": { "type": "array", "items": { "type": "string" }, "description": "Globs, like migrations/**." },
                    "maxDiffLines": { "type": "integer", "minimum": 1 },
                    "areas": { "type": "array", "items": { "type": "string" }, "description": "One line each: a part of the repo and what it is." },
                    "definitionOfDone": { "type": "string", "description": "Markdown." },
                } },
            }, "required": ["repo", "settings"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false },
        },
        {
            "name": "prove",
            "title": "Prove a Done when item",
            "description": "Attaches one piece of evidence to the task this session runs: the Done when item's number (from 1, \
                in the card's order; 0 for evidence about no single item), the kind, a one-line summary of what it shows, and \
                either `text` (test output, a command and its output, a terminal capture) or `file`, the path of a screenshot \
                or capture saved under ~/.cache/maple-proof/<this task's branch>/ (never in the worktree). Call it once per piece. \
                The answer says which items still have no proof. Only a task's own session can use it.",
            "inputSchema": { "type": "object", "properties": {
                "criterion": { "type": "integer", "minimum": 0, "description": "The Done when item, from 1; 0 for none in particular." },
                "kind": { "type": "string", "enum": PROOF_KINDS, "description": "One the item names after Proof:." },
                "summary": { "type": "string", "maxLength": MAX_PROOF_SUMMARY, "description": "One line: what the evidence shows." },
                "text": { "type": "string", "description": "The evidence itself, up to 64 KB. Give this or file." },
                "file": { "type": "string", "description": "A PNG, JPEG, WebP or text file (at most 5 MB) under ~/.cache/maple-proof/<branch>/. Give this or text." },
            }, "required": ["criterion", "kind", "summary"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false },
        },
        {
            "name": "review",
            "title": "Record a review",
            "description": "Records this review session's verdict on its task's pull request, once: approve or changes, a short \
                summary, specific comments (file:line where it helps), and raiseRisk with a reason when the change is riskier \
                than the project's rules say (it makes the task high risk; nothing lowers it). Only a review session can use it, \
                and the session ends once it's recorded.",
            "inputSchema": { "type": "object", "properties": {
                "verdict": { "type": "string", "enum": ["approve", "changes"] },
                "summary": { "type": "string", "maxLength": MAX_REVIEW_SUMMARY, "description": "A sentence or two: what you found." },
                "comments": { "type": "array", "maxItems": MAX_REVIEW_COMMENTS, "items": { "type": "string", "maxLength": MAX_REVIEW_COMMENT },
                    "description": "What has to change, one point each." },
                "raiseRisk": { "type": ["string", "null"], "maxLength": MAX_RAISE_RISK, "description": "Why this is high risk, if the rules missed it; else null." },
            }, "required": ["verdict", "summary"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false },
        },
    ]);
    if let Value::Array(all) = &mut tools {
        all.extend(card_tools());
    }
    tools
}

/// The factory's cards (control/src/cards.ts), as the Cards page has them; a list of their own to keep
/// `json!` within its recursion limit.
fn card_tools() -> Vec<Value> {
    let read = json!({ "readOnlyHint": true, "openWorldHint": false });
    let card_id = json!({ "type": "string", "description": "Card id (a uuid), from list_cards or plan_card." });
    let Value::Array(tools) = json!([
        {
            "name": "list_cards",
            "title": "List factory cards",
            "description": "Lists the factory's cards, newest change first: specs for one piece of work in a project, on their way \
                to becoming tasks. Each has its status (drafting: its planner is writing it; review: written and waiting for a \
                decision; approved: it has a task; waiting: approved, queued after another card; rejected, split, closed), \
                canApprove, how many problems block approval, and its task once it has one.",
            "inputSchema": { "type": "object", "properties": {
                "status": { "type": "string", "enum": CARD_STATUSES, "description": "Only cards with this status." },
                "project": { "type": "string", "description": "Only this project's cards (owner/name)." },
            } },
            "annotations": read,
        },
        {
            "name": "get_card",
            "title": "Read a factory card",
            "description": "One card in full. The summary says where it stands and what can happen next: still drafting, in review and \
                ready to approve, in review with problems that block approval (each listed), or approved with its task's progress. \
                The data has canApprove, the blocking problems and warnings, the card's fields (size, risk, agent, areas, Queue \
                after, race) and markdown, its latest history, and its task: status, pull request, CI, review and the merge gate.",
            "inputSchema": { "type": "object", "properties": { "id": card_id }, "required": ["id"] },
            "annotations": read,
        },
        {
            "name": "plan_card",
            "title": "Plan a card",
            "description": "Starts a factory card from a one-liner in a project (owner/name, from list_projects), as New card on the \
                Cards page does: the card is made, drafting, and a planner session writes it, exploring the repo in a throwaway \
                worktree. It reaches review when the planner's turn ends, usually in a few minutes; watch with get_card. \
                The planner runs on `machine` if named, else on an online machine that has the repo. \
                Needs \"Read and start sessions\" in Settings → Agents.",
            "inputSchema": { "type": "object", "properties": {
                "project": { "type": "string", "description": "The project's repo as owner/name." },
                "oneLiner": { "type": "string", "maxLength": MAX_ONE_LINER, "description": "What the card is for, in one line." },
                "machine": { "type": "string", "description": "Plan on this machine. Default: one that has the repo." },
            }, "required": ["project", "oneLiner"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": true },
        },
        {
            "name": "approve_card",
            "title": "Approve a card",
            "description": "Approves a card in review with no blocking problems, as the Cards page's Approve does: it becomes a task \
                that builds it and opens a pull request. The task goes to Ready, where any machine with room takes it, unless you \
                name a machine. A card whose Queue after names a card that hasn't merged waits for it. Low-risk work whose checks \
                and review pass may merge to main on its own. `agent` builds a card for claude, codex or either on Claude Code or Codex (default: the card's \
                agent, claude for either); `race` has Claude Code and Codex both build it. `notBefore` schedules it: machines leave its task alone until then \
                (it starts within 15 minutes of that time). `first` puts its task ahead of everything else waiting in its queue \
                (Ready, or the named machine's). A card's own planner and review sessions can't approve. \
                Needs \"Read and start sessions\" in Settings → Agents.",
            "inputSchema": { "type": "object", "properties": {
                "id": card_id,
                "agent": { "type": "string", "enum": ["claude", "codex"], "description": "Claude Code or Codex, whatever the card says (a card for a custom agent keeps it). Default: the card's agent, claude for either." },
                "model": { "type": "string", "description": "The builder's model. Left out: the builder model from Settings → Factory; empty: the agent's own default." },
                "machine": { "type": "string", "description": "Build on this machine. Default: Ready, for any machine." },
                "race": { "type": "boolean", "description": "Claude Code and Codex both build it and the reviewer keeps the better one. Takes no model." },
                "notBefore": { "type": "string", "description": "Start not before this ISO 8601 time, with its offset (2026-10-23T09:00:00+02:00), at most 30 days out. Default: now." },
                "first": { "type": "boolean", "description": "First in Ready (or the named machine's queue): the next machine with room takes it before anything else waiting. Default: last." },
            }, "required": ["id"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": true },
        },
        {
            "name": "tweak_card",
            "title": "Tweak a card",
            "description": "Asks a card's planner for a change, as Tweak on the Cards page does: the comment goes in the card's history \
                and is typed into its planner (or a new planner starts with it). The card goes back to drafting and returns to \
                review when the planner's turn ends. Needs \"Read and start sessions\" in Settings → Agents.",
            "inputSchema": { "type": "object", "properties": {
                "id": card_id,
                "comment": { "type": "string", "maxLength": MAX_CARD_COMMENT, "description": "What to change." },
            }, "required": ["id", "comment"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false },
        },
        {
            "name": "split_card",
            "title": "Split a card",
            "description": "Asks a card's planner to cut it into smaller cards, as Split on the Cards page does, each its own `## ` card \
                in the note. It comes back to review; the user then makes them separate cards. Needs \"Read and start sessions\" \
                in Settings → Agents.",
            "inputSchema": { "type": "object", "properties": {
                "id": card_id,
                "how": { "type": "string", "maxLength": MAX_CARD_COMMENT, "description": "How to split it, if you have a view." },
            }, "required": ["id"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false },
        },
        {
            "name": "reject_card",
            "title": "Reject a card",
            "description": "Closes a card that is drafting, in review or waiting, as Reject on the Cards page does, and stops its \
                planner. Needs \"Read and start sessions\" in Settings → Agents.",
            "inputSchema": { "type": "object", "properties": {
                "id": card_id,
                "reason": { "type": "string", "maxLength": MAX_REJECT_REASON, "description": "Why, in a line." },
            }, "required": ["id"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": true, "openWorldHint": false },
        },
        {
            "name": "review_again",
            "title": "Review a task again",
            "description": "Starts a fresh review of a card's task whose pull request is open, as Review again on the task's page \
                does: a new reviewer session on the PR's current head. Use it when the last review failed (it never started, \
                or never answered). Says plainly why when it can't, for example a review is already running, the head already \
                has a verdict, or the runner has no review support. Not from a review session or from the task's own session. \
                Needs \"Read and start sessions\" in Settings → Agents.",
            "inputSchema": { "type": "object", "properties": {
                "taskId": { "type": "string", "description": "The task's id (a uuid), from list_tasks or get_card." },
            }, "required": ["taskId"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false },
        },
        {
            "name": "recheck_ci",
            "title": "Recheck a task's CI",
            "description": "Reads the CI of a task's open pull request from GitHub now, as Recheck CI on the task's page does, \
                instead of waiting for the PR poll or a webhook: its check runs and statuses on the PR's head, settled or not. \
                Answers with the CI state, whether it changed since the last read, and the merge gate's checks. A read that \
                turns CI green on an otherwise green gate merges the PR, as usual. It only reads; it doesn't rerun failed \
                jobs. Says plainly why when it can't, for example the PR isn't open or the GitHub App isn't set up. \
                Needs \"Read and start sessions\" in Settings → Agents.",
            "inputSchema": { "type": "object", "properties": {
                "taskId": { "type": "string", "description": "The task's id (a uuid), from list_tasks or get_card." },
            }, "required": ["taskId"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": true },
        },
        {
            "name": "propose_cards",
            "title": "Propose cards",
            "description": "Only for a scout session (the factory starts one per project when Ready runs dry before the user's \
                next sitting): proposes up to 3 one-liners for the scout's own project, each with where it came from (a merged \
                card's Out of scope or Assumptions, a failed task, an undone planner call, a file in the repo). Each becomes a \
                factory card whose planner writes it; auto-approve takes the clean ones to Ready. Once per run: a second call, \
                a 4th one-liner or another project is refused. Works whatever Settings → Agents says.",
            "inputSchema": { "type": "object", "properties": {
                "oneLiners": { "type": "array", "minItems": 1, "maxItems": 3, "items": { "type": "object", "properties": {
                    "text": { "type": "string", "maxLength": MAX_ONE_LINER, "description": "What the card is for, in one line." },
                    "source": { "type": "string", "maxLength": 300, "description": "Where the idea came from." },
                }, "required": ["text", "source"] } },
                "project": { "type": "string", "description": "The scout's project as owner/name. Default: its own." },
            }, "required": ["oneLiners"] },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": true },
        },
        {
            "name": "scout_now",
            "title": "Scout now",
            "description": "Starts a scout for one project now, as the Scout button in Mission Control does, whatever the Scout \
                switch in Settings → Factory says: a session that reads the project's recent history and proposes up to 3 \
                one-liners as factory cards when its turn ends (list_cards shows them). If the project's scout is still \
                running, nothing starts and the answer says so. Not from a scout session. Needs \"Read and start sessions\" \
                in Settings → Agents.",
            "inputSchema": { "type": "object", "properties": {
                "project": { "type": "string", "description": "The project as owner/name (list_projects shows them). Default: the repo of the task this session runs, else its card's project." },
            } },
            "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": true },
        },
    ]) else {
        unreachable!()
    };
    tools
}

/// Checks and normalizes a tool's arguments: only known fields, defaults filled in.
pub fn validate(tool: &str, args: &Value) -> Result<Value, String> {
    let empty = serde_json::Map::new();
    let obj = match args {
        Value::Null => &empty,
        Value::Object(o) => o,
        _ => return Err("Arguments must be an object.".into()),
    };
    let s = |k: &str, max: usize, required: bool| -> Result<Option<String>, String> {
        match obj.get(k) {
            None | Some(Value::Null) if required => Err(format!("{k} is required.")),
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(v)) if required && v.trim().is_empty() => Err(format!("{k} can't be empty.")),
            Some(Value::String(v)) if v.chars().count() > max => Err(format!("{k} is too long (at most {max} characters).")),
            Some(Value::String(v)) => Ok(Some(v.clone())),
            Some(_) => Err(format!("{k} must be a string.")),
        }
    };
    let b = |k: &str, default: bool| -> Result<bool, String> {
        match obj.get(k) {
            None | Some(Value::Null) => Ok(default),
            Some(Value::Bool(v)) => Ok(*v),
            Some(_) => Err(format!("{k} must be true or false.")),
        }
    };
    let n = |k: &str, min: u64, max: u64, default: u64| -> Result<u64, String> {
        match obj.get(k) {
            None | Some(Value::Null) => Ok(default),
            Some(v) => match v.as_f64() {
                Some(f) if f.fract() == 0.0 && f >= min as f64 && f <= max as f64 => Ok(f as u64),
                _ => Err(format!("{k} must be a whole number from {min} to {max}.")),
            },
        }
    };
    let machine = || s("machine", 63, true);
    let id = || -> Result<String, String> {
        let id = s("id", 64, true)?.unwrap();
        Uuid::parse_str(id.trim()).map(|u| u.to_string()).map_err(|_| "id must be a session id (a uuid) from list_sessions.".to_string())
    };
    Ok(match tool {
        "list_machines" => json!({}),
        "list_sessions" => {
            let mut out = json!({ "includeEnded": b("includeEnded", false)? });
            if let Some(m) = s("machine", 63, false)?.filter(|m| !m.trim().is_empty()) {
                out["machine"] = json!(m);
            }
            out
        }
        "get_session" | "stop_session" => json!({ "machine": machine()?, "id": id()? }),
        "read_output" => json!({ "machine": machine()?, "id": id()?, "lines": n("lines", 1, MAX_LINES, 200)? }),
        "start_session" => {
            let mut out = json!({ "machine": machine()?, "cwd": s("cwd", 1024, true)?, "agent": s("agent", 32, true)? });
            if let Some(p) = s("prompt", MAX_TEXT, false)?.filter(|p| !p.trim().is_empty()) {
                out["prompt"] = json!(p);
            }
            match obj.get("worktree") {
                None | Some(Value::Null) => {}
                Some(Value::Object(w)) => match w.get("name").and_then(Value::as_str).map(str::trim) {
                    Some(name) if !name.is_empty() && name.len() <= 100 => out["worktree"] = json!({ "name": name }),
                    _ => return Err("worktree.name is required (up to 100 characters).".into()),
                },
                Some(_) => return Err("worktree must be an object like {\"name\": \"fix-login\"}.".into()),
            }
            out
        }
        "send_input" => {
            let text = match obj.get("text") {
                Some(Value::String(t)) if t.chars().count() <= MAX_TEXT => t.clone(),
                Some(Value::String(_)) => return Err(format!("text is too long (at most {MAX_TEXT} characters).")),
                None | Some(Value::Null) => return Err("text is required.".into()),
                Some(_) => return Err("text must be a string.".into()),
            };
            let enter = b("enter", true)?;
            if text.is_empty() && !enter {
                return Err("Nothing to send: text is empty and enter is false.".into());
            }
            json!({ "machine": machine()?, "id": id()?, "text": text, "enter": enter })
        }
        "wait_for" => {
            let until = s("until", 16, false)?.unwrap_or_else(|| "done".into());
            if !["done", "waiting", "any"].contains(&until.as_str()) {
                return Err("until must be \"done\", \"waiting\" or \"any\".".into());
            }
            json!({ "machine": machine()?, "id": id()?, "until": until, "timeoutSeconds": n("timeoutSeconds", 1, MAX_WAIT_SECS, 300)? })
        }
        "create_task" => {
            let mut out = json!({
                "machine": machine()?,
                "title": s("title", 200, true)?.map(|t| t.trim().to_string()),
                "prompt": s("prompt", MAX_TEXT, true)?,
            });
            let cwd = s("cwd", 1024, false)?.filter(|c| !c.trim().is_empty());
            let project = s("project", 201, false)?.map(|p| p.trim().to_string()).filter(|p| !p.is_empty());
            match (cwd, project) {
                (Some(_), Some(_)) => return Err("Give cwd or project, not both.".into()),
                (Some(c), None) => out["cwd"] = json!(c),
                (None, Some(p)) => out["project"] = json!(p),
                (None, None) => return Err("cwd or project is required (the repository folder, or a project's owner/name).".into()),
            }
            if let Some(a) = s("agent", 32, false)?.filter(|a| !a.trim().is_empty()) {
                out["agent"] = json!(a.trim());
            }
            if let Some(b) = s("base", 200, false)?.filter(|b| !b.trim().is_empty()) {
                out["base"] = json!(b.trim());
            }
            // Kept when empty: "" is the agent's own default, and left out the builder setting decides.
            if let Some(m) = s("model", 100, false)? {
                out["model"] = json!(m.trim());
            }
            out
        }
        "list_tasks" => {
            let mut out = json!({ "limit": n("limit", 1, 100, 20)? });
            if let Some(m) = s("machine", 63, false)?.filter(|m| !m.trim().is_empty()) {
                out["machine"] = json!(m);
            }
            if let Some(st) = s("status", 16, false)?.filter(|st| !st.is_empty()) {
                if !TASK_STATUSES.contains(&st.as_str()) {
                    return Err(format!("status must be one of {}.", TASK_STATUSES.join(", ")));
                }
                out["status"] = json!(st);
            }
            out
        }
        "list_notes" => {
            let mut out = json!({ "limit": n("limit", 1, 200, 50)? });
            if let Some(q) = s("q", 200, false)?.filter(|q| !q.trim().is_empty()) {
                out["q"] = json!(q.trim());
            }
            out
        }
        "read_note" | "append_note" | "edit_note" => {
            let id = s("id", 64, false)?.map(|i| i.trim().to_lowercase()).filter(|i| !i.is_empty());
            let title = s("title", 200, false)?.map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
            let mut out = match (id, title) {
                (Some(id), _) => {
                    Uuid::parse_str(&id).map_err(|_| "id must be a note id (a uuid) from list_notes.".to_string())?;
                    json!({ "id": id })
                }
                (None, Some(title)) => json!({ "title": title }),
                (None, None) => return Err("Give the note's id or title (list_notes shows them).".into()),
            };
            match tool {
                "read_note" => {
                    if let Some(sec) = s("section", 200, false)?.filter(|x| !x.trim().is_empty()) {
                        out["section"] = json!(sec.trim());
                    }
                }
                "append_note" => out["text"] = json!(s("text", MAX_NOTE, true)?),
                _ => {
                    // Exact text: not trimmed, and `new` may be empty (a deletion).
                    match obj.get("old") {
                        Some(Value::String(o)) if o.is_empty() => return Err("old can't be empty: give the exact text to replace.".into()),
                        Some(Value::String(o)) if o.chars().count() > MAX_NOTE => return Err(format!("old is too long (at most {MAX_NOTE} characters).")),
                        Some(Value::String(o)) => out["old"] = json!(o),
                        None | Some(Value::Null) => return Err("old is required: the exact text to replace.".into()),
                        Some(_) => return Err("old must be a string.".into()),
                    }
                    match obj.get("new") {
                        Some(Value::String(n)) if n.chars().count() > MAX_NOTE => return Err(format!("new is too long (at most {MAX_NOTE} characters).")),
                        Some(Value::String(n)) => out["new"] = json!(n),
                        None | Some(Value::Null) => return Err("new is required (an empty string deletes old).".into()),
                        Some(_) => return Err("new must be a string.".into()),
                    }
                }
            }
            if let Some(v) = version(obj)?.filter(|_| tool != "read_note") {
                out["version"] = json!(v);
            }
            out
        }
        "write_note" => {
            let body = match obj.get("body") {
                Some(Value::String(b)) if b.chars().count() <= MAX_NOTE => b.clone(),
                Some(Value::String(_)) => return Err(format!("body is too long (at most {MAX_NOTE} characters).")),
                None | Some(Value::Null) => return Err("body is required.".into()),
                Some(_) => return Err("body must be a string.".into()),
            };
            let mut out = json!({ "body": body });
            if let Some(id) = s("id", 64, false)?.map(|i| i.trim().to_lowercase()).filter(|i| !i.is_empty()) {
                Uuid::parse_str(&id).map_err(|_| "id must be a note id (a uuid) from list_notes.".to_string())?;
                out["id"] = json!(id);
            }
            if let Some(t) = s("title", 200, false)? {
                out["title"] = json!(t.trim());
            }
            if let Some(v) = version(obj)? {
                if !out.get("id").is_some_and(Value::is_string) {
                    return Err("version only goes with id (the note you read).".into());
                }
                out["version"] = json!(v);
            }
            out
        }
        "list_projects" => json!({}),
        "get_project" => json!({ "repo": s("repo", 201, true)?.map(|r| r.trim().to_string()) }),
        "save_project" => {
            // The settings are checked by the control plane, the same way as the web app's form.
            let settings = match obj.get("settings") {
                Some(Value::Object(o)) => Value::Object(o.clone()),
                None | Some(Value::Null) => return Err("settings is required (all of them: keys left out are cleared).".into()),
                Some(_) => return Err("settings must be an object.".into()),
            };
            let mut out = json!({ "repo": s("repo", 201, true)?.map(|r| r.trim().to_string()), "settings": settings });
            if let Some(name) = s("name", 100, false)? {
                out["name"] = json!(name.trim());
            }
            out
        }
        "prove" => {
            let criterion = match obj.get("criterion") {
                None | Some(Value::Null) => {
                    return Err("criterion is required: the Done when item's number, from 1 (0 for evidence about no single item).".into());
                }
                Some(v) => match v.as_f64() {
                    Some(f) if f.fract() == 0.0 && (0.0..=1000.0).contains(&f) => f as u64,
                    _ => return Err("criterion must be a whole number: the Done when item, from 1 (0 for evidence about no single item).".into()),
                },
            };
            let kind = s("kind", 16, true)?.unwrap();
            if !PROOF_KINDS.contains(&kind.trim()) {
                return Err(format!("kind must be one of {}.", PROOF_KINDS.join(", ")));
            }
            let summary = s("summary", MAX_PROOF_SUMMARY, true)?.unwrap();
            if summary.contains('\n') {
                return Err("summary is one line; put the details in text.".into());
            }
            let mut out = json!({ "criterion": criterion, "kind": kind.trim(), "summary": summary.trim() });
            let text = match obj.get("text") {
                None | Some(Value::Null) => None,
                Some(Value::String(t)) if t.trim().is_empty() => return Err("text can't be empty.".into()),
                Some(Value::String(t)) if t.len() > MAX_PROOF_TEXT => {
                    return Err(format!(
                        "text is {} KB; at most 64 KB. Keep the end of the output, or save it to a file under the proof folder.",
                        t.len() / 1024
                    ));
                }
                Some(Value::String(t)) => Some(t.clone()),
                Some(_) => return Err("text must be a string.".into()),
            };
            let file = s("file", 1024, false)?.map(|f| f.trim().to_string()).filter(|f| !f.is_empty());
            match (text, file) {
                (Some(_), Some(_)) => return Err("Give text or file, not both: one call per piece of evidence.".into()),
                (Some(t), None) => out["text"] = json!(t),
                (None, Some(f)) => out["file"] = json!(f),
                (None, None) => return Err("Give the evidence: text (output or a capture), or file (a path under ~/.cache/maple-proof/<branch>/).".into()),
            }
            out
        }
        "review" => {
            let verdict = s("verdict", 16, true)?.unwrap();
            if !["approve", "changes"].contains(&verdict.trim()) {
                return Err("verdict must be \"approve\" or \"changes\".".into());
            }
            let summary = s("summary", MAX_REVIEW_SUMMARY, true)?.unwrap();
            let comments = match obj.get("comments") {
                None | Some(Value::Null) => vec![],
                Some(Value::Array(a)) if a.len() > MAX_REVIEW_COMMENTS => {
                    return Err(format!("At most {MAX_REVIEW_COMMENTS} comments: keep the ones that matter most."));
                }
                Some(Value::Array(a)) => {
                    let mut out = vec![];
                    for c in a {
                        match c {
                            Value::String(t) if t.trim().is_empty() => return Err("Each comment is a non-empty string.".into()),
                            Value::String(t) if t.chars().count() > MAX_REVIEW_COMMENT => {
                                return Err(format!("Each comment is at most {MAX_REVIEW_COMMENT} characters."));
                            }
                            Value::String(t) => out.push(t.trim().to_string()),
                            _ => return Err("Each comment is a string.".into()),
                        }
                    }
                    out
                }
                Some(_) => return Err("comments must be a list of strings.".into()),
            };
            let raise = s("raiseRisk", MAX_RAISE_RISK, false)?.map(|r| r.trim().to_string()).filter(|r| !r.is_empty());
            json!({ "verdict": verdict.trim(), "summary": summary.trim(), "comments": comments, "raiseRisk": raise })
        }
        "list_cards" => {
            let mut out = json!({});
            if let Some(st) = s("status", 16, false)?.map(|st| st.trim().to_string()).filter(|st| !st.is_empty()) {
                if !CARD_STATUSES.contains(&st.as_str()) {
                    return Err(format!("status must be one of {}.", CARD_STATUSES.join(", ")));
                }
                out["status"] = json!(st);
            }
            if let Some(p) = s("project", 201, false)?.map(|p| p.trim().to_string()).filter(|p| !p.is_empty()) {
                out["project"] = json!(p);
            }
            out
        }
        "get_card" => json!({ "id": card_id(obj)? }),
        "plan_card" => {
            let one_liner = s("oneLiner", MAX_ONE_LINER, true)?.unwrap();
            if one_liner.contains('\n') {
                return Err("oneLiner is one line: what the card is for. The planner writes the rest.".into());
            }
            let mut out = json!({ "project": s("project", 201, true)?.map(|p| p.trim().to_string()), "oneLiner": one_liner.trim() });
            if let Some(m) = s("machine", 63, false)?.map(|m| m.trim().to_string()).filter(|m| !m.is_empty()) {
                out["machine"] = json!(m);
            }
            out
        }
        "approve_card" => {
            let mut out = json!({ "id": card_id(obj)? });
            if let Some(a) = s("agent", 32, false)?.map(|a| a.trim().to_string()).filter(|a| !a.is_empty()) {
                if a != "claude" && a != "codex" {
                    return Err("agent must be \"claude\" or \"codex\".".into());
                }
                out["agent"] = json!(a);
            }
            // Kept when empty: "" is the agent's own default, and left out the builder setting decides.
            if let Some(m) = s("model", 100, false)? {
                out["model"] = json!(m.trim());
            }
            if let Some(m) = s("machine", 63, false)?.map(|m| m.trim().to_string()).filter(|m| !m.is_empty()) {
                out["machine"] = json!(m);
            }
            if b("race", false)? {
                if out.get("model").is_some() {
                    return Err("A race builds on each agent's builder model, so it takes no model.".into());
                }
                out["race"] = json!(true);
            }
            // Checked by the control plane (mcp.ts `isoTime`), which knows the time now.
            if let Some(t) = s("notBefore", 64, false)?.map(|t| t.trim().to_string()).filter(|t| !t.is_empty()) {
                out["notBefore"] = json!(t);
            }
            if b("first", false)? {
                out["first"] = json!(true);
            }
            out
        }
        "tweak_card" => json!({ "id": card_id(obj)?, "comment": s("comment", MAX_CARD_COMMENT, true)?.map(|c| c.trim().to_string()) }),
        "split_card" | "reject_card" => {
            let (key, max) = if tool == "split_card" { ("how", MAX_CARD_COMMENT) } else { ("reason", MAX_REJECT_REASON) };
            let mut out = json!({ "id": card_id(obj)? });
            if let Some(v) = s(key, max, false)?.map(|v| v.trim().to_string()).filter(|v| !v.is_empty()) {
                out[key] = json!(v);
            }
            out
        }
        "review_again" | "recheck_ci" => match obj.get("taskId") {
            None | Some(Value::Null) => return Err("taskId is required: the task's id, from list_tasks or get_card.".into()),
            Some(Value::String(id)) => match Uuid::parse_str(id.trim()) {
                Ok(u) => json!({ "taskId": u.to_string() }),
                Err(_) => return Err("taskId must be a task id (a uuid) from list_tasks or get_card.".into()),
            },
            Some(_) => return Err("taskId must be a string: the task's id, from list_tasks or get_card.".into()),
        },
        // The control plane checks each one-liner and the limits (scout.ts), so its refusals say why.
        "propose_cards" => {
            let list = match obj.get("oneLiners") {
                Some(Value::Array(a)) if a.iter().all(Value::is_object) => a.clone(),
                None | Some(Value::Null) => return Err("oneLiners is required: a list of {text, source}.".into()),
                Some(_) => return Err("oneLiners must be a list of {text, source}.".into()),
            };
            let mut out = json!({ "oneLiners": list });
            if let Some(p) = s("project", 201, false)?.map(|p| p.trim().to_string()).filter(|p| !p.is_empty()) {
                out["project"] = json!(p);
            }
            out
        }
        "scout_now" => {
            let mut out = json!({});
            if let Some(p) = s("project", 201, false)?.map(|p| p.trim().to_string()).filter(|p| !p.is_empty()) {
                out["project"] = json!(p);
            }
            out
        }
        other => return Err(format!("Unknown tool: {other}")),
    })
}

/// A card's `id` (from list_cards), lowercased.
fn card_id(obj: &serde_json::Map<String, Value>) -> Result<String, String> {
    match obj.get("id") {
        None | Some(Value::Null) => Err("id is required: the card's id, from list_cards or plan_card.".into()),
        Some(Value::String(id)) => {
            Uuid::parse_str(id.trim()).map(|u| u.to_string()).map_err(|_| "id must be a card id (a uuid) from list_cards or plan_card.".to_string())
        }
        Some(_) => Err("id must be a string: the card's id, from list_cards or plan_card.".into()),
    }
}

/// A note's optional `version` (from read_note): a whole number from 1.
fn version(obj: &serde_json::Map<String, Value>) -> Result<Option<u64>, String> {
    match obj.get("version") {
        None | Some(Value::Null) => Ok(None),
        Some(v) => match v.as_f64() {
            Some(f) if f.fract() == 0.0 && (1.0..=9_007_199_254_740_991.0).contains(&f) => Ok(Some(f as u64)),
            _ => Err("version must be the note's version from read_note (a whole number).".into()),
        },
    }
}

/// A tool result: a summary line, then the data (pretty JSON, or text as is).
fn tool_result(summary: &str, data: Option<&Value>, is_error: bool) -> Value {
    let text = match data {
        None | Some(Value::Null) => summary.to_string(),
        Some(Value::String(s)) => format!("{summary}\n\n{s}"),
        Some(v) => format!("{summary}\n\n{}", serde_json::to_string_pretty(v).unwrap_or_default()),
    };
    json!({ "content": [{ "type": "text", "text": text }], "isError": is_error })
}

fn hub_result(result: &Value) -> Value {
    let summary = result.get("summary").and_then(Value::as_str).unwrap_or("Done.");
    tool_result(summary, result.get("data"), false)
}

pub fn call_tool(backend: &dyn Backend, name: &str, args: &Value) -> Value {
    let args = match validate(name, args) {
        Ok(args) => args,
        Err(e) => return tool_result(&e, None, true),
    };
    let result = if name == "wait_for" { wait_for(backend, &args) } else { backend.call(name, &args).map(|r| hub_result(&r)) };
    result.unwrap_or_else(|e| tool_result(&e, None, true))
}

/// Whether a session (as the hub describes it) is in the state `until` waits for.
fn reached(until: &str, session: &Value) -> bool {
    let status = session.get("status").and_then(Value::as_str).unwrap_or("");
    let activity = session.get("activity").and_then(Value::as_str).unwrap_or("");
    if status == "exited" || status == "error" {
        return true;
    }
    match until {
        "done" => activity == "done",
        "waiting" => activity == "waiting",
        _ => activity == "done" || activity == "waiting",
    }
}

fn describe(session: &Value) -> String {
    let status = session.get("status").and_then(Value::as_str).unwrap_or("unknown");
    match (status, session.get("activity").and_then(Value::as_str)) {
        ("running", Some("waiting")) => "waiting for input".into(),
        ("running", Some(a)) => a.into(),
        (s, _) => s.into(),
    }
}

/// Polls the session (through the hub's `wait_for`, which answers like `get_session`) until it
/// reaches the state or the time is up. Only the first poll is audited.
fn wait_for(backend: &dyn Backend, args: &Value) -> Result<Value, String> {
    let until = args["until"].as_str().unwrap_or("done");
    let timeout = Duration::from_secs(args["timeoutSeconds"].as_u64().unwrap_or(300));
    let mut waited = Duration::ZERO;
    let mut poll = 0u64;
    loop {
        let mut a = args.clone();
        a["poll"] = json!(poll);
        let result = backend.call("wait_for", &a)?;
        let session = result.get("data").cloned().unwrap_or(Value::Null);
        let secs = waited.as_secs();
        let title = session.get("title").and_then(Value::as_str).unwrap_or("The session");
        if reached(until, &session) {
            let summary = format!("{title} is {} (after {secs}s).", describe(&session));
            return Ok(tool_result(&summary, Some(&json!({ "timedOut": false, "waitedSeconds": secs, "session": session })), false));
        }
        if waited >= timeout {
            let summary = format!("Stopped waiting after {secs}s: {title} is still {}.", describe(&session));
            return Ok(tool_result(&summary, Some(&json!({ "timedOut": true, "waitedSeconds": secs, "session": session })), false));
        }
        let step = POLL.min(timeout - waited);
        backend.sleep(step);
        waited += step;
        poll += 1;
    }
}

// ---------------------------------------------------------------------------
// The runner's side: forwarding requests from the socket to the hub

type Reply = Result<Value, String>;

static PENDING: LazyLock<Mutex<HashMap<String, oneshot::Sender<Reply>>>> = LazyLock::new(Mutex::default);
static CONNECTED: AtomicBool = AtomicBool::new(false);

/// Whether the runner is connected to the hub right now (requests go nowhere otherwise).
pub fn set_connected(connected: bool) {
    CONNECTED.store(connected, Ordering::Relaxed);
    if !connected {
        // Anything in flight was lost with the connection.
        for (_, tx) in PENDING.lock().unwrap().drain() {
            let _ = tx.send(Err("The runner lost its connection to the control plane. Try again in a moment.".into()));
        }
    }
}

/// The hub's `mcp.response`.
pub fn resolve(req_id: &str, result: Option<Value>, error: Option<String>) {
    if let Some(tx) = PENDING.lock().unwrap().remove(req_id) {
        let _ = tx.send(match (result, error) {
            (_, Some(e)) => Err(e),
            (Some(r), None) => Ok(r),
            (None, None) => Ok(Value::Null),
        });
    }
}

/// One `{"mcp":{…}}` request line from the socket; returns the line to answer with.
pub async fn forward(sessions: &Sessions, request: &Value) -> Value {
    let answer = |r: Reply| match r {
        Ok(result) => json!({ "result": result }),
        Err(e) => json!({ "error": e }),
    };
    let session = request.get("session").and_then(Value::as_str).and_then(|s| Uuid::parse_str(s).ok());
    let tool = request.get("tool").and_then(Value::as_str).unwrap_or_default();
    let Some(session) = session.filter(|id| sessions.is_live(*id)) else {
        return answer(Err("This session isn't one the runner is running, so it can't use the agents tools.".into()));
    };
    if !TOOL_NAMES.contains(&tool) {
        return answer(Err(format!("Unknown tool: {tool}")));
    }
    if !CONNECTED.load(Ordering::Relaxed) {
        return answer(Err("The runner isn't connected to the control plane right now. Try again in a moment.".into()));
    }
    let req_id = Uuid::new_v4().to_string();
    let (tx, rx) = oneshot::channel();
    PENDING.lock().unwrap().insert(req_id.clone(), tx);
    let mut args = request.get("args").cloned().unwrap_or(json!({}));
    // Evidence files go up over HTTP first; the hub gets their keys.
    if tool == "prove" {
        args = match crate::proof::prepare(sessions, session, args).await {
            Ok(args) => args,
            Err(e) => return answer(Err(e)),
        };
    }
    sessions.emit(Outbound::McpRequest { req_id: req_id.clone(), session, tool: tool.to_string(), args });
    let reply = match tokio::time::timeout(HUB_TIMEOUT, rx).await {
        Ok(Ok(reply)) => reply,
        Ok(Err(_)) => Err("The request was dropped.".into()),
        Err(_) => Err("The control plane didn't answer within 60s.".into()),
    };
    PENDING.lock().unwrap().remove(&req_id);
    answer(reply)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

    fn reply(line: &str) -> Value {
        match handle(line) {
            Handled::Reply(v) => v,
            other => panic!("expected a reply, got {other:?}"),
        }
    }

    #[test]
    fn initialize_negotiates_the_version() {
        let r = reply(
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
        );
        assert_eq!(r["id"], 1);
        assert_eq!(r["result"]["protocolVersion"], "2025-06-18");
        assert_eq!(r["result"]["serverInfo"]["name"], "agents");
        assert!(r["result"]["capabilities"]["tools"].is_object());
        // An older version we speak is echoed; one we don't gets ours.
        let r = reply(r#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#);
        assert_eq!((r["id"].as_str(), r["result"]["protocolVersion"].as_str()), (Some("a"), Some("2024-11-05")));
        let r = reply(r#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#);
        assert_eq!(r["result"]["protocolVersion"], PROTOCOL_VERSION);
    }

    #[test]
    fn notifications_ping_and_errors() {
        assert_eq!(handle(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), Handled::Nothing);
        assert_eq!(handle(r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#), Handled::Nothing);
        assert_eq!(handle("   "), Handled::Nothing);
        assert_eq!(reply(r#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)["result"], json!({}));
        let r = reply("{not json");
        assert_eq!((r["id"].clone(), r["error"]["code"].as_i64()), (Value::Null, Some(-32700)));
        assert_eq!(reply(r#"{"jsonrpc":"2.0","id":8,"method":"sampling/whatever"}"#)["error"]["code"], -32601);
        assert_eq!(reply(r#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"rm_rf"}}"#)["error"]["code"], -32602);
        // A response from the client to something we never asked: ignored.
        assert_eq!(handle(r#"{"jsonrpc":"2.0","id":5,"result":{}}"#), Handled::Nothing);
    }

    #[test]
    fn lists_the_tools() {
        let r = reply(r#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#);
        let names: Vec<&str> = r["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, TOOL_NAMES);
        for t in r["result"]["tools"].as_array().unwrap() {
            assert_eq!(t["inputSchema"]["type"], "object", "{}", t["name"]);
            assert!(t["description"].as_str().unwrap().len() > 20);
        }
    }

    #[test]
    fn tools_call_is_dispatched() {
        let h = handle(r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_session","arguments":{"machine":"m","id":"x"}}}"#);
        assert_eq!(h, Handled::Call { id: json!(4), name: "get_session".into(), args: json!({"machine":"m","id":"x"}) });
    }

    #[test]
    fn validates_arguments() {
        let id = "6F1C6A7E-2F6B-4D55-9B1A-2B7F0F6F0A11";
        let ok = |tool: &str, args: Value| validate(tool, &args).unwrap();
        let err = |tool: &str, args: Value| validate(tool, &args).unwrap_err();
        assert_eq!(ok("list_machines", Value::Null), json!({}));
        assert_eq!(ok("list_sessions", json!({"machine": "", "junk": 1})), json!({"includeEnded": false}));
        assert_eq!(ok("list_sessions", json!({"machine": "mbp", "includeEnded": true})), json!({"machine": "mbp", "includeEnded": true}));
        // Ids are normalized to lowercase.
        assert_eq!(ok("get_session", json!({"machine": "m", "id": id}))["id"], id.to_lowercase());
        assert!(err("get_session", json!({"machine": "m", "id": "nope"})).contains("uuid"));
        assert!(err("get_session", json!({"id": id})).contains("machine is required"));
        assert!(err("get_session", json!([1])).contains("object"));
        assert_eq!(ok("read_output", json!({"machine": "m", "id": id}))["lines"], 200);
        assert!(err("read_output", json!({"machine": "m", "id": id, "lines": 5000})).contains("1 to 2000"));
        assert!(err("read_output", json!({"machine": "m", "id": id, "lines": 1.5})).contains("whole number"));
        let started = ok("start_session", json!({"machine": "m", "cwd": "~/x", "agent": "codex", "prompt": "  ", "worktree": {"name": " fix "}}));
        assert_eq!(started, json!({"machine": "m", "cwd": "~/x", "agent": "codex", "worktree": {"name": "fix"}}));
        assert!(err("start_session", json!({"machine": "m", "cwd": "~/x", "agent": "codex", "worktree": "fix"})).contains("worktree"));
        assert!(err("start_session", json!({"machine": "m", "cwd": " ", "agent": "codex"})).contains("cwd can't be empty"));
        assert_eq!(ok("send_input", json!({"machine": "m", "id": id, "text": "echo hi"}))["enter"], true);
        assert_eq!(ok("send_input", json!({"machine": "m", "id": id, "text": ""}))["text"], "");
        assert!(err("send_input", json!({"machine": "m", "id": id, "text": "", "enter": false})).contains("Nothing to send"));
        assert!(err("send_input", json!({"machine": "m", "id": id, "text": 5})).contains("string"));
        assert!(err("send_input", json!({"machine": "m", "id": id, "text": "x".repeat(MAX_TEXT + 1)})).contains("too long"));
        let w = ok("wait_for", json!({"machine": "m", "id": id}));
        assert_eq!((w["until"].as_str(), w["timeoutSeconds"].as_u64()), (Some("done"), Some(300)));
        assert!(err("wait_for", json!({"machine": "m", "id": id, "until": "forever"})).contains("until"));
        assert!(err("wait_for", json!({"machine": "m", "id": id, "timeoutSeconds": 601})).contains("1 to 600"));
        let task = ok("create_task", json!({"machine": "m", "cwd": "~/app", "title": " Fix it ", "prompt": "fix the test", "agent": "", "base": " main "}));
        assert_eq!(task, json!({"machine": "m", "cwd": "~/app", "title": "Fix it", "prompt": "fix the test", "base": "main"}));
        assert!(err("create_task", json!({"machine": "m", "cwd": "~/app", "title": "x"})).contains("prompt is required"));
        assert!(err("create_task", json!({"machine": "m", "cwd": "~/app", "title": "x".repeat(201), "prompt": "p"})).contains("too long"));
        // A model is passed on as given, empty included; left out, it stays out.
        assert_eq!(ok("create_task", json!({"machine": "m", "cwd": "~/app", "title": "x", "prompt": "p", "model": ""}))["model"], "");
        assert_eq!(ok("create_task", json!({"machine": "m", "cwd": "~/app", "title": "x", "prompt": "p", "model": " opus "}))["model"], "opus");
        assert!(err("create_task", json!({"machine": "m", "cwd": "~/app", "title": "x", "prompt": "p", "model": 4})).contains("string"));
        assert_eq!(ok("list_tasks", Value::Null), json!({"limit": 20}));
        assert_eq!(ok("list_tasks", json!({"status": "pr_open", "machine": "m"})), json!({"limit": 20, "status": "pr_open", "machine": "m"}));
        assert!(err("list_tasks", json!({"status": "landed"})).contains("status must be"));
        assert_eq!(ok("list_tasks", json!({"status": "merged"})), json!({"limit": 20, "status": "merged"}));
        assert_eq!(ok("list_notes", json!({"q": "  "})), json!({"limit": 50}));
        assert_eq!(ok("list_notes", json!({"q": " plan ", "limit": 5})), json!({"limit": 5, "q": "plan"}));
        assert_eq!(ok("read_note", json!({"id": id, "section": " Rollout "})), json!({"id": id.to_lowercase(), "section": "Rollout"}));
        assert_eq!(ok("read_note", json!({"title": " Feature plan "})), json!({"title": "Feature plan"}));
        assert!(err("read_note", json!({})).contains("id or title"));
        assert!(err("read_note", json!({"id": "nope"})).contains("note id"));
        assert_eq!(ok("write_note", json!({"body": "# Plan", "title": " Plan "})), json!({"body": "# Plan", "title": "Plan"}));
        assert!(err("write_note", json!({"title": "x"})).contains("body is required"));
        assert!(err("write_note", json!({"body": "x".repeat(MAX_NOTE + 1)})).contains("too long"));
        assert_eq!(ok("append_note", json!({"id": id, "text": "- [ ] more"})), json!({"id": id.to_lowercase(), "text": "- [ ] more"}));
        assert!(err("append_note", json!({"id": id})).contains("text is required"));
        assert_eq!(ok("append_note", json!({"id": id, "text": "x", "version": 3}))["version"], 3);
        assert!(err("append_note", json!({"id": id, "text": "x", "version": 0})).contains("version"));
        assert_eq!(ok("write_note", json!({"id": id, "body": "x", "version": 7}))["version"], 7);
        assert!(err("write_note", json!({"body": "x", "version": 7})).contains("only goes with id"));
        assert!(err("write_note", json!({"id": id, "body": "x", "version": "7"})).contains("whole number"));
        // edit_note: exact text, not trimmed; new may be empty.
        let edit = ok("edit_note", json!({"id": id, "old": "  - [ ] a\n", "new": "", "version": 2}));
        assert_eq!(edit, json!({"id": id.to_lowercase(), "old": "  - [ ] a\n", "new": "", "version": 2}));
        assert_eq!(ok("edit_note", json!({"title": "Plan", "old": "a", "new": "b"})), json!({"title": "Plan", "old": "a", "new": "b"}));
        assert!(err("edit_note", json!({"id": id, "new": "b"})).contains("old is required"));
        assert!(err("edit_note", json!({"id": id, "old": "", "new": "b"})).contains("old can't be empty"));
        assert!(err("edit_note", json!({"id": id, "old": "a"})).contains("new is required"));
        assert!(err("edit_note", json!({"id": id, "old": "a", "new": 1})).contains("new must be a string"));
        assert!(err("edit_note", json!({"old": "a", "new": "b"})).contains("id or title"));
        assert!(err("edit_note", json!({"id": id, "old": "a", "new": "b", "version": 1.5})).contains("version"));
    }

    #[test]
    fn validates_project_arguments() {
        let ok = |tool: &str, args: Value| validate(tool, &args).unwrap();
        let err = |tool: &str, args: Value| validate(tool, &args).unwrap_err();
        // create_task takes a project instead of a folder, never both.
        let task = ok("create_task", json!({"machine": "m", "project": " acme/widgets ", "title": "Fix it", "prompt": "p"}));
        assert_eq!(task, json!({"machine": "m", "project": "acme/widgets", "title": "Fix it", "prompt": "p"}));
        assert!(err("create_task", json!({"machine": "m", "title": "x", "prompt": "p"})).contains("cwd or project is required"));
        assert!(err("create_task", json!({"machine": "m", "cwd": "~/app", "project": "acme/widgets", "title": "x", "prompt": "p"})).contains("not both"));
        assert_eq!(ok("list_projects", Value::Null), json!({}));
        assert_eq!(ok("get_project", json!({"repo": " acme/widgets "})), json!({"repo": "acme/widgets"}));
        assert!(err("get_project", json!({})).contains("repo is required"));
        let settings = json!({"test": "npm test", "proofKinds": ["test"]});
        assert_eq!(ok("save_project", json!({"repo": "acme/widgets", "settings": settings, "junk": 1})), json!({"repo": "acme/widgets", "settings": settings}));
        assert_eq!(ok("save_project", json!({"repo": "acme/widgets", "name": " Widgets ", "settings": {}}))["name"], "Widgets");
        assert!(err("save_project", json!({"repo": "acme/widgets"})).contains("settings is required"));
        assert!(err("save_project", json!({"repo": "acme/widgets", "settings": "npm test"})).contains("must be an object"));
        assert!(err("save_project", json!({"settings": {}})).contains("repo is required"));
    }

    #[test]
    fn validates_prove() {
        let ok = |args: Value| validate("prove", &args).unwrap();
        let err = |args: Value| validate("prove", &args).unwrap_err();
        let text = ok(json!({"criterion": 3, "kind": "test", "summary": " cleanup keeps a dirty worktree ", "text": "✔ cleanup (12ms)\nℹ pass 41", "junk": 1}));
        assert_eq!(text, json!({"criterion": 3, "kind": "test", "summary": "cleanup keeps a dirty worktree", "text": "✔ cleanup (12ms)\nℹ pass 41"}));
        let file = ok(json!({"criterion": 0, "kind": "screen", "summary": "Tasks at 390px", "file": " ~/.cache/maple-proof/agent/x/tasks-390.png "}));
        assert_eq!(file["file"], "~/.cache/maple-proof/agent/x/tasks-390.png");
        assert_eq!(file["criterion"], 0);
        // The number: whole, from 0.
        assert!(err(json!({"kind": "test", "summary": "s", "text": "t"})).contains("criterion is required"));
        assert!(err(json!({"criterion": -1, "kind": "test", "summary": "s", "text": "t"})).contains("whole number"));
        assert!(err(json!({"criterion": 1.5, "kind": "test", "summary": "s", "text": "t"})).contains("whole number"));
        assert!(err(json!({"criterion": "2", "kind": "test", "summary": "s", "text": "t"})).contains("whole number"));
        // The kind, and a one-line summary of at most 300 characters.
        assert!(err(json!({"criterion": 1, "kind": "video", "summary": "s", "text": "t"})).contains("test, command, terminal, screen"));
        assert!(err(json!({"criterion": 1, "kind": "test", "text": "t"})).contains("summary is required"));
        assert!(err(json!({"criterion": 1, "kind": "test", "summary": "x".repeat(301), "text": "t"})).contains("at most 300"));
        assert!(err(json!({"criterion": 1, "kind": "test", "summary": "a\nb", "text": "t"})).contains("one line"));
        // Exactly one of text (at most 64 KB) or file.
        assert!(err(json!({"criterion": 1, "kind": "test", "summary": "s"})).contains("Give the evidence"));
        assert!(err(json!({"criterion": 1, "kind": "test", "summary": "s", "text": "t", "file": "/f.png"})).contains("not both"));
        assert!(err(json!({"criterion": 1, "kind": "test", "summary": "s", "text": "x".repeat(MAX_PROOF_TEXT + 1)})).contains("at most 64 KB"));
        assert_eq!(
            ok(json!({"criterion": 1, "kind": "test", "summary": "s", "text": "x".repeat(MAX_PROOF_TEXT)}))["text"].as_str().unwrap().len(),
            MAX_PROOF_TEXT
        );
        assert!(err(json!({"criterion": 1, "kind": "test", "summary": "s", "text": " "})).contains("can't be empty"));
        assert!(err(json!({"criterion": 1, "kind": "test", "summary": "s", "file": 7})).contains("must be a string"));
    }

    #[test]
    fn validates_review() {
        let ok = |args: Value| validate("review", &args).unwrap();
        let err = |args: Value| validate("review", &args).unwrap_err();
        assert_eq!(
            ok(json!({"verdict": "changes", "summary": " Item 3 differs. ", "comments": [" web/src/tasks.ts:212 says 'kept' "], "junk": 1})),
            json!({"verdict": "changes", "summary": "Item 3 differs.", "comments": ["web/src/tasks.ts:212 says 'kept'"], "raiseRisk": null})
        );
        assert_eq!(ok(json!({"verdict": "approve", "summary": "All good.", "raiseRisk": " touches billing "}))["raiseRisk"], "touches billing");
        assert_eq!(ok(json!({"verdict": "approve", "summary": "All good.", "raiseRisk": null}))["comments"], json!([]));
        assert!(err(json!({"summary": "s"})).contains("verdict is required"));
        assert!(err(json!({"verdict": "maybe", "summary": "s"})).contains("approve"));
        assert!(err(json!({"verdict": "approve"})).contains("summary is required"));
        assert!(err(json!({"verdict": "approve", "summary": "s", "comments": "fix it"})).contains("list of strings"));
        assert!(err(json!({"verdict": "approve", "summary": "s", "comments": [1]})).contains("is a string"));
        assert!(err(json!({"verdict": "approve", "summary": "s", "comments": [" "]})).contains("non-empty"));
        assert!(err(json!({"verdict": "approve", "summary": "s", "comments": vec!["c"; 21]})).contains("At most 20"));
        assert!(err(json!({"verdict": "approve", "summary": "s", "comments": ["x".repeat(1001)]})).contains("at most 1000"));
        assert!(err(json!({"verdict": "approve", "summary": "s", "raiseRisk": "x".repeat(501)})).contains("at most 500"));
    }

    #[test]
    fn validates_card_arguments() {
        let id = "6F1C6A7E-2F6B-4D55-9B1A-2B7F0F6F0A11";
        let lower = id.to_lowercase();
        let ok = |tool: &str, args: Value| validate(tool, &args).unwrap();
        let err = |tool: &str, args: Value| validate(tool, &args).unwrap_err();
        assert_eq!(ok("list_cards", Value::Null), json!({}));
        assert_eq!(
            ok("list_cards", json!({"status": " review ", "project": " acme/widgets ", "junk": 1})),
            json!({"status": "review", "project": "acme/widgets"})
        );
        assert!(err("list_cards", json!({"status": "done"})).contains("drafting, review, approved, waiting, rejected, split, closed"));
        assert_eq!(ok("get_card", json!({"id": id})), json!({"id": lower}));
        assert!(err("get_card", json!({})).contains("id is required"));
        assert!(err("get_card", json!({"id": "card-1"})).contains("card id (a uuid)"));
        assert!(err("get_card", json!({"id": 7})).contains("must be a string"));
        // plan_card: a project and a one-line one-liner; a machine only when named.
        let plan = ok("plan_card", json!({"project": " acme/widgets ", "oneLiner": " Clean up worktrees ", "machine": " "}));
        assert_eq!(plan, json!({"project": "acme/widgets", "oneLiner": "Clean up worktrees"}));
        assert_eq!(ok("plan_card", json!({"project": "a/b", "oneLiner": "x", "machine": "studio"}))["machine"], "studio");
        assert!(err("plan_card", json!({"oneLiner": "x"})).contains("project is required"));
        assert!(err("plan_card", json!({"project": "a/b"})).contains("oneLiner is required"));
        assert!(err("plan_card", json!({"project": "a/b", "oneLiner": "a\nb"})).contains("one line"));
        assert!(err("plan_card", json!({"project": "a/b", "oneLiner": "x".repeat(201)})).contains("at most 200"));
        // approve_card: everything but the id is optional; a model is passed on as given, empty included.
        assert_eq!(ok("approve_card", json!({"id": id})), json!({"id": lower}));
        let full = ok("approve_card", json!({"id": id, "agent": " codex ", "model": " gpt-5.5 ", "machine": "laptop", "race": false}));
        assert_eq!(full, json!({"id": lower, "agent": "codex", "model": "gpt-5.5", "machine": "laptop"}));
        assert_eq!(ok("approve_card", json!({"id": id, "model": ""}))["model"], "");
        assert_eq!(ok("approve_card", json!({"id": id, "race": true})), json!({"id": lower, "race": true}));
        assert!(err("approve_card", json!({"id": id, "agent": "shell"})).contains("\"claude\" or \"codex\""));
        assert!(err("approve_card", json!({"id": id, "race": "yes"})).contains("true or false"));
        assert!(err("approve_card", json!({"id": id, "race": true, "model": "opus"})).contains("takes no model"));
        // notBefore is passed on as given (trimmed); the control plane checks the time.
        assert_eq!(ok("approve_card", json!({"id": id, "notBefore": " 2026-10-23T09:00:00Z "}))["notBefore"], "2026-10-23T09:00:00Z");
        assert_eq!(ok("approve_card", json!({"id": id, "notBefore": ""})), json!({"id": lower}));
        assert!(err("approve_card", json!({"id": id, "notBefore": 1})).contains("must be a string"));
        // first: passed on only when true.
        assert_eq!(ok("approve_card", json!({"id": id, "first": true})), json!({"id": lower, "first": true}));
        assert_eq!(ok("approve_card", json!({"id": id, "first": false})), json!({"id": lower}));
        assert!(err("approve_card", json!({"id": id, "first": "yes"})).contains("true or false"));
        // tweak_card needs a comment; split_card's how and reject_card's reason are optional.
        assert_eq!(ok("tweak_card", json!({"id": id, "comment": " also closed PRs "})), json!({"id": lower, "comment": "also closed PRs"}));
        assert!(err("tweak_card", json!({"id": id})).contains("comment is required"));
        assert!(err("tweak_card", json!({"id": id, "comment": "x".repeat(4001)})).contains("at most 4000"));
        assert_eq!(ok("split_card", json!({"id": id, "how": "  "})), json!({"id": lower}));
        assert_eq!(ok("split_card", json!({"id": id, "how": " table, then API "}))["how"], "table, then API");
        assert_eq!(ok("reject_card", json!({"id": id, "reason": " duplicate "})), json!({"id": lower, "reason": "duplicate"}));
        assert!(err("reject_card", json!({"id": id, "reason": "x".repeat(501)})).contains("at most 500"));
        assert!(err("reject_card", json!({"reason": "x"})).contains("id is required"));
    }

    #[test]
    fn validates_propose_cards() {
        let ok = |args: Value| validate("propose_cards", &args).unwrap();
        let err = |args: Value| validate("propose_cards", &args).unwrap_err();
        let one = json!([{"text": "Hold from the card page", "source": "Out of scope of “Auto-approve”"}]);
        assert_eq!(ok(json!({"oneLiners": one, "project": " ", "junk": 1})), json!({"oneLiners": one}));
        assert_eq!(ok(json!({"oneLiners": one, "project": " acme/widgets "}))["project"], "acme/widgets");
        // A 4th goes through: the control plane refuses it, saying why.
        assert_eq!(ok(json!({"oneLiners": [{}, {}, {}, {}]}))["oneLiners"].as_array().unwrap().len(), 4);
        assert!(err(json!({})).contains("oneLiners is required"));
        assert!(err(json!({"oneLiners": ["x"]})).contains("list of {text, source}"));
        let tools = tools();
        let tool = tools.as_array().unwrap().iter().find(|t| t["name"] == "propose_cards").unwrap();
        assert_eq!(tool["inputSchema"]["required"], json!(["oneLiners"]));
        assert_eq!(tool["inputSchema"]["properties"]["oneLiners"]["maxItems"], 3);
        assert!(tool["description"].as_str().unwrap().contains("Only for a scout session"));
    }

    #[test]
    fn validates_review_again() {
        let id = "6F1C6A7E-2F6B-4D55-9B1A-2B7F0F6F0A11";
        assert_eq!(validate("review_again", &json!({"taskId": format!(" {id} "), "junk": 1})).unwrap(), json!({"taskId": id.to_lowercase()}));
        assert!(validate("review_again", &json!({})).unwrap_err().contains("taskId is required"));
        assert!(validate("review_again", &json!({"taskId": "task-1"})).unwrap_err().contains("task id (a uuid)"));
        assert!(validate("review_again", &json!({"taskId": 7})).unwrap_err().contains("must be a string"));
        let tools = tools();
        let tool = tools.as_array().unwrap().iter().find(|t| t["name"] == "review_again").unwrap();
        assert_eq!(tool["inputSchema"]["required"], json!(["taskId"]));
        assert_eq!(tool["annotations"]["readOnlyHint"], false);
        assert!(tool["description"].as_str().unwrap().contains("Read and start sessions"));
    }

    #[test]
    fn validates_scout_now() {
        assert_eq!(validate("scout_now", &json!({"project": " acme/widgets ", "junk": 1})).unwrap(), json!({"project": "acme/widgets"}));
        assert_eq!(validate("scout_now", &json!({"project": " "})).unwrap(), json!({}));
        assert_eq!(validate("scout_now", &Value::Null).unwrap(), json!({}));
        assert!(validate("scout_now", &json!({"project": 7})).unwrap_err().contains("must be a string"));
        let tools = tools();
        let tool = tools.as_array().unwrap().iter().find(|t| t["name"] == "scout_now").unwrap();
        assert_eq!(tool["inputSchema"]["properties"]["project"]["type"], "string");
        assert!(tool["inputSchema"].get("required").is_none());
        assert_eq!(tool["annotations"], json!({"readOnlyHint": false, "destructiveHint": false, "openWorldHint": true}));
        assert!(tool["description"].as_str().unwrap().contains("Read and start sessions"));
    }

    #[test]
    fn validates_recheck_ci() {
        let id = "6F1C6A7E-2F6B-4D55-9B1A-2B7F0F6F0A11";
        assert_eq!(validate("recheck_ci", &json!({"taskId": format!(" {id} "), "junk": 1})).unwrap(), json!({"taskId": id.to_lowercase()}));
        assert!(validate("recheck_ci", &json!({})).unwrap_err().contains("taskId is required"));
        assert!(validate("recheck_ci", &json!({"taskId": "task-1"})).unwrap_err().contains("task id (a uuid)"));
        assert!(validate("recheck_ci", &json!({"taskId": 7})).unwrap_err().contains("must be a string"));
        let tools = tools();
        let tool = tools.as_array().unwrap().iter().find(|t| t["name"] == "recheck_ci").unwrap();
        assert_eq!(tool["title"], "Recheck a task's CI");
        assert_eq!(tool["inputSchema"]["required"], json!(["taskId"]));
        assert_eq!(tool["inputSchema"]["properties"]["taskId"]["type"], "string");
        assert_eq!(tool["annotations"], json!({ "readOnlyHint": false, "destructiveHint": false, "openWorldHint": true }));
        let says = tool["description"].as_str().unwrap();
        assert!(says.contains("Recheck CI") && says.contains("Read and start sessions"), "{says}");
    }

    #[test]
    fn card_tools_say_what_they_do() {
        let tools = tools();
        let tool = |name: &str| tools.as_array().unwrap().iter().find(|t| t["name"] == name).unwrap().clone();
        let says = |name: &str| tool(name)["description"].as_str().unwrap().split_whitespace().collect::<Vec<_>>().join(" ");
        // Reading is read-only; the rest need full mode, as start_session does.
        for name in ["list_cards", "get_card"] {
            assert_eq!(tool(name)["annotations"]["readOnlyHint"], true, "{name}");
            assert!(!says(name).contains("Read and start sessions"), "{name}");
        }
        for name in ["plan_card", "approve_card", "tweak_card", "split_card", "reject_card"] {
            assert_eq!(tool(name)["annotations"]["readOnlyHint"], false, "{name}");
            assert!(says(name).contains("Needs \"Read and start sessions\" in Settings → Agents."), "{name}");
        }
        let approve = says("approve_card");
        assert!(approve.contains("The task goes to Ready, where any machine with room takes it, unless you name a machine."), "{approve}");
        assert!(approve.contains("Low-risk work whose checks and review pass may merge to main on its own."), "{approve}");
        assert!(says("plan_card").contains("It reaches review when the planner's turn ends"));
        assert!(says("get_card").contains("in review with problems that block approval"));
        assert_eq!(tool("get_card")["inputSchema"]["required"], json!(["id"]));
        assert_eq!(tool("plan_card")["inputSchema"]["required"], json!(["project", "oneLiner"]));
        assert_eq!(tool("tweak_card")["inputSchema"]["required"], json!(["id", "comment"]));
        assert_eq!(tool("list_cards")["inputSchema"]["properties"]["status"]["enum"], json!(CARD_STATUSES));
    }

    /// Answers `wait_for` polls from a script of sessions; records every call.
    struct Fake {
        calls: StdMutex<Vec<(String, Value)>>,
        states: StdMutex<Vec<Value>>,
        slept: StdMutex<Duration>,
    }

    impl Fake {
        fn new(states: Vec<Value>) -> Self {
            Self { calls: StdMutex::default(), states: StdMutex::new(states), slept: StdMutex::default() }
        }
    }

    impl Backend for Fake {
        fn call(&self, tool: &str, args: &Value) -> Result<Value, String> {
            self.calls.lock().unwrap().push((tool.into(), args.clone()));
            if tool == "stop_session" {
                return Err("You can't stop your own session.".into());
            }
            let mut states = self.states.lock().unwrap();
            let s = if states.len() > 1 { states.remove(0) } else { states[0].clone() };
            Ok(json!({ "summary": "ok", "data": s }))
        }
        fn sleep(&self, d: Duration) {
            *self.slept.lock().unwrap() += d;
        }
    }

    fn text(result: &Value) -> &str {
        result["content"][0]["text"].as_str().unwrap()
    }

    #[test]
    fn wait_for_polls_until_the_state() {
        let id = "6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11";
        let s = |activity: &str| json!({ "title": "Fix it", "status": "running", "activity": activity });
        let fake = Fake::new(vec![s("working"), s("working"), s("done")]);
        let r = call_tool(&fake, "wait_for", &json!({ "machine": "m", "id": id }));
        assert_eq!(r["isError"], false);
        assert!(text(&r).starts_with("Fix it is done (after 4s)."), "{}", text(&r));
        let calls = fake.calls.lock().unwrap();
        assert_eq!(calls.len(), 3);
        assert_eq!(calls.iter().map(|(_, a)| a["poll"].as_u64().unwrap()).collect::<Vec<_>>(), [0, 1, 2]);
        assert!(calls.iter().all(|(t, _)| t == "wait_for"));
    }

    #[test]
    fn wait_for_times_out_and_counts_ending() {
        let id = "6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11";
        let fake = Fake::new(vec![json!({ "status": "running", "activity": "working" })]);
        let r = call_tool(&fake, "wait_for", &json!({ "machine": "m", "id": id, "until": "waiting", "timeoutSeconds": 5 }));
        assert!(text(&r).starts_with("Stopped waiting after 5s"), "{}", text(&r));
        assert!(text(&r).contains("\"timedOut\": true"));
        assert_eq!(*fake.slept.lock().unwrap(), Duration::from_secs(5));
        // An ended session ends any wait; "any" takes done or waiting.
        assert!(reached("done", &json!({ "status": "exited" })));
        assert!(reached("any", &json!({ "status": "running", "activity": "waiting" })));
        assert!(!reached("waiting", &json!({ "status": "running", "activity": "done" })));
        assert!(!reached("done", &json!({ "status": "running" })));
    }

    #[test]
    fn results_and_errors() {
        let fake = Fake::new(vec![json!([{ "id": "m1" }])]);
        let r = call_tool(&fake, "list_machines", &Value::Null);
        assert_eq!(r["isError"], false);
        assert!(text(&r).starts_with("ok\n\n[\n"), "{}", text(&r));
        let id = "6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11";
        let r = call_tool(&fake, "stop_session", &json!({ "machine": "m", "id": id }));
        assert_eq!((r["isError"].as_bool(), text(&r)), (Some(true), "You can't stop your own session."));
        // Bad arguments never reach the backend.
        let before = fake.calls.lock().unwrap().len();
        let r = call_tool(&fake, "read_output", &json!({ "machine": "m" }));
        assert_eq!(r["isError"], true);
        assert_eq!(fake.calls.lock().unwrap().len(), before);
        // Outside a session, every tool says where it works.
        let r = call_tool(&NoSession, "list_machines", &Value::Null);
        assert!(r["isError"].as_bool().unwrap() && text(&r).contains("inside a session"));
        // Text data is shown as is, not as a JSON string.
        assert_eq!(text(&tool_result("2 lines", Some(&json!("a\nb")), false)), "2 lines\n\na\nb");
    }
}
