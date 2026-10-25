//! Live thumbnails for the dashboard and the Wall: the bottom few lines of a session's screen.
//!
//! The hub says which sessions some browser is looking at (`thumbs.watch`, the union over its
//! browsers). For those, and only those, the runner reads the visible screen with
//! `capture-pane -p -e` (read-only; nothing is resized) about once a second while the session is
//! printing or its agent is working or waiting, and every few seconds otherwise, and sends a
//! `thumb` only when the text changed. Nobody watching means no captures at all. A peek asks for
//! `history`: then the capture starts that many rows up in the scrollback (`-S -<n>`), and the
//! thumb says how many of its first lines came from there (`scrollback`).

use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;
use uuid::Uuid;

use crate::protocol::{Outbound, json_len};
use crate::sessions::Sessions;

/// Lines a thumbnail shows when the hub doesn't say.
pub const DEFAULT_LINES: u16 = 14;
/// The most lines anyone may ask for of the visible screen (a tall Wall tile).
pub const MAX_LINES: u16 = 60;
/// The most lines of a watch that takes in history (a peek).
pub const MAX_HISTORY_LINES: u16 = 100;
/// A `thumb` message stays under this many bytes of JSON.
pub const MAX_BYTES: usize = 16 * 1024;
/// One line's escapes and text, at most (a line is a screen row, so this is generous).
const MAX_LINE: usize = 2 * 1024;
/// Most sessions watched at once.
const MAX_WATCHED: usize = 64;

const FAST: Duration = Duration::from_secs(1);
const SLOW: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Deserialize)]
pub struct Watch {
    pub id: Uuid,
    #[serde(default = "default_lines")]
    pub lines: u16,
    /// Take in the scrollback above the screen too (`capture-pane -S`), for a peek.
    #[serde(default)]
    pub history: bool,
}

fn default_lines() -> u16 {
    DEFAULT_LINES
}

struct Watched {
    lines: u16,
    history: bool,
    /// Hash of the last thumb sent; `None` sends the next capture whatever it is.
    sent: Option<u64>,
    captured: Option<Instant>,
    /// The session's output counter at the last capture.
    output_seen: u64,
}

static WATCHED: Mutex<Option<HashMap<Uuid, Watched>>> = Mutex::new(None);

/// Replaces the watched set. `fresh` are sessions a browser has just started watching: they get
/// a thumb straight away even if it's unchanged, since that browser has none yet.
pub fn watch(list: Vec<Watch>, fresh: &[Uuid]) {
    let mut guard = WATCHED.lock().unwrap();
    let old = guard.take().unwrap_or_default();
    let fresh: HashSet<&Uuid> = fresh.iter().collect();
    let mut next = HashMap::new();
    for w in list.into_iter().take(MAX_WATCHED) {
        let lines = w.lines.clamp(1, if w.history { MAX_HISTORY_LINES } else { MAX_LINES });
        let history = w.history;
        let entry = match old.get(&w.id) {
            Some(o) if o.lines == lines && o.history == history && !fresh.contains(&w.id) => {
                Watched { lines, history, sent: o.sent, captured: o.captured, output_seen: o.output_seen }
            }
            _ => Watched { lines, history, sent: None, captured: None, output_seen: 0 },
        };
        next.insert(w.id, entry);
    }
    *guard = Some(next);
}

/// Forget everything (the connection to the hub dropped; it says again after the hello).
pub fn clear() {
    *WATCHED.lock().unwrap() = None;
}

/// Captures watched sessions and sends thumbs that changed.
pub async fn report(sessions: Sessions) {
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        let now = Instant::now();
        // Which watched sessions are due: a fresh watch at once; busy ones every second; the rest every few.
        let due: Vec<(Uuid, u16, bool, u64)> = {
            let guard = WATCHED.lock().unwrap();
            let Some(map) = guard.as_ref() else { continue };
            map.iter()
                .filter_map(|(id, w)| {
                    let (output, busy) = sessions.thumb_state(*id)?;
                    let every = if busy || output != w.output_seen { FAST } else { SLOW };
                    let ready = w.captured.is_none_or(|at| now.duration_since(at) >= every);
                    ready.then_some((*id, w.lines, w.history, output))
                })
                .collect()
        };
        for (id, lines, history, output) in due {
            let Some((screen, cols, above)) = sessions.screen(id, history.then_some(lines)).await else { continue };
            let (lines, start) = crop_rows(&screen, lines as usize);
            // The first lines that came from the history above the screen.
            let scrollback = above.saturating_sub(start).min(lines.len());
            let hash = {
                let mut h = DefaultHasher::new();
                (&lines, cols, scrollback).hash(&mut h);
                h.finish()
            };
            let send = {
                let mut guard = WATCHED.lock().unwrap();
                let Some(w) = guard.as_mut().and_then(|m| m.get_mut(&id)) else { continue };
                w.captured = Some(Instant::now());
                w.output_seen = output;
                let changed = w.sent != Some(hash);
                w.sent = Some(hash);
                changed
            };
            if send {
                sessions.emit(Outbound::Thumb { id, lines, cols, at: crate::sessions::now_ms(), scrollback });
            }
        }
    }
}

/// Whether a captured line shows nothing: only spaces and escape sequences.
fn is_blank(line: &str) -> bool {
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match c {
            '\x1b' => {
                // CSI: ESC [ params final
                if chars.clone().next() == Some('[') {
                    chars.next();
                    for c in chars.by_ref() {
                        if ('\x40'..='\x7e').contains(&c) {
                            break;
                        }
                    }
                }
            }
            c if c.is_whitespace() => {}
            _ => return false,
        }
    }
    true
}

/// The SGR sequences (`ESC[…m`) in `text`, in order.
fn sgr_sequences(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let bytes = text.as_bytes();
    let mut i = 0;
    while i + 1 < bytes.len() {
        if bytes[i] == 0x1b && bytes[i + 1] == b'[' {
            let start = i;
            let mut j = i + 2;
            while j < bytes.len() && !(0x40..=0x7e).contains(&bytes[j]) {
                j += 1;
            }
            if j < bytes.len() && bytes[j] == b'm' {
                out.push(&text[start..=j]);
            }
            i = j + 1;
        } else {
            i += 1;
        }
    }
    out
}

/// The last `n` lines of a screen capture, without the blank rows below the last text, each cut
/// to `MAX_LINE` bytes, the whole within `MAX_BYTES` of JSON. tmux carries colours across lines,
/// so the colours of the rows left out above are replayed at the start of the first row kept.
#[cfg(test)]
pub fn crop(screen: &str, n: usize) -> Vec<String> {
    crop_rows(screen, n).0
}

/// `crop`, and the row of `screen` the first line kept came from.
pub fn crop_rows(screen: &str, n: usize) -> (Vec<String>, usize) {
    let rows: Vec<&str> = screen.lines().collect();
    let end = rows.iter().rposition(|l| !is_blank(l)).map_or(0, |i| i + 1);
    let mut start = end.saturating_sub(n);
    let mut lines: Vec<String> = rows[start..end].iter().map(|l| cut(l, MAX_LINE)).collect();
    // Keep the newest lines that fit.
    let budget = MAX_BYTES - 256;
    let mut used: usize = lines.iter().map(|l| json_len(l) + 3).sum();
    while used > budget && !lines.is_empty() {
        used -= json_len(&lines[0]) + 3;
        lines.remove(0);
        start += 1;
    }
    if start > 0 && !lines.is_empty() {
        let before = rows[..start].join("\n");
        let seqs = sgr_sequences(&before);
        // Everything up to the last reset is moot.
        let from = seqs.iter().rposition(|s| *s == "\x1b[0m" || *s == "\x1b[m").unwrap_or(0);
        let prefix: String = seqs[from..].concat();
        if !prefix.is_empty() && prefix.len() <= 512 {
            lines[0].insert_str(0, &prefix);
        }
    }
    (lines, start)
}

/// `s` cut to at most `max` bytes, at a character boundary.
fn cut(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crops_to_the_last_lines_with_text() {
        let screen = "one\ntwo\n\x1b[31mthree\x1b[0m\n   \n\x1b[0m  \n\n";
        assert_eq!(crop(screen, 2), vec!["two", "\x1b[31mthree\x1b[0m"]);
        assert_eq!(crop(screen, 10), vec!["one", "two", "\x1b[31mthree\x1b[0m"]);
        assert!(crop("\n\n  \n", 5).is_empty());
    }

    #[test]
    fn says_where_the_lines_start() {
        // Two rows of history, then the screen (with blank rows at the bottom).
        let capture = "h1\nh2\nv1\nv2\n\n";
        assert_eq!(crop_rows(capture, 3), (vec!["h2".to_string(), "v1".into(), "v2".into()], 1));
        assert_eq!(crop_rows(capture, 10).1, 0);
    }

    #[test]
    fn carries_colours_into_the_first_line() {
        let screen = "\x1b[0mplain\n\x1b[1m\x1b[32mgreen starts\nstill green\nlast";
        assert_eq!(crop(screen, 2), vec!["\x1b[0m\x1b[1m\x1b[32mstill green", "last"]);
    }

    #[test]
    fn stays_small() {
        let row = format!("\x1b[38;2;1;2;3m{}", "x".repeat(5000));
        let screen = vec![row; 60].join("\n");
        let lines = crop(&screen, 60);
        assert!(lines.iter().all(|l| l.len() <= MAX_LINE));
        let json = serde_json::to_string(&lines).unwrap();
        assert!(json.len() <= MAX_BYTES, "{}", json.len());
        assert!(!lines.is_empty());
    }

    #[test]
    fn watches_and_forgets() {
        let a = Uuid::new_v4();
        watch(vec![Watch { id: a, lines: 500, history: false }], &[]);
        assert_eq!(WATCHED.lock().unwrap().as_ref().unwrap()[&a].lines, MAX_LINES);
        watch(vec![Watch { id: a, lines: 500, history: true }], &[]);
        assert_eq!(WATCHED.lock().unwrap().as_ref().unwrap()[&a].lines, MAX_HISTORY_LINES);
        watch(vec![], &[]);
        assert!(WATCHED.lock().unwrap().as_ref().unwrap().is_empty());
        clear();
        assert!(WATCHED.lock().unwrap().is_none());
    }
}
