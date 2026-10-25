//! `~/.config/maple/agents.toml`: change the built-in agents and add your own.
//!
//! ```toml
//! [agents.claude]
//! args = ["--model", "opus"]          # appended after the runner's own hook arguments
//!
//! [agents.aider]
//! label = "Aider"
//! command = "aider"
//! args = ["--no-auto-commits"]
//! prompt = "flag:--message"           # "positional" | "flag:<name>" | "none" (the default)
//! ```
//!
//! The file is optional and read again for every `hello` and session open, so edits apply
//! without restarting the runner; `watch` also notices edits and sends the new list (`agents`),
//! so the New session picker updates live. A file that doesn't parse is ignored as a whole
//! (with a warning naming the problem) rather than half-applied: the built-ins always work.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::{Duration, SystemTime};

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use tracing::warn;

use crate::agents::{self, Agent, PromptMode};

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    #[serde(default)]
    agents: BTreeMap<String, Entry>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    label: Option<String>,
    command: Option<String>,
    #[serde(default)]
    args: Vec<String>,
    prompt: Option<String>,
}

/// The agents this runner offers: built-ins first, then custom ones by id.
pub fn load() -> Vec<Agent> {
    let Ok(path) = crate::config::dir().map(|d| d.join("agents.toml")) else { return agents::builtins() };
    match read(&path) {
        Ok(list) => list,
        Err(e) => {
            warn!("ignoring {}: {e:#}. Using the built-in agents.", path.display());
            agents::builtins()
        }
    }
}

/// How often `watch` looks at the file.
const WATCH_EVERY: Duration = Duration::from_secs(5);

/// Polls agents.toml's modification time and sends `agents` with the new list when it changes
/// (created, edited or deleted). `hello` carries the list on every connect, so a change made
/// while offline needs nothing extra.
pub async fn watch(sessions: crate::sessions::Sessions) {
    let Ok(path) = crate::config::dir().map(|d| d.join("agents.toml")) else { return };
    let mut last = stamp(&path);
    let mut tick = tokio::time::interval(WATCH_EVERY);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        let now = stamp(&path);
        if now == last {
            continue;
        }
        last = now;
        let agents: Vec<_> = load().iter().map(|a| a.advertised()).collect();
        tracing::info!("{} changed; sending {} agents", path.display(), agents.len());
        sessions.emit(crate::protocol::Outbound::Agents { agents });
    }
}

/// What changes when the file does: its modification time and size, or None when it's absent.
fn stamp(path: &Path) -> Option<(SystemTime, u64)> {
    let meta = std::fs::metadata(path).ok()?;
    Some((meta.modified().ok()?, meta.len()))
}

pub fn find(id: &str) -> Option<Agent> {
    load().into_iter().find(|a| a.id == id)
}

fn read(path: &Path) -> Result<Vec<Agent>> {
    match std::fs::read_to_string(path) {
        Ok(text) => parse(&text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(agents::builtins()),
        Err(e) => Err(e).context("reading it"),
    }
}

/// Merges the file over the built-ins.
pub fn parse(text: &str) -> Result<Vec<Agent>> {
    let file: File = toml::from_str(text)?;
    let mut list = agents::builtins();
    for (id, entry) in file.agents {
        if !valid_id(&id) {
            bail!("agent id `{id}` isn't valid: use lowercase letters, digits, `-` and `_` (up to 32)");
        }
        let prompt = entry.prompt.as_deref().map(|p| prompt_mode(p).with_context(|| format!("[agents.{id}] prompt"))).transpose()?;
        if let Some(label) = &entry.label
            && (label.trim().is_empty() || label.len() > 40)
        {
            bail!("[agents.{id}] label must be 1–40 characters");
        }
        if let Some(command) = &entry.command
            && (command.trim().is_empty() || command.contains('\0'))
        {
            bail!("[agents.{id}] command can't be empty");
        }
        match list.iter_mut().find(|a| a.id == id) {
            Some(builtin) => {
                if let Some(label) = entry.label {
                    builtin.label = label;
                }
                if let Some(command) = entry.command {
                    builtin.command = command;
                }
                if let Some(prompt) = prompt {
                    builtin.prompt = prompt;
                }
                builtin.args.extend(entry.args);
            }
            None => {
                let Some(command) = entry.command else { bail!("[agents.{id}] needs a command") };
                list.push(Agent {
                    label: entry.label.unwrap_or_else(|| id.clone()),
                    id,
                    command,
                    args: entry.args,
                    prompt: prompt.unwrap_or(PromptMode::None),
                    // Status hooks exist only for Claude Code and Codex.
                    hooks: false,
                });
            }
        }
    }
    Ok(list)
}

fn prompt_mode(s: &str) -> Result<PromptMode> {
    Ok(match s {
        "positional" => PromptMode::Positional,
        "none" => PromptMode::None,
        _ => match s.strip_prefix("flag:") {
            Some(flag) if flag.starts_with('-') && !flag.contains(char::is_whitespace) => PromptMode::Flag(flag.into()),
            _ => bail!("`{s}` should be \"positional\", \"none\" or \"flag:--name\""),
        },
    })
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 32 && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_file_is_the_builtins() {
        assert_eq!(parse("").unwrap(), agents::builtins());
    }

    #[test]
    fn changes_a_builtin_and_adds_custom_agents() {
        let list = parse(
            r#"
            [agents.claude]
            args = ["--model", "opus"]

            [agents.aider]
            label = "Aider"
            command = "aider"
            prompt = "flag:--message"

            [agents.echo]
            command = "sh"
            args = ["-c", "echo hi; exec cat"]
            "#,
        )
        .unwrap();
        let ids: Vec<_> = list.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, ["claude", "codex", "shell", "aider", "echo"]);
        let claude = &list[0];
        assert_eq!((claude.command.as_str(), claude.args.clone(), claude.hooks), ("claude", vec!["--model".into(), "opus".into()], true));
        assert_eq!(claude.prompt, PromptMode::Positional);
        let aider = &list[3];
        assert_eq!((aider.label.as_str(), aider.prompt.clone(), aider.hooks), ("Aider", PromptMode::Flag("--message".into()), false));
        let echo = &list[4];
        assert_eq!((echo.label.as_str(), echo.prompt.clone()), ("echo", PromptMode::None));
        assert_eq!(echo.advertised(), agents::Advertised { id: "echo".into(), label: "echo".into(), takes_prompt: false });
    }

    #[test]
    fn bad_files_say_what_is_wrong() {
        let err = |text: &str| format!("{:#}", parse(text).unwrap_err());
        assert!(err("[agents.x]\nlabel = \"X\"").contains("needs a command"));
        assert!(err("[agents.x]\ncommand = \"x\"\nprompt = \"flag:message\"").contains("prompt"));
        assert!(err("[agents.Bad]\ncommand = \"x\"").contains("isn't valid"));
        assert!(err("[agents.x]\ncommand = \"x\"\nflags = []").contains("unknown field"));
        assert!(parse("[agents.x\n").is_err());
    }
}
