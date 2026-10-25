//! Sessions live in a private tmux server (`tmux -S ~/.config/maple/tmux/<name>.sock`) so they
//! survive runner restarts and can be attached over SSH. The socket lives in the runner's own
//! folder, not `/tmp`: temp cleaners (macOS's periodic jobs, systemd-tmpfiles) delete sockets there,
//! and a server whose socket is gone looks like it has no sessions at all. The runner talks to each session
//! through a control-mode client (`tmux -C`), which streams the pane's raw
//! output and accepts input as hex, so the browser's xterm.js stays the real
//! terminal (native scrollback, selection, links).

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result, anyhow, bail};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::mpsc;

use crate::agents::INHERITED_SESSION_MARKERS;

const CONFIG: &str = r#"# Written by maple-runner. Applies only to the runner's own tmux server (tmux -S <socket>).
set -g default-terminal "tmux-256color"
set -as terminal-features ",xterm-256color:RGB"
set -g history-limit 50000
# Keep a finished pane around until the runner has read its exit status.
set -g remain-on-exit on
set -g escape-time 0
# Claude Code and others use focus reports.
set -g focus-events on
set -g mouse on
set -g status-left "[maple] "
"#;

/// Lines of history included when a browser attaches.
const REPLAY_HISTORY: u32 = 3000;
/// At most this many bytes of them (the newest lines win). The replay travels as base64 in one
/// JSON message, so it grows by a third; 1 MiB keeps it well under `MAX_MESSAGE` and quick to
/// load on a phone. 3000 lines of a colourful, wide terminal can be several megabytes.
const REPLAY_BYTES: usize = 1024 * 1024;
const _: () = assert!(REPLAY_BYTES.div_ceil(3) * 4 + crate::protocol::ENVELOPE <= crate::protocol::MAX_MESSAGE);

pub struct Tmux {
    bin: PathBuf,
    socket: String,
    socket_path: PathBuf,
    config: PathBuf,
    /// The server's pid when last seen, kept on disk too, to recreate a deleted socket.
    server_pid: AtomicU32,
}

/// A session found on the tmux server, with the metadata the runner stored on it.
pub struct Existing {
    pub name: String,
    pub agent: String,
    pub cwd: String,
    pub started_at: u64,
    pub pid: Option<u32>,
    /// `PORT` and `MAPLE_API_PORT` given to the session, from `@maple_ports`.
    pub ports: Option<(u16, u16)>,
    /// The task it runs, from `@maple_task`.
    pub task: Option<crate::proof::TaskTag>,
}

pub struct PaneState {
    pub dead: bool,
    pub status: Option<u32>,
    /// The signal that killed it (tmux 3.4+), when one did.
    pub signal: Option<u32>,
}

/// The server couldn't be reached. That says nothing about whether sessions ended.
#[derive(Debug)]
pub struct Unreachable(pub String);

impl std::fmt::Display for Unreachable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "tmux server unreachable: {}", self.0)
    }
}

impl std::error::Error for Unreachable {}

impl Tmux {
    pub fn new(socket: &str, dir: &Path) -> Result<Self> {
        let bin = find_tmux().ok_or_else(|| anyhow!("tmux not found. Install it with `brew install tmux` or set MAPLE_TMUX."))?;
        let config = dir.join("tmux.conf");
        std::fs::write(&config, CONFIG)?;
        let sockets = dir.join("tmux");
        std::fs::create_dir_all(&sockets)?;
        let socket_path = sockets.join(format!("{socket}.sock"));
        let server_pid = std::fs::read_to_string(sockets.join(format!("{socket}.pid"))).ok().and_then(|p| p.trim().parse().ok()).unwrap_or(0);
        Ok(Self { bin, socket: socket.to_string(), socket_path, config, server_pid: AtomicU32::new(server_pid) })
    }

    pub fn socket(&self) -> &str {
        &self.socket
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    fn command(&self) -> Command {
        let mut cmd = Command::new(&self.bin);
        // -u: UTF-8 even when launchd gives us no locale.
        cmd.arg("-u").arg("-S").arg(&self.socket_path).arg("-f").arg(&self.config);
        // The server inherits our environment when it starts; keep agent markers out of it.
        for var in INHERITED_SESSION_MARKERS {
            cmd.env_remove(var);
        }
        cmd.stdin(Stdio::null()).kill_on_drop(true);
        cmd
    }

    pub async fn run<S: AsRef<std::ffi::OsStr>>(&self, args: &[S]) -> Result<String> {
        let out = self.command().args(args).output().await.context("running tmux")?;
        if !out.status.success() {
            bail!("{}", String::from_utf8_lossy(&out.stderr).trim());
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }

    /// Sessions this runner created, found by their `maple-` prefix.
    pub async fn list(&self) -> Result<Vec<Existing>> {
        let format = "#{session_name}\t#{@maple_agent}\t#{@maple_cwd}\t#{@maple_started}\t#{pane_pid}\t#{@maple_ports}\t#{@maple_task}";
        let out = match self.run(&["list-sessions", "-F", format]).await {
            Ok(out) => out,
            Err(e) if is_no_server(&e) => return Ok(vec![]),
            Err(e) => return Err(e),
        };
        Ok(out
            .lines()
            .filter_map(|line| {
                let f: Vec<&str> = line.split('\t').collect();
                (f.len() == 7 && f[0].starts_with("maple-")).then(|| Existing {
                    name: f[0].to_string(),
                    agent: f[1].to_string(),
                    cwd: f[2].to_string(),
                    started_at: f[3].parse().unwrap_or(0),
                    pid: f[4].parse().ok(),
                    ports: crate::sessions::parse_ports(f[5]),
                    task: crate::proof::TaskTag::parse(f[6]),
                })
            })
            .collect())
    }

    /// Every pane on the server. An unreachable server is an error ([`Unreachable`]), never an
    /// empty list: a missing socket or a busy server must not look like every session ended.
    pub async fn panes(&self) -> Result<HashMap<String, PaneState>> {
        let format = "#{session_name}\t#{pane_dead}\t#{pane_dead_status}\t#{pane_dead_signal}\t#{pid}";
        let out = match self.run(&["list-panes", "-a", "-F", format]).await {
            Ok(out) => out,
            Err(e) if is_no_server(&e) => return Err(Unreachable(e.to_string()).into()),
            Err(e) => return Err(e),
        };
        let mut panes = HashMap::new();
        for line in out.lines() {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() != 5 {
                continue;
            }
            if let Ok(pid) = f[4].parse() {
                self.remember_server(pid);
            }
            let signal = f[3].parse().ok().filter(|s| *s != 0);
            panes.insert(f[0].to_string(), PaneState { dead: f[1] == "1", status: f[2].parse().ok(), signal });
        }
        Ok(panes)
    }

    fn remember_server(&self, pid: u32) {
        if self.server_pid.swap(pid, Ordering::Relaxed) != pid {
            let _ = std::fs::write(self.socket_path.with_extension("pid"), pid.to_string());
        }
    }

    /// Whether the server process is still running, as far as we know its pid.
    pub fn server_alive(&self) -> Option<bool> {
        let pid = self.server_pid.load(Ordering::Relaxed);
        (pid != 0).then(|| unsafe { libc::kill(pid as libc::pid_t, 0) } == 0)
    }

    /// A running server whose socket was deleted makes a new one on SIGUSR1 (tmux(1)).
    /// Returns whether it was asked to.
    pub fn recover_socket(&self) -> bool {
        if self.socket_path.exists() || self.server_alive() != Some(true) {
            return false;
        }
        let pid = self.server_pid.load(Ordering::Relaxed);
        unsafe { libc::kill(pid as libc::pid_t, libc::SIGUSR1) == 0 }
    }

    /// The last `lines` lines of a pane (a dead one too, while remain-on-exit keeps it), without colours.
    pub async fn last_lines(&self, target: &str, lines: u32) -> Vec<String> {
        let start = format!("-{lines}");
        match self.run(&["capture-pane", "-p", "-J", "-S", &start, "-t", target]).await {
            Ok(out) => {
                // remain-on-exit's own "Pane is dead (status 3, …)" line isn't the program's output.
                let mut all: Vec<String> = out.lines().map(|l| l.trim_end().to_string()).filter(|l| !l.starts_with("Pane is dead")).collect();
                while all.last().is_some_and(|l| l.is_empty()) {
                    all.pop();
                }
                let skip = all.len().saturating_sub(lines as usize);
                all.split_off(skip)
            }
            Err(_) => vec![],
        }
    }

    /// Starts a control-mode client attached to `session`. Output and replays are
    /// delivered through `sink` in the order tmux produced them.
    pub fn control(&self, session: &str, sink: impl Fn(ControlEvent) + Send + 'static) -> Result<Control> {
        let mut child = self
            .command()
            .args(["-C", "attach-session", "-t", session])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .context("starting tmux control client")?;
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let pending: Arc<Mutex<VecDeque<Reply>>> = Arc::default();

        // Writer: queue the expected replies, then send the line, so replies
        // are matched to commands in order.
        let (tx, mut rx) = mpsc::unbounded_channel::<(String, Vec<Reply>)>();
        let queue = pending.clone();
        tokio::spawn(async move {
            let mut stdin = stdin;
            while let Some((line, replies)) = rx.recv().await {
                queue.lock().unwrap().extend(replies);
                if stdin.write_all(format!("{line}\n").as_bytes()).await.is_err() {
                    break;
                }
            }
        });

        tokio::spawn(read_control(stdout, pending, sink));
        Ok(Control { tx, _child: child })
    }
}

/// What a control client hands back to the session.
pub enum ControlEvent {
    Output(Vec<u8>),
    Replay { nonce: String, data: Vec<u8> },
    Exit,
}

pub struct Control {
    tx: mpsc::UnboundedSender<(String, Vec<Reply>)>,
    _child: Child,
}

impl Control {
    fn send(&self, line: String, replies: Vec<Reply>) {
        let _ = self.tx.send((line, replies));
    }

    pub fn input(&self, target: &str, data: &[u8]) {
        for chunk in data.chunks(256) {
            let hex: Vec<String> = chunk.iter().map(|b| format!("{b:02x}")).collect();
            self.send(format!("send-keys -t {target} -H {}", hex.join(" ")), vec![Reply::Ignore]);
        }
    }

    pub fn resize(&self, target: &str, cols: u16, rows: u16) {
        self.send(format!("resize-window -t {target} -x {cols} -y {rows}"), vec![Reply::Ignore]);
    }

    /// Asks tmux for the screen, recent history and cursor. tmux runs the three
    /// commands back to back, so no output lands between them, and the reply
    /// arrives in-stream: everything before it is in the snapshot.
    pub fn replay(&self, target: &str, nonce: String) {
        let line = format!(
            "display-message -p -t {target} '#{{alternate_on}} #{{cursor_x}} #{{cursor_y}}' ; \
             capture-pane -p -e -S -{REPLAY_HISTORY} -t {target} ; \
             capture-pane -p -e -a -q -t {target}"
        );
        self.send(line, vec![Reply::ReplayInfo, Reply::ReplayMain, Reply::ReplayAlt(nonce)]);
    }
}

enum Reply {
    Ignore,
    ReplayInfo,
    ReplayMain,
    ReplayAlt(String),
}

async fn read_control(stdout: tokio::process::ChildStdout, pending: Arc<Mutex<VecDeque<Reply>>>, sink: impl Fn(ControlEvent)) {
    let mut reader = BufReader::new(stdout);
    let mut line = Vec::new();
    // (begin tag, sent by us, body)
    let mut block: Option<(Vec<u8>, bool, Vec<Vec<u8>>)> = None;
    let mut info = (false, 0u32, 0u32);
    let mut main: Vec<Vec<u8>> = Vec::new();

    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        if line.ends_with(b"\n") {
            line.pop();
        }

        if let Some((tag, ours, body)) = block.as_mut() {
            let ended =
                (line.starts_with(b"%end ") || line.starts_with(b"%error ")) && line[line.iter().position(|&b| b == b' ').unwrap() + 1..].starts_with(tag);
            if !ended {
                body.push(line.clone());
                continue;
            }
            let (ours, body) = (*ours, std::mem::take(body));
            block = None;
            if !ours {
                continue;
            }
            match pending.lock().unwrap().pop_front() {
                Some(Reply::ReplayInfo) => {
                    let text = body.first().map(|l| String::from_utf8_lossy(l).into_owned()).unwrap_or_default();
                    let mut f = text.split(' ').map(|s| s.parse::<u32>().unwrap_or(0));
                    info = (f.next() == Some(1), f.next().unwrap_or(0), f.next().unwrap_or(0));
                }
                Some(Reply::ReplayMain) => main = body,
                Some(Reply::ReplayAlt(nonce)) => {
                    let data = render_replay(&std::mem::take(&mut main), info.0.then_some(&body), info.1, info.2, REPLAY_BYTES);
                    sink(ControlEvent::Replay { nonce, data });
                }
                Some(Reply::Ignore) | None => {}
            }
        } else if let Some(rest) = line.strip_prefix(b"%begin ") {
            // "%begin <time> <number> <flags>": flags 1 means we sent the command.
            let ours = rest.ends_with(b" 1");
            let tag = rest[..rest.iter().rposition(|&b| b == b' ').unwrap_or(rest.len())].to_vec();
            block = Some((tag, ours, Vec::new()));
        } else if let Some(rest) = line.strip_prefix(b"%output ") {
            // "%output %<pane> <data>"
            if let Some(space) = rest.iter().position(|&b| b == b' ') {
                sink(ControlEvent::Output(unescape(&rest[space + 1..])));
            }
        } else if line.starts_with(b"%exit") {
            break;
        }
    }
    sink(ControlEvent::Exit);
}

/// Turns captured lines back into bytes that repaint a fresh terminal, in at most about `budget`
/// bytes: the oldest history lines are left out first. (The cursor position is relative to the
/// screen, which is the newest lines, so it stays right.)
fn render_replay(main: &[Vec<u8>], alt: Option<&Vec<Vec<u8>>>, cursor_x: u32, cursor_y: u32, budget: usize) -> Vec<u8> {
    const SEP: usize = b"\x1b[0m\r\n".len();
    let alt_size = alt.map_or(0, |a| 16 + a.iter().map(|l| l.len() + SEP).sum::<usize>());
    let mut room = budget.saturating_sub(alt_size + 32);
    let mut keep = 0;
    for line in main.iter().rev() {
        if line.len() + SEP > room {
            break;
        }
        room -= line.len() + SEP;
        keep += 1;
    }
    let main = &main[main.len() - keep..];
    let mut out = Vec::new();
    let join = |out: &mut Vec<u8>, lines: &[Vec<u8>]| {
        for (i, l) in lines.iter().enumerate() {
            if i > 0 {
                out.extend_from_slice(b"\x1b[0m\r\n");
            }
            out.extend_from_slice(l);
        }
        out.extend_from_slice(b"\x1b[0m");
    };
    join(&mut out, main);
    if let Some(alt) = alt {
        out.extend_from_slice(b"\x1b[?1049h\x1b[H");
        join(&mut out, alt);
    }
    out.extend_from_slice(format!("\x1b[{};{}H", cursor_y + 1, cursor_x + 1).as_bytes());
    out
}

/// tmux escapes bytes below 0x20 and backslashes as `\ooo`.
fn unescape(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let mut i = 0;
    while i < data.len() {
        if data[i] == b'\\' && i + 3 < data.len() && data[i + 1..i + 4].iter().all(|b| (b'0'..=b'7').contains(b)) {
            out.push((data[i + 1] - b'0') * 64 + (data[i + 2] - b'0') * 8 + (data[i + 3] - b'0'));
            i += 4;
        } else {
            out.push(data[i]);
            i += 1;
        }
    }
    out
}

fn is_no_server(e: &anyhow::Error) -> bool {
    let msg = e.to_string();
    msg.contains("no server running") || msg.contains("error connecting") || msg.contains("No such file")
}

fn find_tmux() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("MAPLE_TMUX") {
        return Some(PathBuf::from(path));
    }
    // launchd gives a minimal PATH, so check the usual install locations first.
    let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].map(PathBuf::from);
    let from_path = std::env::var_os("PATH").into_iter().flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>()).map(|dir| dir.join("tmux"));
    candidates.into_iter().chain(from_path).find(|p| p.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unescapes_control_bytes() {
        assert_eq!(unescape(br"a\015\012b\134c"), b"a\r\nb\\c");
        assert_eq!(unescape("été".as_bytes()), "été".as_bytes());
        assert_eq!(unescape(br"trailing\01"), br"trailing\01");
    }

    #[test]
    fn replay_positions_cursor() {
        let out = render_replay(&[b"one".to_vec(), b"two".to_vec()], None, 3, 1, REPLAY_BYTES);
        assert_eq!(out, b"one\x1b[0m\r\ntwo\x1b[0m\x1b[2;4H");
    }

    #[test]
    fn replay_keeps_the_newest_lines_within_budget() {
        let lines: Vec<Vec<u8>> = (0..5000).map(|i| format!("\x1b[31mline {i:05} {}", "x".repeat(400)).into_bytes()).collect();
        let out = render_replay(&lines, None, 0, 0, REPLAY_BYTES);
        assert!(out.len() <= REPLAY_BYTES, "{} bytes", out.len());
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("line 04999") && !text.contains("line 00000"));
        // As base64 in a session.replay, it's well under the message limit.
        assert!(text.len().div_ceil(3) * 4 + crate::protocol::ENVELOPE <= crate::protocol::MAX_MESSAGE);
        // An alternate screen (a full-screen app) is always kept whole.
        let alt = vec![b"vim".to_vec()];
        let out = render_replay(&lines, Some(&alt), 0, 0, 1000);
        assert!(String::from_utf8(out).unwrap().contains("\x1b[?1049h\x1b[Hvim"));
    }
}
