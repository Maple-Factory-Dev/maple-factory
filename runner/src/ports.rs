//! Dev servers listening on this machine, and how to reach them from the tailnet.
//!
//! Every few seconds the runner lists this user's listening TCP sockets (`lsof` on macOS, `ss` on
//! Linux), works out which session's folder each process runs in, and asks Tailscale for this
//! machine's name and which ports `tailscale serve` shares. A server bound to all interfaces is
//! already reachable at `http://<machine>.<tailnet>.ts.net:<port>`; one bound to localhost isn't,
//! and can be shared through `tailscale serve` on the same port number.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::Value;
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::Notify;
use uuid::Uuid;

use crate::protocol::Outbound;
use crate::sessions::Sessions;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tailnet {
    /// This machine's MagicDNS name, without the trailing dot.
    pub dns_name: String,
    pub ips: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Port {
    pub port: u16,
    /// The address it's bound to: `*`, `0.0.0.0` or `::` for every interface, `127.0.0.1` or
    /// `::1` for this machine only.
    pub bind: String,
    pub pid: u32,
    pub process: String,
    pub cwd: Option<String>,
    /// The session whose folder the process runs in, if any.
    pub session_id: Option<Uuid>,
    /// Shared on the tailnet through `tailscale serve`.
    pub shared: bool,
    /// How to reach it from another device on the tailnet. None when it's localhost-only and
    /// not shared, or this machine isn't on a tailnet.
    pub url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Report {
    pub tailnet: Option<Tailnet>,
    pub ports: Vec<Port>,
}

const SCAN_EVERY: Duration = Duration::from_secs(5);
/// Tailscale's state changes rarely; a share or unshare from the web app refreshes it at once.
const TAILSCALE_EVERY: Duration = Duration::from_secs(15);
/// Everything is re-sent this often, so a hub that missed a report catches up.
const FULL_EVERY: Duration = Duration::from_secs(60);

/// Ports in one report (a few hundred bytes each, so the report stays far below the message limit).
const MAX_PORTS: usize = 500;

/// The start of the IANA ephemeral range (macOS's default; Linux's starts lower, at 32768).
const EPHEMERAL: u16 = 49152;

/// Wakes the scan loop early: after a share/unshare, or a reconnect.
static WAKE: Notify = Notify::const_new();
/// Set on reconnect: the next report goes out even if nothing changed.
static RESEND: AtomicBool = AtomicBool::new(false);
/// The last scan, so share requests only touch ports that are actually listening.
static LAST: Mutex<Option<Report>> = Mutex::new(None);

/// Call after (re)connecting: events produced while offline were dropped, so send the ports again.
pub fn resend() {
    RESEND.store(true, Ordering::SeqCst);
    WAKE.notify_one();
}

/// Scans every few seconds and sends a `ports` report when anything changed (and every minute).
pub async fn report(sessions: Sessions) {
    let mut tick = tokio::time::interval(SCAN_EVERY);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut tailscale: Option<Tailscale> = None;
    let mut tailscale_at: Option<Instant> = None;
    let mut last: Option<Report> = None;
    let mut sent_at = Instant::now();
    loop {
        let woken = tokio::select! {
            _ = tick.tick() => false,
            _ = WAKE.notified() => true,
        };
        if woken || tailscale_at.is_none_or(|t| t.elapsed() >= TAILSCALE_EVERY) {
            tailscale = Tailscale::read().await;
            tailscale_at = Some(Instant::now());
        }
        let report = scan(&sessions, tailscale.as_ref()).await;
        let resend = RESEND.swap(false, Ordering::SeqCst);
        if resend || sent_at.elapsed() >= FULL_EVERY || last.as_ref() != Some(&report) {
            sessions.emit(Outbound::Ports(report.clone()));
            sent_at = Instant::now();
        }
        *LAST.lock().unwrap() = Some(report.clone());
        last = Some(report);
    }
}

async fn scan(sessions: &Sessions, tailscale: Option<&Tailscale>) -> Report {
    let listeners = dedupe(listeners().await);
    let mut pids: Vec<u32> = listeners.iter().map(|l| l.pid).collect();
    pids.sort_unstable();
    pids.dedup();
    let cwds = cwds(&pids).await;
    let parents = parents().await;
    let panes: Vec<SessionProc> = sessions.list().into_iter().map(|s| SessionProc { id: s.id, pid: s.pid, started_at: s.started_at }).collect();
    build(listeners, &cwds, &parents, &panes, tailscale)
}

/// The pure part of a scan: listeners + cwds + sessions + Tailscale → the report.
fn build(
    listeners: Vec<Listener>,
    cwds: &HashMap<u32, String>,
    parents: &HashMap<u32, u32>,
    sessions: &[SessionProc],
    tailscale: Option<&Tailscale>,
) -> Report {
    let tailnet = tailscale.filter(|t| t.running).map(|t| Tailnet { dns_name: t.dns_name.clone(), ips: t.ips.clone() });
    let served = tailscale.filter(|t| t.running).map(|t| t.served.as_slice()).unwrap_or_default();
    let ports = listeners
        .into_iter()
        .map(|l| {
            let cwd = cwds.get(&l.pid).cloned();
            let session_id = session_for(l.pid, parents, sessions);
            let share = served.iter().find(|s| s.local_port == l.port && s.path == "/").or_else(|| served.iter().find(|s| s.local_port == l.port));
            let url = match (&tailnet, share) {
                (_, Some(s)) => Some(s.url.clone()),
                (Some(t), None) if reachable(&l.bind, &t.ips) => Some(format!("http://{}:{}", t.dns_name, l.port)),
                _ => None,
            };
            Port { port: l.port, bind: l.bind, pid: l.pid, process: l.process, cwd, session_id, shared: share.is_some(), url }
        })
        // Tools pick random ports from the OS's ephemeral range for their own plumbing (wrangler
        // and node inspectors open several); nobody browses to those unless a session started them.
        .filter(|p: &Port| p.port < EPHEMERAL || p.session_id.is_some() || p.shared)
        .take(MAX_PORTS)
        .collect();
    Report { tailnet, ports }
}

// ---- listening sockets ----

#[derive(Debug, Clone, PartialEq)]
struct Listener {
    port: u16,
    bind: String,
    pid: u32,
    process: String,
}

/// Processes whose ports aren't anyone's dev server: the runner and tmux themselves, and macOS
/// services that listen on high ports (Handoff, the AirPlay receiver).
const IGNORED: &[&str] = &["maple-runner", "tmux", "rapportd", "ControlCenter", "sharingd"];

async fn listeners() -> Vec<Listener> {
    if cfg!(target_os = "macos") {
        // -F: one field per line. Without sudo, lsof only sees this user's processes.
        run(Path::new("lsof"), &["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], Duration::from_secs(10)).await.map(|o| parse_lsof(&o)).unwrap_or_default()
    } else {
        // Without root, ss only names the processes of this user; the rest have no `users:`.
        run(Path::new("ss"), &["-ltnpH"], Duration::from_secs(10)).await.map(|o| parse_ss(&o)).unwrap_or_default()
    }
}

/// `lsof -Fpcn`: `p<pid>`, `c<command>`, then `f<fd>` / `n<addr>:<port>` per socket.
fn parse_lsof(out: &str) -> Vec<Listener> {
    let mut list = Vec::new();
    let (mut pid, mut process) = (0u32, String::new());
    for line in out.lines() {
        let Some((field, value)) = line.split_at_checked(1) else { continue };
        match field {
            "p" => {
                pid = value.parse().unwrap_or(0);
                process.clear();
            }
            "c" => process = value.to_string(),
            "n" => {
                if let Some((bind, port)) = split_addr(value) {
                    list.push(Listener { port, bind, pid, process: process.clone() });
                }
            }
            _ => {}
        }
    }
    list
}

/// `ss -ltnpH`: `LISTEN 0 511 127.0.0.1:3000 0.0.0.0:* users:(("node",pid=123,fd=20))`.
/// A socket shared by several processes (a forking server) lists each.
fn parse_ss(out: &str) -> Vec<Listener> {
    let mut list = Vec::new();
    for line in out.lines() {
        // The local address is the first column shaped like addr:port (state and queues aren't).
        let Some((bind, port)) = line.split_whitespace().find_map(split_addr) else { continue };
        let Some(users) = line.find("users:(").map(|i| &line[i..]) else { continue };
        for entry in users.split("(\"").skip(1) {
            let Some((name, rest)) = entry.split_once('"') else { continue };
            let Some(pid) = rest.split("pid=").nth(1).and_then(|p| p.split(|c: char| !c.is_ascii_digit()).next()).and_then(|p| p.parse().ok()) else {
                continue;
            };
            list.push(Listener { port, bind: bind.clone(), pid, process: name.to_string() });
        }
    }
    list
}

/// `127.0.0.1:3000`, `[::1]:3000`, `*:3000`, `127.0.0.53%lo:53` → (address, port).
fn split_addr(s: &str) -> Option<(String, u16)> {
    let (addr, port) = s.rsplit_once(':')?;
    let port = port.parse().ok()?;
    let addr = addr.trim_start_matches('[').trim_end_matches(']');
    let addr = addr.split('%').next().unwrap_or(addr);
    (!addr.is_empty()).then(|| (addr.to_string(), port))
}

/// One entry per port and process: a server usually listens on both IPv4 and IPv6. The widest
/// bind wins (all interfaces over localhost), so the URL reflects what's actually reachable.
fn dedupe(list: Vec<Listener>) -> Vec<Listener> {
    let me = std::process::id();
    let mut by_key: BTreeMap<(u16, u32), Listener> = BTreeMap::new();
    for l in list {
        if l.port < 1024 || l.pid == me || IGNORED.iter().any(|name| l.process == *name || l.process.starts_with("tmux")) {
            continue;
        }
        match by_key.get_mut(&(l.port, l.pid)) {
            Some(existing) if scope(&l.bind) > scope(&existing.bind) => *existing = l,
            Some(_) => {}
            None => {
                by_key.insert((l.port, l.pid), l);
            }
        }
    }
    by_key.into_values().collect()
}

/// 0 = localhost, 1 = one specific address, 2 = every interface.
fn scope(bind: &str) -> u8 {
    match bind {
        "*" | "0.0.0.0" | "::" => 2,
        "127.0.0.1" | "::1" | "localhost" | "::ffff:127.0.0.1" => 0,
        b if b.starts_with("127.") => 0,
        _ => 1,
    }
}

/// Whether a server bound to `bind` answers on this machine's tailnet addresses.
fn reachable(bind: &str, tailnet_ips: &[String]) -> bool {
    scope(bind) == 2 || tailnet_ips.iter().any(|ip| ip == bind)
}

// ---- working directories and sessions ----

async fn cwds(pids: &[u32]) -> HashMap<u32, String> {
    if pids.is_empty() {
        return HashMap::new();
    }
    if cfg!(target_os = "macos") {
        let list = pids.iter().map(u32::to_string).collect::<Vec<_>>().join(",");
        run(Path::new("lsof"), &["-a", "-p", &list, "-d", "cwd", "-Fpn"], Duration::from_secs(10)).await.map(|o| parse_lsof_cwd(&o)).unwrap_or_default()
    } else {
        pids.iter().filter_map(|pid| Some((*pid, std::fs::read_link(format!("/proc/{pid}/cwd")).ok()?.to_string_lossy().into_owned()))).collect()
    }
}

/// `lsof -a -p 1,2 -d cwd -Fpn`: `p<pid>`, `fcwd`, `n<path>` per process.
fn parse_lsof_cwd(out: &str) -> HashMap<u32, String> {
    let mut map = HashMap::new();
    let mut pid = 0u32;
    for line in out.lines() {
        if let Some(p) = line.strip_prefix('p') {
            pid = p.parse().unwrap_or(0);
        } else if let Some(path) = line.strip_prefix('n') {
            map.insert(pid, path.to_string());
        }
    }
    map
}

struct SessionProc {
    id: Uuid,
    /// The session's tmux pane process (its shell or agent).
    pid: Option<u32>,
    started_at: u64,
}

/// The session that started `pid`: the one whose pane process is an ancestor of it. Matching by
/// process rather than folder keeps servers started elsewhere (an editor, another terminal) under
/// a session's folder from being credited to that session.
fn session_for(pid: u32, parents: &HashMap<u32, u32>, sessions: &[SessionProc]) -> Option<Uuid> {
    let mut cur = pid;
    for _ in 0..64 {
        if let Some(s) = sessions.iter().filter(|s| s.pid == Some(cur)).max_by_key(|s| s.started_at) {
            return Some(s.id);
        }
        match parents.get(&cur) {
            Some(&parent) if parent > 1 && parent != cur => cur = parent,
            _ => return None,
        }
    }
    None
}

/// Whether `pid` is one of `roots` or was started (at any depth) by one of them.
pub async fn descends_from(pid: u32, roots: &HashSet<u32>) -> bool {
    descends_in(pid, roots, &parents().await)
}

/// The `pids` that are one of `roots` or were started (at any depth) by one, from a single `ps`.
pub async fn descending_from(pids: &[u32], roots: &HashSet<u32>) -> HashSet<u32> {
    let parents = parents().await;
    pids.iter().copied().filter(|&pid| descends_in(pid, roots, &parents)).collect()
}

fn descends_in(pid: u32, roots: &HashSet<u32>, parents: &HashMap<u32, u32>) -> bool {
    let mut cur = pid;
    for _ in 0..64 {
        if roots.contains(&cur) {
            return true;
        }
        match parents.get(&cur) {
            Some(&parent) if parent > 1 && parent != cur => cur = parent,
            _ => return false,
        }
    }
    false
}

/// Every process's parent, from `ps` (the same flags work on macOS and Linux).
async fn parents() -> HashMap<u32, u32> {
    let mut cmd = tokio::process::Command::new("ps");
    cmd.args(["-A", "-o", "pid=,ppid="]).stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null()).kill_on_drop(true);
    let Ok(Ok(out)) = tokio::time::timeout(std::time::Duration::from_secs(5), cmd.output()).await else { return HashMap::new() };
    parse_ps(&String::from_utf8_lossy(&out.stdout))
}

fn parse_ps(text: &str) -> HashMap<u32, u32> {
    text.lines()
        .filter_map(|line| {
            let mut f = line.split_whitespace();
            Some((f.next()?.parse().ok()?, f.next()?.parse().ok()?))
        })
        .collect()
}

// ---- Tailscale ----

/// This machine's Tailscale state, from `tailscale status --json` and `tailscale serve status --json`.
#[derive(Debug, Clone, PartialEq)]
struct Tailscale {
    running: bool,
    dns_name: String,
    ips: Vec<String>,
    /// The tailnet has HTTPS certificates turned on, so `serve` can use HTTPS.
    https: bool,
    served: Vec<Served>,
}

/// One `tailscale serve` handler proxying to a port on this machine.
#[derive(Debug, Clone, PartialEq)]
struct Served {
    local_port: u16,
    serve_port: u16,
    https: bool,
    path: String,
    url: String,
}

impl Tailscale {
    async fn read() -> Option<Self> {
        let cli = tailscale_cli()?;
        let status = run(&cli, &["status", "--json"], Duration::from_secs(10)).await.ok()?;
        let mut state = parse_status(&status)?;
        if state.running
            && let Ok(serve) = run(&cli, &["serve", "status", "--json"], Duration::from_secs(10)).await
        {
            state.served = parse_serve(&serve);
        }
        Some(state)
    }
}

/// The CLI: on PATH, or where the macOS app and the Linux packages put it. A runner started by
/// launchd has a minimal PATH, hence the fixed locations.
fn tailscale_cli() -> Option<PathBuf> {
    let on_path = std::env::var_os("PATH").into_iter().flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>()).map(|d| d.join("tailscale"));
    let fixed = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/usr/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        .map(PathBuf::from);
    on_path.chain(fixed).find(|p| p.is_file())
}

fn parse_status(json: &str) -> Option<Tailscale> {
    let v: Value = serde_json::from_str(json).ok()?;
    let me = v.get("Self")?;
    let dns_name = me.get("DNSName").and_then(Value::as_str).unwrap_or_default().trim_end_matches('.').to_string();
    let ips = me.get("TailscaleIPs").and_then(Value::as_array).map(|a| a.iter().filter_map(|ip| ip.as_str().map(String::from)).collect()).unwrap_or_default();
    let running = v.get("BackendState").and_then(Value::as_str) == Some("Running") && !dns_name.is_empty();
    let https = v.get("CertDomains").and_then(Value::as_array).is_some_and(|a| !a.is_empty());
    Some(Tailscale { running, dns_name, ips, https, served: Vec::new() })
}

/// `tailscale serve status --json`:
/// `{"TCP":{"3000":{"HTTP":true}},"Web":{"host.ts.net:3000":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}`.
/// Handlers started in the foreground sit under `Foreground.<session>` with the same shape.
fn parse_serve(json: &str) -> Vec<Served> {
    let Ok(v) = serde_json::from_str::<Value>(json) else { return Vec::new() };
    let mut out = Vec::new();
    collect_served(&v, &mut out);
    if let Some(fg) = v.get("Foreground").and_then(Value::as_object) {
        for config in fg.values() {
            collect_served(config, &mut out);
        }
    }
    out
}

fn collect_served(config: &Value, out: &mut Vec<Served>) {
    let Some(web) = config.get("Web").and_then(Value::as_object) else { return };
    for (host_port, site) in web {
        let Some((host, serve_port)) = host_port.rsplit_once(':').and_then(|(h, p)| Some((h, p.parse::<u16>().ok()?))) else { continue };
        let https = config.pointer(&format!("/TCP/{serve_port}/HTTPS")).and_then(Value::as_bool).unwrap_or(false);
        let Some(handlers) = site.get("Handlers").and_then(Value::as_object) else { continue };
        for (path, handler) in handlers {
            let Some(local_port) = handler.get("Proxy").and_then(Value::as_str).and_then(local_port) else { continue };
            let scheme = if https { "https" } else { "http" };
            let default = if https { 443 } else { 80 };
            let port = if serve_port == default { String::new() } else { format!(":{serve_port}") };
            let url = format!("{scheme}://{host}{port}{path}");
            out.push(Served { local_port, serve_port, https, path: path.clone(), url });
        }
    }
}

/// The port of a proxy target on this machine: `http://127.0.0.1:3000`, `http://localhost:3000/x`,
/// `https+insecure://localhost:8443`. None for anything elsewhere.
fn local_port(target: &str) -> Option<u16> {
    let rest = target.split_once("://").map_or(target, |(_, r)| r);
    let host_port = rest.split('/').next()?;
    let (host, port) = host_port.rsplit_once(':')?;
    let host = host.trim_start_matches('[').trim_end_matches(']');
    matches!(host, "127.0.0.1" | "localhost" | "::1" | "0.0.0.0").then(|| port.parse().ok()).flatten()
}

// ---- public share links ----

/// Where a share link's request for `port` goes (`127.0.0.1` or `[::1]`), or why it can't. Only a
/// port this runner last saw listening, bound to localhost or every interface: the hub can't make
/// the runner reach arbitrary ports, or servers bound to one specific address.
pub fn proxy_host(port: u16) -> Result<&'static str, String> {
    let last = LAST.lock().unwrap();
    let Some(listed) = last.as_ref().and_then(|r| r.ports.iter().find(|p| p.port == port)) else {
        return Err(format!("Nothing is listening on port {port} on this machine right now."));
    };
    proxy_host_for(&listed.bind).ok_or_else(|| format!("Port {port} is bound to {} only, so it can't be shared.", listed.bind))
}

fn proxy_host_for(bind: &str) -> Option<&'static str> {
    match (scope(bind), bind) {
        (_, "::1" | "::") => Some("[::1]"),
        (0 | 2, _) => Some("127.0.0.1"),
        _ => None,
    }
}

// ---- sharing ----

/// Shares (or stops sharing) a port on the tailnet, answering failures with `port.error`.
pub fn set_shared(sessions: &Sessions, port: u16, share: bool) {
    let sessions = sessions.clone();
    tokio::spawn(async move {
        let result = if share { share_port(port).await } else { unshare_port(port).await };
        match result {
            Ok(()) => tracing::info!("{} port {port} on the tailnet", if share { "shared" } else { "stopped sharing" }),
            Err(message) => {
                tracing::warn!("port {port}: {message}");
                sessions.emit(Outbound::PortError { port, message });
            }
        }
        WAKE.notify_one();
    });
}

async fn share_port(port: u16) -> Result<(), String> {
    // Only what this runner reported, so the hub can't expose arbitrary ports.
    let listed = LAST.lock().unwrap().as_ref().and_then(|r| r.ports.iter().find(|p| p.port == port).cloned());
    let Some(listed) = listed else { return Err("nothing is listening on it.".to_string()) };
    if listed.shared {
        return Ok(());
    }
    if listed.url.is_some() {
        return Err("it's already reachable on the tailnet.".into());
    }
    let cli = tailscale_cli().ok_or("Tailscale isn't installed on this machine.")?;
    let state = Tailscale::read().await.filter(|t| t.running).ok_or("Tailscale isn't connected on this machine.")?;
    // HTTPS needs the tailnet's HTTPS certificates; without them `serve --https` waits for an
    // admin to turn them on, so use plain HTTP (it's still inside the WireGuard tunnel).
    let mode = format!("--{}={port}", if state.https { "https" } else { "http" });
    let target = format!("http://127.0.0.1:{port}");
    run(&cli, &["serve", "--bg", "--yes", &mode, &target], Duration::from_secs(20)).await.map(drop)
}

async fn unshare_port(port: u16) -> Result<(), String> {
    let cli = tailscale_cli().ok_or("Tailscale isn't installed on this machine.")?;
    let serve = run(&cli, &["serve", "status", "--json"], Duration::from_secs(10)).await?;
    let handlers: Vec<Served> = parse_serve(&serve).into_iter().filter(|s| s.local_port == port).collect();
    if handlers.is_empty() {
        return Err("it isn't shared.".into());
    }
    for s in handlers {
        let mode = format!("--{}={}", if s.https { "https" } else { "http" }, s.serve_port);
        let set_path = format!("--set-path={}", s.path);
        let mut args = vec!["serve", &mode];
        if s.path != "/" {
            args.push(&set_path);
        }
        args.push("off");
        run(&cli, &args, Duration::from_secs(20)).await?;
    }
    Ok(())
}

// ---- processes ----

/// Runs a command with a timeout. Ok(stdout) on success; otherwise what it printed (a command
/// waiting on something, like Tailscale asking an admin to turn a feature on, is cut off but its
/// message is kept).
async fn run(program: &Path, args: &[&str], timeout: Duration) -> Result<String, String> {
    let name = program.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("couldn't run {name}: {e}"))?;
    let stdout = Arc::new(Mutex::new(Vec::new()));
    let stderr = Arc::new(Mutex::new(Vec::new()));
    let readers = [tokio::spawn(drain(child.stdout.take(), stdout.clone())), tokio::spawn(drain(child.stderr.take(), stderr.clone()))];
    let status = tokio::time::timeout(timeout, child.wait()).await;
    if status.is_err() {
        let _ = child.kill().await;
    }
    for r in readers {
        let _ = tokio::time::timeout(Duration::from_secs(1), r).await;
    }
    let text = |b: &Arc<Mutex<Vec<u8>>>| String::from_utf8_lossy(&b.lock().unwrap()).trim().to_string();
    let (out, err) = (text(&stdout), text(&stderr));
    match status {
        Ok(Ok(s)) if s.success() => Ok(out),
        // lsof exits 1 when it finds nothing.
        Ok(Ok(_)) if name == "lsof" && err.is_empty() => Ok(out),
        Ok(Ok(s)) => Err(first_non_empty(&err, &out).unwrap_or_else(|| format!("{name} failed ({s})"))),
        Ok(Err(e)) => Err(format!("{name} failed: {e}")),
        Err(_) => Err(match first_non_empty(&err, &out) {
            Some(said) => format!("{name} didn't finish: {}", said.split_whitespace().collect::<Vec<_>>().join(" ")),
            None => format!("{name} didn't finish in {}s", timeout.as_secs()),
        }),
    }
}

async fn drain<R: tokio::io::AsyncRead + Unpin>(pipe: Option<R>, into: Arc<Mutex<Vec<u8>>>) {
    let Some(mut pipe) = pipe else { return };
    let mut buf = [0u8; 4096];
    while let Ok(n) = pipe.read(&mut buf).await {
        if n == 0 {
            break;
        }
        into.lock().unwrap().extend_from_slice(&buf[..n]);
    }
}

fn first_non_empty(a: &str, b: &str) -> Option<String> {
    [a, b].into_iter().find(|s| !s.is_empty()).map(String::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn l(port: u16, bind: &str, pid: u32, process: &str) -> Listener {
        Listener { port, bind: bind.into(), pid, process: process.into() }
    }

    #[test]
    fn parses_lsof() {
        let out = "p996\ncrapportd\nf11\nn*:49565\np1452\ncDiscord Helper (Renderer)\nf37\nn127.0.0.1:6463\np23502\ncworkerd\nf14\nn[::1]:8787\nf15\nn127.0.0.1:8787\n";
        assert_eq!(
            parse_lsof(out),
            vec![
                l(49565, "*", 996, "rapportd"),
                l(6463, "127.0.0.1", 1452, "Discord Helper (Renderer)"),
                l(8787, "::1", 23502, "workerd"),
                l(8787, "127.0.0.1", 23502, "workerd"),
            ]
        );
    }

    #[test]
    fn parses_ss() {
        let out = "LISTEN 0      511        127.0.0.1:3000       0.0.0.0:*    users:((\"node\",pid=1234,fd=20))\n\
                   LISTEN 0      4096            [::]:22          [::]:*\n\
                   LISTEN 0      128   127.0.0.53%lo:5353     0.0.0.0:*    users:((\"resolved\",pid=9,fd=1))\n\
                   LISTEN 0      511               *:8080            *:*    users:((\"gunicorn\",pid=50,fd=5),(\"gunicorn\",pid=51,fd=5))\n";
        assert_eq!(
            parse_ss(out),
            vec![l(3000, "127.0.0.1", 1234, "node"), l(5353, "127.0.0.53", 9, "resolved"), l(8080, "*", 50, "gunicorn"), l(8080, "*", 51, "gunicorn"),]
        );
    }

    #[test]
    fn dedupes_and_filters() {
        let list = vec![
            l(8787, "::1", 7, "workerd"),
            l(8787, "127.0.0.1", 7, "workerd"),
            l(5173, "127.0.0.1", 8, "node"),
            l(5173, "*", 8, "node"),
            l(80, "*", 9, "nginx"),
            l(49565, "*", 10, "rapportd"),
            l(40000, "127.0.0.1", 11, "tmux: server"),
            l(40001, "127.0.0.1", 12, "maple-runner"),
        ];
        assert_eq!(dedupe(list), vec![l(5173, "*", 8, "node"), l(8787, "::1", 7, "workerd")]);
    }

    #[test]
    fn parses_lsof_cwd() {
        let map = parse_lsof_cwd("p12\nfcwd\nn/Users/me/app\np13\nfcwd\nn/\n");
        assert_eq!(map.get(&12).map(String::as_str), Some("/Users/me/app"));
        assert_eq!(map.get(&13).map(String::as_str), Some("/"));
    }

    #[test]
    fn parses_tailscale_status() {
        let json = r#"{"BackendState":"Running","CertDomains":null,"Self":{"DNSName":"mbp.tail1234.ts.net.","TailscaleIPs":["100.65.1.2","fd7a::1"]}}"#;
        let s = parse_status(json).unwrap();
        assert_eq!((s.running, s.dns_name.as_str(), s.https), (true, "mbp.tail1234.ts.net", false));
        assert_eq!(s.ips, vec!["100.65.1.2", "fd7a::1"]);
        let stopped = parse_status(r#"{"BackendState":"Stopped","CertDomains":["mbp.tail1234.ts.net"],"Self":{"DNSName":"","TailscaleIPs":null}}"#).unwrap();
        assert!(!stopped.running && stopped.https);
        assert!(parse_status("not json").is_none());
    }

    #[test]
    fn parses_serve_status() {
        assert!(parse_serve("{}").is_empty());
        let json = r#"{
          "TCP": {"47123": {"HTTP": true}, "443": {"HTTPS": true}},
          "Web": {
            "mbp.tail1234.ts.net:47123": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:47123"}}},
            "mbp.tail1234.ts.net:443": {"Handlers": {"/api": {"Proxy": "http://localhost:5173/api"}, "/files": {"Path": "/tmp"}}}
          },
          "Foreground": {"abc": {"TCP": {"8443": {"HTTPS": true}}, "Web": {"mbp.tail1234.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:3000"}}}}}}
        }"#;
        let mut served = parse_serve(json);
        served.sort_by_key(|s| s.local_port);
        let summary: Vec<_> = served.iter().map(|s| (s.local_port, s.serve_port, s.https, s.path.as_str(), s.url.as_str())).collect();
        assert_eq!(
            summary,
            vec![
                (3000, 8443, true, "/", "https://mbp.tail1234.ts.net:8443/"),
                (5173, 443, true, "/api", "https://mbp.tail1234.ts.net/api"),
                (47123, 47123, false, "/", "http://mbp.tail1234.ts.net:47123/"),
            ]
        );
        assert_eq!(local_port("https+insecure://localhost:8443"), Some(8443));
        assert_eq!(local_port("http://10.0.0.5:3000"), None);
        assert_eq!(local_port("http://[::1]:4000/x"), Some(4000));
    }

    #[test]
    fn matches_sessions_and_urls() {
        let a = Uuid::from_u128(1);
        let b = Uuid::from_u128(2);
        // Pane 100 belongs to session a, pane 200 to b. Process 1 runs in b's pane (via 201), 2 in a's,
        // and 3 was started outside any session (its parent is launchd).
        let sessions = vec![SessionProc { id: a, pid: Some(100), started_at: 1 }, SessionProc { id: b, pid: Some(200), started_at: 2 }];
        let parents: HashMap<u32, u32> = [(1, 201), (201, 200), (200, 50), (2, 100), (3, 1)].into();
        let cwds: HashMap<u32, String> = [(1, "/Users/me/Projects/app/web".into()), (2, "/Users/me/Projects/other".into()), (3, "/opt".into())].into();
        let tailscale = Tailscale {
            running: true,
            dns_name: "mbp.ts.net".into(),
            ips: vec!["100.65.1.2".into()],
            https: false,
            served: vec![Served { local_port: 5000, serve_port: 5000, https: false, path: "/".into(), url: "http://mbp.ts.net:5000/".into() }],
        };
        let listeners = vec![
            l(3000, "*", 1, "node"),
            l(4000, "127.0.0.1", 2, "ruby"),
            l(5000, "127.0.0.1", 3, "python3"),
            l(6000, "100.65.1.2", 3, "x"),
            l(55000, "127.0.0.1", 1, "node"),    // ephemeral, but started by a session
            l(55001, "127.0.0.1", 3, "workerd"), // ephemeral plumbing: hidden
        ];
        let r = build(listeners.clone(), &cwds, &parents, &sessions, Some(&tailscale));
        assert_eq!(r.tailnet, Some(Tailnet { dns_name: "mbp.ts.net".into(), ips: vec!["100.65.1.2".into()] }));
        let got: Vec<_> = r.ports.iter().map(|p| (p.port, p.session_id, p.shared, p.url.as_deref())).collect();
        assert_eq!(
            got,
            vec![
                (3000, Some(b), false, Some("http://mbp.ts.net:3000")),
                (4000, Some(a), false, None),
                (5000, None, true, Some("http://mbp.ts.net:5000/")),
                (6000, None, false, Some("http://mbp.ts.net:6000")),
                (55000, Some(b), false, None),
            ]
        );
        // Off the tailnet nothing is reachable, even when bound to every interface.
        let r = build(listeners, &cwds, &parents, &sessions, None);
        assert_eq!(parse_ps("  1     0\n 4012  1\njunk\n"), [(1, 0), (4012, 1)].into());
        assert!(r.tailnet.is_none() && r.ports.iter().all(|p| p.url.is_none() && !p.shared));
    }

    #[test]
    fn share_links_reach_loopback_or_wildcard_binds_only() {
        assert_eq!(proxy_host_for("127.0.0.1"), Some("127.0.0.1"));
        assert_eq!(proxy_host_for("localhost"), Some("127.0.0.1"));
        assert_eq!(proxy_host_for("::ffff:127.0.0.1"), Some("127.0.0.1"));
        assert_eq!(proxy_host_for("*"), Some("127.0.0.1"));
        assert_eq!(proxy_host_for("0.0.0.0"), Some("127.0.0.1"));
        assert_eq!(proxy_host_for("::1"), Some("[::1]"));
        assert_eq!(proxy_host_for("::"), Some("[::1]"));
        assert_eq!(proxy_host_for("100.64.1.2"), None);
        assert_eq!(proxy_host_for("192.168.1.20"), None);
    }

    #[test]
    fn serializes_report() {
        let r = Report {
            tailnet: None,
            ports: vec![Port { port: 3000, bind: "*".into(), pid: 1, process: "node".into(), cwd: None, session_id: None, shared: false, url: None }],
        };
        assert_eq!(
            serde_json::to_value(Outbound::Ports(r)).unwrap(),
            serde_json::json!({"type":"ports","tailnet":null,"ports":[{"port":3000,"bind":"*","pid":1,"process":"node","cwd":null,"sessionId":null,"shared":false,"url":null}]})
        );
        assert_eq!(
            serde_json::to_value(Outbound::PortError { port: 3000, message: "x".into() }).unwrap(),
            serde_json::json!({"type":"port.error","port":3000,"message":"x"})
        );
    }
}
