//! `maple-runner statusline`: the status line of every Claude Code session the runner starts.
//!
//! Claude Code runs the `statusLine` command from the runner's `--settings` file with a JSON
//! description of the session on stdin, and shows the first lines it prints. This passes the
//! plan's rate limits on to the runner (for the web app's Usage page) and prints them:
//!
//!     5h 23% (resets 3:10pm) · 7d 41% · Opus 5.5
//!
//! The `--settings` status line replaces one in your own settings, so if you have one it still
//! runs (same input, briefly) and ours is added after its first line. Nothing here may fail or
//! hang a status line: every step is best effort and time-limited, and it always exits 0.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::{Value, json};

use crate::hooks::{SESSION_ENV, SOCKET_ENV};
use crate::usage::{Window, claude_windows, now_ms};

/// Set for your own status line command, so it can't end up running ours (and so on).
const NESTED_ENV: &str = "MAPLE_STATUSLINE";
/// How long your own status line command gets.
const THEIRS_TIMEOUT: Duration = Duration::from_millis(1500);

const DIM: &str = "\x1b[2m";
const AMBER: &str = "\x1b[33m";
const RED: &str = "\x1b[31m";
const RESET: &str = "\x1b[0m";

pub fn run() -> ! {
    let mut raw = String::new();
    let _ = std::io::stdin().take(4 << 20).read_to_string(&mut raw);
    let input: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
    let nested = std::env::var_os(NESTED_ENV).is_some();
    let theirs = if nested { None } else { their_command(&input).and_then(|cmd| run_theirs(&cmd, &input, &raw)) };
    if !nested {
        forward(&input);
    }
    let now = now_ms();
    let out = match theirs {
        Some(text) => append(&text, &usage_text(&windows(&input), now, &local_clock)),
        None => line(&input, now, &local_clock),
    };
    let mut stdout = std::io::stdout();
    let _ = stdout.write_all(out.as_bytes());
    let _ = stdout.write_all(b"\n");
    let _ = stdout.flush();
    std::process::exit(0);
}

fn windows(input: &Value) -> Vec<Window> {
    claude_windows(input.get("rate_limits").unwrap_or(&Value::Null))
}

/// Our whole line: usage, then the model. Just the model without rate limits (API keys, older versions).
pub fn line(input: &Value, now: u64, clock: &dyn Fn(u64) -> Clock) -> String {
    let usage = usage_text(&windows(input), now, clock);
    let model = input.pointer("/model/display_name").and_then(Value::as_str).unwrap_or("").trim();
    match (usage.is_empty(), model.is_empty()) {
        (true, _) => model.to_string(),
        (false, true) => usage,
        (false, false) => format!("{usage}{DIM} · {RESET}{model}"),
    }
}

/// Your status line's output with ours after its first line.
fn append(theirs: &str, usage: &str) -> String {
    if usage.is_empty() {
        return theirs.to_string();
    }
    let mut lines = theirs.lines();
    let first = lines.next().unwrap_or("").trim_end();
    let rest: Vec<&str> = lines.collect();
    let first = if first.is_empty() { usage.to_string() } else { format!("{first}{DIM} · {RESET}{usage}") };
    std::iter::once(first.as_str()).chain(rest).collect::<Vec<_>>().join("\n")
}

/// "5h 23% (resets 3:10pm) · 7d 41%", colored amber from 80% and red from 95%.
pub fn usage_text(windows: &[Window], now: u64, clock: &dyn Fn(u64) -> Clock) -> String {
    windows
        .iter()
        .map(|w| {
            let color = if w.used_percent >= 95.0 {
                RED
            } else if w.used_percent >= 80.0 {
                AMBER
            } else {
                DIM
            };
            match w.resets_at {
                // The window ended after this reading: the next request starts a new one.
                Some(r) if r <= now => format!("{DIM}{} reset{RESET}", w.label),
                Some(r) if w.label == "5h" || w.used_percent >= 80.0 => {
                    format!("{color}{} {}%{RESET}{DIM} (resets {}){RESET}", w.label, percent(w.used_percent), reset_hint(r, now, clock))
                }
                _ => format!("{color}{} {}%{RESET}", w.label, percent(w.used_percent)),
            }
        })
        .collect::<Vec<_>>()
        .join(&format!("{DIM} · {RESET}"))
}

fn percent(p: f64) -> String {
    format!("{:.0}", p.clamp(0.0, 999.0))
}

/// Local wall-clock time.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Clock {
    /// Days since some fixed day: equal means the same calendar day.
    pub day: i64,
    /// 0 = Sunday.
    pub weekday: u32,
    pub hour: u32,
    pub minute: u32,
}

/// "3:10pm" today, "Fri 9am" on another day.
fn reset_hint(at: u64, now: u64, clock: &dyn Fn(u64) -> Clock) -> String {
    let (t, today) = (clock(at), clock(now));
    let h12 = match t.hour % 12 {
        0 => 12,
        h => h,
    };
    let ampm = if t.hour < 12 { "am" } else { "pm" };
    let time = if t.minute == 0 { format!("{h12}{ampm}") } else { format!("{h12}:{:02}{ampm}", t.minute) };
    if t.day == today.day {
        time
    } else {
        let day = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][t.weekday as usize % 7];
        format!("{day} {time}")
    }
}

fn local_clock(ms: u64) -> Clock {
    let secs = (ms / 1000) as libc::time_t;
    // SAFETY: localtime_r writes into the zeroed `tm` we own and reads only `secs`.
    let tm = unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&secs, &mut tm).is_null() {
            return utc_clock(ms);
        }
        tm
    };
    Clock { day: tm.tm_year as i64 * 400 + tm.tm_yday as i64, weekday: tm.tm_wday as u32, hour: tm.tm_hour as u32, minute: tm.tm_min as u32 }
}

pub fn utc_clock(ms: u64) -> Clock {
    let mins = (ms / 60_000) as i64;
    let day = mins.div_euclid(1440);
    Clock { day, weekday: ((day + 4).rem_euclid(7)) as u32, hour: (mins.rem_euclid(1440) / 60) as u32, minute: (mins % 60) as u32 }
}

/// Sends the rate limits to the runner, if this is one of its sessions. Never waits long.
fn forward(input: &Value) {
    let (Some(socket), Some(limits)) = (std::env::var_os(SOCKET_ENV), input.get("rate_limits").filter(|v| v.is_object())) else {
        return;
    };
    let msg = json!({ "usage": {
        "agent": "claude",
        "rateLimits": limits,
        "model": input.pointer("/model/display_name"),
        "session": std::env::var(SESSION_ENV).ok(),
    } });
    let Ok(mut stream) = std::os::unix::net::UnixStream::connect(socket) else { return };
    let _ = stream.set_write_timeout(Some(Duration::from_millis(200)));
    let mut line = msg.to_string();
    line.push('\n');
    let _ = stream.write_all(line.as_bytes());
}

// ---- your own status line ----

/// The status line command from your own settings (local project, project, then user settings,
/// as Claude Code ranks them), unless it's this one.
fn their_command(input: &Value) -> Option<String> {
    let config = match std::env::var_os("CLAUDE_CONFIG_DIR") {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => PathBuf::from(std::env::var_os("HOME")?).join(".claude"),
    };
    let project = input.pointer("/workspace/project_dir").or_else(|| input.get("cwd")).and_then(Value::as_str).map(PathBuf::from);
    let mut files = Vec::new();
    if let Some(p) = &project {
        files.push(p.join(".claude/settings.local.json"));
        files.push(p.join(".claude/settings.json"));
    }
    files.push(config.join("settings.json"));
    files.iter().find_map(|f| {
        let settings: Value = serde_json::from_slice(&std::fs::read(f).ok()?).ok()?;
        let s = settings.get("statusLine")?;
        if s.get("type").and_then(Value::as_str).is_some_and(|t| t != "command") {
            return None;
        }
        let cmd = s.get("command")?.as_str()?.trim();
        (!cmd.is_empty() && !is_ours(cmd)).then(|| cmd.to_string())
    })
}

fn is_ours(cmd: &str) -> bool {
    cmd.contains("maple-runner") && cmd.contains("statusline")
}

/// Runs your status line command with the same input; its output, or None if it failed or took too long.
fn run_theirs(cmd: &str, input: &Value, raw: &str) -> Option<String> {
    let mut command = Command::new("/bin/sh");
    command.arg("-c").arg(cmd).env(NESTED_ENV, "1").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    if let Some(dir) = input.get("cwd").and_then(Value::as_str).filter(|d| std::path::Path::new(d).is_dir()) {
        command.current_dir(dir);
    }
    let mut child = command.spawn().ok()?;
    let mut stdin = child.stdin.take()?;
    let mut stdout = child.stdout.take()?;
    let raw = raw.to_string();
    std::thread::spawn(move || {
        let _ = stdin.write_all(raw.as_bytes());
    });
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut out = Vec::new();
        let _ = (&mut stdout).take(64 * 1024).read_to_end(&mut out);
        let _ = tx.send(out);
    });
    let out = rx.recv_timeout(THEIRS_TIMEOUT).ok();
    if out.is_none() {
        let _ = child.kill();
    }
    let _ = child.wait();
    let text = String::from_utf8_lossy(&out?).trim_end().to_string();
    (!text.is_empty()).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(s: &str) -> String {
        let mut out = String::new();
        let mut chars = s.chars();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                for c in chars.by_ref() {
                    if c == 'm' {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    // 2026-10-11 20:11:40 UTC, a Sunday.
    const NOW: u64 = 1_791_749_500_000;

    fn input(five: f64, seven: f64) -> Value {
        json!({
            "model": { "id": "claude-opus-5-5", "display_name": "Opus 5.5" },
            "rate_limits": {
                "five_hour": { "used_percentage": five, "resets_at": 1_791_753_000 }, // 21:10 UTC
                "seven_day": { "used_percentage": seven, "resets_at": 1_792_353_600 }, // Sun 18 Oct 20:00 UTC
            }
        })
    }

    #[test]
    fn shows_usage_and_model() {
        let l = line(&input(23.0, 41.4), NOW, &utc_clock);
        assert_eq!(plain(&l), "5h 23% (resets 9:10pm) · 7d 41% · Opus 5.5");
        assert!(l.contains(DIM) && !l.contains(AMBER) && !l.contains(RED));
    }

    #[test]
    fn warns_when_close_to_a_limit() {
        let l = line(&input(96.0, 84.0), NOW, &utc_clock);
        assert_eq!(plain(&l), "5h 96% (resets 9:10pm) · 7d 84% (resets Sun 8pm) · Opus 5.5");
        assert!(l.contains(&format!("{RED}5h 96%")));
        assert!(l.contains(&format!("{AMBER}7d 84%")));
    }

    #[test]
    fn a_window_that_already_reset() {
        let l = line(&input(50.0, 10.0), 1_791_753_000_000, &utc_clock);
        assert_eq!(plain(&l), "5h reset · 7d 10% · Opus 5.5");
    }

    #[test]
    fn without_rate_limits_just_the_model() {
        let api_key = json!({ "model": { "display_name": "Sonnet 5" }, "rate_limits": null });
        assert_eq!(line(&api_key, NOW, &utc_clock), "Sonnet 5");
        assert_eq!(line(&json!({ "model": { "display_name": "Sonnet 5" } }), NOW, &utc_clock), "Sonnet 5");
        assert_eq!(line(&Value::Null, NOW, &utc_clock), "");
        let no_model = json!({ "rate_limits": { "seven_day": { "used_percentage": 5 } } });
        assert_eq!(plain(&line(&no_model, NOW, &utc_clock)), "7d 5%");
    }

    #[test]
    fn appended_after_your_own_first_line() {
        assert_eq!(plain(&append("~/app main\nsecond", "5h 3%")), "~/app main · 5h 3%\nsecond");
        assert_eq!(append("mine", ""), "mine");
    }

    #[test]
    fn runs_your_own_status_line() {
        let out = run_theirs("read x; echo \"mine:$x\"", &Value::Null, "hello\n");
        assert_eq!(out.as_deref(), Some("mine:hello"));
        let t = std::time::Instant::now();
        assert_eq!(run_theirs("sleep 5", &Value::Null, ""), None);
        assert!(t.elapsed() < Duration::from_secs(3));
        assert_eq!(run_theirs("exit 1", &Value::Null, ""), None);
        assert!(is_ours("'/Users/me/.local/share/maple/bin/maple-runner' statusline"));
        assert!(!is_ours("~/bin/my-status.sh"));
    }

    #[test]
    fn finds_your_status_line_setting() {
        let dir = std::env::temp_dir().join(format!("maple-statusline-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(dir.join(".claude")).unwrap();
        std::fs::write(dir.join(".claude/settings.json"), r#"{"statusLine":{"type":"command","command":"echo project"}}"#).unwrap();
        let input = json!({ "workspace": { "project_dir": dir } });
        assert_eq!(their_command(&input).as_deref(), Some("echo project"));
        std::fs::write(dir.join(".claude/settings.local.json"), r#"{"statusLine":{"type":"command","command":"maple-runner statusline"}}"#).unwrap();
        // Ours in a higher-ranked file is skipped, not run.
        assert_eq!(their_command(&input).as_deref(), Some("echo project"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn clock() {
        assert_eq!(utc_clock(NOW), Clock { day: 20_737, weekday: 0, hour: 20, minute: 11 });
        assert_eq!(reset_hint(NOW + 3_600_000 - 11 * 60_000, NOW, &utc_clock), "9pm");
        assert_eq!(reset_hint(NOW + 4 * 3_600_000, NOW, &utc_clock), "Mon 12:11am");
    }
}
