//! Turns an agent's own transcript (Claude's `transcript_path` JSONL, Codex's rollout) into the
//! native view's `SessionEvent`s. One record in, zero or more events out, with `seq` left at 0 for
//! the stream (events.rs) to number. The mapping is in docs/native-session-view.md; the fixtures in
//! protocol/fixtures/session-events/ are the contract. Both formats are internal to their agents, so
//! anything this doesn't know becomes an `other` event rather than an error: the stream never breaks.

use serde_json::{Map, Value, json};
use uuid::Uuid;

use crate::usage::parse_utc;
use crate::wire::{SessionEvent, ToolCallInfo, TurnState, TurnUsage};

/// Tool output kept whole up to this many chars; past it, the head and tail.
pub const RESULT_LIMIT: usize = 4000;
/// Any string in a tool's `input` longer than this is cut the same way.
const INPUT_LIMIT: usize = 2000;
/// The `other` event's summary.
const SUMMARY_LIMIT: usize = 200;

/// `s` cut to at most `max` chars, keeping its head and tail around a marker, and whether it was cut.
pub fn cut(s: &str, max: usize) -> (String, bool) {
    let n = s.chars().count();
    if n <= max {
        return (s.to_string(), false);
    }
    let keep = max.saturating_sub(3) / 2;
    let head: String = s.chars().take(keep).collect();
    let tail: String = s.chars().skip(n - keep).collect();
    (format!("{head}\n…\n{tail}"), true)
}

fn cut_input(v: &Value) -> Value {
    match v {
        Value::String(s) => Value::String(cut(s, INPUT_LIMIT).0),
        Value::Array(a) => Value::Array(a.iter().map(cut_input).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, v)| (k.clone(), cut_input(v))).collect()),
        other => other.clone(),
    }
}

fn s<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

fn u(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn nonzero(n: u64) -> Option<u64> {
    (n > 0).then_some(n)
}

/// `path` relative to `cwd` when it's inside it.
fn relative(path: &str, cwd: Option<&str>) -> String {
    match cwd.map(|c| c.trim_end_matches('/')) {
        Some(c) if !c.is_empty() => path.strip_prefix(c).and_then(|r| r.strip_prefix('/')).unwrap_or(path).to_string(),
        _ => path.to_string(),
    }
}

/// A short one-line cut of a record, for `other`.
fn summarize(text: &str) -> String {
    let flat: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= SUMMARY_LIMIT { flat } else { format!("{}…", flat.chars().take(SUMMARY_LIMIT).collect::<String>()) }
}

/// The record's text for an `other` event, minus bulky fields.
fn other(id: String, session: Uuid, at: u64, agent: &str, kind: String, record: &Value) -> SessionEvent {
    let summary = summarize(&record.to_string());
    SessionEvent::Other { id, session, seq: 0, at, agent: agent.into(), kind, summary }
}

fn invalid(id: String, session: Uuid, at: u64, agent: &str, line: &str) -> SessionEvent {
    SessionEvent::Other { id, session, seq: 0, at, agent: agent.into(), kind: "invalid".into(), summary: summarize(line) }
}

/// Text from a content that's a string or a list of `{type: text|input_text|output_text, text}` blocks.
fn content_text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Array(a) => a.iter().filter_map(|b| b.as_str().or_else(|| s(b, "text"))).collect::<Vec<_>>().join(""),
        _ => String::new(),
    }
}

// ---- Claude ----

#[derive(Debug, Clone)]
pub struct ClaudeState {
    pub session: Uuid,
    /// The last assistant message's usage, for the turn's `turn_duration`.
    usage: Option<Value>,
    /// Lines seen, for ids of records that carry none.
    line: u64,
    last_at: u64,
}

impl ClaudeState {
    pub fn new(session: Uuid) -> Self {
        Self { session, usage: None, line: 0, last_at: 0 }
    }
}

/// Claude records that map to nothing.
const CLAUDE_SKIP: &[&str] = &[
    "mode",
    "permission-mode",
    "attachment",
    "file-history-snapshot",
    "ai-title",
    "custom-title",
    "last-prompt",
    "api-request-shape",
    "api-request",
    "api-request-error",
    "cost-state",
    "summary",
    "queue-operation",
    "progress",
];
const CLAUDE_SYSTEM_SKIP: &[&str] = &["stop_hook_summary", "informational", "compact_boundary", "away_summary"];

/// The `/name args` of a `<command-name>…` wrapper (local commands and slash prompts).
fn slash_command(text: &str) -> Option<String> {
    let tag = |t: &str| {
        let open = format!("<{t}>");
        let start = text.find(&open)? + open.len();
        let end = text[start..].find(&format!("</{t}>"))? + start;
        Some(text[start..end].trim().to_string())
    };
    let name = tag("command-name")?;
    let args = tag("command-args").unwrap_or_default();
    let name = if name.starts_with('/') { name } else { format!("/{name}") };
    Some(if args.is_empty() { name } else { format!("{name} {args}") })
}

/// The unified diff the view shows for an Edit or Write.
fn claude_diff(name: &str, input: &Value, rel: &str) -> Option<String> {
    let lines = |prefix: char, text: &str| text.lines().map(|l| format!("{prefix}{l}\n")).collect::<String>();
    let diff = match name {
        "Edit" => format!("--- a/{rel}\n+++ b/{rel}\n{}{}", lines('-', s(input, "old_string")?), lines('+', s(input, "new_string")?)),
        "MultiEdit" => {
            let edits = input.get("edits")?.as_array()?;
            let mut d = format!("--- a/{rel}\n+++ b/{rel}\n");
            for e in edits {
                d += &lines('-', s(e, "old_string").unwrap_or(""));
                d += &lines('+', s(e, "new_string").unwrap_or(""));
            }
            d
        }
        "Write" => format!("--- /dev/null\n+++ b/{rel}\n{}", lines('+', s(input, "content")?)),
        _ => return None,
    };
    Some(cut(&diff, RESULT_LIMIT).0)
}

fn claude_tool_call(block: &Value, cwd: Option<&str>) -> ToolCallInfo {
    let name = s(block, "name").unwrap_or("tool").to_string();
    let input = block.get("input").cloned().unwrap_or(Value::Null);
    let file = s(&input, "file_path").or_else(|| s(&input, "notebook_path")).or_else(|| s(&input, "path"));
    let path = file.map(|f| relative(f, cwd));
    let summary = match name.as_str() {
        "Bash" => s(&input, "command").map(str::to_string),
        "Grep" | "Glob" => s(&input, "pattern").map(str::to_string),
        "WebFetch" => s(&input, "url").map(str::to_string),
        "WebSearch" => s(&input, "query").map(str::to_string),
        "Task" | "Agent" => s(&input, "description").map(str::to_string),
        _ => None,
    }
    .or_else(|| path.clone())
    .or_else(|| s(&input, "description").map(str::to_string))
    .unwrap_or_else(|| name.clone());
    let summary = summary.lines().next().unwrap_or("").to_string();
    let diff = path.as_deref().and_then(|rel| claude_diff(&name, &input, rel));
    ToolCallInfo {
        call_id: s(block, "id").unwrap_or_default().to_string(),
        name,
        summary: cut(&summary, SUMMARY_LIMIT).0,
        path,
        diff,
        input: (!input.is_null()).then(|| cut_input(&input)),
    }
}

fn claude_usage(usage: Option<&Value>, duration: Option<u64>) -> Option<TurnUsage> {
    let u_ = usage?;
    Some(TurnUsage {
        input_tokens: u(u_, "input_tokens"),
        output_tokens: u(u_, "output_tokens"),
        cache_read_tokens: nonzero(u(u_, "cache_read_input_tokens")),
        cache_write_tokens: nonzero(u(u_, "cache_creation_input_tokens")),
        cost_usd: None,
        duration_ms: duration,
    })
}

/// One line of a Claude transcript. A line that isn't JSON, or a record type this doesn't know,
/// comes back as one `other` event.
pub fn parse_claude(line: &str, st: &mut ClaudeState) -> Vec<SessionEvent> {
    st.line += 1;
    let session = st.session;
    let agent = "claude";
    let line = line.trim();
    if line.is_empty() {
        return vec![];
    }
    let Ok(rec) = serde_json::from_str::<Value>(line) else {
        return vec![invalid(format!("{session}:line:{}", st.line), session, st.last_at, agent, line)];
    };
    let ty = s(&rec, "type").unwrap_or("").to_string();
    if let Some(at) = s(&rec, "timestamp").and_then(parse_utc) {
        st.last_at = at;
    }
    let at = st.last_at;
    let id = s(&rec, "uuid").map(str::to_string).unwrap_or_else(|| format!("{session}:line:{}", st.line));
    if CLAUDE_SKIP.contains(&ty.as_str()) {
        return vec![];
    }
    let cwd = s(&rec, "cwd");
    let meta = rec.get("isMeta").and_then(Value::as_bool).unwrap_or(false);
    match ty.as_str() {
        "user" => {
            let content = &rec["message"]["content"];
            let mut out = vec![];
            match content {
                Value::String(text) => {
                    if meta {
                        return out;
                    }
                    if let Some(cmd) = slash_command(text) {
                        out.push(SessionEvent::User { id, session, seq: 0, at, agent: agent.into(), text: cmd });
                    } else if text.starts_with("[Request interrupted") {
                        out.push(SessionEvent::Turn {
                            id,
                            session,
                            seq: 0,
                            at,
                            agent: agent.into(),
                            state: TurnState::Interrupted,
                            usage: None,
                            message: None,
                        });
                    } else if !(text.starts_with("<local-command-") || text.starts_with("<command-message>")) {
                        out.push(SessionEvent::User { id, session, seq: 0, at, agent: agent.into(), text: text.clone() });
                    }
                }
                Value::Array(blocks) => {
                    let texts: Vec<&str> = blocks.iter().filter(|b| s(b, "type") == Some("text")).filter_map(|b| s(b, "text")).collect();
                    if !texts.is_empty() && !meta {
                        let text = texts.join("\n");
                        if text.starts_with("[Request interrupted") {
                            out.push(SessionEvent::Turn {
                                id: id.clone(),
                                session,
                                seq: 0,
                                at,
                                agent: agent.into(),
                                state: TurnState::Interrupted,
                                usage: None,
                                message: None,
                            });
                        } else {
                            out.push(SessionEvent::User { id: id.clone(), session, seq: 0, at, agent: agent.into(), text });
                        }
                    }
                    for b in blocks.iter().filter(|b| s(b, "type") == Some("tool_result")) {
                        let call_id = s(b, "tool_use_id").unwrap_or_default().to_string();
                        let (text, truncated) = cut(&content_text(b.get("content").unwrap_or(&Value::Null)), RESULT_LIMIT);
                        let ok = !b.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                        out.push(SessionEvent::ToolResult {
                            id: format!("{id}:{call_id}"),
                            session,
                            seq: 0,
                            at,
                            agent: agent.into(),
                            call_id,
                            ok,
                            text,
                            truncated,
                        });
                    }
                }
                _ => {}
            }
            out
        }
        "assistant" => {
            let msg = &rec["message"];
            if let Some(usage) = msg.get("usage") {
                st.usage = Some(usage.clone());
            }
            let model = s(msg, "model").filter(|m| *m != "<synthetic>").map(str::to_string);
            let blocks = msg["content"].as_array().cloned().unwrap_or_default();
            let several = blocks.len() > 1;
            let block_id = |n: usize| if several { format!("{id}:{n}") } else { id.clone() };
            let mut out = vec![];
            for (n, b) in blocks.iter().enumerate() {
                match s(b, "type") {
                    Some("text") => {
                        let text = s(b, "text").unwrap_or("");
                        if !text.trim().is_empty() {
                            out.push(SessionEvent::Assistant {
                                id: block_id(n),
                                session,
                                seq: 0,
                                at,
                                agent: agent.into(),
                                markdown: text.into(),
                                model: model.clone(),
                            });
                        }
                    }
                    Some("thinking") => {
                        let text = s(b, "thinking").unwrap_or("");
                        if !text.trim().is_empty() {
                            out.push(SessionEvent::Thinking { id: block_id(n), session, seq: 0, at, agent: agent.into(), text: text.into() });
                        }
                    }
                    Some("tool_use") => {
                        out.push(SessionEvent::ToolCall { id: block_id(n), session, seq: 0, at, agent: agent.into(), call: claude_tool_call(b, cwd) });
                    }
                    _ => {}
                }
            }
            out
        }
        "system" => {
            let sub = s(&rec, "subtype").unwrap_or("");
            match sub {
                "turn_duration" => {
                    let usage = claude_usage(st.usage.take().as_ref(), rec.get("durationMs").and_then(Value::as_u64));
                    vec![SessionEvent::Turn { id, session, seq: 0, at, agent: agent.into(), state: TurnState::Done, usage, message: None }]
                }
                "local_command" => match s(&rec, "content").and_then(slash_command) {
                    Some(text) => vec![SessionEvent::User { id, session, seq: 0, at, agent: agent.into(), text }],
                    None => vec![],
                },
                "api_error" => {
                    let message = s(&rec, "content").map(str::to_string).or_else(|| rec.get("error").map(|e| summarize(&e.to_string())));
                    vec![SessionEvent::Turn { id, session, seq: 0, at, agent: agent.into(), state: TurnState::Error, usage: None, message }]
                }
                s_ if CLAUDE_SYSTEM_SKIP.contains(&s_) => vec![],
                _ => vec![other(id, session, at, agent, format!("system/{sub}"), &rec)],
            }
        }
        _ => vec![other(id, session, at, agent, if ty.is_empty() { "unknown".into() } else { ty }, &rec)],
    }
}

// ---- Codex ----

#[derive(Debug, Clone)]
pub struct CodexState {
    pub session: Uuid,
    /// The rollout's own thread id (from `session_meta`), for turn ids.
    thread: Option<String>,
    /// The running turn's summed `last_token_usage`.
    usage: Option<TurnUsage>,
    line: u64,
    last_at: u64,
}

impl CodexState {
    pub fn new(session: Uuid) -> Self {
        Self { session, thread: None, usage: None, line: 0, last_at: 0 }
    }
}

/// Codex records (top-level `type`, or an `event_msg`'s payload type) that map to nothing; most
/// duplicate a `response_item`.
const CODEX_SKIP: &[&str] = &[
    "turn_context",
    "world_state",
    "token_usage_record",
    "compacted",
    "thread_settings_applied",
    "item_started",
    "item_completed",
    "user_message",
    "agent_message",
    "agent_message_delta",
    "agent_reasoning",
    "agent_reasoning_delta",
    "agent_reasoning_raw_content",
    "agent_reasoning_section_break",
    "exec_command_begin",
    "exec_command_end",
    "exec_command_output_delta",
    "patch_apply_begin",
    "patch_apply_end",
    "mcp_tool_call_begin",
    "mcp_tool_call_end",
    "web_search_begin",
    "web_search_end",
    "turn_diff",
    "context_compacted",
    "rate_limits",
    "session_configured",
    "mcp_startup_update",
    "mcp_startup_complete",
];

/// Whether a user-role message is the harness talking (environment context, instructions), not the person.
fn codex_harness_text(text: &str) -> bool {
    let t = text.trim_start();
    ["<environment_context>", "<user_instructions>", "<permissions instructions>", "# AGENTS.md", "<turn_aborted>"].iter().any(|p| t.starts_with(p))
}

/// The patch inside an apply_patch call (plain, or escaped inside a script string).
fn patch_of(text: &str) -> Option<String> {
    let start = text.find("*** Begin Patch")?;
    let end = text[start..].find("*** End Patch").map(|e| start + e + "*** End Patch".len()).unwrap_or(text.len());
    let p = &text[start..end];
    Some(if !p.contains('\n') && p.contains("\\n") { p.replace("\\n", "\n").replace("\\\"", "\"").replace("\\\\", "\\") } else { p.to_string() })
}

fn patch_path(patch: &str) -> Option<String> {
    patch
        .lines()
        .find_map(|l| ["*** Update File: ", "*** Add File: ", "*** Delete File: "].iter().find_map(|p| l.strip_prefix(p)).map(|p| p.trim().to_string()))
}

/// The `cmd` an exec script passes to `tools.exec_command({cmd: "…"})`.
fn exec_cmd(script: &str) -> Option<String> {
    let i = script.find("cmd")?;
    let rest = script[i + 3..].trim_start_matches('"').trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    let quote = rest.chars().next().filter(|c| *c == '"' || *c == '\'' || *c == '`')?;
    let body = &rest[1..];
    let mut out = String::new();
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                other => out.push(other),
            },
            c if c == quote => return Some(out),
            c => out.push(c),
        }
    }
    None
}

fn codex_tool_call(p: &Value, cwd: Option<&str>) -> ToolCallInfo {
    let name = s(p, "name").unwrap_or("tool").to_string();
    // custom_tool_call: `input` a string; function_call: `arguments` a JSON string.
    let raw = s(p, "input").map(str::to_string).or_else(|| s(p, "arguments").map(str::to_string)).unwrap_or_default();
    let args: Option<Value> = s(p, "arguments").and_then(|a| serde_json::from_str(a).ok());
    let input = match &args {
        Some(v) => v.clone(),
        None => Value::String(raw.clone()),
    };
    let patch = patch_of(&raw).or_else(|| args.as_ref().and_then(|a| s(a, "input")).and_then(patch_of));
    let path = patch.as_deref().and_then(patch_path).map(|p| relative(&p, cwd));
    let summary = if let Some(a) = &args {
        match a.get("cmd").or_else(|| a.get("command")) {
            Some(Value::String(c)) => Some(c.clone()),
            Some(Value::Array(parts)) => {
                let parts: Vec<&str> = parts.iter().filter_map(Value::as_str).collect();
                // ["bash", "-lc", "the command"]: the command.
                Some(if parts.len() == 3 && parts[1] == "-lc" { parts[2].to_string() } else { parts.join(" ") })
            }
            _ => None,
        }
    } else {
        exec_cmd(&raw)
    };
    let summary =
        summary.or_else(|| path.clone()).or_else(|| raw.lines().find(|l| !l.trim().is_empty()).map(|l| l.trim().to_string())).unwrap_or_else(|| name.clone());
    ToolCallInfo {
        call_id: s(p, "call_id").unwrap_or_default().to_string(),
        name,
        summary: cut(summary.lines().next().unwrap_or(""), SUMMARY_LIMIT).0,
        path,
        diff: patch.map(|d| cut(&d, RESULT_LIMIT).0),
        input: Some(cut_input(&input)),
    }
}

fn codex_output(v: &Value) -> (String, bool) {
    match v {
        Value::String(s_) => {
            // function_call_output's output is sometimes JSON: {"output": "...", "metadata": {"exit_code": n}}.
            if let Ok(inner) = serde_json::from_str::<Map<String, Value>>(s_)
                && let Some(out) = inner.get("output").and_then(Value::as_str)
            {
                let code = inner.get("metadata").and_then(|m| m.get("exit_code")).and_then(Value::as_i64).unwrap_or(0);
                return (out.to_string(), code == 0);
            }
            (s_.clone(), true)
        }
        Value::Array(_) => (content_text(v), true),
        Value::Object(o) => {
            let text = o.get("content").map(content_text).unwrap_or_default();
            (text, o.get("success").and_then(Value::as_bool).unwrap_or(true))
        }
        _ => (String::new(), true),
    }
}

/// One line of a Codex rollout. A line that isn't JSON, or a record type this doesn't know,
/// comes back as one `other` event.
pub fn parse_codex(line: &str, st: &mut CodexState) -> Vec<SessionEvent> {
    st.line += 1;
    let session = st.session;
    let agent = "codex";
    let line = line.trim();
    if line.is_empty() {
        return vec![];
    }
    let Ok(rec) = serde_json::from_str::<Value>(line) else {
        return vec![invalid(format!("{session}:line:{}", st.line), session, st.last_at, agent, line)];
    };
    if let Some(at) = s(&rec, "timestamp").and_then(parse_utc) {
        st.last_at = at;
    }
    let at = st.last_at;
    let ty = s(&rec, "type").unwrap_or("");
    let p = &rec["payload"];
    let pty = s(p, "type").unwrap_or("");
    if st.thread.is_none() {
        st.thread = match (ty, pty) {
            ("session_meta", _) => s(p, "id").map(str::to_string),
            (_, "thread_settings_applied") => s(p, "thread_id").map(str::to_string),
            _ => None,
        };
    }
    let thread = st.thread.clone().unwrap_or_else(|| session.to_string());
    let ordinal_id = || match rec.get("ordinal").and_then(Value::as_u64) {
        Some(n) => format!("{thread}:{n}"),
        None => format!("{thread}:line:{}", st.line),
    };
    let item_id = || s(p, "id").map(str::to_string).unwrap_or_else(ordinal_id);
    if ty == "session_meta" || CODEX_SKIP.contains(&ty) {
        return vec![];
    }
    let turn = |state: TurnState, usage: Option<TurnUsage>, message: Option<String>| SessionEvent::Turn {
        id: ordinal_id(),
        session,
        seq: 0,
        at,
        agent: agent.into(),
        state,
        usage,
        message,
    };
    match ty {
        "event_msg" => match pty {
            "task_started" => {
                st.usage = None;
                vec![turn(TurnState::Running, None, None)]
            }
            "token_count" => {
                if let Some(last) = p.get("info").and_then(|i| i.get("last_token_usage")) {
                    let t = st.usage.get_or_insert(TurnUsage {
                        input_tokens: 0,
                        output_tokens: 0,
                        cache_read_tokens: None,
                        cache_write_tokens: None,
                        cost_usd: None,
                        duration_ms: None,
                    });
                    t.input_tokens += u(last, "input_tokens");
                    t.output_tokens += u(last, "output_tokens");
                    t.cache_read_tokens = nonzero(t.cache_read_tokens.unwrap_or(0) + u(last, "cached_input_tokens"));
                    t.cache_write_tokens = nonzero(t.cache_write_tokens.unwrap_or(0) + u(last, "cache_write_input_tokens"));
                }
                vec![]
            }
            "task_complete" => {
                let mut usage = st.usage.take();
                if let (Some(u_), Some(d)) = (usage.as_mut(), p.get("duration_ms").and_then(Value::as_u64)) {
                    u_.duration_ms = Some(d);
                }
                vec![turn(TurnState::Done, usage, None)]
            }
            "turn_aborted" => {
                st.usage = None;
                vec![turn(TurnState::Interrupted, None, s(p, "reason").map(str::to_string))]
            }
            "error" | "stream_error" => vec![turn(TurnState::Error, None, s(p, "message").map(str::to_string))],
            t if CODEX_SKIP.contains(&t) => vec![],
            t => vec![other(ordinal_id(), session, at, agent, format!("event_msg/{t}"), &rec)],
        },
        "response_item" => match pty {
            "message" => {
                let text = content_text(p.get("content").unwrap_or(&Value::Null));
                match s(p, "role") {
                    Some("user") if !codex_harness_text(&text) && !text.trim().is_empty() => {
                        vec![SessionEvent::User { id: item_id(), session, seq: 0, at, agent: agent.into(), text }]
                    }
                    Some("assistant") if !text.trim().is_empty() => {
                        vec![SessionEvent::Assistant { id: item_id(), session, seq: 0, at, agent: agent.into(), markdown: text, model: None }]
                    }
                    _ => vec![],
                }
            }
            "reasoning" => {
                let text = p
                    .get("summary")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(|b| s(b, "text")).collect::<Vec<_>>().join("\n\n"))
                    .unwrap_or_default();
                if text.trim().is_empty() { vec![] } else { vec![SessionEvent::Thinking { id: item_id(), session, seq: 0, at, agent: agent.into(), text }] }
            }
            "custom_tool_call" | "function_call" | "local_shell_call" => {
                vec![SessionEvent::ToolCall { id: item_id(), session, seq: 0, at, agent: agent.into(), call: codex_tool_call(p, None) }]
            }
            "custom_tool_call_output" | "function_call_output" => {
                let (text, ok) = codex_output(p.get("output").unwrap_or(&Value::Null));
                let (text, truncated) = cut(&text, RESULT_LIMIT);
                let call_id = s(p, "call_id").unwrap_or_default().to_string();
                vec![SessionEvent::ToolResult { id: item_id(), session, seq: 0, at, agent: agent.into(), call_id, ok, text, truncated }]
            }
            t => vec![other(item_id(), session, at, agent, format!("response_item/{t}"), &rec)],
        },
        t => vec![other(ordinal_id(), session, at, agent, if t.is_empty() { "unknown".into() } else { t.into() }, &rec)],
    }
}

// ---- Events in general ----

#[cfg(test)]
pub fn id_of(e: &SessionEvent) -> &str {
    match e {
        SessionEvent::User { id, .. }
        | SessionEvent::Assistant { id, .. }
        | SessionEvent::Thinking { id, .. }
        | SessionEvent::ToolCall { id, .. }
        | SessionEvent::ToolResult { id, .. }
        | SessionEvent::Prompt { id, .. }
        | SessionEvent::PromptResolved { id, .. }
        | SessionEvent::Turn { id, .. }
        | SessionEvent::Other { id, .. } => id,
    }
}

pub fn seq_of(e: &SessionEvent) -> u64 {
    match e {
        SessionEvent::User { seq, .. }
        | SessionEvent::Assistant { seq, .. }
        | SessionEvent::Thinking { seq, .. }
        | SessionEvent::ToolCall { seq, .. }
        | SessionEvent::ToolResult { seq, .. }
        | SessionEvent::Prompt { seq, .. }
        | SessionEvent::PromptResolved { seq, .. }
        | SessionEvent::Turn { seq, .. }
        | SessionEvent::Other { seq, .. } => *seq,
    }
}

pub fn set_seq(e: &mut SessionEvent, n: u64) {
    match e {
        SessionEvent::User { seq, .. }
        | SessionEvent::Assistant { seq, .. }
        | SessionEvent::Thinking { seq, .. }
        | SessionEvent::ToolCall { seq, .. }
        | SessionEvent::ToolResult { seq, .. }
        | SessionEvent::Prompt { seq, .. }
        | SessionEvent::PromptResolved { seq, .. }
        | SessionEvent::Turn { seq, .. }
        | SessionEvent::Other { seq, .. } => *seq = n,
    }
}

/// An agent's parse state, so a stream can hold either.
#[derive(Debug, Clone)]
pub enum Parser {
    Claude(ClaudeState),
    Codex(CodexState),
}

impl Parser {
    pub fn new(agent: &str, session: Uuid) -> Self {
        if agent == "codex" { Parser::Codex(CodexState::new(session)) } else { Parser::Claude(ClaudeState::new(session)) }
    }

    pub fn parse(&mut self, line: &str) -> Vec<SessionEvent> {
        match self {
            Parser::Claude(st) => parse_claude(line, st),
            Parser::Codex(st) => parse_codex(line, st),
        }
    }
}

/// For tests and debugging: an event as the fixtures write it.
#[allow(dead_code)]
pub fn to_json(e: &SessionEvent) -> Value {
    serde_json::to_value(e).unwrap_or_else(|_| json!(null))
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../protocol/fixtures/session-events");

    fn fixture(name: &str) -> String {
        std::fs::read_to_string(format!("{FIXTURES}/{name}")).unwrap()
    }

    fn numbered(events: Vec<SessionEvent>, from: u64) -> Value {
        Value::Array(
            events
                .into_iter()
                .enumerate()
                .map(|(i, mut e)| {
                    set_seq(&mut e, from + i as u64);
                    to_json(&e)
                })
                .collect(),
        )
    }

    fn assert_events(got: Value, want: Value) {
        let (g, w) = (got.as_array().unwrap(), want.as_array().unwrap());
        for (i, (a, b)) in g.iter().zip(w).enumerate() {
            assert_eq!(a, b, "event {i} differs");
        }
        assert_eq!(g.len(), w.len(), "event count");
    }

    #[test]
    fn claude_fixture_matches_expected() {
        let session = Uuid::parse_str("3f2b6c1e-8d4a-4f7e-9b0a-1c2d3e4f5a6b").unwrap();
        let mut st = ClaudeState::new(session);
        let events: Vec<_> = fixture("claude.jsonl").lines().flat_map(|l| parse_claude(l, &mut st)).collect();
        assert_events(numbered(events, 1), serde_json::from_str(&fixture("claude.expected.json")).unwrap());
    }

    #[test]
    fn codex_fixture_matches_expected() {
        let session = Uuid::parse_str("01a1710e-273b-7952-964c-d8756239a231").unwrap();
        let mut st = CodexState::new(session);
        let events: Vec<_> = fixture("codex.jsonl").lines().flat_map(|l| parse_codex(l, &mut st)).collect();
        assert_events(numbered(events, 1), serde_json::from_str(&fixture("codex.expected.json")).unwrap());
    }

    #[test]
    fn unknown_and_garbage_lines_pass_through_as_other() {
        let session = Uuid::new_v4();
        let mut st = ClaudeState::new(session);
        let lines = [
            r#"{"type":"hologram","uuid":"u1","timestamp":"2026-10-16T19:17:31.317Z","beam":"on"}"#,
            r#"{"type":"user","message":{"role":"user","content":"still he"#,
            r#"{"type":"user","uuid":"u2","timestamp":"2026-10-16T19:17:32.000Z","message":{"role":"user","content":"hello"}}"#,
        ];
        let events: Vec<_> = lines.iter().flat_map(|l| parse_claude(l, &mut st)).collect();
        assert_eq!(events.len(), 3);
        assert!(matches!(&events[0], SessionEvent::Other { kind, id, .. } if kind == "hologram" && id == "u1"));
        assert!(matches!(&events[1], SessionEvent::Other { kind, .. } if kind == "invalid"));
        assert!(matches!(&events[2], SessionEvent::User { text, .. } if text == "hello"));

        let mut st = CodexState::new(session);
        let lines = [
            r#"{"timestamp":"2026-10-25T03:15:49.044Z","ordinal":3,"type":"response_item","payload":{"type":"teleport","id":"tp_1"}}"#,
            "not json",
            r#"{"timestamp":"2026-10-25T03:15:49.046Z","ordinal":4,"type":"event_msg","payload":{"type":"task_started"}}"#,
        ];
        let events: Vec<_> = lines.iter().flat_map(|l| parse_codex(l, &mut st)).collect();
        assert_eq!(events.len(), 3);
        assert!(matches!(&events[0], SessionEvent::Other { kind, id, .. } if kind == "response_item/teleport" && id == "tp_1"));
        assert!(matches!(&events[1], SessionEvent::Other { kind, .. } if kind == "invalid"));
        assert!(matches!(&events[2], SessionEvent::Turn { state: TurnState::Running, .. }));
    }

    #[test]
    fn long_output_keeps_head_and_tail() {
        let long = format!("{}{}", "a".repeat(3000), "z".repeat(3000));
        let (text, cut_) = cut(&long, RESULT_LIMIT);
        assert!(cut_ && text.chars().count() <= RESULT_LIMIT + 3 && text.starts_with('a') && text.ends_with('z'));
    }

    #[test]
    fn codex_apply_patch_fills_path_and_diff() {
        let p = json!({"type":"function_call","name":"apply_patch","call_id":"c1","arguments":"{\"input\":\"*** Begin Patch\\n*** Update File: src/a.rs\\n@@\\n-old\\n+new\\n*** End Patch\"}"});
        let call = codex_tool_call(&p, None);
        assert_eq!(call.path.as_deref(), Some("src/a.rs"));
        assert!(call.diff.unwrap().contains("+new"));
    }
}
