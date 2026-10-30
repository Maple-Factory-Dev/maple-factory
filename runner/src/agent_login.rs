//! Signing an agent in from the app (`agent.login`): `codex login --device-auth`, run through the
//! login shell the way `health` checks it. Its link and one-time code go to the hub as
//! `agent.login_status` (waiting), then how it ended (done, failed, cancelled). One login at a time
//! per agent; asking again while one waits sends its status again. The process is killed on cancel
//! or once its code expires.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::Notify;

use crate::protocol::Outbound;
use crate::sessions::Sessions;
use crate::wire::{AgentLoginState, AgentLoginStatus, RunnerMessage};

/// How long a code lasts when the output doesn't say.
const DEFAULT_EXPIRY: Duration = Duration::from_secs(15 * 60);

struct Running {
    stop: Arc<Notify>,
    last: AgentLoginStatus,
}

static RUNNING: LazyLock<Mutex<HashMap<String, Running>>> = LazyLock::new(Default::default);

/// Starts signing `agent` in. `signed_in` is notified when it succeeds, so health checks the agent again.
pub fn start(sessions: Sessions, agent: String, signed_in: Arc<Notify>) {
    let emit = {
        let sessions = sessions.clone();
        move |status: AgentLoginStatus| sessions.emit(Outbound::Wire(RunnerMessage::AgentLoginStatus { status }))
    };
    if agent != "codex" {
        return emit(status(&agent, AgentLoginState::Failed, Some(format!("Sign in to {agent} from a terminal on this machine."))));
    }
    let stop = Arc::new(Notify::new());
    {
        let mut running = RUNNING.lock().unwrap();
        if let Some(r) = running.get(&agent) {
            return emit(r.last.clone());
        }
        running.insert(agent.clone(), Running { stop: stop.clone(), last: status(&agent, AgentLoginState::Starting, None) });
    }
    tokio::spawn(async move {
        let record = |s: AgentLoginStatus| {
            if let Some(r) = RUNNING.lock().unwrap().get_mut(&s.agent) {
                r.last = s.clone();
            }
            emit(s);
        };
        record(status(&agent, AgentLoginState::Starting, None));
        let end = drive(codex_command(), &agent, stop, &record).await;
        RUNNING.lock().unwrap().remove(&agent);
        let ok = end.state == AgentLoginState::Done;
        record(end);
        if ok {
            signed_in.notify_one();
        }
    });
}

pub fn cancel(agent: &str) {
    if let Some(r) = RUNNING.lock().unwrap().get(agent) {
        r.stop.notify_one();
    }
}

/// `codex login --device-auth` through the interactive login shell (see `health::shell`), both
/// streams on one pipe, in its own process group so a cancel takes all of it.
fn codex_command() -> Command {
    let mut cmd = Command::new(crate::agents::login_shell());
    cmd.args(["-l", "-i", "-c", "exec 2>&1; exec codex login --device-auth"]);
    cmd
}

/// Runs `cmd`, reporting `waiting` once its output has a link and code, and returns how it ended.
async fn drive(mut cmd: Command, agent: &str, stop: Arc<Notify>, emit: &impl Fn(AgentLoginStatus)) -> AgentLoginStatus {
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).process_group(0).kill_on_drop(true);
    for var in crate::agents::INHERITED_SESSION_MARKERS {
        cmd.env_remove(var);
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return status(agent, AgentLoginState::Failed, Some(format!("Couldn't start codex login: {e}"))),
    };
    let group = child.id().map(|id| id as i32);
    let kill = || {
        if let Some(g) = group {
            unsafe { libc::killpg(g, libc::SIGKILL) };
        }
    };
    let mut lines = BufReader::new(child.stdout.take().expect("piped")).lines();
    let mut output = String::new();
    let mut shown = false;
    let mut expires = tokio::time::Instant::now() + DEFAULT_EXPIRY;
    let stopped = stop.notified();
    tokio::pin!(stopped);
    loop {
        tokio::select! {
            line = lines.next_line() => match line {
                Ok(Some(line)) => {
                    output.push_str(&strip_ansi(&line));
                    output.push('\n');
                    if !shown && let Some(p) = parse(&output) {
                        shown = true;
                        expires = tokio::time::Instant::now() + p.expires_in;
                        emit(AgentLoginStatus {
                            url: Some(p.url),
                            code: Some(p.code),
                            expires_at: Some(crate::sessions::now_ms() + p.expires_in.as_millis() as u64),
                            ..status(agent, AgentLoginState::Waiting, None)
                        });
                    }
                }
                _ => break,
            },
            _ = &mut stopped => {
                kill();
                let _ = child.wait().await;
                return status(agent, AgentLoginState::Cancelled, None);
            }
            _ = tokio::time::sleep_until(expires) => {
                kill();
                let _ = child.wait().await;
                return status(agent, AgentLoginState::Cancelled, Some("The code expired before sign-in finished.".into()));
            }
        }
    }
    let exit = child.wait().await;
    kill();
    finished(agent, exit.map(|s| (s.success(), s.code())).unwrap_or((false, None)), &output)
}

/// How a login that exited ended: done on success, else failed with its last line.
fn finished(agent: &str, (success, code): (bool, Option<i32>), output: &str) -> AgentLoginStatus {
    if success {
        return status(agent, AgentLoginState::Done, None);
    }
    let last = output.lines().map(str::trim).rfind(|l| !l.is_empty()).map(str::to_string);
    let message = last.unwrap_or_else(|| match code {
        Some(c) => format!("codex login exited with code {c}."),
        None => "codex login was stopped.".into(),
    });
    status(agent, AgentLoginState::Failed, Some(message))
}

fn status(agent: &str, state: AgentLoginState, message: Option<String>) -> AgentLoginStatus {
    AgentLoginStatus { agent: agent.to_string(), state, url: None, code: None, expires_at: None, message }
}

#[derive(Debug, PartialEq)]
struct Prompt {
    url: String,
    code: String,
    expires_in: Duration,
}

/// The link, one-time code and expiry in `codex login --device-auth`'s output (ANSI already stripped).
fn parse(output: &str) -> Option<Prompt> {
    let url = output.split_whitespace().find(|w| w.starts_with("https://"))?.to_string();
    let code = output.lines().map(str::trim).find(|l| is_code(l))?.to_string();
    let expires_in = output
        .split("expires in ")
        .nth(1)
        .and_then(|rest| rest.split_whitespace().next()?.parse::<u64>().ok())
        .map_or(DEFAULT_EXPIRY, |m| Duration::from_secs(m * 60));
    Some(Prompt { url, code, expires_in })
}

/// "PCJL-K5RMO": groups of capitals and digits joined by dashes.
fn is_code(line: &str) -> bool {
    let parts: Vec<_> = line.split('-').collect();
    parts.len() >= 2 && line.len() <= 20 && parts.iter().all(|p| p.len() >= 3 && p.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit()))
}

/// Drops terminal escapes: CSI (`ESC [ … final`) and OSC (`ESC ] … BEL` or `ESC \`).
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('[') => {
                for c in chars.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&c) {
                        break;
                    }
                }
            }
            Some(']') => {
                while let Some(c) = chars.next() {
                    if c == '\u{7}' || (c == '\u{1b}' && chars.next_if_eq(&'\\').is_some()) {
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The brief's output, as a terminal shows it.
    const PLAIN: &str = "Welcome to Codex [v0.164.0]
OpenAI's command-line coding agent

Follow these steps to sign in with ChatGPT using device code authorization:

1. Open this link in your browser and sign in to your account
   https://auth.openai.com/codex/device

2. Enter this one-time code (expires in 15 minutes)
   PCJL-K5RMO

Continue only if you started this login in Codex. If a website or another person gave you this code, cancel.
";

    /// What codex 0.166.0 writes to a pipe: the same, coloured.
    const ANSI: &str = "\nWelcome to Codex [v\u{1b}[90m0.166.0\u{1b}[0m]
\u{1b}[90mOpenAI's command-line coding agent\u{1b}[0m

Follow these steps to sign in with ChatGPT using device code authorization:

1. Open this link in your browser and sign in to your account
   \u{1b}[94mhttps://auth.openai.com/codex/device\u{1b}[0m

2. Enter this one-time code \u{1b}[90m(expires in 15 minutes)\u{1b}[0m
   \u{1b}[94mPCT7-B39O7\u{1b}[0m

\u{1b}[90mContinue only if you started this login in Codex. If a website or another person gave you this code, cancel.\u{1b}[0m
";

    #[test]
    fn reads_the_link_and_code() {
        let p = parse(PLAIN).unwrap();
        assert_eq!(p, Prompt { url: "https://auth.openai.com/codex/device".into(), code: "PCJL-K5RMO".into(), expires_in: Duration::from_secs(900) });
    }

    #[test]
    fn reads_them_through_ansi() {
        let stripped: String = ANSI.lines().map(|l| strip_ansi(l) + "\n").collect();
        assert!(!stripped.contains('\u{1b}'));
        let p = parse(&stripped).unwrap();
        assert_eq!((p.url.as_str(), p.code.as_str()), ("https://auth.openai.com/codex/device", "PCT7-B39O7"));
        assert_eq!(strip_ansi("\u{1b}]8;;https://x\u{7}link\u{1b}]8;;\u{1b}\\"), "link");
    }

    #[test]
    fn waits_for_both() {
        let before_code = &PLAIN[..PLAIN.find("2. Enter").unwrap()];
        assert_eq!(parse(before_code), None);
        assert!(!is_code("OpenAI's command-line coding agent"));
        assert!(!is_code("---"));
    }

    fn sh(script: &str) -> Command {
        let mut cmd = Command::new("sh");
        cmd.args(["-c", script]);
        cmd
    }

    async fn run(script: &str, stop: Arc<Notify>) -> (Vec<AgentLoginStatus>, AgentLoginStatus) {
        let seen = Mutex::new(vec![]);
        let end = drive(sh(script), "codex", stop, &|s| seen.lock().unwrap().push(s)).await;
        (seen.into_inner().unwrap(), end)
    }

    fn printing(output: &str, then: &str) -> String {
        format!("printf '%s' '{}'; {then}", output.replace('\'', r"'\''"))
    }

    #[tokio::test]
    async fn signs_in() {
        let (seen, end) = run(&printing(ANSI, "echo 'Successfully logged in'"), Arc::new(Notify::new())).await;
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].state, AgentLoginState::Waiting);
        assert_eq!(seen[0].code.as_deref(), Some("PCT7-B39O7"));
        assert!(seen[0].expires_at.unwrap() > crate::sessions::now_ms() + 14 * 60 * 1000);
        assert_eq!(end.state, AgentLoginState::Done);
    }

    #[tokio::test]
    async fn a_failed_exit_fails() {
        let (_, end) = run(&printing(PLAIN, "echo 'Error: device code expired'; exit 1"), Arc::new(Notify::new())).await;
        assert_eq!(end.state, AgentLoginState::Failed);
        assert_eq!(end.message.as_deref(), Some("Error: device code expired"));
        let (seen, end) = run("exit 3", Arc::new(Notify::new())).await;
        assert!(seen.is_empty());
        assert_eq!((end.state, end.message.as_deref()), (AgentLoginState::Failed, Some("codex login exited with code 3.")));
    }

    #[tokio::test]
    async fn cancel_kills_it() {
        let stop = Arc::new(Notify::new());
        let later = stop.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            later.notify_one();
        });
        let began = std::time::Instant::now();
        let (seen, end) = run(&printing(PLAIN, "sleep 30"), stop).await;
        assert_eq!(seen[0].state, AgentLoginState::Waiting);
        assert_eq!(end.state, AgentLoginState::Cancelled);
        assert!(began.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn reports_how_it_exited() {
        assert_eq!(finished("codex", (true, Some(0)), "").state, AgentLoginState::Done);
        assert_eq!(finished("codex", (false, None), "").message.as_deref(), Some("codex login was stopped."));
    }
}
