//! Colors for what the runner prints: off when NO_COLOR is set or stdout isn't a terminal, so
//! service logs and pipes stay plain.

use std::fmt::Display;
use std::io::IsTerminal;
use std::sync::OnceLock;

use clap::builder::styling::{AnsiColor, Effects, Style, Styles};

/// `--help`: bold green headers and usage, cyan commands and flags, dim placeholders.
/// clap applies its own NO_COLOR and terminal checks.
pub const HELP: Styles = Styles::styled()
    .header(AnsiColor::Green.on_default().effects(Effects::BOLD))
    .usage(AnsiColor::Green.on_default().effects(Effects::BOLD))
    .literal(AnsiColor::Cyan.on_default().effects(Effects::BOLD))
    .placeholder(Style::new().effects(Effects::DIMMED))
    .valid(AnsiColor::Cyan.on_default())
    .invalid(AnsiColor::Yellow.on_default().effects(Effects::BOLD))
    .error(AnsiColor::Red.on_default().effects(Effects::BOLD));

/// Whether this process colors its output. Never under `cargo test`, so tests can compare
/// plain strings even when run from a terminal.
pub fn enabled() -> bool {
    if cfg!(test) {
        return false;
    }
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| colors(std::env::var_os("NO_COLOR").as_deref(), std::io::stdout().is_terminal()))
}

/// https://no-color.org: any non-empty NO_COLOR turns color off.
fn colors(no_color: Option<&std::ffi::OsStr>, terminal: bool) -> bool {
    terminal && no_color.is_none_or(|v| v.is_empty())
}

fn paint(style: Style, text: impl Display, on: bool) -> String {
    if on { format!("{style}{text}{style:#}") } else { text.to_string() }
}

/// Success.
pub fn ok(text: impl Display) -> String {
    paint(AnsiColor::Green.on_default().effects(Effects::BOLD), text, enabled())
}

pub fn warn(text: impl Display) -> String {
    paint(AnsiColor::Yellow.on_default().effects(Effects::BOLD), text, enabled())
}

pub fn err(text: impl Display) -> String {
    paint(AnsiColor::Red.on_default().effects(Effects::BOLD), text, enabled())
}

/// Labels and asides.
pub fn dim(text: impl Display) -> String {
    paint(Style::new().effects(Effects::DIMMED), text, enabled())
}

/// Values: paths, URLs, commands.
pub fn accent(text: impl Display) -> String {
    paint(AnsiColor::Cyan.on_default(), text, enabled())
}

pub fn bold(text: impl Display) -> String {
    paint(Style::new().effects(Effects::BOLD), text, enabled())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn color_needs_a_terminal_and_no_no_color() {
        assert!(colors(None, true));
        assert!(colors(Some("".as_ref()), true));
        assert!(!colors(Some("1".as_ref()), true));
        assert!(!colors(None, false));
        assert!(!colors(Some("1".as_ref()), false));
    }

    #[test]
    fn plain_when_off() {
        let green = AnsiColor::Green.on_default();
        assert_eq!(paint(green, "done", false), "done");
        assert_eq!(paint(green, "done", true), "\u{1b}[32mdone\u{1b}[0m");
    }
}
