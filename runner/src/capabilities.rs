//! What this machine can do, as tags the server shows on the machine (and, later, routes by):
//! `macos`/`linux`, `arm64`/`x86_64`, `xcode`, `ios-simulator`, `playwright`, `docker`, `node`.
//!
//! Detection is cheap: a handful of quick probes run in parallel, each cut off after 3s. It runs
//! once before connecting (for the hello), then every 10 minutes and whenever health rechecks,
//! and the hub only hears about it when the set changed.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use tokio::process::Command;
use tokio::sync::Notify;

const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
const DETECT_EVERY: Duration = Duration::from_secs(10 * 60);

static CURRENT: Mutex<Vec<String>> = Mutex::new(Vec::new());
static WAKE: Notify = Notify::const_new();

/// The tags last detected, for the hello.
pub fn current() -> Vec<String> {
    CURRENT.lock().unwrap().clone()
}

/// Detect again soon (health's recheck).
pub fn poke() {
    WAKE.notify_one();
}

/// Detects once, so the first hello carries the tags.
pub async fn init() {
    let tags = detect().await;
    tracing::info!("capabilities: {}", tags.join(", "));
    *CURRENT.lock().unwrap() = tags;
}

/// Detects again on a timer or a poke, and sends `capabilities` when the set changed.
pub async fn report(sessions: crate::sessions::Sessions) {
    loop {
        tokio::select! {
            _ = tokio::time::sleep(DETECT_EVERY) => {}
            _ = WAKE.notified() => {}
        }
        let tags = detect().await;
        let changed = {
            let mut current = CURRENT.lock().unwrap();
            let changed = *current != tags;
            if changed {
                *current = tags.clone();
            }
            changed
        };
        if changed {
            tracing::info!("capabilities changed: {}", tags.join(", "));
            sessions.emit(crate::protocol::Outbound::Wire(crate::wire::RunnerMessage::Capabilities { capabilities: tags }));
        }
    }
}

/// Runs the probes in parallel and returns sorted, unique tags.
pub async fn detect() -> Vec<String> {
    let (xcode, simulator, docker, node) = tokio::join!(
        succeeds("xcodebuild", &["-version"]),
        output("xcrun", &["simctl", "list", "runtimes"]),
        succeeds("docker", &["info"]),
        succeeds("node", &["--version"]),
    );
    let playwright = tokio::task::spawn_blocking(|| playwright_dirs().iter().any(|d| has_chromium(d))).await.unwrap_or(false);
    tags(Found {
        os: std::env::consts::OS,
        arch: std::env::consts::ARCH,
        xcode,
        ios_simulator: simulator.as_deref().is_some_and(has_ios_runtime),
        playwright,
        docker,
        node,
    })
}

/// What the probes found.
#[derive(Default)]
pub struct Found<'a> {
    pub os: &'a str,
    pub arch: &'a str,
    pub xcode: bool,
    pub ios_simulator: bool,
    pub playwright: bool,
    pub docker: bool,
    pub node: bool,
}

/// The tags for what was found, sorted and unique.
pub fn tags(found: Found) -> Vec<String> {
    let mut tags: Vec<String> = Vec::new();
    match found.os {
        "macos" => tags.push("macos".into()),
        "linux" => tags.push("linux".into()),
        _ => {}
    }
    match found.arch {
        "aarch64" | "arm64" => tags.push("arm64".into()),
        "x86_64" => tags.push("x86_64".into()),
        _ => {}
    }
    for (on, tag) in [
        (found.xcode, "xcode"),
        (found.ios_simulator, "ios-simulator"),
        (found.playwright, "playwright"),
        (found.docker, "docker"),
        (found.node, "node"),
    ] {
        if on {
            tags.push(tag.into());
        }
    }
    tags.sort();
    tags.dedup();
    tags
}

/// Whether `xcrun simctl list runtimes` lists an iOS runtime that's available.
pub fn has_ios_runtime(list: &str) -> bool {
    list.lines().any(|line| {
        let line = line.trim();
        line.starts_with("iOS ") && !line.contains("unavailable")
    })
}

/// Where Playwright keeps its browsers on this platform (or PLAYWRIGHT_BROWSERS_PATH).
fn playwright_dirs() -> Vec<PathBuf> {
    if let Some(p) = std::env::var_os("PLAYWRIGHT_BROWSERS_PATH").filter(|p| !p.is_empty() && p != "0") {
        return vec![PathBuf::from(p)];
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else { return vec![] };
    if cfg!(target_os = "macos") {
        vec![home.join("Library/Caches/ms-playwright")]
    } else {
        let cache = std::env::var_os("XDG_CACHE_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".cache"));
        vec![cache.join("ms-playwright")]
    }
}

/// Whether `dir` holds a Playwright Chromium (a `chromium-*` or `chromium_headless_shell-*` dir).
pub fn has_chromium(dir: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else { return false };
    entries.flatten().any(|e| {
        e.file_name().to_str().is_some_and(|n| n.starts_with("chromium-") || n.starts_with("chromium_headless_shell-"))
            && e.path().is_dir()
    })
}

async fn succeeds(program: &str, args: &[&str]) -> bool {
    run(program, args).await.is_some_and(|o| o.status.success())
}

async fn output(program: &str, args: &[&str]) -> Option<String> {
    run(program, args).await.filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
}

async fn run(program: &str, args: &[&str]) -> Option<std::process::Output> {
    let child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    tokio::time::timeout(PROBE_TIMEOUT, child).await.ok()?.ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_for_a_mac() {
        let t = tags(Found { os: "macos", arch: "aarch64", xcode: true, ios_simulator: true, node: true, ..Default::default() });
        assert_eq!(t, ["arm64", "ios-simulator", "macos", "node", "xcode"]);
    }

    #[test]
    fn tags_for_a_linux_box() {
        let t = tags(Found { os: "linux", arch: "x86_64", docker: true, node: true, playwright: true, ..Default::default() });
        assert_eq!(t, ["docker", "linux", "node", "playwright", "x86_64"]);
    }

    #[test]
    fn unknown_os_and_arch_are_left_out() {
        let t = tags(Found { os: "freebsd", arch: "riscv64", ..Default::default() });
        assert!(t.is_empty());
    }

    #[test]
    fn ios_runtime_parsing() {
        let list = "== Runtimes ==\niOS 18.2 (18.2 - 22C150) - com.apple.CoreSimulator.SimRuntime.iOS-18-2\nwatchOS 11.2 (11.2 - 22S99) - com.apple.CoreSimulator.SimRuntime.watchOS-11-2\n";
        assert!(has_ios_runtime(list));
        assert!(!has_ios_runtime("== Runtimes ==\nwatchOS 11.2 (11.2) - x\n"));
        assert!(!has_ios_runtime("== Runtimes ==\niOS 17.0 (17.0) - x (unavailable, runtime path not found)\n"));
        assert!(!has_ios_runtime("== Runtimes ==\n"));
    }

    #[test]
    fn chromium_dir_detection() {
        let dir = std::env::temp_dir().join(format!("maple-pw-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("ffmpeg-1011")).unwrap();
        assert!(!has_chromium(&dir));
        std::fs::create_dir_all(dir.join("chromium-1148")).unwrap();
        assert!(has_chromium(&dir));
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(!has_chromium(&dir));
    }
}
