//! Wire protocol between the runner and its RunnerHub Durable Object.
//!
//! Text frames carry JSON control messages. Binary frames carry terminal bytes:
//! `[16-byte session uuid][payload]`. Output flows runner → hub, input hub → runner.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// The largest WebSocket message (text or binary) the runner sends, in bytes.
///
/// Cloudflare closes a Worker's or Durable Object's WebSocket with 1009 when it receives a
/// message over 32 MiB (https://developers.cloudflare.com/workers/runtime-apis/websockets/,
/// raised from 1 MiB in October 2025). We stay well under that: a message this big already
/// takes seconds to reach a phone, and the hub parses and re-sends every one. Anything that
/// can grow (diffs, file lists, replays, reports) is cut to fit, and `connect` refuses to send
/// anything bigger. Keep in sync with `MAX_MESSAGE` in control/src/protocol.ts.
pub const MAX_MESSAGE: usize = 4 * 1024 * 1024;

/// Room for a message's envelope (type, ids, paths) around its one big field.
pub const ENVELOPE: usize = 64 * 1024;

/// Bytes `s` takes inside a JSON string, as serde_json writes it.
pub fn json_len(s: &str) -> usize {
    s.chars().map(json_char_len).sum()
}

fn json_char_len(c: char) -> usize {
    match c {
        '"' | '\\' | '\n' | '\r' | '\t' | '\u{8}' | '\u{c}' => 2,
        c if (c as u32) < 0x20 => 6,
        c => c.len_utf8(),
    }
}

/// Cuts `text` so it takes at most `budget` bytes as a JSON string, at the end of a line when
/// there is one. Returns whether anything was cut.
pub fn fit_text(text: &mut String, budget: usize) -> bool {
    let mut used = 0;
    let mut end = text.len();
    for (i, c) in text.char_indices() {
        used += json_char_len(c);
        if used > budget {
            end = i;
            break;
        }
    }
    if end == text.len() {
        return false;
    }
    let cut = text[..end].rfind('\n').map_or(end, |n| n + 1);
    text.truncate(cut);
    true
}

/// Keeps the end of `text` within `budget` JSON bytes, from the start of a line. Returns whether anything was cut.
pub fn fit_tail(text: &mut String, budget: usize) -> bool {
    let mut used = 0;
    let mut start = 0;
    for (i, c) in text.char_indices().rev() {
        used += json_char_len(c);
        if used > budget {
            start = i + c.len_utf8();
            break;
        }
    }
    if start == 0 {
        return false;
    }
    let from = text[start..].find('\n').map_or(start, |n| start + n + 1);
    text.drain(..from);
    true
}

/// Keeps the leading items of `items` whose JSON fits in `budget` bytes. Returns whether any were dropped.
pub fn fit_items<T: Serialize>(items: &mut Vec<T>, budget: usize) -> bool {
    let mut used = 2;
    for (i, item) in items.iter().enumerate() {
        used += serde_json::to_string(item).map_or(0, |j| j.len()) + 1;
        if used > budget {
            items.truncate(i);
            return true;
        }
    }
    false
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    pub id: Uuid,
    pub agent: String,
    pub cwd: String,
    pub pid: Option<u32>,
    pub started_at: u64,
}

/// What an agent's hooks last said about a session, with the hub's merge rules already applied
/// (see `AgentState::next`). `at` is this runner's clock, strictly increasing across events.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AgentState {
    pub state: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub question: Option<serde_json::Value>,
    pub at: u64,
    /// The last tool Claude was about to use, as a permission payload (`hooks::permission`): what a
    /// bare "needs your permission" notification is about when the PermissionRequest hook didn't say.
    #[serde(skip)]
    pub pending_tool: Option<serde_json::Value>,
}

/// Messages the runner sends.
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Outbound {
    /// The agents changed (agents.toml was edited); replaces `hello`'s list.
    #[serde(rename = "agents")]
    Agents { agents: Vec<crate::agents::Advertised> },
    #[serde(rename = "session.error")]
    SessionError { id: Uuid, message: String },
    /// The bottom lines of a watched session's screen (`thumbs.watch`), with colours, sent when they change.
    /// `scrollback`: how many of the first lines are history above the visible screen (only when
    /// the watch asked for `history`, as a peek does).
    #[serde(rename = "thumb")]
    Thumb {
        id: Uuid,
        lines: Vec<String>,
        cols: u16,
        at: u64,
        #[serde(skip_serializing_if = "is_zero")]
        scrollback: usize,
    },
    /// A GitHub token to push a finishing task's branch to owner/repo (answered with `task.token`).
    #[serde(rename = "task.token_request")]
    TaskTokenRequest {
        req_id: String,
        task_id: String,
        owner: String,
        repo: String,
        /// "fetch": a read-only token to fetch (or clone) a starting task's repo; "handoff": to push a
        /// task's branch before it moves to another machine. None: to push a finishing task's.
        #[serde(skip_serializing_if = "Option::is_none")]
        purpose: Option<&'static str>,
    },
    /// A repo's secrets (answered with `secrets.reply`): for a task this machine is running, or with no
    /// task for its owner's own checkout (`maple-runner secrets pull`). See `secrets`.
    #[serde(rename = "secrets.request")]
    SecretsRequest {
        req_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        task_id: Option<String>,
        repo: String,
    },
    /// A task's session is starting: its repo, and the project and `.factory.toml` it got (see `factory`).
    #[serde(rename = "task.started")]
    TaskStarted {
        task_id: String,
        repo: Option<String>,
        /// The checkout the worktree was made from (`~`-abbreviated), and the branch it started from.
        repo_dir: String,
        base: String,
        project: Option<String>,
        factory: Option<crate::factory::FileReport>,
        /// The rules its PR's risk is held to (the merged settings); None without a project.
        rules: Option<crate::factory::Rules>,
    },
    /// Where this machine keeps each GitHub repository (see `repos`); on connect and when it changes.
    #[serde(rename = "repos")]
    Repos { repos: Vec<crate::repos::Checkout> },
    /// How `task.finish` went.
    #[serde(rename = "task.finished")]
    TaskFinished {
        task_id: String,
        ok: bool,
        /// "app" (GitHub App token; the hub opens the PR) or "fallback" (origin, machine credentials, no PR).
        #[serde(skip_serializing_if = "Option::is_none")]
        pushed: Option<&'static str>,
        #[serde(skip_serializing_if = "Option::is_none")]
        owner: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        repo: Option<String>,
        branch: String,
        base: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        commit: Option<String>,
        /// Why the app couldn't push, when the fallback did.
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        /// What went wrong, when `ok` is false.
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    /// How `task.handoff` went: the branch is on origin at `commit`, or `message` says why not.
    #[serde(rename = "task.handed_off")]
    TaskHandedOff {
        task_id: String,
        ok: bool,
        /// "app" or "fallback", as for `task.finished`.
        #[serde(skip_serializing_if = "Option::is_none")]
        pushed: Option<&'static str>,
        #[serde(skip_serializing_if = "Option::is_none")]
        commit: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    /// A task's check is starting (`n` of `of`), for the Tasks list.
    #[serde(rename = "task.check")]
    TaskCheck { task_id: String, command: String, n: usize, of: usize },
    /// How `task.prove` went: each check that ran, the ones that didn't (after a failure), the
    /// screens captured once they all passed, and the worktree's HEAD; or why they couldn't run at all.
    #[serde(rename = "task.proved")]
    TaskProved {
        task_id: String,
        results: Vec<crate::proof::CheckResult>,
        not_run: Vec<String>,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        screens: Vec<crate::proof::ScreenProof>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// What a Draft with AI run is doing (see `draft`).
    #[serde(rename = "draft.progress")]
    DraftProgress { id: String, text: String, kind: crate::wire::DraftLineKind },
    /// A Draft with AI run finished: the agent's last message, or why it couldn't.
    #[serde(rename = "draft.done")]
    DraftDone { id: String, output: Option<String>, error: Option<String> },
    /// A line for a task's timeline: one of its repo's worktree scripts ran (see `worktree_scripts`).
    #[serde(rename = "task.progress")]
    TaskProgress { task_id: String, text: String },
    /// How `task.cleanup` went: the worktree (and branch) removed, or why not.
    #[serde(rename = "task.cleaned")]
    TaskCleaned { task_id: String, ok: bool, branch_deleted: bool, message: Option<String> },
    /// Scrollback for one attaching browser, routed by `nonce`.
    #[serde(rename = "session.replay")]
    SessionReplay { id: Uuid, nonce: String, data: String },
    /// How `task.merge` went.
    #[serde(rename = "task.merged")]
    TaskMerged { task_id: String, ok: bool, commit: Option<String>, message: Option<String> },
    /// How an update the hub asked for (`runner.update`) is going. `version` is the latest
    /// release's, once known. `updating` is sent just before the runner exits to restart
    /// into the new build.
    #[serde(rename = "update.status")]
    RunnerUpdateStatus { state: UpdateState, version: Option<String>, message: Option<String> },
    /// Machine vitals, every 10s.
    /// Git state of session directories, sent when it changes.
    #[serde(rename = "git")]
    Git { sessions: Vec<GitReport> },
    /// Sent only when a requested restart can't happen.
    #[serde(rename = "runner.restart_status")]
    RunnerRestartStatus { message: String },
    /// Listening ports and how to reach them on the tailnet; sent when they change and every minute.
    #[serde(rename = "ports")]
    Ports(crate::ports::Report),
    /// A `port.share` / `port.unshare` that didn't work.
    #[serde(rename = "port.error")]
    PortError { port: u16, message: String },
    /// Worktrees of every repo sessions have used; on change and every minute.
    #[serde(rename = "worktrees")]
    Worktrees { repos: Vec<crate::worktrees::Repo> },
    /// Plan usage limits (5-hour and weekly windows), only the agents whose reading changed;
    /// all of them again on reconnect.
    #[serde(rename = "usage")]
    Usage { agents: Vec<crate::usage::AgentUsage> },
    /// Why `worktree.remove` didn't; `session` when the hub named one (an ended setup session or planner).
    #[serde(rename = "worktree.error")]
    WorktreeError {
        path: String,
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        session: Option<String>,
    },
    /// `worktree.remove` for a session the hub named: it's gone.
    #[serde(rename = "worktree.removed")]
    WorktreeRemoved { path: String, session: String },
    /// Folders for the directory picker, answering `fs.list` / `fs.mkdir` by `req_id`.
    #[serde(rename = "fs.listing")]
    FsListing {
        req_id: String,
        path: String,
        entries: Vec<crate::fs_browse::Entry>,
        #[serde(skip_serializing_if = "std::ops::Not::not")]
        truncated: bool,
        /// The folder `fs.mkdir` made.
        #[serde(skip_serializing_if = "Option::is_none")]
        created: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// A tool call from the `agents` MCP server inside `session`, for the hub to run
    /// (answered with `mcp.response` by `req_id`).
    #[serde(rename = "mcp.request")]
    McpRequest { req_id: String, session: Uuid, tool: String, args: serde_json::Value },
    /// A session's screen and recent history as plain text, answering `session.capture`.
    #[serde(rename = "session.captured")]
    SessionCaptured {
        req_id: String,
        text: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// Answers `task.images`: each image's local path or why it isn't there, or `error` for them all.
    #[serde(rename = "task.images.fetched")]
    TaskImagesFetched {
        req_id: String,
        got: Vec<ImageGot>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// Answers `folder.*` by `req_id`: a `kind`ed payload, or `error`.
    #[serde(rename = "folder.result")]
    FolderResult {
        req_id: String,
        #[serde(flatten)]
        result: FolderReply,
    },
    /// The head of a share link's response (`http.request`); the body follows in
    /// `http.response.body` chunks, the last with `end`.
    #[serde(rename = "http.response")]
    HttpResponse { req_id: String, status: u16, headers: Vec<(String, String)> },
    /// Up to `proxy::CHUNK` bytes of a response body, base64.
    #[serde(rename = "http.response.body")]
    HttpResponseBody { req_id: String, data: String, end: bool },
    /// An `http.request` that couldn't be made (or a body that broke off part way).
    #[serde(rename = "http.error")]
    HttpError { req_id: String, status: u16, message: String },
    /// Answers `file.stat` by `req_id`: whether a path printed in a terminal exists, and what it is.
    #[serde(rename = "file.info")]
    FileInfo {
        req_id: String,
        #[serde(flatten)]
        stat: crate::media::Stat,
    },
    /// Answers `file.read` by `req_id`: one piece of a file, or `error`.
    #[serde(rename = "file.chunk")]
    FileChunk {
        req_id: String,
        #[serde(flatten)]
        result: ChunkReply,
    },
    /// A message from the shared protocol (protocol/schema.ts), which carries its own `type`.
    #[serde(untagged)]
    Wire(crate::wire::RunnerMessage),
}

impl Outbound {
    /// What to send instead of this message when it came out bigger than `MAX_MESSAGE`
    /// (`size` bytes): an error for the request it answers, or nothing for a report.
    pub fn oversized(&self, size: usize) -> Option<Outbound> {
        let message = format!("The answer was too big to send ({:.1} MB).", size as f64 / (1024.0 * 1024.0));
        match self {
            Outbound::FolderResult { req_id, .. } => Some(Outbound::FolderResult { req_id: req_id.clone(), result: FolderReply::Err { error: message } }),
            Outbound::FsListing { req_id, path, .. } => {
                Some(Outbound::FsListing { req_id: req_id.clone(), path: path.clone(), entries: vec![], truncated: false, created: None, error: Some(message) })
            }
            Outbound::SessionCaptured { req_id, .. } => Some(Outbound::SessionCaptured { req_id: req_id.clone(), text: String::new(), error: Some(message) }),
            Outbound::TaskImagesFetched { req_id, .. } => Some(Outbound::TaskImagesFetched { req_id: req_id.clone(), got: vec![], error: Some(message) }),
            // Reports (ports, worktrees, git) are re-sent on change; a replay that never comes
            // leaves the browser's terminal as it is after a few seconds.
            _ => None,
        }
    }
}

/// One of `task.images`' files: where the runner put it, or why it couldn't.
#[derive(Debug, Serialize, PartialEq)]
pub struct ImageGot {
    pub file: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum ChunkReply {
    Ok(crate::media::Chunk),
    Err { error: String },
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum FolderReply {
    Ok(crate::folder::Payload),
    Err { error: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UpdateState {
    Checking,
    /// Downloading and checking the new build (hub-requested runs only).
    Installing,
    UpToDate,
    Updating,
    Failed,
}

/// Messages the hub sends.
#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum Inbound {
    #[serde(rename = "session.open")]
    SessionOpen {
        id: Uuid,
        agent: String,
        cwd: String,
        #[serde(default)]
        prompt: Option<String>,
        cols: u16,
        rows: u16,
        /// Start in a new (or existing) git worktree instead of `cwd` itself.
        #[serde(default)]
        worktree: Option<crate::worktrees::Request>,
        /// The task it runs, and the projects to find its repo's in.
        #[serde(default)]
        task: Option<crate::factory::TaskStart>,
        /// The model Claude Code or Codex starts on (`--model`); other agents ignore it.
        #[serde(default)]
        model: Option<String>,
        /// A factory session's permission prompts (Settings → Factory): the agent's flags for them.
        #[serde(default)]
        unattended: Option<crate::agents::Unattended>,
        /// A task's builder: the stored files its card's images are (`images`), fetched to local files.
        #[serde(default)]
        images: Vec<String>,
        /// Reopen: continue the agent's last conversation in `cwd` (Claude Code and Codex; others ignore it).
        #[serde(default)]
        resume: bool,
        /// The factory's MCP connectors, secrets included (Settings → Connectors), beside `maple`.
        #[serde(default)]
        connectors: Option<Vec<crate::wire::McpConnector>>,
    },
    #[serde(rename = "session.resize")]
    SessionResize { id: Uuid, cols: u16, rows: u16 },
    #[serde(rename = "session.kill")]
    SessionKill { id: Uuid },
    #[serde(rename = "session.replay")]
    SessionReplay { id: Uuid, nonce: String },
    /// Check for a newer runner now and install it (answered with `runner.update_status`).
    #[serde(rename = "runner.update")]
    RunnerUpdate,
    /// Restart the runner process; its service starts it again. Sessions live on in tmux.
    #[serde(rename = "runner.restart")]
    RunnerRestart,
    /// Share a localhost-only port on the tailnet with `tailscale serve`.
    #[serde(rename = "port.share")]
    PortShare { port: u16 },
    /// Stop sharing it.
    #[serde(rename = "port.unshare")]
    PortUnshare { port: u16 },
    /// Remove a worktree if nothing would be lost. `session`: the ended setup session or planner it was
    /// made for, named in the answer (`worktree.removed` / `worktree.error`). `force`: throw away
    /// uncommitted changes in a merged worktree (the Worktrees view's Force remove).
    #[serde(rename = "worktree.remove")]
    WorktreeRemove {
        path: String,
        #[serde(default)]
        session: Option<String>,
        #[serde(default)]
        force: bool,
    },
    #[serde(rename = "fs.list")]
    FsList {
        #[serde(rename = "reqId")]
        req_id: String,
        #[serde(default)]
        path: String,
        /// Include dot folders (the user typed a leading `.`).
        #[serde(default)]
        hidden: bool,
    },
    #[serde(rename = "fs.mkdir")]
    FsMkdir {
        #[serde(rename = "reqId")]
        req_id: String,
        path: String,
    },
    /// The folder page's file list.
    #[serde(rename = "folder.files")]
    FolderFiles {
        #[serde(rename = "reqId")]
        req_id: String,
        path: String,
    },
    /// Branch and changed files.
    #[serde(rename = "folder.status")]
    FolderStatus {
        #[serde(rename = "reqId")]
        req_id: String,
        path: String,
    },
    /// One file's diff against HEAD (`oldFile`: a rename's old path).
    #[serde(rename = "folder.diff")]
    FolderDiff {
        #[serde(rename = "reqId")]
        req_id: String,
        path: String,
        file: String,
        #[serde(default, rename = "oldFile")]
        old_file: Option<String>,
    },
    /// One file's contents.
    #[serde(rename = "folder.read")]
    FolderRead {
        #[serde(rename = "reqId")]
        req_id: String,
        path: String,
        file: String,
    },
    /// What a path is: `path` is absolute, `~/…` or relative to the session's current folder
    /// (`session`, read from tmux) or else `cwd`.
    #[serde(rename = "file.stat")]
    FileStat {
        #[serde(rename = "reqId")]
        req_id: String,
        path: String,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        session: Option<Uuid>,
    },
    /// Up to `length` bytes (at most 512 KB) of a file from `offset`.
    #[serde(rename = "file.read")]
    FileRead {
        #[serde(rename = "reqId")]
        req_id: String,
        path: String,
        #[serde(default)]
        offset: u64,
        #[serde(default = "default_chunk")]
        length: u64,
    },
    /// The hub's answer to an `mcp.request`: `result` or `error`.
    #[serde(rename = "mcp.response")]
    McpResponse {
        #[serde(rename = "reqId")]
        req_id: String,
        #[serde(default)]
        result: Option<serde_json::Value>,
        #[serde(default)]
        error: Option<String>,
    },
    /// Plain text of a session's last `lines` lines (for the MCP `read_output` tool).
    #[serde(rename = "session.capture")]
    SessionCapture {
        #[serde(rename = "reqId")]
        req_id: String,
        id: Uuid,
        #[serde(default = "default_capture_lines")]
        lines: u32,
    },
    /// A share link's request for `127.0.0.1:<port>` (see `proxy`).
    #[serde(rename = "http.request")]
    HttpRequest(crate::proxy::Head),
    /// More of that request's body.
    #[serde(rename = "http.request.body")]
    HttpRequestBody {
        #[serde(rename = "reqId")]
        req_id: String,
        #[serde(default)]
        data: String,
        #[serde(default)]
        end: bool,
    },
    /// The visitor's browser took `bytes` more of the response: send that much more.
    #[serde(rename = "http.ack")]
    HttpAck {
        #[serde(rename = "reqId")]
        req_id: String,
        bytes: u32,
    },
    /// The visitor went away (or the hub gave up): stop.
    #[serde(rename = "http.cancel")]
    HttpCancel {
        #[serde(rename = "reqId")]
        req_id: String,
    },
    /// Commit and push a task's worktree (see `tasks`).
    #[serde(rename = "task.finish")]
    TaskFinish(crate::tasks::Finish),
    /// Push a task's branch, uncommitted changes and all, before it moves to another machine (see `tasks`).
    #[serde(rename = "task.handoff")]
    TaskHandoff(crate::tasks::Handoff),
    /// Run a task's checks before it's finished (see `proof`).
    #[serde(rename = "task.prove")]
    TaskProve(crate::proof::Prove),
    /// Run Draft with AI's agent once, read-only (see `draft`).
    #[serde(rename = "draft.run")]
    DraftRun(crate::draft::Run),
    #[serde(rename = "draft.cancel")]
    DraftCancel { id: String },
    /// Sign an agent in with a device code, or cancel that (see `agent_login`).
    #[serde(rename = "agent.login")]
    AgentLogin {
        agent: String,
        #[serde(default)]
        cancel: bool,
    },
    /// Remove a merged or closed task's worktree and local branch (see `worktrees::remove_task`).
    #[serde(rename = "task.cleanup")]
    TaskCleanup(crate::tasks::Cleanup),
    /// Fetch images sent with Ask the builder into the task's folder before the ask is typed (see
    /// `images::fetch_for`); answered with `task.images.fetched` by `req_id`.
    #[serde(rename = "task.images")]
    TaskImages {
        #[serde(rename = "reqId")]
        req_id: String,
        #[serde(rename = "taskId")]
        task_id: String,
        #[serde(default)]
        files: Vec<String>,
    },
    /// Report a task's diff against its base (see `tasks::run_diff`).
    #[serde(rename = "task.diff")]
    TaskDiff(crate::tasks::DiffRequest),
    /// Dry-run merging a task's branch into its base (see `tasks::run_merge_check`).
    #[serde(rename = "task.merge_check")]
    TaskMergeCheck(crate::tasks::MergeCheck),
    /// Merge a task's branch into its base on origin (see `tasks::run_merge`).
    #[serde(rename = "task.merge")]
    TaskMerge(crate::tasks::Merge),
    /// The hub's answer to `task.token_request`: `token`, or `error` with a `code`.
    #[serde(rename = "task.token")]
    TaskToken {
        #[serde(rename = "reqId")]
        req_id: String,
        #[serde(default)]
        token: Option<String>,
        #[serde(default)]
        error: Option<String>,
        #[serde(default)]
        code: Option<String>,
    },
    /// The hub's answer to `secrets.request`: `values` by name, or `error` with a `code`.
    #[serde(rename = "secrets.reply")]
    SecretsReply {
        #[serde(rename = "reqId")]
        req_id: String,
        #[serde(default)]
        values: Option<std::collections::BTreeMap<String, String>>,
        #[serde(default)]
        error: Option<String>,
        #[serde(default)]
        code: Option<String>,
    },
    /// Settings → Usage: whether to run Claude Code's `/usage` in the background (see `usage`).
    #[serde(rename = "usage.config")]
    UsageConfig {
        #[serde(rename = "claudeCheck", default = "yes")]
        claude_check: bool,
    },
    /// Refresh on an agent's card on the Usage page: ask that agent for its limits now.
    #[serde(rename = "usage.refresh")]
    UsageRefresh { agent: String },
    /// The sessions some browser shows a thumbnail of (the union over the hub's browsers);
    /// replaces the last list. `fresh`: just started watching, so send one even if unchanged.
    #[serde(rename = "thumbs.watch")]
    ThumbsWatch {
        #[serde(default)]
        sessions: Vec<crate::thumbs::Watch>,
        #[serde(default)]
        fresh: Vec<Uuid>,
    },
    #[serde(other)]
    Unknown,
}

fn is_zero(n: &usize) -> bool {
    *n == 0
}

fn yes() -> bool {
    true
}

fn default_capture_lines() -> u32 {
    200
}

fn default_chunk() -> u64 {
    crate::media::MAX_CHUNK
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GitReport {
    pub id: Uuid,
    #[serde(flatten)]
    pub git: crate::git::GitState,
}

pub fn encode_frame(id: Uuid, payload: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(16 + payload.len());
    frame.extend_from_slice(id.as_bytes());
    frame.extend_from_slice(payload);
    frame
}

pub fn decode_frame(frame: &[u8]) -> Option<(Uuid, &[u8])> {
    if frame.len() < 16 {
        return None;
    }
    let id = Uuid::from_slice(&frame[..16]).ok()?;
    Some((id, &frame[16..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_a_newer_server_adds_still_decode() {
        use crate::wire::{EndCause, HandReason, TaskState};
        let reason: HandReason = serde_json::from_str(r#""somethingNew""#).unwrap();
        assert_eq!(reason, HandReason::Other);
        assert_eq!(serde_json::from_str::<HandReason>(r#""mergeFailed""#).unwrap(), HandReason::MergeFailed);
        assert_eq!(serde_json::from_str::<TaskState>(r#""somethingNew""#).unwrap(), TaskState::Other);
        // EndCause has its own `unknown`, which doubles as the catch-all.
        assert_eq!(serde_json::from_str::<EndCause>(r#""somethingNew""#).unwrap(), EndCause::Unknown);
        // A whole message the runner doesn't know is still dropped, not fatal.
        let msg: Inbound = serde_json::from_str(r#"{"type":"something.new","reason":"somethingNew"}"#).unwrap();
        assert!(matches!(msg, Inbound::Unknown));
    }

    #[test]
    fn update_messages() {
        let msg: Inbound = serde_json::from_str(r#"{"type":"runner.update"}"#).unwrap();
        assert!(matches!(msg, Inbound::RunnerUpdate));
        let msg: Inbound = serde_json::from_str(r#"{"type":"runner.something_new","x":1}"#).unwrap();
        assert!(matches!(msg, Inbound::Unknown));

        let out = |state, version: Option<&str>, message: Option<&str>| {
            serde_json::to_value(Outbound::RunnerUpdateStatus { state, version: version.map(Into::into), message: message.map(Into::into) }).unwrap()
        };
        assert_eq!(
            out(UpdateState::Updating, Some("0.2.0"), Some("installed 0.2.0; restarting")),
            serde_json::json!({"type":"update.status","state":"updating","version":"0.2.0","message":"installed 0.2.0; restarting"})
        );
        assert_eq!(out(UpdateState::Checking, None, None), serde_json::json!({"type":"update.status","state":"checking","version":null,"message":null}));
        assert_eq!(out(UpdateState::UpToDate, Some("0.1.0"), None)["state"], "up_to_date");
        assert_eq!(out(UpdateState::Installing, Some("0.2.0"), None)["state"], "installing");
        assert_eq!(out(UpdateState::Failed, None, Some("x"))["state"], "failed");
    }

    #[test]
    fn hello_says_it_takes_a_model() {
        let msg: Inbound = serde_json::from_str(
            r#"{"type":"session.open","id":"6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11","agent":"claude","cwd":"~/x","cols":80,"rows":24,"model":"claude-opus-5-5"}"#,
        )
        .unwrap();
        assert!(matches!(msg, Inbound::SessionOpen { model: Some(m), resume: false, .. } if m == "claude-opus-5-5"));
        let reopen: Inbound = serde_json::from_str(
            r#"{"type":"session.open","id":"6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11","agent":"claude","cwd":"~/x","cols":80,"rows":24,"resume":true}"#,
        )
        .unwrap();
        assert!(matches!(reopen, Inbound::SessionOpen { resume: true, .. }));
        let ended = serde_json::to_value(Outbound::Wire(crate::wire::RunnerMessage::Health {
            health: crate::wire::Health {
                cpu: 0.5,
                cores: 8,
                load1: 1.0,
                mem_used: 1,
                mem_total: 2,
                disk_used: 1,
                disk_total: 2,
                uptime: 3,
                battery: None,
                agents: vec![],
            },
        }))
        .unwrap();
        assert_eq!(ended["type"], "health");
        assert_eq!(ended["health"]["memTotal"], 2);
    }

    #[test]
    fn session_open_takes_unattended() {
        let msg: Inbound = serde_json::from_str(
            r#"{"type":"session.open","id":"6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11","agent":"claude","cwd":"","cols":80,"rows":24,"unattended":{"mode":"project","commands":["npm test"]}}"#,
        )
        .unwrap();
        let Inbound::SessionOpen { unattended: Some(u), .. } = msg else { panic!() };
        assert_eq!((u.mode, u.commands), (crate::agents::UnattendedMode::Project, vec!["npm test".to_string()]));
    }

    #[test]
    fn session_open_takes_a_tasks_images() {
        let msg: Inbound = serde_json::from_str(
            r#"{"type":"session.open","id":"6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11","agent":"codex","cwd":"","cols":80,"rows":24,"images":["3f9c1a2b-a.png","77d0e4aa-b.jpg"]}"#,
        )
        .unwrap();
        let Inbound::SessionOpen { images, .. } = msg else { panic!() };
        assert_eq!(images, ["3f9c1a2b-a.png", "77d0e4aa-b.jpg"]);
        // An older hub's, without them.
        let msg: Inbound =
            serde_json::from_str(r#"{"type":"session.open","id":"6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11","agent":"codex","cwd":"","cols":80,"rows":24}"#)
                .unwrap();
        let Inbound::SessionOpen { images, .. } = msg else { panic!() };
        assert!(images.is_empty());
    }

    #[test]
    fn worktree_and_fs_messages() {
        let msg: Inbound = serde_json::from_str(
            r#"{"type":"session.open","id":"6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11","agent":"shell","cwd":"~/x","cols":80,"rows":24,"worktree":{"name":"fix","base":"main"}}"#,
        )
        .unwrap();
        let Inbound::SessionOpen { worktree: Some(w), model: None, .. } = msg else { panic!() };
        assert_eq!((w.name.as_str(), w.base.as_deref(), w.existing), ("fix", Some("main"), false));
        let msg: Inbound = serde_json::from_str(
            r#"{"type":"session.open","id":"6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11","agent":"claude","cwd":"~/w","cols":80,"rows":24,"worktree":{"name":"fix","existing":true}}"#,
        )
        .unwrap();
        let Inbound::SessionOpen { worktree: Some(w), .. } = msg else { panic!() };
        assert!(w.existing);
        let msg: Inbound = serde_json::from_str(r#"{"type":"fs.list","reqId":"r1","path":"~"}"#).unwrap();
        assert!(matches!(msg, Inbound::FsList { req_id, hidden: false, .. } if req_id == "r1"));
        let out = serde_json::to_value(Outbound::FsListing {
            req_id: "r1".into(),
            path: "~".into(),
            entries: vec![crate::fs_browse::Entry { name: "app".into(), is_repo: true }],
            truncated: false,
            created: None,
            error: None,
        })
        .unwrap();
        assert_eq!(out, serde_json::json!({"type":"fs.listing","reqId":"r1","path":"~","entries":[{"name":"app","isRepo":true}]}));
    }

    #[test]
    fn folder_messages() {
        let msg: Inbound = serde_json::from_str(r#"{"type":"folder.diff","reqId":"r2","path":"~/app","file":"src/new.rs","oldFile":"src/old.rs"}"#).unwrap();
        assert!(
            matches!(msg, Inbound::FolderDiff { ref req_id, ref file, old_file: Some(ref old), .. } if req_id == "r2" && file == "src/new.rs" && old == "src/old.rs")
        );
        let msg: Inbound = serde_json::from_str(r#"{"type":"folder.read","reqId":"r3","path":"~/app","file":"a"}"#).unwrap();
        assert!(matches!(msg, Inbound::FolderRead { .. }));
        let out = serde_json::to_value(Outbound::FolderResult {
            req_id: "r3".into(),
            result: FolderReply::Ok(crate::folder::Payload::Read { path: "~/app".into(), file: "a".into(), contents: "x".into(), size: 1, binary: false }),
        })
        .unwrap();
        assert_eq!(
            out,
            serde_json::json!({"type":"folder.result","reqId":"r3","kind":"read","path":"~/app","file":"a","contents":"x","size":1,"binary":false})
        );
        let out = serde_json::to_value(Outbound::FolderResult { req_id: "r4".into(), result: FolderReply::Err { error: "nope".into() } }).unwrap();
        assert_eq!(out, serde_json::json!({"type":"folder.result","reqId":"r4","error":"nope"}));
    }

    #[test]
    fn fitting_text_counts_json_escapes() {
        assert_eq!(json_len("a\"\n\u{1}é"), 1 + 2 + 2 + 6 + 2);
        assert_eq!(json_len("x"), serde_json::to_string("x").unwrap().len() - 2);
        let sample = "tab\there \"quoted\" \u{1b}[0m é 😀\r\n";
        assert_eq!(json_len(sample), serde_json::to_string(sample).unwrap().len() - 2);

        let mut text = "one\ntwo\nthree\n".to_string();
        assert!(!fit_text(&mut text, 100));
        assert!(fit_text(&mut text, 10));
        assert_eq!(text, "one\ntwo\n");
        // Escapes count: six control bytes take 36 JSON bytes.
        let mut text = "\u{1}".repeat(6);
        assert!(fit_text(&mut text, 20));
        assert_eq!(text.len(), 3);

        let mut text = "one\ntwo\nthree\n".to_string();
        assert!(fit_tail(&mut text, 12));
        assert_eq!(text, "three\n");
        assert!(!fit_tail(&mut text, 100));

        let mut items = vec!["aaaa".to_string(); 10];
        assert!(fit_items(&mut items, 30));
        assert!(serde_json::to_string(&items).unwrap().len() <= 30);
        assert_eq!(items.len(), 4);
    }

    #[test]
    fn oversized_answers_become_errors() {
        let big = Outbound::FolderResult {
            req_id: "r1".into(),
            result: FolderReply::Ok(crate::folder::Payload::Read { path: "~".into(), file: "a".into(), contents: "x".into(), size: 1, binary: false }),
        };
        let out = serde_json::to_value(big.oversized(5 * 1024 * 1024).unwrap()).unwrap();
        assert_eq!(out, serde_json::json!({"type":"folder.result","reqId":"r1","error":"The answer was too big to send (5.0 MB)."}));
        assert!(Outbound::Worktrees { repos: vec![] }.oversized(1).is_none());
    }

    #[test]
    fn http_messages() {
        let msg: Inbound = serde_json::from_str(
            r#"{"type":"http.request","reqId":"h1","port":3000,"method":"GET","path":"/a?b","headers":[["accept","*/*"]],"origin":"https://x.share.example.com","end":true}"#,
        )
        .unwrap();
        let Inbound::HttpRequest(head) = msg else { panic!() };
        assert_eq!((head.req_id.as_str(), head.port, head.path.as_str(), head.end, head.body), ("h1", 3000, "/a?b", true, None));
        assert_eq!(head.headers, vec![("accept".to_string(), "*/*".to_string())]);
        assert_eq!((head.host, head.local_domain, head.base), (None, None, None));
        let msg: Inbound = serde_json::from_str(
            r#"{"type":"http.request","reqId":"h2","port":3000,"method":"GET","path":"/","origin":"https://x--acme.share.example.com","host":"acme.lvh.me:3000","localDomain":"lvh.me","base":"https://x.share.example.com","end":true}"#,
        )
        .unwrap();
        let Inbound::HttpRequest(head) = msg else { panic!() };
        assert_eq!(head.host.as_deref(), Some("acme.lvh.me:3000"));
        assert_eq!(head.local_domain.as_deref(), Some("lvh.me"));
        assert_eq!(head.base.as_deref(), Some("https://x.share.example.com"));
        let msg: Inbound = serde_json::from_str(r#"{"type":"http.request.body","reqId":"h1","data":"aGk=","end":true}"#).unwrap();
        assert!(matches!(msg, Inbound::HttpRequestBody { end: true, .. }));
        let msg: Inbound = serde_json::from_str(r#"{"type":"http.ack","reqId":"h1","bytes":262144}"#).unwrap();
        assert!(matches!(msg, Inbound::HttpAck { bytes: 262144, .. }));
        let msg: Inbound = serde_json::from_str(r#"{"type":"http.cancel","reqId":"h1"}"#).unwrap();
        assert!(matches!(msg, Inbound::HttpCancel { .. }));
        let out = serde_json::to_value(Outbound::HttpResponse { req_id: "h1".into(), status: 200, headers: vec![("a".into(), "b".into())] }).unwrap();
        assert_eq!(out, serde_json::json!({"type":"http.response","reqId":"h1","status":200,"headers":[["a","b"]]}));
        let out = serde_json::to_value(Outbound::HttpResponseBody { req_id: "h1".into(), data: "".into(), end: true }).unwrap();
        assert_eq!(out, serde_json::json!({"type":"http.response.body","reqId":"h1","data":"","end":true}));
    }

    #[test]
    fn file_messages() {
        let msg: Inbound =
            serde_json::from_str(r#"{"type":"file.stat","reqId":"s1","path":"out/a.png","session":"6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11"}"#).unwrap();
        assert!(matches!(msg, Inbound::FileStat { ref path, cwd: None, session: Some(_), .. } if path == "out/a.png"));
        let msg: Inbound = serde_json::from_str(r#"{"type":"file.read","reqId":"r1","path":"~/a.png"}"#).unwrap();
        assert!(matches!(msg, Inbound::FileRead { offset: 0, length: crate::media::MAX_CHUNK, .. }));
        let out = serde_json::to_value(Outbound::FileChunk {
            req_id: "r1".into(),
            result: ChunkReply::Ok(crate::media::Chunk { size: 3, mime: "image/png", offset: 0, data: "AAAA".into(), eof: true }),
        })
        .unwrap();
        assert_eq!(out, serde_json::json!({"type":"file.chunk","reqId":"r1","size":3,"mime":"image/png","offset":0,"data":"AAAA","eof":true}));
        let out = serde_json::to_value(Outbound::FileChunk { req_id: "r2".into(), result: ChunkReply::Err { error: "no".into() } }).unwrap();
        assert_eq!(out, serde_json::json!({"type":"file.chunk","reqId":"r2","error":"no"}));
        let out = serde_json::to_value(Outbound::FileInfo {
            req_id: "s1".into(),
            stat: crate::media::Stat {
                exists: true,
                kind: Some("image"),
                size: Some(3),
                mime: Some("image/png"),
                resolved: Some("~/a.png".into()),
                cwd: Some("~".into()),
                error: None,
            },
        })
        .unwrap();
        assert_eq!(
            out,
            serde_json::json!({"type":"file.info","reqId":"s1","exists":true,"kind":"image","size":3,"mime":"image/png","resolved":"~/a.png","cwd":"~"})
        );
    }

    #[test]
    fn mcp_messages() {
        let id = Uuid::parse_str("6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11").unwrap();
        let out = serde_json::to_value(Outbound::McpRequest {
            req_id: "r1".into(),
            session: id,
            tool: "list_sessions".into(),
            args: serde_json::json!({"machine": "mbp"}),
        })
        .unwrap();
        assert_eq!(out, serde_json::json!({"type":"mcp.request","reqId":"r1","session":id.to_string(),"tool":"list_sessions","args":{"machine":"mbp"}}));
        let msg: Inbound = serde_json::from_str(r#"{"type":"mcp.response","reqId":"r1","result":{"summary":"ok"}}"#).unwrap();
        assert!(matches!(msg, Inbound::McpResponse { req_id, result: Some(_), error: None } if req_id == "r1"));
        let msg: Inbound = serde_json::from_str(r#"{"type":"mcp.response","reqId":"r2","error":"no"}"#).unwrap();
        assert!(matches!(msg, Inbound::McpResponse { result: None, error: Some(e), .. } if e == "no"));
        let msg: Inbound = serde_json::from_str(r#"{"type":"session.capture","reqId":"c1","id":"6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11","lines":50}"#).unwrap();
        assert!(matches!(msg, Inbound::SessionCapture { lines: 50, .. }));
        let out = serde_json::to_value(Outbound::SessionCaptured { req_id: "c1".into(), text: "hi".into(), error: None }).unwrap();
        assert_eq!(out, serde_json::json!({"type":"session.captured","reqId":"c1","text":"hi"}));
    }

    #[test]
    fn task_images_messages() {
        let msg: Inbound = serde_json::from_str(r#"{"type":"task.images","reqId":"i1","taskId":"t1","files":["3f9c1a2b-wall.png"]}"#).unwrap();
        assert!(
            matches!(msg, Inbound::TaskImages { ref req_id, ref task_id, ref files } if req_id == "i1" && task_id == "t1" && files == &["3f9c1a2b-wall.png"])
        );
        let got = vec![
            ImageGot { file: "3f9c1a2b-wall.png".into(), path: Some("/h/.config/maple/images/t1/3f9c1a2b-wall.png".into()), error: None },
            ImageGot { file: "bad".into(), path: None, error: Some("not an image's name".into()) },
        ];
        let out = serde_json::to_value(Outbound::TaskImagesFetched { req_id: "i1".into(), got, error: None }).unwrap();
        assert_eq!(
            out,
            serde_json::json!({"type":"task.images.fetched","reqId":"i1","got":[
                {"file":"3f9c1a2b-wall.png","path":"/h/.config/maple/images/t1/3f9c1a2b-wall.png"},
                {"file":"bad","error":"not an image's name"},
            ]})
        );
        let big = Outbound::TaskImagesFetched { req_id: "i1".into(), got: vec![], error: None }.oversized(600_000).unwrap();
        assert!(matches!(big, Outbound::TaskImagesFetched { ref got, error: Some(_), .. } if got.is_empty()));
    }

    #[test]
    fn task_messages() {
        let msg: Inbound = serde_json::from_str(
            r#"{"type":"task.finish","taskId":"t1","session":"s","cwd":"~/.worktrees/app/fix-1a2b","repoDir":"~/app","branch":"agent/fix-1a2b","base":"main","title":"Fix it","fallback":false}"#,
        )
        .unwrap();
        assert!(matches!(msg, Inbound::TaskFinish(ref f) if f.branch == "agent/fix-1a2b" && f.base.as_deref() == Some("main") && !f.fallback));
        let msg: Inbound = serde_json::from_str(r#"{"type":"task.token","reqId":"r1","error":"not installed","code":"not_installed"}"#).unwrap();
        assert!(matches!(msg, Inbound::TaskToken { token: None, code: Some(ref c), .. } if c == "not_installed"));
        let out = serde_json::to_value(Outbound::TaskTokenRequest {
            req_id: "r1".into(),
            task_id: "t1".into(),
            owner: "acme".into(),
            repo: "w".into(),
            purpose: None,
        })
        .unwrap();
        assert_eq!(out, serde_json::json!({"type":"task.token_request","reqId":"r1","taskId":"t1","owner":"acme","repo":"w"}));
        let out = serde_json::to_value(Outbound::TaskFinished {
            task_id: "t1".into(),
            ok: false,
            pushed: None,
            owner: None,
            repo: None,
            branch: "agent/x".into(),
            base: None,
            commit: None,
            reason: None,
            message: Some("nope".into()),
        })
        .unwrap();
        assert_eq!(out, serde_json::json!({"type":"task.finished","taskId":"t1","ok":false,"branch":"agent/x","base":null,"message":"nope"}));
        let msg: Inbound = serde_json::from_str(
            r#"{"type":"task.handoff","taskId":"t1","cwd":"~/.worktrees/app/fix-1a2b","repoDir":"~/app","branch":"agent/fix-1a2b","base":"main","title":"Fix it","fallback":true}"#,
        )
        .unwrap();
        assert!(matches!(msg, Inbound::TaskHandoff(ref h) if h.branch == "agent/fix-1a2b" && h.base.as_deref() == Some("main") && h.fallback));
        let out =
            serde_json::to_value(Outbound::TaskHandedOff { task_id: "t1".into(), ok: true, pushed: Some("app"), commit: Some("abc".into()), message: None })
                .unwrap();
        assert_eq!(out, serde_json::json!({"type":"task.handed_off","taskId":"t1","ok":true,"pushed":"app","commit":"abc"}));
        let out = serde_json::to_value(Outbound::TaskHandedOff { task_id: "t1".into(), ok: false, pushed: None, commit: None, message: Some("nope".into()) })
            .unwrap();
        assert_eq!(out, serde_json::json!({"type":"task.handed_off","taskId":"t1","ok":false,"message":"nope"}));
        let msg: Inbound = serde_json::from_str(
            r#"{"type":"task.cleanup","taskId":"t1","cwd":"~/.worktrees/app/fix-1a2b","repoDir":"~/app","branch":"agent/fix-1a2b","merged":true,"heads":["0123456789012345678901234567890123456789"]}"#,
        )
        .unwrap();
        assert!(matches!(msg, Inbound::TaskCleanup(ref c) if c.merged && c.heads.len() == 1 && c.repo_dir == "~/app"));
        let msg: Inbound = serde_json::from_str(
            r#"{"type":"task.prove","taskId":"t1","cwd":"~/.worktrees/app/fix-1a2b","base":"main","projects":[{"repo":"acme/app","name":"App","settings":{"test":"npm test"}}]}"#,
        )
        .unwrap();
        assert!(matches!(msg, Inbound::TaskProve(ref p) if p.base.as_deref() == Some("main") && p.projects[0].settings.test.as_deref() == Some("npm test")));
        let out = serde_json::to_value(Outbound::TaskCheck { task_id: "t1".into(), command: "npm test".into(), n: 1, of: 2 }).unwrap();
        assert_eq!(out, serde_json::json!({"type":"task.check","taskId":"t1","command":"npm test","n":1,"of":2}));
        let result = crate::proof::CheckResult { command: "false".into(), code: Some(1), ms: 6, timed_out: false, tail: "no".into() };
        let out = serde_json::to_value(Outbound::TaskProved {
            task_id: "t1".into(),
            results: vec![result],
            not_run: vec!["true".into()],
            screens: vec![],
            head: None,
            error: None,
        })
        .unwrap();
        assert_eq!(
            out,
            serde_json::json!({"type":"task.proved","taskId":"t1","results":[{"command":"false","code":1,"ms":6,"timedOut":false,"tail":"no"}],"notRun":["true"]})
        );
        let shot = crate::proof::ScreenProof {
            kind: "screen",
            summary: "#tasks at 390px".into(),
            text: None,
            file: Some("tasks/t1/0123456789ab-tasks-390.png".into()),
        };
        let out =
            serde_json::to_value(Outbound::TaskProved { task_id: "t1".into(), results: vec![], not_run: vec![], screens: vec![shot], head: None, error: None })
                .unwrap();
        assert_eq!(out["screens"], serde_json::json!([{"kind":"screen","summary":"#tasks at 390px","file":"tasks/t1/0123456789ab-tasks-390.png"}]));
        let out =
            serde_json::to_value(Outbound::TaskCleaned { task_id: "t1".into(), ok: true, branch_deleted: true, message: Some("Removed".into()) }).unwrap();
        assert_eq!(out, serde_json::json!({"type":"task.cleaned","taskId":"t1","ok":true,"branchDeleted":true,"message":"Removed"}));
    }

    #[test]
    fn worktree_remove_names_the_session_in_its_answer() {
        // From the Worktrees page: no session, and an error says only what went wrong.
        let msg: Inbound = serde_json::from_str(r#"{"type":"worktree.remove","path":"~/.worktrees/app/x"}"#).unwrap();
        assert!(matches!(msg, Inbound::WorktreeRemove { session: None, force: false, .. }));
        let msg: Inbound = serde_json::from_str(r#"{"type":"worktree.remove","path":"~/.worktrees/app/x","force":true}"#).unwrap();
        assert!(matches!(msg, Inbound::WorktreeRemove { force: true, .. }));
        let out = serde_json::to_value(Outbound::WorktreeError { path: "p".into(), message: "dirty".into(), session: None }).unwrap();
        assert_eq!(out, serde_json::json!({"type":"worktree.error","path":"p","message":"dirty"}));
        // For an ended setup session or planner, both answers name it.
        let msg: Inbound = serde_json::from_str(r#"{"type":"worktree.remove","path":"~/.worktrees/app/plan-x-1a2b","session":"s1"}"#).unwrap();
        assert!(matches!(msg, Inbound::WorktreeRemove { session: Some(ref s), .. } if s == "s1"));
        let out = serde_json::to_value(Outbound::WorktreeError { path: "p".into(), message: "dirty".into(), session: Some("s1".into()) }).unwrap();
        assert_eq!(out, serde_json::json!({"type":"worktree.error","path":"p","message":"dirty","session":"s1"}));
        let out = serde_json::to_value(Outbound::WorktreeRemoved { path: "p".into(), session: "s1".into() }).unwrap();
        assert_eq!(out, serde_json::json!({"type":"worktree.removed","path":"p","session":"s1"}));
    }

    #[test]
    fn usage_messages() {
        let msg: Inbound = serde_json::from_str(r#"{"type":"usage.config","claudeCheck":false}"#).unwrap();
        assert!(matches!(msg, Inbound::UsageConfig { claude_check: false }));
        assert!(matches!(serde_json::from_str::<Inbound>(r#"{"type":"usage.config"}"#).unwrap(), Inbound::UsageConfig { claude_check: true }));
        assert!(
            matches!(serde_json::from_str::<Inbound>(r#"{"type":"usage.refresh","agent":"codex"}"#).unwrap(), Inbound::UsageRefresh { ref agent } if agent == "codex")
        );
    }
}
