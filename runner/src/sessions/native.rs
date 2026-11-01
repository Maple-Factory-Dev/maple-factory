//! The native session view on the runner's side: each session's event stream (events.rs), its
//! tailer, what hooks add to it, and typing the native composer's input into the pane.
//!
//! Permissions: `session.events.subscribe` and `session.input` reach the runner only from its own
//! server connection, which already applied the terminal's watch / `canType` rule, so nothing here
//! checks the viewer again.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Result, anyhow};
use tracing::{info, warn};
use uuid::Uuid;

use super::Sessions;
use crate::events::EventStream;
use crate::hooks::{NativeHook, menu_options};
use crate::protocol::Outbound;
use crate::wire::{self, PromptKind, SessionEvent, SessionInput, TurnState};

/// How often a subscribed stream's transcript is read.
const TAIL_EVERY: Duration = Duration::from_millis(300);
/// Events per `session.events` message in a backfill.
const CHUNK: usize = 100;
/// Between pasting text and pressing Enter, so the TUI takes the paste first.
const ENTER_AFTER: Duration = Duration::from_millis(80);

impl Sessions {
    /// Makes the session's stream if it has none: Claude's waits for a `transcript_path`; Codex's
    /// finds its rollout by cwd and start time, retried until it exists.
    fn ensure_stream(&self, id: Uuid) -> bool {
        if self.streams.lock().unwrap().contains_key(&id) {
            return true;
        }
        let Some(info) = self.inner.lock().unwrap().get(&id).map(|s| s.info.clone()) else { return false };
        let locate: Option<crate::events::Locate> = (info.agent == "codex").then(|| {
            let cwd = super::expand_home(&info.cwd);
            let started = info.started_at;
            Box::new(move || crate::costs::find_rollout(&crate::usage::codex_sessions_dir(), &cwd, started)) as crate::events::Locate
        });
        self.streams.lock().unwrap().entry(id).or_insert_with(|| EventStream::new(id, &info.agent, None, locate));
        true
    }

    /// A hook named the session's transcript: the stream learns it, or follows it to a new file.
    pub fn set_transcript(&self, id: Uuid, agent: &str, path: PathBuf) {
        if agent != "claude" || !self.ensure_stream(id) {
            return;
        }
        if let Some(s) = self.streams.lock().unwrap().get_mut(&id)
            && s.set_path(path.clone())
        {
            info!("session {id}: native view follows {}", path.display());
        }
    }

    fn send_events(&self, id: Uuid, stream: &EventStream, events: Vec<SessionEvent>, backfill: bool, nonce: Option<String>) {
        let msg = wire::RunnerMessage::SessionEvents {
            id,
            events,
            backfill,
            next_seq: stream.next_seq(),
            epoch: stream.epoch.clone(),
            nonce,
            cursor: Some(stream.cursor()),
        };
        self.emit(Outbound::Wire(msg));
    }

    /// `session.events.subscribe`: a backfill tagged with `nonce`, then live events while anyone
    /// is subscribed. With `stop`, one subscriber fewer; the tailer ends at none.
    pub fn subscribe_events(&self, id: Uuid, since: Option<u64>, epoch: Option<String>, limit: Option<u32>, stop: bool, nonce: Option<String>) {
        if stop {
            if let Some(s) = self.streams.lock().unwrap().get_mut(&id) {
                s.subscribers = s.subscribers.saturating_sub(1);
            }
            return;
        }
        if !self.ensure_stream(id) {
            self.emit(Outbound::SessionError { id, message: "no such session".into() });
            return;
        }
        let start_tailer = {
            let mut streams = self.streams.lock().unwrap();
            let Some(s) = streams.get_mut(&id) else { return };
            // Catch up first, so the backfill is current; anything new goes to live subscribers too.
            let fresh = s.poll();
            if !fresh.is_empty() && s.subscribers > 0 {
                self.send_events(id, s, fresh, false, None);
            }
            let backfill = s.backfill(since, epoch.as_deref(), limit.map(|l| l as usize));
            if backfill.is_empty() {
                self.send_events(id, s, vec![], true, nonce.clone());
            }
            for chunk in backfill.chunks(CHUNK) {
                self.send_events(id, s, chunk.to_vec(), true, nonce.clone());
            }
            s.subscribers += 1;
            s.subscribers == 1
        };
        if start_tailer {
            tokio::spawn(self.clone().tail(id));
        }
    }

    async fn tail(self, id: Uuid) {
        loop {
            tokio::time::sleep(TAIL_EVERY).await;
            let mut streams = self.streams.lock().unwrap();
            let Some(s) = streams.get_mut(&id) else { return };
            if s.subscribers == 0 {
                return;
            }
            let events = s.poll();
            if !events.is_empty() {
                self.send_events(id, s, events, false, None);
            }
        }
    }

    /// What a hook adds to the stream: turns running, permission prompts (their menu read off the
    /// pane), prompts resolved. Only for a stream someone made; the transcript is read first so
    /// the order holds.
    pub async fn push_hook_events(&self, id: Uuid, hooks: Vec<NativeHook>) {
        if !self.streams.lock().unwrap().contains_key(&id) {
            return;
        }
        let mut pane = None;
        if hooks.iter().any(|h| matches!(h, NativeHook::Permission { .. })) {
            // The menu is drawn a moment after the hook fires.
            tokio::time::sleep(Duration::from_millis(250)).await;
            if let Some(name) = self.inner.lock().unwrap().get(&id).map(|s| s.name.clone()) {
                pane = Some(name);
            }
        }
        let lines = match &pane {
            Some(name) => self.tmux.last_lines(name, 20).await,
            None => vec![],
        };
        let mut streams = self.streams.lock().unwrap();
        let Some(s) = streams.get_mut(&id) else { return };
        let mut out = s.poll();
        let agent = self.inner.lock().unwrap().get(&id).map(|x| x.info.agent.clone()).unwrap_or_default();
        for h in hooks {
            match h {
                NativeHook::Running { call } => {
                    if call.is_some() {
                        s.last_call = call;
                    }
                    if !s.running {
                        s.running = true;
                        let at = super::now_ms();
                        let e = SessionEvent::Turn {
                            id: format!("{id}:running:{at}"),
                            session: id,
                            seq: 0,
                            at,
                            agent: agent.clone(),
                            state: TurnState::Running,
                            usage: None,
                            message: None,
                        };
                        out.extend(s.push(vec![e]));
                    }
                }
                NativeHook::Permission { text } => {
                    let call = s.last_call.clone();
                    let e = SessionEvent::Prompt {
                        id: String::new(),
                        session: id,
                        seq: 0,
                        at: super::now_ms(),
                        agent: agent.clone(),
                        kind: PromptKind::Permission,
                        text,
                        options: menu_options(&lines),
                        call_id: call.clone(),
                    };
                    out.extend(s.open_prompt(e, call.as_deref()));
                }
                NativeHook::Resolved => out.extend(s.resolve(None)),
            }
        }
        if !out.is_empty() && s.subscribers > 0 {
            self.send_events(id, s, out, false, None);
        }
    }

    /// `session.input`: typed into the pane the way a person would, so `/rc` and the TUI's own
    /// menus work. A `key` goes only to the prompt it names, while it's still showing.
    pub async fn send_input(&self, id: Uuid, input: SessionInput) -> Result<()> {
        let name = self.inner.lock().unwrap().get(&id).map(|s| s.name.clone()).ok_or_else(|| anyhow!("no such session"))?;
        let control = |data: &[u8]| {
            if let Some(s) = self.inner.lock().unwrap().get(&id) {
                s.control.input(&name, data);
            }
        };
        match input {
            SessionInput::Text { text } => {
                control(format!("\x1b[200~{text}\x1b[201~").as_bytes());
                tokio::time::sleep(ENTER_AFTER).await;
                control(b"\r");
            }
            SessionInput::Slash { command } => {
                // Typed as it is, so the TUI treats it exactly like a person's /command.
                control(command.trim_end_matches(['\r', '\n']).as_bytes());
                tokio::time::sleep(ENTER_AFTER).await;
                control(b"\r");
            }
            SessionInput::Key { prompt_id, key } => {
                let bytes = check_key(self.streams.lock().unwrap().get(&id), &prompt_id, &key).inspect_err(|e| warn!("session {id}: {e:#}"))?;
                control(&bytes);
                let mut streams = self.streams.lock().unwrap();
                if let Some(s) = streams.get_mut(&id) {
                    let resolved = s.resolve(Some(key));
                    if s.subscribers > 0 && !resolved.is_empty() {
                        self.send_events(id, s, resolved, false, None);
                    }
                }
            }
        }
        Ok(())
    }
}

/// The bytes a prompt answer types, or why it's refused: only for the prompt showing now, and
/// only a menu number or Escape (the keys `task.answerPrompt` uses).
fn check_key(stream: Option<&EventStream>, prompt_id: &str, key: &str) -> Result<Vec<u8>> {
    let showing = stream.and_then(|s| s.prompt_showing());
    if showing != Some(prompt_id) {
        return Err(anyhow!("refused key for prompt {prompt_id}: {} is showing", showing.unwrap_or("no prompt")));
    }
    match key {
        "Escape" | "Esc" => Ok(b"\x1b".to_vec()),
        k if !k.is_empty() && k.len() <= 2 && k.chars().all(|c| c.is_ascii_digit()) => Ok(k.as_bytes().to_vec()),
        k => Err(anyhow!("refused key {k:?}: not a menu option")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prompt() -> SessionEvent {
        SessionEvent::Prompt {
            id: String::new(),
            session: Uuid::nil(),
            seq: 0,
            at: 1,
            agent: "claude".into(),
            kind: PromptKind::Permission,
            text: "?".into(),
            options: vec![],
            call_id: None,
        }
    }

    #[test]
    fn a_key_for_a_stale_prompt_is_refused() {
        let mut s = EventStream::new(Uuid::nil(), "claude", None, None);
        assert!(check_key(Some(&s), "prompt-1", "1").is_err(), "no prompt showing");
        s.open_prompt(prompt(), None);
        assert_eq!(check_key(Some(&s), "prompt-1", "1").unwrap(), b"1");
        assert_eq!(check_key(Some(&s), "prompt-1", "Escape").unwrap(), b"\x1b");
        assert!(check_key(Some(&s), "prompt-1", "rm -rf /\r").is_err(), "only menu keys");
        // A second prompt replaces the first: the first's id is stale now.
        s.open_prompt(prompt(), None);
        assert!(check_key(Some(&s), "prompt-1", "1").is_err());
        assert!(check_key(Some(&s), "prompt-2", "1").is_ok());
        s.resolve(None);
        assert!(check_key(Some(&s), "prompt-2", "1").is_err(), "answered already");
        assert!(check_key(None, "prompt-2", "1").is_err());
    }
}

/// A live run against a real Claude Code session in tmux (`cargo test live_claude -- --ignored --nocapture`):
/// the stream's backfill and live `session.events`, as the server would get them, and a slash command
/// typed with send-keys the way `send_input` types it.
#[cfg(test)]
mod live {
    use super::*;
    use std::process::Command;

    fn tmux(sock: &str, args: &[&str]) -> String {
        String::from_utf8_lossy(&Command::new("tmux").arg("-L").arg(sock).args(args).output().unwrap().stdout).into_owned()
    }

    fn type_bytes(sock: &str, target: &str, data: &[u8]) {
        let hex: Vec<String> = data.iter().map(|b| format!("{b:02x}")).collect();
        let mut args = vec!["send-keys", "-t", target, "-H"];
        args.extend(hex.iter().map(String::as_str));
        tmux(sock, &args);
    }

    fn print_msg(stream: &EventStream, id: Uuid, events: Vec<SessionEvent>, backfill: bool, nonce: Option<String>) {
        let msg = wire::RunnerMessage::SessionEvents {
            id,
            events,
            backfill,
            next_seq: stream.next_seq(),
            epoch: stream.epoch.clone(),
            nonce,
            cursor: Some(stream.cursor()),
        };
        let json = serde_json::to_value(&msg).unwrap();
        let rows: Vec<String> = json["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| {
                let what = ["text", "markdown", "kind", "state"].iter().find_map(|k| e[*k].as_str()).or_else(|| e["call"]["summary"].as_str()).unwrap_or("");
                format!("    seq {} {}: {}", e["seq"], e["type"].as_str().unwrap(), what.chars().take(70).collect::<String>().replace('\n', " "))
            })
            .collect();
        println!(
            "→ server: session.events backfill={} nonce={} nextSeq={} epoch={} cursor={}\n{}",
            json["backfill"],
            json["nonce"],
            json["nextSeq"],
            json["epoch"],
            json["cursor"]["token"].as_str().unwrap_or("").rsplit('/').next().unwrap(),
            rows.join("\n")
        );
    }

    #[test]
    #[ignore]
    fn live_claude() {
        let cwd = std::env::var("LIVE_CWD").expect("LIVE_CWD");
        let sock = "maple-mf200-live";
        let id = Uuid::new_v4();
        tmux(sock, &["new-session", "-d", "-s", "live", "-x", "160", "-y", "50", "-c", &cwd, "claude", "Reply with just the word ready."]);
        let projects = PathBuf::from(std::env::var("HOME").unwrap()).join(".claude/projects").join(cwd.replace(['/', '.'], "-"));
        let started = std::time::SystemTime::now();
        // The transcript_path a hook would give: the session's file under ~/.claude/projects.
        let find = move || {
            std::fs::read_dir(&projects)
                .ok()?
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
                .find(|p| p.metadata().and_then(|m| m.modified()).is_ok_and(|m| m >= started))
        };
        let mut stream = EventStream::new(id, "claude", None, Some(Box::new(find)));
        let wait = |stream: &mut EventStream, until: &dyn Fn(&SessionEvent) -> bool, secs: u64| -> Vec<SessionEvent> {
            let mut got = vec![];
            for _ in 0..secs * 4 {
                std::thread::sleep(Duration::from_millis(250));
                got.extend(stream.poll());
                if got.iter().any(until) {
                    break;
                }
            }
            got
        };
        let got = wait(&mut stream, &|e| matches!(e, SessionEvent::Turn { state: TurnState::Done, .. }), 90);
        println!("transcript: {}", stream.cursor().token.unwrap_or_default());
        println!("{} events read before the subscribe", got.len());
        // session.events.subscribe {nonce: "n-live-1"}: the backfill.
        print_msg(&stream, id, stream.backfill(None, None, None), true, Some("n-live-1".into()));
        // session.input {type: slash, command: "/context"}: typed, then Enter.
        type_bytes(sock, "live", b"/context");
        std::thread::sleep(ENTER_AFTER);
        type_bytes(sock, "live", b"\r");
        let live = wait(&mut stream, &|e| matches!(e, SessionEvent::User { text, .. } if text == "/context"), 30);
        print_msg(&stream, id, live.clone(), false, None);
        println!(
            "pane after /context:\n{}",
            tmux(sock, &["capture-pane", "-p", "-t", "live"]).lines().filter(|l| !l.trim().is_empty()).take(12).collect::<Vec<_>>().join("\n")
        );
        tmux(sock, &["kill-server"]);
        assert!(live.iter().any(|e| matches!(e, SessionEvent::User { text, .. } if text == "/context")), "no /context user event");
    }
}
