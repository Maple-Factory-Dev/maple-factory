//! A session's native-view stream: tails its transcript from a byte offset, numbers events with
//! `seq` in an `epoch`, keeps a ring of recent ones for backfill, and takes events the hooks add
//! (turns, prompts) in the same numbering. The tailer itself (a task polling `poll`) lives in
//! sessions.rs; everything here is synchronous so tests can drive it.

use std::collections::VecDeque;
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;

use uuid::Uuid;

use crate::transcript::{Parser, seq_of, set_seq};
use crate::wire::{SessionEvent, SessionEventCursor};

/// Events kept for backfill.
pub const RING: usize = 2000;
/// A backfill without `since` sends this many by default.
pub const DEFAULT_LIMIT: usize = 200;
/// At most this many bytes are read per poll, so one huge transcript doesn't stall the runner.
const READ_CHUNK: u64 = 4 << 20;

/// Finds a transcript that isn't there yet (Codex's rollout, found by cwd and start time).
pub type Locate = Box<dyn Fn() -> Option<PathBuf> + Send>;

pub struct EventStream {
    session: Uuid,
    agent: String,
    path: Option<PathBuf>,
    locate: Option<Locate>,
    offset: u64,
    /// The file's identity (inode) and length last time, to notice rotation or truncation.
    inode: Option<u64>,
    /// Bytes after the last newline: a record still being written.
    partial: Vec<u8>,
    parser: Parser,
    next_seq: u64,
    pub epoch: String,
    ring: VecDeque<SessionEvent>,
    pub subscribers: usize,
    /// The prompt showing now (its event id), so a `key` input can be checked against it.
    open_prompt: Option<String>,
    prompts: u64,
    /// Whether a turn is running (a `turn running` went out since the last done/interrupted/error).
    pub running: bool,
    /// The tool call the last PreToolUse named, for the permission prompt that may follow it.
    pub last_call: Option<String>,
}

fn inode(meta: &std::fs::Metadata) -> Option<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some(meta.ino())
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        None
    }
}

impl EventStream {
    pub fn new(session: Uuid, agent: &str, path: Option<PathBuf>, locate: Option<Locate>) -> Self {
        Self {
            session,
            agent: agent.into(),
            path,
            locate,
            offset: 0,
            inode: None,
            partial: vec![],
            parser: Parser::new(agent, session),
            next_seq: 1,
            epoch: Uuid::new_v4().simple().to_string()[..12].to_string(),
            ring: VecDeque::new(),
            subscribers: 0,
            open_prompt: None,
            prompts: 0,
            running: false,
            last_call: None,
        }
    }

    pub fn next_seq(&self) -> u64 {
        self.next_seq
    }

    pub fn cursor(&self) -> SessionEventCursor {
        SessionEventCursor { seq: self.next_seq.saturating_sub(1), token: self.path.as_ref().map(|p| format!("{}:{}", p.display(), self.read_offset())) }
    }

    /// Follows the agent to a new transcript (after `/clear`, `/compact`, a resume). Seq keeps
    /// counting up in the same epoch.
    pub fn set_path(&mut self, path: PathBuf) -> bool {
        if self.path.as_deref() == Some(path.as_path()) {
            return false;
        }
        self.path = Some(path);
        self.restart_file();
        true
    }

    fn restart_file(&mut self) {
        self.offset = 0;
        self.inode = None;
        self.partial.clear();
        self.parser = Parser::new(&self.agent, self.session);
    }

    /// Numbers `events` and keeps them; returns them numbered.
    pub fn push(&mut self, events: Vec<SessionEvent>) -> Vec<SessionEvent> {
        let mut out = Vec::with_capacity(events.len());
        for mut e in events {
            set_seq(&mut e, self.next_seq);
            self.next_seq += 1;
            if let SessionEvent::Turn { state, .. } = &e {
                self.running = *state == crate::wire::TurnState::Running;
            }
            if let SessionEvent::ToolResult { call_id, .. } = &e
                && self.open_prompt.as_deref().is_some_and(|p| p.ends_with(&format!(":{call_id}")))
            {
                // The tool it asked about ran: the prompt was answered (in the terminal, maybe).
                let resolved = self.resolve_event(None);
                self.ring.push_back(e.clone());
                out.push(e);
                if let Some(r) = resolved {
                    self.ring.push_back(r.clone());
                    out.push(r);
                }
                continue;
            }
            self.ring.push_back(e.clone());
            out.push(e);
        }
        while self.ring.len() > RING {
            self.ring.pop_front();
        }
        out
    }

    /// Reads whatever the transcript gained since last time (whole lines only) and returns the new
    /// events, numbered. A missing file is retried next time; a file that shrank or was replaced is
    /// read again from its start, seq still counting up.
    pub fn poll(&mut self) -> Vec<SessionEvent> {
        if self.path.is_none()
            && let Some(found) = self.locate.as_ref().and_then(|l| l())
        {
            self.path = Some(found);
            self.restart_file();
        }
        let Some(path) = self.path.clone() else { return vec![] };
        let Ok(mut file) = std::fs::File::open(&path) else { return vec![] };
        let Ok(meta) = file.metadata() else { return vec![] };
        let ino = inode(&meta);
        if (self.inode.is_some() && ino != self.inode) || meta.len() < self.offset {
            self.restart_file();
        }
        self.inode = ino;
        if meta.len() == self.offset {
            return vec![];
        }
        if file.seek(SeekFrom::Start(self.offset)).is_err() {
            return vec![];
        }
        let mut buf = Vec::new();
        if file.take(READ_CHUNK).read_to_end(&mut buf).is_err() {
            return vec![];
        }
        self.offset += buf.len() as u64;
        self.partial.extend_from_slice(&buf);
        let Some(last_nl) = self.partial.iter().rposition(|b| *b == b'\n') else { return vec![] };
        let rest = self.partial.split_off(last_nl + 1);
        let whole = std::mem::replace(&mut self.partial, rest);
        let text = String::from_utf8_lossy(&whole);
        let events: Vec<_> = text.lines().flat_map(|l| self.parser.parse(l)).collect();
        self.push(events)
    }

    /// Byte offset of the last whole line read, for the cursor token.
    pub fn read_offset(&self) -> u64 {
        self.offset - self.partial.len() as u64
    }

    /// The backfill for a subscriber: events after `since` when `epoch` is this stream's, else
    /// from the start of what's held; without `since`, the last `limit`.
    pub fn backfill(&self, since: Option<u64>, epoch: Option<&str>, limit: Option<usize>) -> Vec<SessionEvent> {
        let since = if epoch.is_some_and(|e| e != self.epoch) { Some(0) } else { since };
        match since {
            Some(since) => {
                let all: Vec<_> = self.ring.iter().filter(|e| seq_of(e) > since).cloned().collect();
                match limit {
                    Some(l) if all.len() > l => all[..l].to_vec(),
                    _ => all,
                }
            }
            None => {
                let limit = limit.unwrap_or(DEFAULT_LIMIT);
                self.ring.iter().skip(self.ring.len().saturating_sub(limit)).cloned().collect()
            }
        }
    }

    /// Opens a prompt (from a hook); returns it numbered. An open one it replaces is resolved first.
    pub fn open_prompt(&mut self, mut prompt: SessionEvent, call_id: Option<&str>) -> Vec<SessionEvent> {
        let mut numbered = self.resolve(None);
        self.prompts += 1;
        let id = match call_id {
            Some(c) => format!("prompt-{}:{c}", self.prompts),
            None => format!("prompt-{}", self.prompts),
        };
        if let SessionEvent::Prompt { id: pid, .. } = &mut prompt {
            *pid = id.clone();
        }
        self.open_prompt = Some(id);
        numbered.extend(self.push(vec![prompt]));
        numbered
    }

    pub fn prompt_showing(&self) -> Option<&str> {
        self.open_prompt.as_deref()
    }

    fn resolve_event(&mut self, key: Option<String>) -> Option<SessionEvent> {
        let prompt_id = self.open_prompt.take()?;
        let mut e = SessionEvent::PromptResolved {
            id: format!("{prompt_id}:resolved"),
            session: self.session,
            seq: 0,
            at: crate::sessions::now_ms(),
            agent: self.agent.clone(),
            prompt_id,
            key,
        };
        set_seq(&mut e, self.next_seq);
        self.next_seq += 1;
        Some(e)
    }

    /// Closes the open prompt, if any; returns its `prompt.resolved`, numbered.
    pub fn resolve(&mut self, key: Option<String>) -> Vec<SessionEvent> {
        match self.resolve_event(key) {
            Some(e) => {
                self.ring.push_back(e.clone());
                vec![e]
            }
            None => vec![],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::id_of;
    use std::io::Write;
    use std::path::Path;

    fn user(uuid: &str, text: &str) -> String {
        format!(
            "{{\"type\":\"user\",\"uuid\":\"{uuid}\",\"timestamp\":\"2026-10-16T19:17:31.317Z\",\"message\":{{\"role\":\"user\",\"content\":\"{text}\"}}}}\n"
        )
    }

    fn texts(events: &[SessionEvent]) -> Vec<String> {
        events
            .iter()
            .map(|e| match e {
                SessionEvent::User { text, seq, .. } => format!("{seq}:{text}"),
                other => format!("{}:{}", seq_of(other), id_of(other)),
            })
            .collect()
    }

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("maple-events-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(name)
    }

    fn append(path: &Path, s: &str) {
        std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap().write_all(s.as_bytes()).unwrap();
    }

    #[test]
    fn a_half_written_line_waits_for_its_newline() {
        let path = temp("t.jsonl");
        let line = user("a", "hello");
        let (head, tail) = line.split_at(30);
        append(&path, &user("z", "first"));
        append(&path, head);
        let mut s = EventStream::new(Uuid::new_v4(), "claude", Some(path.clone()), None);
        assert_eq!(texts(&s.poll()), ["1:first"]);
        assert!(s.poll().is_empty());
        append(&path, tail);
        assert_eq!(texts(&s.poll()), ["2:hello"]);
        assert_eq!(s.read_offset(), std::fs::metadata(&path).unwrap().len());
    }

    #[test]
    fn a_transcript_that_appears_late_streams_from_its_start() {
        let path = temp("rollout.jsonl");
        let p = path.clone();
        let mut s = EventStream::new(Uuid::new_v4(), "claude", None, Some(Box::new(move || p.exists().then(|| p.clone()))));
        assert!(s.poll().is_empty());
        append(&path, &user("a", "one"));
        append(&path, &user("b", "two"));
        assert_eq!(texts(&s.poll()), ["1:one", "2:two"]);
    }

    #[test]
    fn rotation_keeps_seq_going_up() {
        let (a, b) = (temp("a.jsonl"), temp("b.jsonl"));
        append(&a, &user("a1", "before"));
        let mut s = EventStream::new(Uuid::new_v4(), "claude", Some(a.clone()), None);
        let epoch = s.epoch.clone();
        assert_eq!(texts(&s.poll()), ["1:before"]);
        append(&b, &user("b1", "after clear"));
        assert!(s.set_path(b.clone()));
        assert_eq!(texts(&s.poll()), ["2:after clear"]);
        // The same file replaced (truncated and rewritten) is read again, still counting up.
        std::fs::write(&b, user("b2", "rewritten")).unwrap();
        assert_eq!(texts(&s.poll()), ["3:rewritten"]);
        assert_eq!(s.epoch, epoch);
    }

    #[test]
    fn backfill_honours_since_limit_and_epoch() {
        let path = temp("t.jsonl");
        for i in 1..=5 {
            append(&path, &user(&format!("u{i}"), &format!("m{i}")));
        }
        let mut s = EventStream::new(Uuid::new_v4(), "claude", Some(path), None);
        s.poll();
        let epoch = s.epoch.clone();
        assert_eq!(texts(&s.backfill(Some(3), Some(&epoch), None)), ["4:m4", "5:m5"]);
        assert_eq!(texts(&s.backfill(Some(1), Some(&epoch), Some(2))), ["2:m2", "3:m3"]);
        assert_eq!(texts(&s.backfill(None, None, Some(2))), ["4:m4", "5:m5"]);
        // A since from another epoch means nothing: everything from seq 1.
        assert_eq!(texts(&s.backfill(Some(4), Some("stale"), None)).len(), 5);
        assert_eq!(s.backfill(Some(4), Some("stale"), None)[0].clone().pipe(|e| seq_of(&e)), 1);
        assert_eq!(s.cursor().seq, 5);
    }

    #[test]
    fn a_tool_result_resolves_its_permission_prompt() {
        let path = temp("t.jsonl");
        let mut s = EventStream::new(Uuid::new_v4(), "claude", Some(path.clone()), None);
        let prompt = SessionEvent::Prompt {
            id: String::new(),
            session: Uuid::nil(),
            seq: 0,
            at: 1,
            agent: "claude".into(),
            kind: crate::wire::PromptKind::Permission,
            text: "?".into(),
            options: vec![],
            call_id: Some("toolu_1".into()),
        };
        let opened = s.open_prompt(prompt, Some("toolu_1"));
        assert_eq!(texts(&opened), ["1:prompt-1:toolu_1"]);
        assert_eq!(s.prompt_showing(), Some("prompt-1:toolu_1"));
        append(
            &path,
            "{\"type\":\"user\",\"uuid\":\"r\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"ok\"}]}}\n",
        );
        assert_eq!(texts(&s.poll()), ["2:r:toolu_1", "3:prompt-1:toolu_1:resolved"]);
        assert_eq!(s.prompt_showing(), None);
    }

    trait Pipe: Sized {
        fn pipe<T>(self, f: impl FnOnce(Self) -> T) -> T {
            f(self)
        }
    }
    impl<T> Pipe for T {}
}
