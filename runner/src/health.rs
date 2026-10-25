//! Machine vitals and agent logins, reported every 10 seconds.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use serde::Serialize;
use sysinfo::{Disks, System};
use tokio::process::Command;

#[derive(Debug, Clone, Serialize)]
pub struct Battery {
    pub percent: u8,
    pub charging: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AgentState {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub logged_in: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Health {
    pub cpu: f32,
    /// Logical CPUs. The server sizes the machine's task slots from these and memory; older runners don't send it.
    pub cores: u32,
    pub load1: f64,
    pub mem_used: u64,
    pub mem_total: u64,
    pub disk_used: u64,
    pub disk_total: u64,
    pub uptime: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub battery: Option<Battery>,
    pub agents: std::collections::BTreeMap<String, AgentState>,
}

impl Health {
    pub fn to_wire(&self) -> crate::wire::Health {
        crate::wire::Health {
            cpu: self.cpu as f64,
            cores: self.cores,
            load1: self.load1,
            mem_used: self.mem_used,
            mem_total: self.mem_total,
            disk_used: self.disk_used,
            disk_total: self.disk_total,
            uptime: self.uptime,
            battery: self.battery.as_ref().map(|b| crate::wire::Battery { percent: b.percent as f64, charging: b.charging }),
            agents: self
                .agents
                .iter()
                .map(|(name, a)| crate::wire::AgentInstall { name: name.clone(), version: a.version.clone(), logged_in: a.logged_in.unwrap_or(false) })
                .collect(),
        }
    }
}

/// Sends vitals every 10 seconds. While disconnected they're dropped with other stale output.
pub async fn report(sessions: crate::sessions::Sessions) {
    let mut sampler = Sampler::new();
    let mut tick = tokio::time::interval(Duration::from_secs(10));
    loop {
        tick.tick().await;
        let health = sampler.sample().await;
        sessions.emit(crate::protocol::Outbound::Wire(crate::wire::RunnerMessage::Health { health: health.to_wire() }));
    }
}

/// Keeps a `System` between samples: CPU usage is measured as the change since the last refresh.
pub struct Sampler {
    system: System,
    disks: Disks,
    agents: std::collections::BTreeMap<String, AgentState>,
    agents_checked: Option<std::time::Instant>,
}

/// Agent versions and logins change rarely and cost a process spawn each, so check them occasionally.
const AGENT_CHECK_EVERY: Duration = Duration::from_secs(10 * 60);

impl Sampler {
    pub fn new() -> Self {
        let mut system = System::new();
        // The first refresh also finds the CPUs, so `cores` is known from the first sample.
        system.refresh_cpu_usage();
        Self { system, disks: Disks::new_with_refreshed_list(), agents: Default::default(), agents_checked: None }
    }

    pub async fn sample(&mut self) -> Health {
        self.system.refresh_cpu_usage();
        self.system.refresh_memory();
        self.disks.refresh(true);

        let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
        let (disk_used, disk_total) = disk_for(&self.disks, Path::new(&home));

        if self.agents_checked.is_none_or(|t| t.elapsed() >= AGENT_CHECK_EVERY) {
            self.agents = agents().await;
            self.agents_checked = Some(std::time::Instant::now());
        }

        Health {
            cpu: self.system.global_cpu_usage(),
            cores: self.cores(),
            load1: System::load_average().one,
            mem_used: self.system.used_memory(),
            mem_total: self.system.total_memory(),
            disk_used,
            disk_total,
            uptime: System::uptime(),
            battery: battery().await,
            agents: self.agents.clone(),
        }
    }

    /// Logical CPUs, as the OS counts them (hyperthreads and efficiency cores included).
    fn cores(&self) -> u32 {
        let n = self.system.cpus().len();
        let n = if n == 0 { std::thread::available_parallelism().map_or(1, |n| n.get()) } else { n };
        u32::try_from(n).unwrap_or(u32::MAX)
    }
}

/// The disk holding `path`: the mounted volume with the longest mount point that's a prefix of it.
/// On macOS the data volume (`/System/Volumes/Data`) holds home directories.
fn disk_for(disks: &Disks, path: &Path) -> (u64, u64) {
    let best = disks
        .list()
        .iter()
        .filter(|d| path.starts_with(d.mount_point()) || (cfg!(target_os = "macos") && d.mount_point() == Path::new("/System/Volumes/Data")))
        .max_by_key(|d| {
            let data = d.mount_point() == Path::new("/System/Volumes/Data");
            (data, d.mount_point().as_os_str().len())
        });
    match best {
        Some(d) => (d.total_space().saturating_sub(d.available_space()), d.total_space()),
        None => (0, 0),
    }
}

/// Battery level, from `pmset` on macOS and /sys on Linux. None on machines without one.
async fn battery() -> Option<Battery> {
    if cfg!(target_os = "macos") {
        let out = run("pmset", &["-g", "batt"]).await?;
        parse_pmset(&out)
    } else {
        let dir = std::fs::read_dir("/sys/class/power_supply").ok()?.flatten().find(|e| e.file_name().to_string_lossy().starts_with("BAT"))?;
        let percent = std::fs::read_to_string(dir.path().join("capacity")).ok()?.trim().parse().ok()?;
        let status = std::fs::read_to_string(dir.path().join("status")).unwrap_or_default();
        Some(Battery { percent, charging: matches!(status.trim(), "Charging" | "Full") })
    }
}

/// `pmset -g batt` → " -InternalBattery-0 (id=…)<TAB>83%; discharging; 4:21 remaining present: true"
fn parse_pmset(out: &str) -> Option<Battery> {
    let line = out.lines().find(|l| l.contains("InternalBattery"))?;
    let percent = line.split('\t').nth(1)?.split('%').next()?.trim().parse().ok()?;
    let charging = line.contains("; charging") || line.contains("; charged") || line.contains("finishing charge") || line.contains("AC attached");
    Some(Battery { percent, charging })
}

/// Which agents are installed, their versions and (where cheap to tell) whether they're logged in.
async fn agents() -> std::collections::BTreeMap<String, AgentState> {
    let mut map = std::collections::BTreeMap::new();
    if let Some(version) = login_shell("claude --version").await.and_then(|v| first_version(&v)) {
        let logged_in = login_shell("claude auth status").await.map(|s| !s.to_lowercase().contains("not logged in"));
        map.insert("claude".into(), AgentState { version: Some(version), logged_in });
    }
    if let Some(version) = login_shell("codex --version").await.and_then(|v| first_version(&v)) {
        let logged_in = login_shell("codex login status").await.map(|s| s.to_lowercase().contains("logged in") && !s.to_lowercase().contains("not logged in"));
        map.insert("codex".into(), AgentState { version: Some(version), logged_in });
    }
    map
}

/// "codex-cli 0.147.0" / "2.1.296 (Claude Code)" → the first dotted number.
fn first_version(text: &str) -> Option<String> {
    text.split(|c: char| c.is_whitespace() || c == '(' || c == ')')
        .find(|w| w.chars().next().is_some_and(|c| c.is_ascii_digit()) && w.contains('.'))
        .map(str::to_string)
}

/// Runs a command through the login shell (for the same PATH as a terminal), with a timeout.
async fn login_shell(command: &str) -> Option<String> {
    run(&crate::agents::login_shell(), &["-l", "-c", command]).await
}

async fn run(program: &str, args: &[&str]) -> Option<String> {
    let mut cmd = Command::new(program);
    cmd.args(args).stdin(Stdio::null()).stderr(Stdio::piped()).kill_on_drop(true);
    for var in crate::agents::INHERITED_SESSION_MARKERS {
        cmd.env_remove(var);
    }
    let out = tokio::time::timeout(Duration::from_secs(10), cmd.output()).await.ok()?.ok()?;
    // Some status commands print to stderr or exit non-zero when logged out; keep both streams.
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    (out.status.success() || !text.trim().is_empty()).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_pmset() {
        let out = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234)\t83%; discharging; 4:21 remaining present: true\n";
        let b = parse_pmset(out).unwrap();
        assert_eq!((b.percent, b.charging), (83, false));
        let out = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1234)\t100%; charged; 0:00 remaining present: true\n";
        assert!(parse_pmset(out).unwrap().charging);
        assert!(parse_pmset("Now drawing from 'AC Power'\n").is_none());
    }

    #[test]
    fn reports_cores() {
        let sampler = Sampler::new();
        let cores = sampler.cores();
        assert!(cores >= 1);
        assert_eq!(cores as usize, sampler.system.cpus().len(), "found by the first refresh");
        let health = Health {
            cpu: 0.0,
            cores,
            load1: 0.0,
            mem_used: 0,
            mem_total: 0,
            disk_used: 0,
            disk_total: 0,
            uptime: 0,
            battery: None,
            agents: Default::default(),
        };
        let json = serde_json::to_value(&health).unwrap();
        assert_eq!(json["cores"], cores);
    }

    #[test]
    fn finds_versions() {
        assert_eq!(first_version("2.1.296 (Claude Code)").as_deref(), Some("2.1.296"));
        assert_eq!(first_version("codex-cli 0.147.0\n").as_deref(), Some("0.147.0"));
        assert_eq!(first_version("command not found"), None);
    }
}
