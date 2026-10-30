//! Agent sessions, each backed by a tmux session named `maple-<uuid>`.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Result, anyhow};
use base64::Engine;
use tokio::sync::mpsc;
use tracing::{info, warn};
use uuid::Uuid;

use crate::agents;
use crate::hooks::{self, Activity, Hooks};
use crate::proof::TaskTag;
use crate::ends;
use crate::protocol::{AgentState, Outbound, SessionInfo};
use crate::wire::{self, SessionEnd};
use crate::tmux::{Control, ControlEvent, Tmux};

/// Everything the runner wants to send, in the order it happened.
pub enum Event {
    Text(Outbound),
    Output(Uuid, Vec<u8>),
}

pub type Outbox = mpsc::UnboundedSender<Event>;

struct Session {
    info: SessionInfo,
    name: String,
    control: Control,
    /// Counts pieces of output, so thumbnails know when the screen may have changed.
    output: Arc<AtomicU64>,
    /// What the agent's hooks last said, for thumbnails and to say again in a `hello`.
    agent: Option<AgentState>,
    /// The task it runs, for `prove` (proof.rs).
    task: Option<TaskTag>,
}

/// Sessions that ended remembered for the next `hello`, at most.
const MAX_EXITS: usize = 64;
/// A session must be missing from this many polls in a row (a second apart) before it counts as ended.
const MISSING_POLLS: u32 = 3;
/// After this many failed polls in a row, a server whose process is gone counts as lost.
const UNREACHABLE_POLLS: u32 = 10;
/// Lines of screen kept with an end, for the card and to check the cause by eye.
const END_LINES: u32 = 30;
/// A prompt longer than this goes to the session through a file (`prompt_file`), not tmux's command.
const PROMPT_IN_FILE: usize = 1024;

/// Writes a session's prompt to `~/.config/maple/prompts/<id>.txt` (readable only by this user) for the
/// session's shell to read and remove.
fn prompt_file(id: Uuid, prompt: &str) -> Result<PathBuf> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let dir = crate::config::dir()?.join("prompts");
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
    let path = dir.join(format!("{id}.txt"));
    let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&path)?;
    f.write_all(prompt.as_bytes())?;
    Ok(path)
}

/// A strictly increasing time for hook events (ms), so the hub can tell each one apart.
fn stamp() -> u64 {
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = now_ms();
    let prev = LAST.try_update(Ordering::SeqCst, Ordering::SeqCst, |last| Some(now.max(last + 1))).unwrap_or(0);
    now.max(prev + 1)
}

const BRACKETED_ON: &[u8] = b"\x1b[?2004h";
const BRACKETED_OFF: &[u8] = b"\x1b[?2004l";

/// Follows a pane's bracketed paste mode (`ESC[?2004h` / `ESC[?2004l`) through its output,
/// including a sequence split across two pieces of output.
pub struct PasteMode {
    pub on: bool,
    tail: Vec<u8>,
}

impl PasteMode {
    pub fn new(on: bool) -> Self {
        Self { on, tail: Vec::new() }
    }

    pub fn feed(&mut self, data: &[u8]) {
        let mut buf = std::mem::take(&mut self.tail);
        buf.extend_from_slice(data);
        let last = |seq: &[u8]| buf.windows(seq.len()).rposition(|w| w == seq);
        match (last(BRACKETED_ON), last(BRACKETED_OFF)) {
            (Some(a), Some(b)) => self.on = a > b,
            (Some(_), None) => self.on = true,
            (None, Some(_)) => self.on = false,
            (None, None) => {}
        }
        // Keep just enough to finish a sequence that started at the end of this piece.
        let keep = BRACKETED_ON.len() - 1;
        self.tail = buf[buf.len().saturating_sub(keep)..].to_vec();
    }
}

#[derive(Clone)]
pub struct Sessions {
    inner: Arc<Mutex<HashMap<Uuid, Session>>>,
    /// Recent ends, newest last: a `session.ended` sent while disconnected is lost, so `hello` repeats them.
    exits: Arc<Mutex<VecDeque<SessionEnd>>>,
    /// Sessions someone asked to end (Kill, Cancel), so their end says so.
    requested: Arc<Mutex<HashSet<Uuid>>>,
    outbox: Outbox,
    tmux: Arc<Tmux>,
    hooks: Arc<Hooks>,
    /// `PORT` and `MAPLE_API_PORT` of each live session, claimed before its tmux session starts so
    /// two opens at once can't pick the same ones.
    ports: Arc<Mutex<HashMap<Uuid, (u16, u16)>>>,
    /// Adopted sessions whose secrets the hub has to be asked for again (`secrets::recover`).
    refetch: Arc<Mutex<Vec<crate::secrets::Pending>>>,
}

impl Sessions {
    /// Adopts sessions left running by a previous runner, then watches for exits.
    pub async fn start(outbox: Outbox, tmux: Tmux, hooks: Hooks) -> Result<Self> {
        let sessions = Self {
            inner: Arc::default(),
            exits: Arc::default(),
            requested: Arc::default(),
            outbox,
            tmux: Arc::new(tmux),
            hooks: Arc::new(hooks),
            ports: Arc::default(),
            refetch: Arc::default(),
        };
        // A server that lost its socket while the runner was down still has its sessions.
        if sessions.tmux.recover_socket() {
            info!("asked the tmux server to recreate its deleted socket");
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        for existing in sessions.tmux.list().await? {
            let Some(id) = existing.name.strip_prefix("maple-").and_then(|s| Uuid::parse_str(s).ok()) else { continue };
            let info = SessionInfo { id, agent: existing.agent, cwd: existing.cwd, pid: existing.pid, started_at: existing.started_at };
            let task = existing.task.as_ref().map(|t| t.id.clone());
            match sessions.adopt(info, existing.task) {
                Ok(()) => {
                    if let Some(ports) = existing.ports {
                        sessions.ports.lock().unwrap().insert(id, ports);
                    }
                    if let Some(p) = crate::secrets::recover(&sessions.tmux, &existing.name, task.as_deref()).await {
                        sessions.refetch.lock().unwrap().push(p);
                    }
                    info!("reattached to session {id}")
                }
                Err(e) => warn!("could not reattach to {}: {e:#}", existing.name),
            }
        }
        // Connector files of sessions that ended while the runner was down: their secrets go too.
        let live: HashSet<Uuid> = sessions.inner.lock().unwrap().keys().copied().collect();
        sessions.hooks.sweep_session_mcp_configs(&live);
        tokio::spawn(sessions.clone().watch_exits());
        Ok(sessions)
    }

    /// Whether `pid` runs inside one of this runner's sessions: a pane's process or anything it started.
    pub async fn hosts(&self, pid: u32) -> bool {
        let mut roots: HashSet<u32> = self.inner.lock().unwrap().values().filter_map(|s| s.info.pid).collect();
        // The tmux server is every pane's parent, including a pane from before this runner started.
        if let Ok(out) = self.tmux.run(&["display-message", "-p", "#{pid}"]).await {
            roots.extend(out.trim().parse::<u32>().ok());
        }
        crate::ports::descends_from(pid, &roots).await
    }

    /// Once connected: asks the hub again for adopted sessions' secrets (`secrets::recover`), so
    /// they're scrubbed. Any it doesn't answer are asked for on the next connection.
    pub fn refetch_secrets(&self) {
        let pending = std::mem::take(&mut *self.refetch.lock().unwrap());
        for p in pending {
            let sessions = self.clone();
            tokio::spawn(async move {
                let emit = |m: Outbound| sessions.emit(m);
                if !crate::secrets::refetch(&emit, &p).await {
                    sessions.refetch.lock().unwrap().push(p);
                }
            });
        }
    }

    pub fn emit(&self, msg: Outbound) {
        let _ = self.outbox.send(Event::Text(msg));
    }

    pub fn list(&self) -> Vec<SessionInfo> {
        let mut list: Vec<_> = self.inner.lock().unwrap().values().map(|s| s.info.clone()).collect();
        list.sort_by_key(|s| s.started_at);
        list
    }

    /// For `hello`: the live sessions with their agents' latest state, and recent exits.
    pub fn hello(&self) -> (Vec<wire::LiveSession>, Vec<SessionEnd>) {
        let mut list: Vec<_> = self
            .inner
            .lock()
            .unwrap()
            .values()
            .map(|s| wire::LiveSession { session: wire_info(&s.info, s.task.as_ref()), activity: s.agent.as_ref().map(wire_activity), shares: None })
            .collect();
        list.sort_by_key(|s| s.session.started_at);
        (list, self.exits.lock().unwrap().iter().cloned().collect())
    }

    /// A live session's info as the server sees it.
    pub fn wire_info(&self, id: Uuid) -> Option<wire::SessionInfo> {
        self.inner.lock().unwrap().get(&id).map(|s| wire_info(&s.info, s.task.as_ref()))
    }

    // One call site (main.rs) passes the hub's session.open straight through; a struct would only repeat it.
    #[allow(clippy::too_many_arguments)]
    pub async fn open(
        &self,
        id: Uuid,
        agent_name: &str,
        cwd: &str,
        model: Option<&str>,
        unattended: Option<&agents::Unattended>,
        connectors: &[wire::McpConnector],
        images: &[String],
        prompt: Option<&str>,
        resume: bool,
        cols: u16,
        rows: u16,
        task: Option<TaskTag>,
        secrets: Option<(&str, &[(String, String)])>,
    ) -> Result<SessionInfo> {
        let agent = crate::agent_config::find(agent_name).ok_or_else(|| anyhow!("unknown agent {agent_name:?}"))?;
        let dir = expand_home(cwd);
        if !dir.is_dir() {
            return Err(anyhow!("{cwd} is not a directory"));
        }
        let name = format!("maple-{id}");
        let started_at = now_ms();
        let ports = self.claim_ports(id);

        let mut args: Vec<String> = vec![
            "new-session".into(),
            "-d".into(),
            "-s".into(),
            name.clone(),
            "-x".into(),
            cols.to_string(),
            "-y".into(),
            rows.to_string(),
            "-c".into(),
            dir.to_string_lossy().into_owned(),
            "-e".into(),
            "COLORTERM=truecolor".into(),
            "-e".into(),
            format!("{}={id}", hooks::SESSION_ENV),
            "-e".into(),
            format!("{}={}", hooks::SOCKET_ENV, self.hooks.socket.display()),
        ];
        let mut meta = vec![("@maple_agent", agent_name.to_string()), ("@maple_cwd", cwd.to_string()), ("@maple_started", started_at.to_string())];
        if let Some((web, api)) = ports {
            args.extend(["-e".into(), format!("PORT={web}"), "-e".into(), format!("MAPLE_API_PORT={api}")]);
            meta.push(("@maple_ports", format!("{web} {api}")));
        }
        if let Some(t) = &task {
            meta.push(("@maple_task", t.to_meta()));
        }
        // A task's repo secrets: in a one-shot file outside its worktree that the pane's shell reads
        // and removes, so they're only ever in the pane's processes, not tmux's session environment.
        // Codex's connector secrets go the same way (`agents::connector_args` only names them).
        let secrets = secrets.filter(|(_, env)| !env.is_empty());
        let mut env: Vec<(String, String)> = secrets.map(|(_, env)| env.to_vec()).unwrap_or_default();
        if agent_name == "codex" && agent.hooks {
            env.extend(agents::codex_connector_env(connectors));
        }
        let sourced = !env.is_empty();
        if sourced {
            let file = crate::secrets::env_file(id, &env).inspect_err(|_| {
                self.ports.lock().unwrap().remove(&id);
            })?;
            args.extend(["-e".into(), format!("{}={}", crate::secrets::FILE_ENV, file.display())]);
        }
        if let Some((repo, env)) = secrets {
            meta.push((crate::secrets::OPTION, env.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>().join(" ")));
            meta.push((crate::secrets::REPO_OPTION, repo.to_string()));
        }
        // A long prompt goes through a file the shell reads (and removes): tmux refuses a long command.
        let long = prompt.filter(|p| !p.trim().is_empty() && p.len() > PROMPT_IN_FILE && agent.takes_prompt());
        if let Some(p) = long {
            let file = prompt_file(id, p)?;
            args.extend(["-e".into(), format!("{}={}", agents::PROMPT_FILE_ENV, file.display())]);
        }
        args.extend(["-P".into(), "-F".into(), "#{pane_pid}".into(), "--".into()]);
        let mut hook_args = vec![];
        if agent.hooks {
            hook_args = self.hooks.agent_args(agent_name);
            // The factory's connectors: Claude Code reads them (secrets and all) from a file only this user can read.
            let config = match agent_name {
                "claude" => self.hooks.write_session_mcp_config(id, connectors).inspect_err(|_| {
                    self.ports.lock().unwrap().remove(&id);
                    remove_secrets_file(id);
                })?,
                _ => None,
            };
            hook_args.extend(agents::connector_args(agent_name, config.as_deref(), connectors));
        }
        let argv = if long.is_some() {
            agents::argv_with_prompt_file(&agents::login_shell(), &agent, resume, hook_args, model, unattended, images)
        } else {
            agents::argv(&agents::login_shell(), &agent, resume, hook_args, model, unattended, images, prompt)
        };
        args.extend(if sourced { crate::secrets::source_first(argv) } else { argv });
        // The browser decides the size; an SSH client attaching later doesn't resize it.
        // (Set per window: `window-size manual` in the startup config crashes tmux 3.6a.)
        args.extend([";".into(), "set-option".into(), "-w".into(), "-t".into(), name.clone(), "window-size".into(), "manual".into()]);
        // Metadata lives on the tmux session so a restarted runner can adopt it.
        for (key, value) in meta {
            args.extend([";".into(), "set-option".into(), "-t".into(), name.clone(), key.into(), value]);
        }
        let out = match self.tmux.run(&args).await {
            Ok(out) => out,
            Err(e) => {
                self.ports.lock().unwrap().remove(&id);
                remove_secrets_file(id);
                self.hooks.remove_session_mcp_config(id);
                return Err(e);
            }
        };

        let info =
            SessionInfo { id, agent: agent_name.to_string(), cwd: cwd.to_string(), pid: out.lines().next().and_then(|l| l.trim().parse().ok()), started_at };
        if let Err(e) = self.adopt(info.clone(), task) {
            // Untracked, it would run with nobody to end it (or remove its files): stop it now.
            let _ = self.tmux.run(&["kill-session", "-t", &name]).await;
            self.ports.lock().unwrap().remove(&id);
            remove_secrets_file(id);
            self.hooks.remove_session_mcp_config(id);
            return Err(e);
        }
        Ok(info)
    }

    /// Two free localhost ports for a new session, skipping those other live sessions hold.
    /// Without them the session still opens, just with no `PORT` set.
    fn claim_ports(&self, id: Uuid) -> Option<(u16, u16)> {
        let mut held = self.ports.lock().unwrap();
        let taken: HashSet<u16> = held.values().flat_map(|&(a, b)| [a, b]).collect();
        match pick_ports(&taken, || Ok(std::net::TcpListener::bind(("127.0.0.1", 0))?.local_addr()?.port())) {
            Ok(ports) => {
                held.insert(id, ports);
                Some(ports)
            }
            Err(e) => {
                warn!("no free ports for session {id}: {e:#}");
                None
            }
        }
    }

    /// Two free localhost ports that no live session holds, for a server the runner starts itself (a
    /// task's screens), so a dev server a builder left running doesn't get in the way.
    pub fn spare_ports(&self) -> Result<(u16, u16)> {
        let taken: HashSet<u16> = self.ports.lock().unwrap().values().flat_map(|&(a, b)| [a, b]).collect();
        pick_ports(&taken, || Ok(std::net::TcpListener::bind(("127.0.0.1", 0))?.local_addr()?.port()))
    }

    fn adopt(&self, info: SessionInfo, task: Option<TaskTag>) -> Result<()> {
        let id = info.id;
        let name = format!("maple-{id}");
        let outbox = self.outbox.clone();
        // Whether the program asked for bracketed paste. tmux keeps that to itself and capture-pane
        // doesn't include it, so a reattached browser would paste a block as typed lines (each
        // newline pressing Enter). Agents ask for it at start, before an adopting runner was there
        // to see it, so they're assumed to want it until they say otherwise.
        let paste = Mutex::new(PasteMode::new(matches!(info.agent.as_str(), "claude" | "codex")));
        let output = Arc::new(AtomicU64::new(0));
        let counter = output.clone();
        // Remembered secrets are taken out of the terminal's bytes too (`secrets::Scrubber`). It holds
        // back the end of a piece that could be the start of one; `flush_after` lets it go if nothing follows.
        let scrubber: Arc<Mutex<(crate::secrets::Scrubber, u64)>> = Arc::default();
        let control = self.tmux.control(&name, move |event| match event {
            ControlEvent::Output(data) => {
                counter.fetch_add(1, Ordering::Relaxed);
                paste.lock().unwrap().feed(&data);
                let mut held = scrubber.lock().unwrap();
                if !crate::secrets::any() && !held.0.holding() {
                    let _ = outbox.send(Event::Output(id, data));
                    return;
                }
                let clean = held.0.feed(&data);
                if !clean.is_empty() {
                    let _ = outbox.send(Event::Output(id, clean));
                }
                if held.0.holding() {
                    held.1 += 1;
                    tokio::spawn(flush_after(scrubber.clone(), held.1, outbox.clone(), id));
                }
            }
            ControlEvent::Replay { nonce, data } => {
                // The replay repaints a fresh terminal; tell it the paste mode too.
                let mode: &[u8] = if paste.lock().unwrap().on { BRACKETED_ON } else { BRACKETED_OFF };
                let mut data = if crate::secrets::any() { crate::secrets::scrub_bytes(&data) } else { data };
                data.splice(0..0, mode.iter().copied());
                let data = base64::engine::general_purpose::STANDARD.encode(data);
                let _ = outbox.send(Event::Text(Outbound::SessionReplay { id, nonce, data }));
            }
            // Exits are picked up by `watch_exits`, which also reads the status.
            ControlEvent::Exit => {
                let rest = scrubber.lock().unwrap().0.flush();
                if !rest.is_empty() {
                    let _ = outbox.send(Event::Output(id, rest));
                }
            }
        })?;
        self.inner.lock().unwrap().insert(id, Session { info, name, control, output, agent: None, task });
        Ok(())
    }

    pub fn write(&self, id: Uuid, data: &[u8]) {
        if let Some(s) = self.inner.lock().unwrap().get(&id) {
            s.control.input(&s.name, data);
        }
    }

    pub fn resize(&self, id: Uuid, cols: u16, rows: u16) {
        if let Some(s) = self.inner.lock().unwrap().get(&id) {
            s.control.resize(&s.name, cols, rows);
        }
    }

    pub async fn kill(&self, id: Uuid) {
        let Some(name) = self.inner.lock().unwrap().get(&id).map(|s| s.name.clone()) else { return };
        self.requested.lock().unwrap().insert(id);
        let last = self.tmux.last_lines(&name, END_LINES).await;
        if let Err(e) = self.tmux.run(&["kill-session", "-t", &name]).await {
            warn!("could not end {name}: {e:#}");
            return;
        }
        // Ended here and now; don't leave it to the watcher, which may find the whole server gone
        // with its last session.
        let seen = ends::Seen { requested: true, last_output: &last, ..Default::default() };
        self.end(id, &name, &seen, last.clone()).await;
    }

    pub fn is_live(&self, id: Uuid) -> bool {
        self.inner.lock().unwrap().contains_key(&id)
    }

    /// The task a live session runs, and the folder it started in (its worktree).
    pub fn task_of(&self, id: Uuid) -> Option<(TaskTag, String)> {
        self.inner.lock().unwrap().get(&id).and_then(|s| Some((s.task.clone()?, s.info.cwd.clone())))
    }

    /// The session's last `lines` lines (history and screen) as plain text, wrapped lines joined.
    pub async fn capture(&self, id: Uuid, lines: u32) -> Result<String> {
        let name = self.inner.lock().unwrap().get(&id).map(|s| s.name.clone()).ok_or_else(|| anyhow!("no such session"))?;
        let lines = lines.clamp(1, 2000);
        let out = self.tmux.run(&["capture-pane", "-p", "-J", "-S", &format!("-{lines}"), "-t", &name]).await?;
        let mut text = last_lines(&out, lines as usize);
        // 2000 joined lines of a wide terminal can be big; keep the newest that fit in a message.
        crate::protocol::fit_tail(&mut text, crate::protocol::MAX_MESSAGE - crate::protocol::ENVELOPE);
        Ok(text)
    }

    /// The directory the session's shell is in now (`#{pane_current_path}`), which follows `cd`.
    pub async fn current_dir(&self, id: Uuid) -> Option<String> {
        let name = self.inner.lock().unwrap().get(&id).map(|s| s.name.clone())?;
        let out = self.tmux.run(&["display-message", "-p", "-t", &name, "#{pane_current_path}"]).await.ok()?;
        let dir = out.trim();
        (!dir.is_empty()).then(|| dir.to_string())
    }

    /// `question`: what Claude Code's AskUserQuestion is asking, while it waits for the answer.
    /// `tool`: the tool a PreToolUse is about to use (`hooks::permission`), in case it asks permission.
    pub fn set_activity(&self, id: Uuid, activity: Activity, summary: Option<String>, question: Option<serde_json::Value>, tool: Option<serde_json::Value>) {
        let u = activity.update();
        let mut inner = self.inner.lock().unwrap();
        let Some(s) = inner.get_mut(&id) else { return };
        let at = stamp();
        s.agent = Some(hooks::next_state(s.agent.as_ref(), u.clone(), summary.clone(), question.clone(), tool, at));
        // Emitted under the lock, so the outbox has events in the order their `at`s say.
        let _ = (u, summary, question);
        if let Some(activity) = s.agent.as_ref().map(wire_activity) {
            self.emit(Outbound::Wire(wire::RunnerMessage::SessionActivity { id, activity }));
        }
    }

    /// For thumbnails: the session's output counter, and whether its agent is busy (working or
    /// waiting, or hasn't said yet). `None` if there's no such session.
    pub fn thumb_state(&self, id: Uuid) -> Option<(u64, bool)> {
        let inner = self.inner.lock().unwrap();
        let s = inner.get(&id)?;
        Some((s.output.load(Ordering::Relaxed), s.agent.as_ref().is_some_and(|a| matches!(a.state, "working" | "waiting"))))
    }

    /// The visible screen with colours (`capture-pane -p -e`, read-only), the pane's width, and how
    /// many of the rows are history above the screen: with `history`, up to that many rows of
    /// scrollback come first (`-S -<n>`); without, none.
    pub async fn screen(&self, id: Uuid, history: Option<u16>) -> Option<(String, u16, usize)> {
        let name = self.inner.lock().unwrap().get(&id).map(|s| s.name.clone())?;
        let start = history.map(|n| format!("-{n}"));
        let mut args = vec!["display-message", "-p", "-t", &name, "#{pane_width} #{pane_height}", ";", "capture-pane", "-p", "-e"];
        if let Some(start) = &start {
            args.extend(["-S", start]);
        }
        args.extend(["-t", &name]);
        let out = self.tmux.run(&args).await.ok()?;
        let (size, screen) = out.split_once('\n').unwrap_or((&out, ""));
        let mut size = size.split_whitespace().map(|n| n.parse::<usize>().ok());
        let width = size.next().flatten().unwrap_or(80) as u16;
        let height = size.next().flatten().unwrap_or(0);
        let above = if history.is_some() { screen.lines().count().saturating_sub(height) } else { 0 };
        Some((screen.to_string(), width, above))
    }

    /// Snapshots the screen for an attaching browser. Waits briefly first: the
    /// browser's resize arrives just before this, and the app needs a moment to
    /// redraw at the new size.
    pub fn replay(&self, id: Uuid, nonce: String) {
        let sessions = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(150)).await;
            if let Some(s) = sessions.inner.lock().unwrap().get(&id) {
                s.control.replay(&s.name, nonce);
            }
        });
    }

    /// Panes stay around after their program exits (remain-on-exit), so the exit status and the
    /// last screen can be read before the tmux session is cleaned up.
    ///
    /// Only what tmux actually reports ends a session. A poll that can't reach the server says
    /// nothing (a deleted socket, a busy server); a session missing from one poll may be a race.
    async fn watch_exits(self) {
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        let mut clock = ends::Clock::new();
        let mut missing: HashMap<Uuid, u32> = HashMap::new();
        let mut unreachable = 0u32;
        loop {
            tick.tick().await;
            if let Some(slept) = clock.tick() {
                info!("the machine slept for {}s", slept.as_secs());
            }
            let panes = match self.tmux.panes().await {
                Ok(panes) => {
                    if unreachable > 0 {
                        info!("tmux server reachable again after {unreachable} failed polls");
                    }
                    unreachable = 0;
                    panes
                }
                // With no sessions, tmux exits on its own (exit-empty); nothing to worry about.
                Err(_) if self.inner.lock().unwrap().is_empty() => {
                    unreachable = 0;
                    continue;
                }
                Err(e) => {
                    unreachable += 1;
                    if unreachable == 1 || unreachable % 60 == 0 {
                        warn!("could not list tmux panes ({unreachable} in a row): {e:#}");
                    }
                    if self.tmux.recover_socket() {
                        warn!("the tmux socket was deleted; asked the server to recreate it");
                    }
                    if unreachable >= UNREACHABLE_POLLS && self.tmux.server_alive() == Some(false) {
                        let lost: Vec<(Uuid, String)> = self.inner.lock().unwrap().values().map(|s| (s.info.id, s.name.clone())).collect();
                        for (id, name) in lost {
                            let seen = ends::Seen { server_lost: true, ..Default::default() };
                            self.end(id, &name, &seen, vec![]).await;
                        }
                    }
                    continue;
                }
            };
            let live: Vec<(Uuid, String)> = self.inner.lock().unwrap().values().map(|s| (s.info.id, s.name.clone())).collect();
            missing.retain(|id, _| live.iter().any(|(l, _)| l == id));
            for (id, name) in live {
                let requested = self.requested.lock().unwrap().contains(&id);
                match panes.get(&name) {
                    Some(p) if !p.dead => {
                        missing.remove(&id);
                    }
                    Some(p) => {
                        let last = self.tmux.last_lines(&name, END_LINES).await;
                        let seen = ends::Seen {
                            status: p.status,
                            signal: p.signal,
                            requested,
                            slept: clock.recent_sleep(),
                            last_output: &last,
                            ..Default::default()
                        };
                        self.end(id, &name, &seen, last.clone()).await;
                    }
                    None => {
                        let polls = missing.entry(id).or_default();
                        *polls += 1;
                        if *polls >= MISSING_POLLS || requested {
                            let seen = ends::Seen { vanished: true, requested, slept: clock.recent_sleep(), ..Default::default() };
                            self.end(id, &name, &seen, vec![]).await;
                        }
                    }
                }
            }
        }
    }

    /// Records why a session ended, tells the server, and cleans up its tmux session.
    async fn end(&self, id: Uuid, name: &str, seen: &ends::Seen<'_>, last_output: Vec<String>) {
        let Some(gone) = self.inner.lock().unwrap().remove(&id) else {
            return;
        };
        // Its last spend reading goes out before the end, so the hub can file it under the session.
        crate::costs::flush(self, &gone.info).await;
        let _ = self.tmux.run(&["kill-session", "-t", name]).await;
        self.ports.lock().unwrap().remove(&id);
        self.requested.lock().unwrap().remove(&id);
        // Its shell removes its secrets file as it starts; this is for one that never did.
        remove_secrets_file(id);
        self.hooks.remove_session_mcp_config(id);
        let (cause, detail) = ends::classify(seen);
        let end = SessionEnd {
            id,
            cause,
            code: seen.status.map(|c| c as i32),
            signal: seen.signal.map(ends::signal_name),
            detail,
            at: now_ms(),
            last_output,
            by: None,
        };
        info!("session {id} ended: {cause:?}{}", end.detail.as_deref().map(|d| format!(" ({d})")).unwrap_or_default());
        {
            let mut exits = self.exits.lock().unwrap();
            if exits.len() >= MAX_EXITS {
                exits.pop_front();
            }
            exits.push_back(end.clone());
        }
        self.emit(Outbound::Wire(wire::RunnerMessage::SessionEnded { end }));
    }
}

/// How long a scrubber holds the start of what could be a secret before letting it go: short, so a
/// prompt that happens to end that way isn't left off the screen.
const SCRUB_HOLD: Duration = Duration::from_millis(50);

/// Sends what a session's scrubber holds back if no more output came in `SCRUB_HOLD` (the count is
/// still `generation`).
async fn flush_after(scrubber: Arc<Mutex<(crate::secrets::Scrubber, u64)>>, generation: u64, outbox: Outbox, id: Uuid) {
    tokio::time::sleep(SCRUB_HOLD).await;
    let mut held = scrubber.lock().unwrap();
    if held.1 == generation {
        let rest = held.0.flush();
        if !rest.is_empty() {
            let _ = outbox.send(Event::Output(id, rest));
        }
    }
}

fn remove_secrets_file(id: Uuid) {
    if let Ok(path) = crate::secrets::env_path(id) {
        let _ = std::fs::remove_file(path);
    }
}

fn wire_info(info: &SessionInfo, task: Option<&TaskTag>) -> wire::SessionInfo {
    wire::SessionInfo {
        id: info.id,
        agent: info.agent.clone(),
        cwd: info.cwd.clone(),
        pid: info.pid,
        started_at: info.started_at,
        task_id: task.map(|t| t.id.clone()),
    }
}

fn wire_activity(a: &AgentState) -> wire::Activity {
    let state = match a.state {
        "working" => wire::AgentState::Working,
        "waiting" => wire::AgentState::Waiting,
        "done" => wire::AgentState::Done,
        _ => wire::AgentState::Idle,
    };
    wire::Activity {
        state,
        message: a.message.clone(),
        step: a.task.clone(),
        summary: a.summary.clone(),
        question: a.question.clone(),
        at: a.at,
    }
}

/// Two different ports from `bind` (the OS's pick of a free one) that aren't in `taken`.
fn pick_ports(taken: &HashSet<u16>, mut bind: impl FnMut() -> std::io::Result<u16>) -> Result<(u16, u16)> {
    let mut got = Vec::with_capacity(2);
    for _ in 0..32 {
        let port = bind()?;
        if !taken.contains(&port) && !got.contains(&port) {
            got.push(port);
            if let [a, b] = got[..] {
                return Ok((a, b));
            }
        }
    }
    Err(anyhow!("kept getting ports that are in use"))
}

/// `@maple_ports` as written by `open`: `"<PORT> <MAPLE_API_PORT>"`.
pub fn parse_ports(value: &str) -> Option<(u16, u16)> {
    let (a, b) = value.trim().split_once(' ')?;
    Some((a.parse().ok()?, b.parse().ok()?))
}

pub fn expand_home(path: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    match path.strip_prefix('~') {
        Some(rest) => PathBuf::from(format!("{home}{rest}")),
        None => PathBuf::from(path),
    }
}

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// The last `n` lines of a capture, without the blank screen rows below the cursor.
fn last_lines(text: &str, n: usize) -> String {
    let lines: Vec<&str> = text.lines().map(str::trim_end).collect();
    let end = lines.iter().rposition(|l| !l.is_empty()).map_or(0, |i| i + 1);
    lines[end.saturating_sub(n)..end].join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_keeps_the_last_lines() {
        assert_eq!(last_lines("a\nb  \nc\n\n\n", 2), "b\nc");
        assert_eq!(last_lines("a\n\nb\n", 10), "a\n\nb");
        assert_eq!(last_lines("\n\n", 5), "");
    }

    #[test]
    fn picks_two_free_ports_not_held_by_live_sessions() {
        // The OS hands out 52411 twice and 52412, which another session holds; both are skipped.
        let mut offers = [52411, 52411, 52412, 52437].into_iter();
        let taken = HashSet::from([52412]);
        assert_eq!(pick_ports(&taken, || Ok(offers.next().unwrap())).unwrap(), (52411, 52437));
        // A second session sees the first one's ports as taken.
        let taken = HashSet::from([52411, 52412, 52437]);
        let mut offers = [52437, 52411, 52438, 52439].into_iter();
        assert_eq!(pick_ports(&taken, || Ok(offers.next().unwrap())).unwrap(), (52438, 52439));
        // Gives up rather than looping forever, and passes bind errors on.
        assert!(pick_ports(&HashSet::from([1]), || Ok(1)).is_err());
        assert!(pick_ports(&HashSet::new(), || Err(std::io::Error::other("no"))).is_err());
        // Real binds give two different ports.
        let (a, b) = pick_ports(&HashSet::new(), || Ok(std::net::TcpListener::bind(("127.0.0.1", 0))?.local_addr()?.port())).unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn reads_ports_back_from_tmux() {
        assert_eq!(parse_ports("52411 52412"), Some((52411, 52412)));
        // Sessions from before ports, or garbage.
        assert_eq!(parse_ports(""), None);
        assert_eq!(parse_ports("52411"), None);
        assert_eq!(parse_ports("a b"), None);
    }

    #[tokio::test]
    async fn a_sessions_connectors_file_goes_when_it_ends() {
        // Short: the tmux socket path must stay under 104 bytes.
        let dir = PathBuf::from(format!("/tmp/mf-test-{}", &Uuid::new_v4().to_string()[..8]));
        std::fs::create_dir_all(&dir).unwrap();
        let (tx, _rx) = mpsc::unbounded_channel();
        let tmux = Tmux::new("t", &dir).unwrap();
        let hooks = Hooks::prepare(&dir, "t").unwrap();
        let sessions = Sessions::start(tx, tmux, hooks).await.unwrap();
        let id = Uuid::new_v4();
        let jira = wire::McpConnector {
            name: "jira".into(),
            transport: wire::McpTransport::Stdio,
            command: Some("npx".into()),
            args: vec![],
            url: None,
            env: [("JIRA_API_TOKEN".to_string(), "secret".to_string())].into(),
            headers: Default::default(),
            enabled: true,
            auto_allow: false,
        };
        // As `open` writes it for a Claude Code session; a plain shell stands in for the agent.
        let file = sessions.hooks.write_session_mcp_config(id, std::slice::from_ref(&jira)).unwrap().unwrap();
        sessions.open(id, "shell", dir.to_str().unwrap(), None, None, &[jira], &[], None, false, 80, 24, None, None).await.unwrap();
        assert!(file.exists() && sessions.is_live(id));
        sessions.kill(id).await;
        assert!(!sessions.is_live(id));
        assert!(!file.exists(), "the session's connectors file is removed when it ends");
        let _ = sessions.tmux.run(&["kill-server"]).await;
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

#[cfg(test)]
mod paste_tests {
    use super::PasteMode;

    #[test]
    fn follows_bracketed_paste_mode() {
        let mut m = PasteMode::new(false);
        m.feed(b"prompt \x1b[?2004h$ ");
        assert!(m.on);
        m.feed(b"ls\r\n\x1b[?2004l");
        assert!(!m.on);
        // Split across two pieces of output.
        m.feed(b"text \x1b[?20");
        assert!(!m.on);
        m.feed(b"04h more");
        assert!(m.on);
        // Both in one piece: the later one wins.
        m.feed(b"\x1b[?2004h...\x1b[?2004l");
        assert!(!m.on);
        // Agents start out on; other output doesn't change it.
        let mut agent = PasteMode::new(true);
        agent.feed(b"\x1b[2J\x1b[H hello");
        assert!(agent.on);
    }

}
