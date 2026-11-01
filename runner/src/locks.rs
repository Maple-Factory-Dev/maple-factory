//! Shared resource locks: counted slots (a semaphore) that processes on this machine queue for,
//! like "ios-simulator" or "rails-test-db" (docs/resource-locks.md).
//!
//! `maple-runner lock <name> -- <command>` holds a connection to the hook socket open while it
//! waits and while its command runs (hooks.rs). Each connection owns a [`Ticket`]; dropping it, on
//! EOF or a broken connection, leaves the queue or frees the slot, so a crashed or killed process
//! can't leak one. Waiters are served first in, first out.
//!
//! A lock's slot count is the machine's override in `~/.config/maple/locks.toml`
//! (`ios-simulator = 2`), else the largest `--slots` any current requester asked for, else 1.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use serde_json::{Value, json};
use tokio::sync::watch;
use uuid::Uuid;

/// Who holds or waits for a slot.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Holder {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<Uuid>,
    /// The factory task the session runs; none for a plain session or the owner's own terminal.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    /// When it took the slot, or joined the queue (ms since the epoch).
    pub since: u64,
}

impl Holder {
    /// How a waiter's message names it: its task, or "your terminal" outside a session.
    pub fn label(&self) -> String {
        match (&self.task, self.session) {
            (Some(task), _) => task.clone(),
            (None, Some(_)) => "a session".into(),
            (None, None) => "your terminal".into(),
        }
    }
}

struct Entry {
    ticket: u64,
    /// The `--slots` this requester asked for.
    asked: u32,
    who: Holder,
}

#[derive(Default)]
struct Lock {
    holders: Vec<Entry>,
    queue: VecDeque<Entry>,
}

/// What a waiting session shows (sessions.rs `show_lock_wait`).
#[derive(Debug, Clone, PartialEq)]
pub enum Wait {
    /// Its waiting line (`waiting_line`).
    Queued(String),
    Granted,
    /// It gave up its place before getting a slot.
    Left,
}

/// Where a ticket is now.
#[derive(Debug, Clone, PartialEq)]
pub enum State {
    Granted,
    /// `position` is its place in line from 1; `holders` hold the slots now.
    Queued { position: usize, holders: Vec<Holder> },
    /// Released (only after the ticket is gone; never seen through a live one).
    Gone,
}

pub struct Locks {
    inner: Mutex<Inner>,
    /// Bumped on every change, so waiters look again.
    changed: watch::Sender<u64>,
}

#[derive(Default)]
struct Inner {
    locks: HashMap<String, Lock>,
    overrides: HashMap<String, u32>,
    next: u64,
}

impl Inner {
    fn slots(&self, name: &str) -> usize {
        if let Some(n) = self.overrides.get(name) {
            return (*n).max(1) as usize;
        }
        let lock = self.locks.get(name);
        let asked = lock.into_iter().flat_map(|l| l.holders.iter().chain(l.queue.iter())).map(|e| e.asked).max();
        asked.unwrap_or(1).max(1) as usize
    }

    /// Moves waiters into free slots, oldest first.
    fn promote(&mut self, name: &str) {
        let slots = self.slots(name);
        let Some(lock) = self.locks.get_mut(name) else { return };
        while lock.holders.len() < slots {
            let Some(mut e) = lock.queue.pop_front() else { break };
            e.who.since = crate::sessions::now_ms();
            lock.holders.push(e);
        }
        if lock.holders.is_empty() && lock.queue.is_empty() {
            self.locks.remove(name);
        }
    }
}

/// A place in a lock's queue, or a slot. Dropping it gives either up.
pub struct Ticket {
    locks: Arc<Locks>,
    pub name: String,
    id: u64,
}

impl Ticket {
    pub fn state(&self) -> State {
        self.locks.state(&self.name, self.id)
    }
}

impl Drop for Ticket {
    fn drop(&mut self) {
        self.locks.release(&self.name, self.id);
    }
}

impl Locks {
    pub fn new(overrides: HashMap<String, u32>) -> Arc<Self> {
        let inner = Inner { overrides, ..Default::default() };
        Arc::new(Self { inner: Mutex::new(inner), changed: watch::channel(0).0 })
    }

    /// The runner's own: overrides from locks.toml, read again on each request.
    pub fn shared() -> Arc<Self> {
        static SHARED: std::sync::LazyLock<Arc<Locks>> = std::sync::LazyLock::new(|| Locks::new(HashMap::new()));
        SHARED.clone()
    }

    /// Replaces the machine's overrides (from locks.toml) and admits anyone they now make room for.
    pub fn set_overrides(&self, overrides: HashMap<String, u32>) {
        let mut inner = self.inner.lock().unwrap();
        if inner.overrides == overrides {
            return;
        }
        inner.overrides = overrides;
        let names: Vec<String> = inner.locks.keys().cloned().collect();
        for name in names {
            inner.promote(&name);
        }
        drop(inner);
        self.bump();
    }

    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changed.subscribe()
    }

    fn bump(&self) {
        self.changed.send_modify(|n| *n += 1);
    }

    /// Joins `name`'s queue, and takes a slot at once if one is free and nobody is ahead.
    pub fn enqueue(self: &Arc<Self>, name: &str, slots: u32, mut who: Holder) -> Ticket {
        who.since = crate::sessions::now_ms();
        let mut inner = self.inner.lock().unwrap();
        inner.next += 1;
        let id = inner.next;
        inner.locks.entry(name.to_string()).or_default().queue.push_back(Entry { ticket: id, asked: slots.max(1), who });
        // A bigger --slots can make room for others already waiting too.
        inner.promote(name);
        drop(inner);
        self.bump();
        Ticket { locks: self.clone(), name: name.to_string(), id }
    }

    fn state(&self, name: &str, id: u64) -> State {
        let inner = self.inner.lock().unwrap();
        let Some(lock) = inner.locks.get(name) else { return State::Gone };
        if lock.holders.iter().any(|e| e.ticket == id) {
            return State::Granted;
        }
        match lock.queue.iter().position(|e| e.ticket == id) {
            Some(i) => State::Queued { position: i + 1, holders: lock.holders.iter().map(|e| e.who.clone()).collect() },
            None => State::Gone,
        }
    }

    fn release(&self, name: &str, id: u64) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(lock) = inner.locks.get_mut(name) {
            lock.holders.retain(|e| e.ticket != id);
            lock.queue.retain(|e| e.ticket != id);
        }
        inner.promote(name);
        drop(inner);
        self.bump();
    }

    /// Every lock: its slots, holders and waiters (oldest first), for `maple-runner locks`.
    pub fn snapshot(&self) -> Value {
        let inner = self.inner.lock().unwrap();
        let mut names: Vec<&String> = inner.locks.keys().collect();
        names.sort();
        let locks: Vec<Value> = names
            .into_iter()
            .map(|name| {
                let lock = &inner.locks[name];
                json!({
                    "name": name,
                    "slots": inner.slots(name),
                    "holders": lock.holders.iter().map(|e| &e.who).collect::<Vec<_>>(),
                    "waiters": lock.queue.iter().map(|e| &e.who).collect::<Vec<_>>(),
                })
            })
            .collect();
        json!({ "locks": locks })
    }
}

/// The machine's slot counts from `~/.config/maple/locks.toml` (`name = slots`); none if it's missing
/// or unreadable.
pub fn load_overrides() -> HashMap<String, u32> {
    let Ok(path) = crate::config::dir().map(|d| d.join("locks.toml")) else { return HashMap::new() };
    let Ok(text) = std::fs::read_to_string(&path) else { return HashMap::new() };
    parse_overrides(&text)
}

pub fn parse_overrides(text: &str) -> HashMap<String, u32> {
    let Ok(table) = text.parse::<toml::Table>() else {
        tracing::warn!("locks.toml isn't valid TOML; ignoring it");
        return HashMap::new();
    };
    table.into_iter().filter_map(|(k, v)| Some((k, u32::try_from(v.as_integer()?).ok()?.max(1)))).collect()
}

/// A waiting session's line: "Waiting for ios-simulator · 1 ahead (MF-327 has it)".
pub fn waiting_line(name: &str, position: usize, holders: &[Holder]) -> String {
    let who = match holders {
        [] => String::new(),
        [one] => format!(" ({} has it)", one.label()),
        [one, rest @ ..] => format!(" ({} and {} more have it)", one.label(), rest.len()),
    };
    format!("Waiting for {name} · {position} ahead{who}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn who(task: &str) -> Holder {
        Holder { session: Some(Uuid::new_v4()), task: Some(task.into()), pid: None, since: 0 }
    }

    #[test]
    fn one_slot_serves_waiters_in_order() {
        let locks = Locks::new(HashMap::new());
        let a = locks.enqueue("sim", 1, who("MF-1"));
        let b = locks.enqueue("sim", 1, who("MF-2"));
        let c = locks.enqueue("sim", 1, who("MF-3"));
        assert_eq!(a.state(), State::Granted);
        assert!(matches!(b.state(), State::Queued { position: 1, ref holders } if holders[0].task.as_deref() == Some("MF-1")));
        assert!(matches!(c.state(), State::Queued { position: 2, .. }));
        drop(a);
        assert_eq!(b.state(), State::Granted);
        assert!(matches!(c.state(), State::Queued { position: 1, .. }));
        drop(b);
        assert_eq!(c.state(), State::Granted);
    }

    #[test]
    fn two_slots_admit_two_at_once() {
        let locks = Locks::new(HashMap::new());
        let a = locks.enqueue("db", 2, who("MF-1"));
        let b = locks.enqueue("db", 2, who("MF-2"));
        let c = locks.enqueue("db", 2, who("MF-3"));
        assert_eq!(a.state(), State::Granted);
        assert_eq!(b.state(), State::Granted);
        assert!(matches!(c.state(), State::Queued { position: 1, ref holders } if holders.len() == 2));
        drop(b);
        assert_eq!(c.state(), State::Granted);
    }

    #[test]
    fn a_waiter_that_leaves_frees_its_place() {
        let locks = Locks::new(HashMap::new());
        let a = locks.enqueue("sim", 1, who("MF-1"));
        let b = locks.enqueue("sim", 1, who("MF-2"));
        let c = locks.enqueue("sim", 1, who("MF-3"));
        drop(b);
        assert!(matches!(c.state(), State::Queued { position: 1, .. }));
        drop(a);
        assert_eq!(c.state(), State::Granted);
        drop(c);
        assert_eq!(locks.snapshot()["locks"], json!([]));
    }

    #[test]
    fn the_machine_override_beats_slots() {
        let locks = Locks::new(HashMap::from([("sim".to_string(), 1)]));
        let a = locks.enqueue("sim", 3, who("MF-1"));
        let b = locks.enqueue("sim", 3, who("MF-2"));
        assert_eq!(a.state(), State::Granted);
        assert!(matches!(b.state(), State::Queued { .. }));
        // Raising it on the machine lets the waiter in.
        locks.set_overrides(HashMap::from([("sim".to_string(), 2)]));
        assert_eq!(b.state(), State::Granted);
        assert_eq!(locks.snapshot()["locks"][0]["slots"], 2);
    }

    #[test]
    fn parses_overrides() {
        let o = parse_overrides("ios-simulator = 2\n\"rails-test-db\" = 1\nbad = \"x\"\nzero = 0\n");
        assert_eq!(o.get("ios-simulator"), Some(&2));
        assert_eq!(o.get("rails-test-db"), Some(&1));
        assert_eq!(o.get("bad"), None);
        assert_eq!(o.get("zero"), Some(&1));
    }

    #[test]
    fn waiting_line_names_the_holder() {
        let terminal = Holder { session: None, task: None, pid: Some(1), since: 0 };
        assert_eq!(waiting_line("ios-simulator", 1, &[who("MF-327")]), "Waiting for ios-simulator · 1 ahead (MF-327 has it)");
        assert_eq!(waiting_line("demo", 2, &[terminal]), "Waiting for demo · 2 ahead (your terminal has it)");
    }
}
