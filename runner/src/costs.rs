//! What each session has spent: measured from the agent's harness, never asked of the agent.
//!
//! Claude Code hands its status line command `cost.total_cost_usd` (its API-equivalent estimate),
//! `context_window.total_input_tokens`/`total_output_tokens` and the model; `maple-runner statusline`
//! forwards them with the session's id over the hook socket (statusline.rs). Codex says no $ figure
//! but writes `token_count` events with `total_token_usage` into its rollout file
//! (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`); the one for a session is the first whose
//! `session_meta` has the session's folder as `cwd` and started after it.
//! The latest reading per session goes to the hub as `session.cost` when it changes (at most every
//! 30s per session), all of them again on reconnect, and once more just before the session ends.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde_json::Value;
use tokio::sync::Notify;
use uuid::Uuid;

use crate::protocol::{Outbound, SessionInfo};
use crate::sessions::{Sessions, expand_home};
use crate::usage::{codex_sessions_dir, newest_rollouts_since, now_ms, parse_utc, read_tail};
use crate::wire::{RunnerMessage, SessionCost};

/// A session's reading goes out at most this often.
const SEND_EVERY: u64 = 30_000;
/// How much of the end of a rollout file to read for its latest token count.
const TAIL: u64 = 512 * 1024;
/// A rollout's `session_meta` may be stamped a little before the runner noted the session's start.
const START_SLACK: u64 = 60_000;

#[derive(Default)]
struct State {
    latest: HashMap<Uuid, SessionCost>,
    /// What went out last, and when.
    sent: HashMap<Uuid, (SessionCost, u64)>,
    /// Each Codex session's rollout file, once found.
    rollouts: HashMap<Uuid, PathBuf>,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);
static WAKE: Notify = Notify::const_new();
/// Set on reconnect: send every reading again.
static RESEND: AtomicBool = AtomicBool::new(false);

fn with<R>(f: impl FnOnce(&mut State) -> R) -> R {
    f(STATE.lock().unwrap().get_or_insert_with(State::default))
}

/// Call after (re)connecting: the hub gets every reading again.
pub fn resend() {
    RESEND.store(true, Ordering::SeqCst);
    WAKE.notify_one();
}

/// A Claude Code status line's reading (forwarded by `maple-runner statusline`).
pub fn observe_claude(msg: &Value) {
    let Some(session) = msg.get("session").and_then(Value::as_str).and_then(|s| Uuid::parse_str(s).ok()) else { return };
    if let Some(cost) = claude_cost(session, msg, now_ms()) {
        keep(cost);
    }
}

/// A Codex session's hook fired: its rollout file may have new totals.
pub fn poke() {
    WAKE.notify_one();
}

/// Keeps a reading unless it would lower a total: a restarted status line starts again from zero.
fn keep(cost: SessionCost) {
    with(|s| {
        let cost = match s.latest.get(&cost.session) {
            Some(old) => merge(old, cost),
            None => cost,
        };
        s.latest.insert(cost.session, cost);
    });
}

/// The higher of each total, and the newer model.
fn merge(old: &SessionCost, new: SessionCost) -> SessionCost {
    let max = |a: Option<f64>, b: Option<f64>| match (a, b) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (a, b) => a.or(b),
    };
    SessionCost {
        cost_usd: max(old.cost_usd, new.cost_usd),
        input_tokens: old.input_tokens.max(new.input_tokens),
        output_tokens: old.output_tokens.max(new.output_tokens),
        cache_read_tokens: old.cache_read_tokens.max(new.cache_read_tokens),
        cache_write_tokens: old.cache_write_tokens.max(new.cache_write_tokens),
        duration_ms: old.duration_ms.max(new.duration_ms),
        model: new.model.or_else(|| old.model.clone()),
        observed_at: old.observed_at.max(new.observed_at),
        ..new
    }
}

/// Sends `session.cost` whenever a reading changes (and on reconnect).
pub async fn report(sessions: Sessions) {
    loop {
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_millis(SEND_EVERY)) => {}
            _ = WAKE.notified() => {}
        }
        let codex: Vec<SessionInfo> = sessions.list().into_iter().filter(|s| s.agent == "codex").collect();
        let _ = tokio::task::spawn_blocking(move || {
            for s in codex {
                scan_codex(&s);
            }
        })
        .await;
        let resend = RESEND.swap(false, Ordering::SeqCst);
        let now = now_ms();
        let due: Vec<SessionCost> = with(|s| {
            let live: Vec<Uuid> = sessions.list().iter().map(|i| i.id).collect();
            // Ended sessions went out in `flush`; forget any a race left behind.
            s.latest.retain(|id, _| live.contains(id));
            s.sent.retain(|id, _| live.contains(id));
            s.rollouts.retain(|id, _| live.contains(id));
            let due: Vec<SessionCost> = s
                .latest
                .values()
                .filter(|c| match s.sent.get(&c.session) {
                    _ if resend => true,
                    None => true,
                    Some((old, at)) => changed(old, c) && now.saturating_sub(*at) >= SEND_EVERY,
                })
                .cloned()
                .collect();
            for c in &due {
                s.sent.insert(c.session, (c.clone(), now));
            }
            due
        });
        for cost in due {
            sessions.emit(Outbound::Wire(RunnerMessage::SessionCost { cost }));
        }
    }
}

/// Just before `session.ended`: the session's last reading, and it's forgotten.
pub async fn flush(sessions: &Sessions, info: &SessionInfo) {
    if info.agent == "codex" {
        let info = info.clone();
        let _ = tokio::task::spawn_blocking(move || scan_codex(&info)).await;
    }
    let last = with(|s| {
        s.sent.remove(&info.id);
        s.rollouts.remove(&info.id);
        s.latest.remove(&info.id)
    });
    if let Some(cost) = last {
        sessions.emit(Outbound::Wire(RunnerMessage::SessionCost { cost }));
    }
}

fn changed(old: &SessionCost, new: &SessionCost) -> bool {
    let key = |c: &SessionCost| (c.cost_usd.map(|d| (d * 10_000.0).round() as i64), c.input_tokens, c.output_tokens, c.cache_read_tokens, c.cache_write_tokens, c.model.clone());
    key(old) != key(new)
}

// ---- Claude Code ----

/// A Claude Code status line input (or what statusline.rs forwards of it) as a reading:
/// `cost.total_cost_usd` and `.total_duration_ms`, `context_window.total_input_tokens` and
/// `.total_output_tokens`, `model.id`. None when it has neither a cost nor tokens.
pub fn claude_cost(session: Uuid, input: &Value, now: u64) -> Option<SessionCost> {
    let cost = input.pointer("/cost/total_cost_usd").and_then(Value::as_f64).filter(|c| c.is_finite() && *c >= 0.0);
    let tokens = |k: &str| input.get("context_window").and_then(|c| c.get(k)).and_then(Value::as_u64);
    let (input_tokens, output_tokens) = (tokens("total_input_tokens"), tokens("total_output_tokens"));
    if cost.is_none() && input_tokens.is_none() && output_tokens.is_none() {
        return None;
    }
    let model = ["/model/id", "/model/display_name"].iter().find_map(|p| input.pointer(p).and_then(Value::as_str)).filter(|m| !m.is_empty());
    Some(SessionCost {
        session,
        agent: "claude".into(),
        model: model.map(str::to_string),
        cost_usd: cost,
        input_tokens: input_tokens.unwrap_or(0),
        output_tokens: output_tokens.unwrap_or(0),
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        duration_ms: input.pointer("/cost/total_duration_ms").and_then(Value::as_u64),
        observed_at: now,
    })
}

// ---- Codex ----

/// Reads a Codex session's rollout file (finding it first) into its reading.
fn scan_codex(info: &SessionInfo) {
    let path = match with(|s| s.rollouts.get(&info.id).cloned()) {
        Some(p) => p,
        None => {
            let Some(p) = find_rollout(&codex_sessions_dir(), &expand_home(&info.cwd), info.started_at) else { return };
            with(|s| s.rollouts.insert(info.id, p.clone()));
            p
        }
    };
    let Some(tail) = read_tail(&path, TAIL) else { return };
    let Some(mut cost) = parse_codex_tail(&tail) else { return };
    cost.session = info.id;
    if cost.model.is_none() {
        cost.model = first_model(&path);
    }
    keep(cost);
}

/// The first rollout file (in start order) for a session in `cwd` that started after `started_at`.
/// Two sessions in one worktree (a builder, then a reviewer) each get their own.
fn find_rollout(dir: &Path, cwd: &Path, started_at: u64) -> Option<PathBuf> {
    let since = started_at.saturating_sub(START_SLACK);
    let mut found: Vec<(u64, PathBuf)> = newest_rollouts_since(dir, since)
        .into_iter()
        .filter_map(|path| {
            let (meta_cwd, at) = session_meta(&path)?;
            (at >= since && same_dir(&meta_cwd, cwd)).then_some((at, path))
        })
        .collect();
    found.sort();
    found.into_iter().next().map(|(_, p)| p)
}

fn same_dir(a: &Path, b: &Path) -> bool {
    let canon = |p: &Path| std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
    a == b || canon(a) == canon(b)
}

/// A rollout file's first line, `session_meta`: its `cwd` and start time.
fn session_meta(path: &Path) -> Option<(PathBuf, u64)> {
    let mut line = String::new();
    BufReader::new(std::fs::File::open(path).ok()?.take(4 << 20)).read_line(&mut line).ok()?;
    parse_session_meta(&line)
}

pub fn parse_session_meta(line: &str) -> Option<(PathBuf, u64)> {
    let v: Value = serde_json::from_str(line).ok()?;
    if v.get("type").and_then(Value::as_str) != Some("session_meta") {
        return None;
    }
    let p = v.get("payload")?;
    let at = p.get("timestamp").or_else(|| v.get("timestamp")).and_then(Value::as_str).and_then(parse_utc)?;
    Some((PathBuf::from(p.get("cwd")?.as_str()?), at))
}

/// The model of a rollout's first turn, for a tail too short to have one.
fn first_model(path: &Path) -> Option<String> {
    let reader = BufReader::new(std::fs::File::open(path).ok()?.take(16 << 20));
    reader.lines().map_while(Result::ok).filter(|l| l.contains("\"turn_context\"")).find_map(|l| turn_model(&serde_json::from_str(&l).ok()?))
}

fn turn_model(v: &Value) -> Option<String> {
    if v.get("type").and_then(Value::as_str) != Some("turn_context") {
        return None;
    }
    v.pointer("/payload/model").and_then(Value::as_str).filter(|m| !m.is_empty()).map(str::to_string)
}

/// The last `token_count` totals in the end of a rollout file, with the latest turn's model. Codex's
/// `input_tokens` includes the cached ones; here they're split out, as Claude's are.
pub fn parse_codex_tail(tail: &str) -> Option<SessionCost> {
    let mut model = None;
    let mut cost = None;
    for line in tail.lines().rev() {
        if cost.is_some() && model.is_some() {
            break;
        }
        let interesting = (cost.is_none() && line.contains("\"total_token_usage\"")) || (model.is_none() && line.contains("\"turn_context\""));
        if !interesting {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        if model.is_none() {
            model = turn_model(&v);
        }
        if cost.is_none()
            && v.pointer("/payload/type").and_then(Value::as_str) == Some("token_count")
            && let Some(total) = v.pointer("/payload/info/total_token_usage")
        {
            let n = |k: &str| total.get(k).and_then(Value::as_u64).unwrap_or(0);
            let cached = n("cached_input_tokens");
            cost = Some(SessionCost {
                session: Uuid::nil(),
                agent: "codex".into(),
                model: None,
                cost_usd: None,
                input_tokens: n("input_tokens").saturating_sub(cached),
                output_tokens: n("output_tokens"),
                cache_read_tokens: cached,
                cache_write_tokens: n("cache_write_input_tokens"),
                duration_ms: None,
                observed_at: v.get("timestamp").and_then(Value::as_str).and_then(parse_utc).unwrap_or_else(now_ms),
            });
        }
    }
    let mut cost = cost?;
    cost.model = model;
    Some(cost)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn id() -> Uuid {
        Uuid::parse_str("6b0e7c1e-3c55-4b8e-9d0f-2a3e4b5c6d7e").unwrap()
    }

    #[test]
    fn claude_status_line_payload() {
        let input = json!({
            "session_id": "abc",
            "model": { "id": "claude-opus-5-5", "display_name": "Opus 5.5" },
            "cost": { "total_cost_usd": 1.2345, "total_duration_ms": 90_000, "total_api_duration_ms": 40_000 },
            "context_window": { "total_input_tokens": 15_234, "total_output_tokens": 4_521, "context_window_size": 200_000 },
            "rate_limits": null
        });
        let c = claude_cost(id(), &input, 7).unwrap();
        assert_eq!(c.session, id());
        assert_eq!((c.agent.as_str(), c.model.as_deref()), ("claude", Some("claude-opus-5-5")));
        assert_eq!(c.cost_usd, Some(1.2345));
        assert_eq!((c.input_tokens, c.output_tokens, c.duration_ms, c.observed_at), (15_234, 4_521, Some(90_000), 7));
        // Nothing to measure: no reading.
        assert!(claude_cost(id(), &json!({ "model": { "id": "x" } }), 7).is_none());
        // Cost alone (an older Claude Code without context_window).
        let c = claude_cost(id(), &json!({ "cost": { "total_cost_usd": 0.5 } }), 7).unwrap();
        assert_eq!((c.cost_usd, c.input_tokens, c.model), (Some(0.5), 0, None));
    }

    #[test]
    fn codex_rollout_token_count() {
        let lines = [
            json!({ "timestamp": "2026-10-25T06:50:12.904Z", "type": "turn_context", "payload": { "cwd": "/w", "model": "gpt-6.1-sol" } }),
            json!({ "timestamp": "2026-10-25T06:51:00.000Z", "type": "event_msg", "payload": { "type": "token_count", "info": { "total_token_usage": { "input_tokens": 1000, "cached_input_tokens": 600, "output_tokens": 50, "total_tokens": 1050 } } } }),
            json!({ "timestamp": "2026-10-25T06:53:36.153Z", "type": "event_msg", "payload": { "type": "token_count", "info": {
                "total_token_usage": { "input_tokens": 384_364, "cached_input_tokens": 358_272, "cache_write_input_tokens": 0, "output_tokens": 1552, "reasoning_output_tokens": 0, "total_tokens": 385_916 },
                "last_token_usage": { "input_tokens": 48_776, "cached_input_tokens": 46_080, "output_tokens": 27 }
            } } }),
            json!({ "timestamp": "2026-10-25T06:53:37.000Z", "type": "event_msg", "payload": { "type": "token_count", "info": null } }),
        ];
        let tail = lines.iter().map(Value::to_string).collect::<Vec<_>>().join("\n");
        let c = parse_codex_tail(&tail).unwrap();
        assert_eq!((c.agent.as_str(), c.model.as_deref(), c.cost_usd), ("codex", Some("gpt-6.1-sol"), None));
        assert_eq!((c.input_tokens, c.cache_read_tokens, c.output_tokens, c.cache_write_tokens), (26_092, 358_272, 1552, 0));
        assert_eq!(c.observed_at, parse_utc("2026-10-25T06:53:36.153Z").unwrap());
        assert!(parse_codex_tail("{\"type\":\"session_meta\"}").is_none());
    }

    #[test]
    fn a_lower_reading_never_lowers_a_total() {
        let first = claude_cost(id(), &json!({ "model": { "id": "m" }, "cost": { "total_cost_usd": 2.0 }, "context_window": { "total_input_tokens": 100, "total_output_tokens": 10 } }), 1).unwrap();
        let restarted = claude_cost(id(), &json!({ "cost": { "total_cost_usd": 0.1 }, "context_window": { "total_input_tokens": 5, "total_output_tokens": 50 } }), 2).unwrap();
        let m = merge(&first, restarted);
        assert_eq!((m.cost_usd, m.input_tokens, m.output_tokens, m.model.as_deref(), m.observed_at), (Some(2.0), 100, 50, Some("m"), 2));
    }

    #[test]
    fn finds_each_sessions_own_rollout() {
        let dir = std::env::temp_dir().join(format!("maple-costs-{}", Uuid::new_v4()));
        let day = dir.join("2026/10/25");
        std::fs::create_dir_all(&day).unwrap();
        let work = dir.join("work");
        std::fs::create_dir_all(&work).unwrap();
        let meta = |at: &str, cwd: &Path| json!({ "type": "session_meta", "payload": { "timestamp": at, "cwd": cwd } }).to_string() + "\n";
        std::fs::write(day.join("rollout-a.jsonl"), meta("2026-10-25T06:00:00Z", &work)).unwrap();
        std::fs::write(day.join("rollout-b.jsonl"), meta("2026-10-25T07:00:00Z", &work)).unwrap();
        std::fs::write(day.join("rollout-c.jsonl"), meta("2026-10-25T06:30:00Z", Path::new("/elsewhere"))).unwrap();
        let at = |s: &str| parse_utc(s).unwrap();
        // The builder started at 05:59, the reviewer at 06:59, in the same worktree.
        assert_eq!(find_rollout(&dir, &work, at("2026-10-25T05:59:30Z")), Some(day.join("rollout-a.jsonl")));
        assert_eq!(find_rollout(&dir, &work, at("2026-10-25T06:59:30Z")), Some(day.join("rollout-b.jsonl")));
        assert_eq!(find_rollout(&dir, &work, at("2026-10-25T08:00:00Z")), None);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
