//! Why a session ended. Every end gets a cause and the evidence for it, so a task's card can
//! say what happened and recovery can tell a machine that slept from an agent that crashed.

use std::time::{Duration, Instant, SystemTime};

use crate::wire::EndCause;

/// What the runner saw when a session ended.
#[derive(Debug, Default)]
pub struct Seen<'a> {
    /// The pane's exit status, when it died on its own.
    pub status: Option<u32>,
    /// The signal that killed it, when one did (`pane_dead_signal`).
    pub signal: Option<u32>,
    /// Someone asked for it to end (Kill, Cancel).
    pub requested: bool,
    /// The machine slept this long shortly before (see [`Clock`]).
    pub slept: Option<Duration>,
    /// The tmux session disappeared without its pane dying where we could see it.
    pub vanished: bool,
    /// The tmux server itself is gone.
    pub server_lost: bool,
    /// The screen's last lines.
    pub last_output: &'a [String],
}

/// Lines agents print when their login is no good, lowercased.
const AUTH_SIGNS: &[&str] = &[
    "please run /login",
    "invalid api key",
    "oauth token has expired",
    "authentication_error",
    "not logged in",
    "run `codex login`",
    "your access token could not be refreshed",
];

/// Lines agents print when the plan's limit is reached, lowercased.
const LIMIT_SIGNS: &[&str] = &[
    "usage limit",
    "you've hit your limit",
    "5-hour limit reached",
    "weekly limit reached",
    "rate_limit_error",
    "limit will reset",
];

pub fn classify(seen: &Seen) -> (EndCause, Option<String>) {
    if seen.requested {
        return (EndCause::Killed, None);
    }
    if seen.server_lost {
        return (EndCause::TmuxLost, Some("the runner's tmux server is no longer running".into()));
    }
    // What the agent printed last beats an exit code: a login prompt exits 1 like any other error.
    let tail: Vec<String> = seen.last_output.iter().rev().take(40).map(|l| l.to_lowercase()).collect();
    if let Some(sign) = find(&tail, AUTH_SIGNS) {
        return (EndCause::AuthExpired, Some(format!("the agent printed \"{sign}\"")));
    }
    if let Some(sign) = find(&tail, LIMIT_SIGNS) {
        return (EndCause::UsageLimit, Some(format!("the agent printed \"{sign}\"")));
    }
    if let Some(signal) = seen.signal.filter(|s| *s != 0) {
        let name = signal_name(signal);
        // Nobody here sent a SIGKILL; on a machine short of memory that's the OS reclaiming it.
        if signal == 9 && memory_pressure() {
            return (EndCause::OutOfMemory, Some(format!("{name} while the machine was short of memory")));
        }
        return (EndCause::Signaled, Some(name));
    }
    if let Some(slept) = seen.slept {
        if seen.vanished || seen.status.is_some_and(|s| s != 0) {
            return (EndCause::MachineSlept, Some(format!("the machine slept for {} just before", minutes(slept))));
        }
    }
    if seen.vanished {
        return (EndCause::Unknown, Some("its tmux session disappeared while the server kept running".into()));
    }
    match seen.status {
        Some(code) => (EndCause::Exited, Some(format!("exit status {code}"))),
        None => (EndCause::Unknown, None),
    }
}

fn find<'a>(lines: &[String], signs: &'a [&'a str]) -> Option<&'a str> {
    signs.iter().copied().find(|sign| lines.iter().any(|l| l.contains(sign)))
}

fn minutes(d: Duration) -> String {
    let m = d.as_secs() / 60;
    if m == 0 { format!("{}s", d.as_secs()) } else { format!("{m} min") }
}

pub fn signal_name(signal: u32) -> String {
    let name = match signal {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        6 => "SIGABRT",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        15 => "SIGTERM",
        _ => return format!("signal {signal}"),
    };
    name.to_string()
}

/// True when the OS says memory is tight right now (macOS: `kern.memorystatus_vm_pressure_level` ≥ 2).
fn memory_pressure() -> bool {
    #[cfg(target_os = "macos")]
    {
        let mut level: libc::c_int = 0;
        let mut size = std::mem::size_of::<libc::c_int>();
        let name = c"kern.memorystatus_vm_pressure_level";
        let ok = unsafe { libc::sysctlbyname(name.as_ptr(), (&raw mut level).cast(), &mut size, std::ptr::null_mut(), 0) } == 0;
        ok && level >= 2
    }
    #[cfg(not(target_os = "macos"))]
    {
        // Linux: under 5% of memory available.
        let info = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
        let field = |key: &str| info.lines().find(|l| l.starts_with(key)).and_then(|l| l.split_whitespace().nth(1)?.parse::<u64>().ok());
        matches!((field("MemAvailable:"), field("MemTotal:")), (Some(a), Some(t)) if t > 0 && a * 20 < t)
    }
}

/// Notices the machine sleeping: the wall clock jumps ahead of the monotonic one, which stops
/// while the machine sleeps on macOS (and CLOCK_MONOTONIC on Linux does too).
pub struct Clock {
    wall: SystemTime,
    mono: Instant,
    last_sleep: Option<(Instant, Duration)>,
}

/// A jump this big is a sleep, not scheduling jitter.
const SLEEP_JUMP: Duration = Duration::from_secs(20);
/// A sleep counts as the cause of ends seen this soon after waking.
const SLEEP_BLAME: Duration = Duration::from_secs(120);

impl Clock {
    pub fn new() -> Self {
        Self { wall: SystemTime::now(), mono: Instant::now(), last_sleep: None }
    }

    /// Call every tick. Returns how long the machine slept since the last tick, if it did.
    pub fn tick(&mut self) -> Option<Duration> {
        let (wall, mono) = (SystemTime::now(), Instant::now());
        let wall_step = wall.duration_since(self.wall).unwrap_or_default();
        let mono_step = mono.duration_since(self.mono);
        self.wall = wall;
        self.mono = mono;
        let jump = wall_step.checked_sub(mono_step).filter(|j| *j >= SLEEP_JUMP)?;
        self.last_sleep = Some((mono, jump));
        Some(jump)
    }

    /// The last sleep, if the machine woke from it recently enough to blame it.
    pub fn recent_sleep(&self) -> Option<Duration> {
        self.last_sleep.filter(|(woke, _)| woke.elapsed() < SLEEP_BLAME).map(|(_, d)| d)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(text: &str) -> Vec<String> {
        text.lines().map(String::from).collect()
    }

    #[test]
    fn a_request_wins_over_everything() {
        let out = lines("Please run /login");
        let seen = Seen { requested: true, status: Some(1), last_output: &out, ..Default::default() };
        assert_eq!(classify(&seen).0, EndCause::Killed);
    }

    #[test]
    fn the_screen_explains_auth_and_limits() {
        let out = lines("…\nAPI Error: 401 OAuth token has expired. Please run /login");
        assert_eq!(classify(&Seen { status: Some(1), last_output: &out, ..Default::default() }).0, EndCause::AuthExpired);
        let out = lines("You've hit your limit · resets 3pm");
        assert_eq!(classify(&Seen { status: Some(1), last_output: &out, ..Default::default() }).0, EndCause::UsageLimit);
    }

    #[test]
    fn signals_name_themselves() {
        let (cause, detail) = classify(&Seen { signal: Some(15), status: Some(143), ..Default::default() });
        assert_eq!(cause, EndCause::Signaled);
        assert_eq!(detail.as_deref(), Some("SIGTERM"));
    }

    #[test]
    fn a_failure_right_after_sleep_is_the_sleep() {
        let seen = Seen { status: Some(1), slept: Some(Duration::from_secs(41 * 60)), ..Default::default() };
        let (cause, detail) = classify(&seen);
        assert_eq!(cause, EndCause::MachineSlept);
        assert_eq!(detail.as_deref(), Some("the machine slept for 41 min just before"));
        // A clean exit after waking is still a clean exit.
        assert_eq!(classify(&Seen { status: Some(0), slept: Some(Duration::from_secs(600)), ..Default::default() }).0, EndCause::Exited);
    }

    #[test]
    fn vanished_and_lost_are_told_apart() {
        assert_eq!(classify(&Seen { vanished: true, ..Default::default() }).0, EndCause::Unknown);
        assert_eq!(classify(&Seen { vanished: true, server_lost: true, ..Default::default() }).0, EndCause::TmuxLost);
        assert_eq!(classify(&Seen { status: Some(0), ..Default::default() }).0, EndCause::Exited);
    }
}
