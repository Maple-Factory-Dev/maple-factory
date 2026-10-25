//! Plan usage limits: how much of its 5-hour and weekly windows each agent's account has used.
//!
//! Claude Code hands its status line command `rate_limits` on stdin; `maple-runner statusline`
//! (statusline.rs) forwards them here over the hook socket. Codex is asked directly: its app
//! server (`codex app-server`, JSON-RPC over stdio) answers `account/rateLimits/read` with the
//! account's live limits, every few minutes and after a Codex session's hook fires. Codex also
//! writes `rate_limits` into its session files (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`);
//! those are read every minute as a fallback (an older Codex, or one that can't be started).
//! Claude Code is also asked directly every five minutes (unless that's turned off in Settings):
//! `claude -p /usage --output-format stream-json` runs `/usage` as a local command (no model turn,
//! no tokens; Haiku is named anyway so a change there would cost the least) and attaches a
//! structured `usage_report`, which also has the per-model weekly limits.
//! The latest reading per agent goes to the hub as a `usage` report when it changes.

use std::collections::BTreeMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::Value;
use tokio::sync::Notify;

use crate::protocol::Outbound;
use crate::sessions::Sessions;

/// Codex's session files are read this often (and when a Codex session's hook fires).
const SCAN_EVERY: Duration = Duration::from_secs(60);
/// A reading that changed nothing is still sent this long after the last one, so "as of" stays honest.
const REFRESH_AFTER: u64 = 5 * 60_000;
/// How much of the end of a session file to read for its latest token count.
const TAIL: u64 = 512 * 1024;
/// Session files to look at, newest first, before giving up.
const FILES: usize = 4;
/// Day folders to look through (a long session keeps writing to the folder of the day it started).
const DAYS: usize = 7;
/// Codex's app server is asked this often, and at most this often after hooks.
const ASK_EVERY: u64 = 5 * 60_000;
const ASK_AFTER_HOOK: u64 = 60_000;
/// How long the app server gets to answer.
const ASK_TIMEOUT: Duration = Duration::from_secs(15);

/// One limit window: "5h" at 23%, resetting at some time.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    /// "5h", "7d", or another length for plans with other windows; "spend" for a spend limit.
    pub label: String,
    pub used_percent: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_minutes: Option<u32>,
    /// Unix milliseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<u64>,
    /// What a scoped limit covers ("Fable" for a model's own weekly limit).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// The latest reading for one agent's account.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentUsage {
    pub agent: &'static str,
    pub windows: Vec<Window>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    /// When the reading was taken (Unix ms).
    pub observed_at: u64,
    /// "statusline" (Claude Code), "app-server" or "session-file" (Codex).
    pub source: &'static str,
    /// Codex: free "full reset" credits the account can spend.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reset_credits: Option<u32>,
    /// Who the agent is signed in as on this machine (machines can use different accounts).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account: Option<Account>,
}

/// An agent's signed-in account: Claude Code's `claude auth status`, Codex's `account/read`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    /// A stable id (Claude's organization, Codex's ChatGPT account), when there is one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    /// Claude's organization name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

static LATEST: Mutex<BTreeMap<&'static str, AgentUsage>> = Mutex::new(BTreeMap::new());
static WAKE: Notify = Notify::const_new();
/// Set on reconnect: send every reading again.
static RESEND: AtomicBool = AtomicBool::new(false);
/// Read Codex's session files on the next wake.
static SCAN: AtomicBool = AtomicBool::new(true);
/// Ask Codex's app server on the next wake (if it hasn't been asked too recently).
static ASK: AtomicBool = AtomicBool::new(true);
/// The signed-in accounts (and Claude's plan), looked up now and then.
static CLAUDE_ACCOUNT: Mutex<Option<(Account, Option<String>)>> = Mutex::new(None);
static CODEX_ACCOUNT: Mutex<Option<Account>> = Mutex::new(None);
/// Claude Code's account is looked up this often.
const CLAUDE_ACCOUNT_EVERY: u64 = 10 * 60_000;
/// Claude Code's `/usage` is run this often, unless Settings turned it off.
const CLAUDE_USAGE_EVERY: u64 = 5 * 60_000;
/// Run Claude Code's `/usage` in the background (Settings → Usage; the hub says on connect).
static CLAUDE_CHECK: AtomicBool = AtomicBool::new(true);
/// Someone pressed Refresh on an agent's card: ask that agent now.
static REFRESH_CLAUDE: AtomicBool = AtomicBool::new(false);
static REFRESH_CODEX: AtomicBool = AtomicBool::new(false);

/// Call after (re)connecting: the hub gets every reading again.
pub fn resend() {
    RESEND.store(true, Ordering::SeqCst);
    WAKE.notify_one();
}

/// The hub's `usage.config`: whether to run Claude Code's `/usage` in the background.
pub fn configure(claude_check: bool) {
    CLAUDE_CHECK.store(claude_check, Ordering::SeqCst);
}

/// The hub's `usage.refresh` (Refresh on an agent's card on the Usage page): ask that agent now.
pub fn refresh_now(agent: &str) {
    match agent {
        "claude" => REFRESH_CLAUDE.store(true, Ordering::SeqCst),
        "codex" => REFRESH_CODEX.store(true, Ordering::SeqCst),
        _ => return,
    }
    WAKE.notify_one();
}

/// A Codex session did something: its session file may have new limits.
pub fn poke_codex() {
    SCAN.store(true, Ordering::SeqCst);
    ASK.store(true, Ordering::SeqCst);
    WAKE.notify_one();
}

/// A Claude Code status line's `rate_limits` (forwarded by `maple-runner statusline`).
pub fn observe_claude(msg: &Value) {
    let windows = claude_windows(msg.get("rateLimits").unwrap_or(&Value::Null));
    if windows.is_empty() {
        return;
    }
    let usage = AgentUsage { agent: "claude", windows, plan: None, observed_at: now_ms(), source: "statusline", reset_credits: None, account: None };
    keep_claude(usage);
    WAKE.notify_one();
}

/// Sends a `usage` report whenever a reading changes (and on reconnect).
pub async fn report(sessions: Sessions) {
    let mut sent: BTreeMap<&'static str, AgentUsage> = BTreeMap::new();
    let mut asked_at = 0u64;
    let mut claude_checked_at = 0u64;
    let mut claude_usage_at = 0u64;
    loop {
        tokio::select! {
            _ = tokio::time::sleep(SCAN_EVERY) => SCAN.store(true, Ordering::SeqCst),
            _ = WAKE.notified() => {}
        }
        let now = now_ms();
        let refresh_claude = REFRESH_CLAUDE.swap(false, Ordering::SeqCst);
        let refresh_codex = REFRESH_CODEX.swap(false, Ordering::SeqCst);
        if refresh_claude || now.saturating_sub(claude_checked_at) >= CLAUDE_ACCOUNT_EVERY {
            claude_checked_at = now;
            if let Some(found) = claude_account().await {
                *CLAUDE_ACCOUNT.lock().unwrap() = Some(found.clone());
                if let Some(u) = LATEST.lock().unwrap().get_mut("claude") {
                    (u.account, u.plan) = (Some(found.0), found.1);
                }
            }
        }
        if refresh_claude || (CLAUDE_CHECK.load(Ordering::SeqCst) && now.saturating_sub(claude_usage_at) >= CLAUDE_USAGE_EVERY) {
            claude_usage_at = now;
            if let Some(claude) = claude_usage().await {
                keep_claude(claude);
            }
        }
        let due = refresh_codex || now.saturating_sub(asked_at) >= ASK_EVERY;
        let mut asked = None;
        if due || (ASK.load(Ordering::SeqCst) && now.saturating_sub(asked_at) >= ASK_AFTER_HOOK) {
            ASK.store(false, Ordering::SeqCst);
            asked_at = now;
            asked = ask_codex().await;
        }
        if let Some(codex) = asked {
            SCAN.store(false, Ordering::SeqCst);
            keep_codex(codex);
        } else if SCAN.swap(false, Ordering::SeqCst)
            && let Ok(Some(codex)) = tokio::task::spawn_blocking(|| scan_codex(&codex_sessions_dir())).await
        {
            keep_codex(codex);
        }
        let resend = RESEND.swap(false, Ordering::SeqCst);
        let latest = LATEST.lock().unwrap().clone();
        // A refreshed agent goes out even when nothing changed, so its card says "just now".
        let forced = |agent: &str| (agent == "claude" && refresh_claude) || (agent == "codex" && refresh_codex);
        let changed: Vec<AgentUsage> =
            latest.values().filter(|u| resend || forced(u.agent) || sent.get(u.agent).is_none_or(|old| worth_sending(old, u))).cloned().collect();
        if changed.is_empty() {
            continue;
        }
        for u in &changed {
            sent.insert(u.agent, u.clone());
        }
        sessions.emit(Outbound::Usage { agents: changed });
    }
}

/// Keeps a Claude Code reading unless a newer one is there, with the machine's account. A status
/// line reading has no per-model limits, so it keeps the last `/usage` ones until they reset.
fn keep_claude(mut claude: AgentUsage) {
    if let Some((account, plan)) = CLAUDE_ACCOUNT.lock().unwrap().clone() {
        claude.account.get_or_insert(account);
        if claude.plan.is_none() {
            claude.plan = plan;
        }
    }
    let mut latest = LATEST.lock().unwrap();
    if let Some(old) = latest.get("claude") {
        if claude.observed_at < old.observed_at {
            return;
        }
        let now = now_ms();
        for w in &old.windows {
            if !claude.windows.iter().any(|n| n.label == w.label) && w.name.is_some() && w.resets_at.is_none_or(|r| r > now) {
                claude.windows.push(w.clone());
            }
        }
    }
    latest.insert("claude", claude);
}

/// Keeps a Codex reading unless a newer one is already there. A session file's older limits
/// keep the app server's credit count.
fn keep_codex(mut codex: AgentUsage) {
    if codex.account.is_none() {
        codex.account = CODEX_ACCOUNT.lock().unwrap().clone();
    }
    let mut latest = LATEST.lock().unwrap();
    if let Some(old) = latest.get("codex") {
        if codex.observed_at < old.observed_at {
            return;
        }
        if codex.reset_credits.is_none() {
            codex.reset_credits = old.reset_credits;
        }
    }
    latest.insert("codex", codex);
}

/// A new reading is worth a message when a number changed, or the last one sent is getting old.
fn worth_sending(old: &AgentUsage, new: &AgentUsage) -> bool {
    // Codex's reset time wobbles by a few seconds from one event to the next.
    let minute = |w: &Window| (w.label.clone(), (w.used_percent * 10.0).round() as i64, w.resets_at.map(|r| r / 60_000));
    let same = old.plan == new.plan
        && old.reset_credits == new.reset_credits
        && old.account == new.account
        && old.windows.len() == new.windows.len()
        && old.windows.iter().zip(&new.windows).all(|(a, b)| minute(a) == minute(b));
    !same || new.observed_at.saturating_sub(old.observed_at) >= REFRESH_AFTER
}

// ---- Claude Code ----

/// Claude Code's status line input has `rate_limits.five_hour` and `.seven_day` (and `.spend_limit`
/// behind a gateway), each `{ used_percentage, resets_at }` with `resets_at` in Unix seconds.
pub fn claude_windows(rate_limits: &Value) -> Vec<Window> {
    [("five_hour", "5h", Some(300)), ("seven_day", "7d", Some(10_080)), ("spend_limit", "spend", None)]
        .into_iter()
        .filter_map(|(key, label, minutes)| {
            let w = rate_limits.get(key)?;
            let used = w.get("used_percentage")?.as_f64().filter(|p| p.is_finite())?;
            Some(Window { label: label.into(), used_percent: used, window_minutes: minutes, resets_at: seconds_to_ms(w.get("resets_at")), name: None })
        })
        .collect()
}

// ---- Codex ----

/// `$CODEX_HOME/sessions`, else `~/.codex/sessions`.
fn codex_sessions_dir() -> PathBuf {
    match std::env::var_os("CODEX_HOME") {
        Some(home) if !home.is_empty() => PathBuf::from(home).join("sessions"),
        _ => PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".codex/sessions"),
    }
}

/// The newest rate limits in Codex's session files, if any.
fn scan_codex(dir: &Path) -> Option<AgentUsage> {
    newest_rollouts(dir).into_iter().find_map(|(path, modified)| {
        let tail = read_tail(&path, TAIL)?;
        let mut usage = parse_codex(&tail)?;
        if usage.observed_at == 0 {
            usage.observed_at = modified;
        }
        Some(usage)
    })
}

/// The most recently written `rollout-*.jsonl` files under the newest day folders, newest first.
fn newest_rollouts(dir: &Path) -> Vec<(PathBuf, u64)> {
    // Folder names sort by date: YYYY/MM/DD.
    let children = |p: &Path| -> Vec<PathBuf> {
        let mut v: Vec<PathBuf> = std::fs::read_dir(p).map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect()).unwrap_or_default();
        v.sort();
        v.reverse();
        v
    };
    let mut days = Vec::new();
    'outer: for year in children(dir) {
        for month in children(&year) {
            for day in children(&month) {
                days.push(day);
                if days.len() >= DAYS {
                    break 'outer;
                }
            }
        }
    }
    let mut files: Vec<(PathBuf, u64)> = days
        .iter()
        .flat_map(|d| std::fs::read_dir(d).into_iter().flatten().flatten())
        .filter(|e| {
            let name = e.file_name();
            let name = name.to_string_lossy();
            name.starts_with("rollout-") && name.ends_with(".jsonl")
        })
        .filter_map(|e| {
            let modified = e.metadata().ok()?.modified().ok()?;
            Some((e.path(), modified.duration_since(UNIX_EPOCH).ok()?.as_millis() as u64))
        })
        .collect();
    files.sort_by_key(|f| std::cmp::Reverse(f.1));
    files.truncate(FILES);
    files
}

/// The last `max` bytes of a file, from the start of a line.
fn read_tail(path: &Path, max: u64) -> Option<String> {
    let mut f = std::fs::File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    let start = len.saturating_sub(max);
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::new();
    f.take(max).read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf).into_owned();
    Some(match (start > 0, text.find('\n')) {
        (true, Some(n)) => text[n + 1..].to_string(),
        _ => text,
    })
}

/// The last `token_count` event with rate limits in the end of a Codex session file. Codex's
/// own limits (`limit_id` "codex") win over any other bucket in the same file.
pub fn parse_codex(tail: &str) -> Option<AgentUsage> {
    let mut fallback = None;
    for line in tail.lines().rev() {
        if !line.contains("\"rate_limits\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        let payload = v.get("payload")?;
        if payload.get("type").and_then(Value::as_str) != Some("token_count") {
            continue;
        }
        let Some(limits) = payload.get("rate_limits").filter(|l| l.is_object()) else { continue };
        let windows: Vec<Window> = ["primary", "secondary"]
            .into_iter()
            .filter_map(|k| {
                let w = limits.get(k)?;
                let used = w.get("used_percent")?.as_f64().filter(|p| p.is_finite())?;
                let minutes = w.get("window_minutes").and_then(Value::as_u64).map(|m| m as u32);
                Some(Window {
                    label: minutes.map(window_label).unwrap_or_else(|| k.into()),
                    used_percent: used,
                    window_minutes: minutes,
                    resets_at: seconds_to_ms(w.get("resets_at")),
                    name: None,
                })
            })
            .collect();
        if windows.is_empty() {
            continue;
        }
        let mut windows = windows;
        windows.sort_by_key(|w| w.window_minutes.unwrap_or(u32::MAX));
        let usage = AgentUsage {
            agent: "codex",
            windows,
            plan: limits.get("plan_type").and_then(Value::as_str).filter(|p| !p.is_empty()).map(str::to_string),
            observed_at: v.get("timestamp").and_then(Value::as_str).and_then(parse_utc).unwrap_or(0),
            source: "session-file",
            reset_credits: None,
            account: None,
        };
        match limits.get("limit_id").and_then(Value::as_str) {
            None | Some("codex") => return Some(usage),
            Some(_) => {
                fallback.get_or_insert(usage);
            }
        }
    }
    fallback
}

/// Codex's live limits from its app server: `initialize`, then `account/rateLimits/read`.
/// Started through an interactive login shell (Codex is often installed by a Node version manager
/// set up in .zshrc), with
/// the command from agents.toml. None if Codex isn't installed, isn't signed in, or is too old.
async fn ask_codex() -> Option<AgentUsage> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let command = crate::agent_config::load().into_iter().find(|a| a.id == "codex")?.command;
    let mut child = tokio::process::Command::new(crate::agents::login_shell())
        .args(["-l", "-i", "-c", &format!("exec {command} app-server")])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let mut stdin = child.stdin.take()?;
    let mut lines = BufReader::new(child.stdout.take()?).lines();
    let talk = async {
        let mut usage: Option<AgentUsage> = None;
        let send = |v: Value| format!("{v}\n");
        let init = serde_json::json!({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "maple-runner", "title": "Agent Orchestrator", "version": env!("CARGO_PKG_VERSION")}}});
        stdin.write_all(send(init).as_bytes()).await.ok()?;
        loop {
            let line = lines.next_line().await.ok()??;
            let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
            match msg.get("id").and_then(Value::as_u64) {
                Some(1) => {
                    stdin.write_all(send(serde_json::json!({"method": "initialized"})).as_bytes()).await.ok()?;
                    stdin.write_all(send(serde_json::json!({"id": 2, "method": "account/rateLimits/read", "params": {}})).as_bytes()).await.ok()?;
                }
                Some(2) => {
                    usage = msg.get("result").and_then(|r| parse_app_server(r, now_ms()));
                    usage.as_ref()?;
                    let read = serde_json::json!({"id": 3, "method": "account/read", "params": {"refreshToken": false}});
                    stdin.write_all(send(read).as_bytes()).await.ok()?;
                }
                Some(3) => {
                    let account = msg.get("result").and_then(codex_account);
                    if account.is_some() {
                        CODEX_ACCOUNT.lock().unwrap().clone_from(&account);
                    }
                    let mut u = usage.take()?;
                    u.account = account;
                    return Some(u);
                }
                _ => {}
            }
        }
    };
    let usage = tokio::time::timeout(ASK_TIMEOUT, talk).await.ok().flatten();
    let _ = child.kill().await;
    usage
}

/// The answer to `account/rateLimits/read`: `rateLimits` (Codex's own bucket) with `primary` and
/// `secondary` windows of `{ usedPercent, windowDurationMins, resetsAt (Unix s) }`, `planType`,
/// and `rateLimitResetCredits.availableCount`.
pub fn parse_app_server(result: &Value, now: u64) -> Option<AgentUsage> {
    let limits = result.get("rateLimitsByLimitId").and_then(|b| b.get("codex")).or_else(|| result.get("rateLimits"))?;
    let mut windows: Vec<Window> = ["primary", "secondary"]
        .into_iter()
        .filter_map(|k| {
            let w = limits.get(k)?;
            let used = w.get("usedPercent")?.as_f64().filter(|p| p.is_finite())?;
            let minutes = w.get("windowDurationMins").and_then(Value::as_u64).map(|m| m as u32);
            Some(Window {
                label: minutes.map(window_label).unwrap_or_else(|| k.into()),
                used_percent: used,
                window_minutes: minutes,
                resets_at: seconds_to_ms(w.get("resetsAt")),
                name: None,
            })
        })
        .collect();
    if windows.is_empty() {
        return None;
    }
    windows.sort_by_key(|w| w.window_minutes.unwrap_or(u32::MAX));
    Some(AgentUsage {
        agent: "codex",
        windows,
        plan: limits.get("planType").and_then(Value::as_str).filter(|p| !p.is_empty()).map(str::to_string),
        observed_at: now,
        source: "app-server",
        reset_credits: result.pointer("/rateLimitResetCredits/availableCount").and_then(Value::as_u64).map(|n| n.min(999) as u32),
        account: None,
    })
}

/// The answer to `account/read`: `account.email`, and the ChatGPT account id as a stable id.
pub fn codex_account(result: &Value) -> Option<Account> {
    let text = |v: Option<&Value>| v.and_then(Value::as_str).filter(|s| !s.is_empty()).map(|s| s.chars().take(200).collect::<String>());
    let account = Account { id: text(result.pointer("/workspaceRouting/chatgptAccountId")), email: text(result.pointer("/account/email")), name: None };
    (account.id.is_some() || account.email.is_some()).then_some(account)
}

/// Claude Code's `/usage`, run as a local command: `claude -p /usage` with stream-json output,
/// whose assistant message carries `usage_report`. Only the user's own settings are loaded (the
/// report needs them; project ones don't apply), and no MCP servers or session file.
async fn claude_usage() -> Option<AgentUsage> {
    let command = crate::agent_config::load().into_iter().find(|a| a.id == "claude")?.command;
    let args = "-p /usage --model claude-haiku-5-5 --output-format stream-json --verbose --no-session-persistence --strict-mcp-config --setting-sources user";
    let mut cmd = tokio::process::Command::new(crate::agents::login_shell());
    cmd.args(["-l", "-i", "-c", &format!("exec {command} {args}")]).stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null()).kill_on_drop(true);
    if let Ok(dir) = crate::config::dir() {
        cmd.current_dir(dir);
    }
    let out = tokio::time::timeout(Duration::from_secs(45), cmd.output()).await.ok()?.ok()?;
    String::from_utf8_lossy(&out.stdout).lines().find_map(|line| {
        let v: Value = serde_json::from_str(line).ok()?;
        parse_usage_report(v.pointer("/message/usage_report").or_else(|| v.get("usage_report"))?, now_ms())
    })
}

/// `usage_report.rate_limits.limits`: `{ kind: "session" | "weekly_all" | "weekly_scoped", percent,
/// resets_at (ISO 8601), scope: { model: { display_name } } }`.
pub fn parse_usage_report(report: &Value, now: u64) -> Option<AgentUsage> {
    let limits = report.pointer("/rate_limits/limits")?.as_array()?;
    let mut windows: Vec<Window> = limits
        .iter()
        .filter_map(|l| {
            let percent = l.get("percent")?.as_f64().filter(|p| p.is_finite())?;
            let resets_at = l.get("resets_at").and_then(Value::as_str).and_then(parse_iso);
            let (label, minutes, name) = match l.get("kind")?.as_str()? {
                "session" => ("5h".to_string(), Some(300), None),
                "weekly_all" => ("7d".to_string(), Some(10080), None),
                "weekly_scoped" => {
                    let name: String = l.pointer("/scope/model/display_name").and_then(Value::as_str)?.chars().take(40).collect();
                    (format!("7d:{}", name.to_lowercase()).chars().take(16).collect(), Some(10080), Some(name))
                }
                _ => return None,
            };
            Some(Window { label, used_percent: percent, window_minutes: minutes, resets_at, name })
        })
        .collect();
    if windows.is_empty() {
        return None;
    }
    windows.sort_by_key(|w| (w.name.is_some(), w.window_minutes.unwrap_or(u32::MAX)));
    Some(AgentUsage { agent: "claude", windows, plan: None, observed_at: now, source: "usage-command", reset_credits: None, account: None })
}

/// An ISO 8601 time with `Z` or a `±hh:mm` offset, as Unix ms.
pub fn parse_iso(s: &str) -> Option<u64> {
    if s.ends_with('Z') {
        return parse_utc(s);
    }
    let (at, sign, offset) = match s.rfind(['+', '-']) {
        Some(i) if i > 10 => (&s[..i], if &s[i..=i] == "+" { 1 } else { -1 }, &s[i + 1..]),
        _ => return None,
    };
    let (h, m) = offset.split_once(':').unwrap_or((offset, "0"));
    let minutes = h.parse::<i64>().ok()? * 60 + m.parse::<i64>().ok()?;
    let utc = parse_utc(&format!("{at}Z"))? as i64 - sign * minutes * 60_000;
    u64::try_from(utc).ok()
}

/// `claude auth status` (JSON): `email`, `orgId`, `orgName` and `subscriptionType` ("max", "pro").
/// Through an interactive login shell with the command from agents.toml, like Codex.
async fn claude_account() -> Option<(Account, Option<String>)> {
    let command = crate::agent_config::load().into_iter().find(|a| a.id == "claude")?.command;
    let out = tokio::time::timeout(
        ASK_TIMEOUT,
        tokio::process::Command::new(crate::agents::login_shell())
            .args(["-l", "-i", "-c", &format!("exec {command} auth status")])
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    parse_claude_account(&serde_json::from_slice(&out.stdout).ok()?)
}

pub fn parse_claude_account(status: &Value) -> Option<(Account, Option<String>)> {
    if status.get("loggedIn").and_then(Value::as_bool) == Some(false) {
        return None;
    }
    let text = |k: &str| status.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(|s| s.chars().take(200).collect::<String>());
    let account = Account { id: text("orgId"), email: text("email"), name: text("orgName") };
    (account.id.is_some() || account.email.is_some()).then(|| (account, text("subscriptionType")))
}

/// 300 → "5h", 10080 → "7d", 90 → "90m".
pub fn window_label(minutes: u32) -> String {
    match minutes {
        m if m > 0 && m % 1440 == 0 => format!("{}d", m / 1440),
        m if m > 0 && m % 60 == 0 => format!("{}h", m / 60),
        m => format!("{m}m"),
    }
}

fn seconds_to_ms(v: Option<&Value>) -> Option<u64> {
    let s = v?.as_f64().filter(|s| s.is_finite() && *s > 0.0)?;
    Some((s * 1000.0) as u64)
}

/// "2026-08-14T00:23:22.469Z" → Unix ms. Only UTC ("Z"), which is what Codex writes.
pub fn parse_utc(s: &str) -> Option<u64> {
    let s = s.strip_suffix('Z')?;
    let (date, time) = s.split_once('T')?;
    let mut d = date.splitn(3, '-').map(|p| p.parse::<i64>().ok());
    let (y, m, day) = (d.next()??, d.next()??, d.next()??);
    let (hms, frac) = time.split_once('.').unwrap_or((time, ""));
    let mut t = hms.splitn(3, ':').map(|p| p.parse::<i64>().ok());
    let (hh, mm, ss) = (t.next()??, t.next()??, t.next()??);
    if !(1..=12).contains(&m) || !(1..=31).contains(&day) || hh > 23 || mm > 59 || ss > 60 {
        return None;
    }
    let ms: i64 = format!("{frac:0<3}").get(..3)?.parse().ok()?;
    // Days from 1970-01-01 (Howard Hinnant's days_from_civil).
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u64::try_from(((days * 24 + hh) * 60 + mm) * 60_000 + ss * 1000 + ms).ok()
}

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    #[test]
    fn app_server_rate_limits() {
        let result = serde_json::json!({
            "rateLimits": {"limitId": "codex", "primary": {"usedPercent": 3, "windowDurationMins": 10080, "resetsAt": 1792377139}, "secondary": null, "planType": "prolite"},
            "rateLimitsByLimitId": {"codex": {"limitId": "codex", "primary": {"usedPercent": 40.5, "windowDurationMins": 10080, "resetsAt": 1792377139},
                "secondary": {"usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1791790000}, "planType": "pro"}},
            "rateLimitResetCredits": {"availableCount": 3, "credits": []}
        });
        let u = parse_app_server(&result, 5).unwrap();
        assert_eq!((u.agent, u.source, u.observed_at, u.plan.as_deref(), u.reset_credits), ("codex", "app-server", 5, Some("pro"), Some(3)));
        assert_eq!(u.windows.iter().map(|w| (w.label.as_str(), w.used_percent)).collect::<Vec<_>>(), [("5h", 12.0), ("7d", 40.5)]);
        assert_eq!(u.windows[1].resets_at, Some(1_792_377_139_000));
        assert!(parse_app_server(&serde_json::json!({"rateLimits": {"primary": null}}), 5).is_none());
    }

    #[test]
    fn usage_report_limits() {
        let report = serde_json::json!({"rate_limits": {"limits": [
            {"kind": "weekly_scoped", "group": "weekly", "percent": 3, "resets_at": "2026-10-18T20:00:00+00:00", "scope": {"model": {"display_name": "Fable"}}},
            {"kind": "session", "group": "session", "percent": 2, "resets_at": "2026-10-12T07:20:00.438849+00:00", "scope": null},
            {"kind": "weekly_all", "group": "weekly", "percent": 7.5, "resets_at": "2026-10-18T20:00:00.438870+00:00", "scope": null},
            {"kind": "something_new", "percent": 1}
        ]}, "extra_usage": {"is_enabled": false}});
        let u = parse_usage_report(&report, 9).unwrap();
        assert_eq!((u.agent, u.source, u.observed_at), ("claude", "usage-command", 9));
        let got: Vec<_> = u.windows.iter().map(|w| (w.label.as_str(), w.used_percent, w.name.as_deref())).collect();
        assert_eq!(got, [("5h", 2.0, None), ("7d", 7.5, None), ("7d:fable", 3.0, Some("Fable"))]);
        assert_eq!(u.windows[0].resets_at, parse_utc("2026-10-12T07:20:00.438Z"));
        assert!(parse_usage_report(&serde_json::json!({"rate_limits": null}), 9).is_none());
        assert!(parse_usage_report(&serde_json::json!({"rate_limits": {"limits": []}}), 9).is_none());
    }

    #[test]
    fn iso_offsets() {
        let utc = parse_utc("2026-10-18T20:00:00Z").unwrap();
        assert_eq!(parse_iso("2026-10-18T20:00:00+00:00"), Some(utc));
        assert_eq!(parse_iso("2026-10-18T14:00:00-06:00"), Some(utc));
        assert_eq!(parse_iso("2026-10-19T01:30:00+05:30"), Some(utc));
        assert_eq!(parse_iso("2026-10-18T20:00:00Z"), Some(utc));
        assert_eq!(parse_iso("2026-10-18"), None);
    }

    #[test]
    fn accounts() {
        let codex = codex_account(
            &serde_json::json!({"account": {"type": "chatgpt", "email": "a@b.c", "planType": "pro"}, "workspaceRouting": {"chatgptAccountId": "acct-1"}}),
        )
        .unwrap();
        assert_eq!(codex, Account { id: Some("acct-1".into()), email: Some("a@b.c".into()), name: None });
        assert!(codex_account(&serde_json::json!({"account": null})).is_none());
        let (claude, plan) = parse_claude_account(
            &serde_json::json!({"loggedIn": true, "email": "a@b.c", "orgId": "org-1", "orgName": "A's Organization", "subscriptionType": "max"}),
        )
        .unwrap();
        assert_eq!((claude.id.as_deref(), claude.name.as_deref(), plan.as_deref()), (Some("org-1"), Some("A's Organization"), Some("max")));
        assert!(parse_claude_account(&serde_json::json!({"loggedIn": false, "email": "a@b.c"})).is_none());
    }

    use super::*;
    use serde_json::json;

    fn line(ts: &str, limits: Value) -> String {
        json!({ "timestamp": ts, "type": "event_msg", "payload": { "type": "token_count", "info": { "total_token_usage": {} }, "rate_limits": limits } })
            .to_string()
    }

    #[test]
    fn reads_codex_rate_limits() {
        let tail = [
            line("2026-08-13T22:00:00.000Z", json!({ "limit_id": "codex", "primary": { "used_percent": 0.0, "window_minutes": 10080, "resets_at": 1787270353 }, "secondary": null, "plan_type": "prolite" })),
            json!({ "timestamp": "2026-08-13T22:01:00.000Z", "type": "response_item", "payload": { "type": "message" } }).to_string(),
            line("2026-08-14T00:23:22.469Z", json!({ "limit_id": "codex", "limit_name": null,
                "primary": { "used_percent": 12.5, "window_minutes": 10080, "resets_at": 1787270358 },
                "secondary": { "used_percent": 40.0, "window_minutes": 300, "resets_at": 1787200000 },
                "credits": { "has_credits": false }, "plan_type": "pro" })),
            line("2026-08-14T00:24:00.000Z", Value::Null),
            "{ not json".to_string(),
        ]
        .join("\n");
        let u = parse_codex(&tail).unwrap();
        assert_eq!(u.agent, "codex");
        assert_eq!(u.plan.as_deref(), Some("pro"));
        assert_eq!(u.observed_at, parse_utc("2026-08-14T00:23:22.469Z").unwrap());
        // Labelled by length, shortest first, whichever of primary/secondary it was.
        assert_eq!(
            u.windows,
            vec![
                Window { label: "5h".into(), used_percent: 40.0, window_minutes: Some(300), resets_at: Some(1_787_200_000_000), name: None },
                Window { label: "7d".into(), used_percent: 12.5, window_minutes: Some(10080), resets_at: Some(1_787_270_358_000), name: None },
            ]
        );
        assert!(parse_codex("").is_none());
        assert!(parse_codex(&line("2026-08-14T00:24:00.000Z", json!({ "primary": null, "secondary": null }))).is_none());
    }

    #[test]
    fn codex_prefers_its_own_bucket() {
        let tail = [
            line("2026-08-14T00:00:00Z", json!({ "limit_id": "codex", "primary": { "used_percent": 3.0, "window_minutes": 300 } })),
            line("2026-08-14T00:01:00Z", json!({ "limit_id": "other", "primary": { "used_percent": 90.0, "window_minutes": 300 } })),
        ]
        .join("\n");
        assert_eq!(parse_codex(&tail).unwrap().windows[0].used_percent, 3.0);
        let only_other = line("2026-08-14T00:01:00Z", json!({ "limit_id": "other", "primary": { "used_percent": 90.0, "window_minutes": 60 } }));
        assert_eq!(parse_codex(&only_other).unwrap().windows[0].label, "1h");
    }

    #[test]
    fn finds_the_newest_session_file() {
        let dir = std::env::temp_dir().join(format!("maple-codex-{}", uuid::Uuid::new_v4()));
        let old = dir.join("2026/08/12");
        let new = dir.join("2026/08/14");
        std::fs::create_dir_all(&old).unwrap();
        std::fs::create_dir_all(&new).unwrap();
        std::fs::write(old.join("rollout-a.jsonl"), line("2026-08-12T00:00:00Z", json!({ "primary": { "used_percent": 1.0, "window_minutes": 300 } })))
            .unwrap();
        std::thread::sleep(Duration::from_millis(20));
        // The newest file has no limits yet; the one before it does.
        std::fs::write(new.join("rollout-c.jsonl"), "{\"type\":\"session_meta\"}\n").unwrap();
        std::fs::write(new.join("notes.txt"), "x").unwrap();
        let big =
            format!("{}\n{}\n", "x".repeat(600 * 1024), line("2026-08-14T01:00:00Z", json!({ "primary": { "used_percent": 7.0, "window_minutes": 300 } })));
        std::fs::write(new.join("rollout-b.jsonl"), big).unwrap();
        let u = scan_codex(&dir).unwrap();
        assert_eq!(u.windows[0].used_percent, 7.0);
        assert!(scan_codex(&dir.join("missing")).is_none());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn claude_status_line_limits() {
        // As captured from Claude Code 2.1.296's status line input.
        let rl = json!({ "five_hour": { "used_percentage": 23, "resets_at": 1791771600 }, "seven_day": { "used_percentage": 6, "resets_at": 1792353600 } });
        assert_eq!(
            claude_windows(&rl),
            vec![
                Window { label: "5h".into(), used_percent: 23.0, window_minutes: Some(300), resets_at: Some(1_791_771_600_000), name: None },
                Window { label: "7d".into(), used_percent: 6.0, window_minutes: Some(10080), resets_at: Some(1_792_353_600_000), name: None },
            ]
        );
        assert!(claude_windows(&Value::Null).is_empty());
        assert!(claude_windows(&json!({ "five_hour": {} })).is_empty());
    }

    #[test]
    fn labels_and_times() {
        assert_eq!(window_label(300), "5h");
        assert_eq!(window_label(10080), "7d");
        assert_eq!(window_label(45), "45m");
        assert_eq!(parse_utc("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_utc("2026-10-11T20:11:40.5Z"), Some(1_791_749_500_500));
        assert_eq!(parse_utc("2026-10-11T20:11:40+02:00"), None);
    }

    #[test]
    fn sends_changes_and_stale_readings() {
        let w = |p: f64, r: u64| Window { label: "5h".into(), used_percent: p, window_minutes: Some(300), resets_at: Some(r), name: None };
        let u = |p: f64, r: u64, at: u64| AgentUsage {
            agent: "codex",
            windows: vec![w(p, r)],
            plan: None,
            observed_at: at,
            source: "session-file",
            reset_credits: None,
            account: None,
        };
        let old = u(10.0, 1_000_000, 0);
        assert!(!worth_sending(&old, &u(10.0, 1_005_000, 60_000)), "a reset time a few seconds off is the same");
        assert!(worth_sending(&old, &u(11.0, 1_000_000, 60_000)));
        assert!(worth_sending(&old, &u(10.0, 1_000_000, REFRESH_AFTER)));
    }
}
