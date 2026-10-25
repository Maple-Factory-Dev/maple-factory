mod agent_config;
mod agents;
mod autoupdate;
mod config;
mod factory;
mod folder;
mod fs_browse;
mod git;
mod health;
mod hooks;
mod images;
mod mcp;
mod media;
mod ports;
mod proof;
mod protocol;
mod proxy;
mod repos;
mod service;
mod sessions;
mod statusline;
mod tasks;
mod thumbs;
mod tmux;
mod update;
mod usage;
mod ends;
mod wire;
mod worktrees;

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Result, bail};
use clap::{Parser, Subcommand};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc::UnboundedReceiver;
use tokio_tungstenite::tungstenite::{self, Message, client::IntoClientRequest, http::HeaderValue};
use tracing::{error, info, warn};

use autoupdate::AutoUpdate;
use config::Config;
use protocol::{Inbound, Outbound};
use sessions::{Event, Sessions};

/// Where a runner connects when nothing says otherwise: `wrangler dev` on this machine.
const LOCAL_DEV_URL: &str = "ws://localhost:8787/runner/connect";

/// Connects this machine to the agent orchestrator and runs terminal sessions for it.
///
/// With no subcommand, runs the runner. Settings come from flags and MAPLE_* variables
/// first, then from ~/.config/maple/runner.json (written by `maple-runner enroll`).
#[derive(Parser, Debug)]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Option<Cmd>,
    #[command(flatten)]
    run: Args,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Connect this machine to your account with a one-time code from the web app.
    Enroll {
        /// The control plane, e.g. https://factory.acme.dev (http://localhost:8787 for local dev).
        #[arg(long)]
        url: String,
        /// The one-time code shown in the web app (ABCD-EFGH).
        #[arg(long)]
        code: String,
        /// Name shown in the UI. Defaults to the short hostname.
        #[arg(long)]
        runner_id: Option<String>,
        /// Enroll as a test runner (tucked away in the UI, never offered for new sessions).
        #[arg(long)]
        test: bool,
    },
    /// Run the runner at login (launchd on macOS, systemd on Linux) from a copy of this binary.
    ///
    /// Copies this binary to ~/.local/share/maple/bin/maple-runner and points the service at that
    /// copy, which then keeps itself up to date.
    Install {
        /// Print the copy, service file and commands instead of installing.
        #[arg(long)]
        dry_run: bool,
    },
    /// Stop the runner service and remove it.
    Uninstall {
        /// Print what would be removed instead of removing it.
        #[arg(long)]
        dry_run: bool,
    },
    /// Show this machine's enrollment, the installed binary, and whether the service is running.
    Status,
    /// Restart the runner service and wait for it to connect again.
    Restart,
    /// Replace this binary with the latest signed release.
    ///
    /// Releases come from the control plane's /releases/ (or MAPLE_UPDATE_URL). The release
    /// manifest must be signed with the built-in release key, and the download must match
    /// its size and sha256 and report the new version before it replaces this binary.
    Update {
        /// Only show the current and latest versions and whether an update is available.
        #[arg(long)]
        check: bool,
        /// Install the latest release even if it isn't newer, or over a development build.
        #[arg(long)]
        force: bool,
    },
    /// The `agents` MCP server over stdio. Claude Code and Codex sessions start it themselves;
    /// it only works inside a session (it needs MAPLE_SESSION_ID and MAPLE_HOOK_SOCKET).
    Mcp,
}

#[derive(clap::Args, Debug)]
struct Args {
    /// Control plane: a base URL (https://factory.acme.dev) or a full ws(s):// runner
    /// endpoint. Defaults to runner.json's, or local `wrangler dev` with an explicit token.
    #[arg(long, env = "MAPLE_URL")]
    url: Option<String>,
    /// Runner token. Defaults to the one saved by `maple-runner enroll`.
    #[arg(long, env = "MAPLE_TOKEN", hide_env_values = true)]
    token: Option<String>,
    /// Name shown in the UI. Defaults to runner.json's, or the short hostname.
    #[arg(long, env = "MAPLE_RUNNER_ID")]
    runner_id: Option<String>,
    /// Marks this as a test runner (for example one an agent starts to try out changes).
    /// The UI tucks test runners away and won't start sessions on them.
    #[arg(long, env = "MAPLE_TEST")]
    test: bool,
    /// tmux server socket name (`tmux -L <name>`). Sessions live on this server.
    #[arg(long, env = "MAPLE_TMUX_SOCKET", default_value = "maple")]
    tmux_socket: String,
    /// Run even though the installed service is already running this machine's runner.json
    /// (the service stops: the hub keeps the newest runner with a name).
    #[arg(long)]
    force: bool,
}

/// The pid of the service a bare `maple-runner` would take the place of, if it must refuse to
/// start. Only a runner using runner.json's enrollment (no --token/MAPLE_TOKEN) can collide with
/// the service, and never the service itself, which runs the same command.
fn second_runner(args: &Args, enrolled: bool, service_pid: Option<u32>, own_pid: u32, under_service: bool) -> Option<u32> {
    if args.token.is_some() || args.force || !enrolled || under_service {
        return None;
    }
    service_pid.filter(|&pid| pid != own_pid)
}

/// What a refused bare `maple-runner` says.
fn second_runner_message(runner_id: &str, pid: u32) -> String {
    format!(
        "maple-runner: the service is already running as {runner_id} (pid {pid}).\n  \
         maple-runner status     what it's doing\n  \
         maple-runner restart    restart it\n  \
         maple-runner --force    run here anyway (the service will stop)"
    )
}

/// Whether launchd started this process as the runner service.
fn launched_by_service() -> bool {
    std::env::var("XPC_SERVICE_NAME").is_ok_and(|name| name == service::LAUNCHD_LABEL)
}

/// Connection settings after flags, environment and runner.json are combined.
#[derive(Debug, PartialEq)]
struct Settings {
    /// The WebSocket endpoint, without `?runner=`.
    url: String,
    token: String,
    runner_id: String,
    test: bool,
}

/// An explicit token (flag or MAPLE_TOKEN) means "don't use runner.json": the dev script
/// passes the shared dev token with no URL, which must keep meaning local `wrangler dev`
/// rather than pairing that token with the enrolled server. Without one, runner.json
/// supplies whatever the flags leave out.
fn settings(args: &Args, config: Option<Config>, host: &str) -> Result<Settings> {
    let (url, token, runner_id, test) = match (&args.token, config) {
        (Some(token), _) => (
            args.url.clone().unwrap_or_else(|| LOCAL_DEV_URL.into()),
            token.clone(),
            args.runner_id.clone().unwrap_or_else(|| config::normalize_runner_id(host)),
            args.test,
        ),
        (None, Some(config)) => {
            (args.url.clone().unwrap_or(config.url), config.token, args.runner_id.clone().unwrap_or(config.runner_id), args.test || config.test)
        }
        (None, None) => bail!(
            "this machine isn't enrolled. Get a code from the web app and run:\n\n    maple-runner enroll --url https://… --code XXXX-XXXX\n\n(or pass --token / MAPLE_TOKEN)"
        ),
    };
    if !config::valid_runner_id(&runner_id) {
        bail!("runner id `{runner_id}` isn't valid: use lowercase letters, digits and dashes (e.g. `{}`)", config::normalize_runner_id(&runner_id));
    }
    Ok(Settings { url: config::ws_endpoint(&url)?, token, runner_id, test })
}

#[tokio::main]
async fn main() -> Result<()> {
    // Agents call `maple-runner hook …` from inside sessions.
    if std::env::args().nth(1).as_deref() == Some("hook") {
        hooks::run_hook();
    }
    // Claude Code's status line in sessions; it prints one line, nothing else.
    if std::env::args().nth(1).as_deref() == Some("statusline") {
        statusline::run();
    }
    // Stdout is the MCP channel, so nothing else may print there.
    if std::env::args().nth(1).as_deref() == Some("mcp") {
        mcp::serve();
    }
    tracing_subscriber::fmt().with_target(false).init();
    let cli = Cli::parse();
    match cli.command {
        None => run(cli.run).await,
        Some(Cmd::Mcp) => mcp::serve(),
        Some(Cmd::Enroll { url, code, runner_id, test }) => enroll(&url, &code, runner_id, test).await,
        Some(Cmd::Install { dry_run }) => install(dry_run),
        Some(Cmd::Uninstall { dry_run }) => service::Service::detect()?.uninstall(dry_run),
        Some(Cmd::Status) => status(cli.run.url.as_deref()),
        Some(Cmd::Restart) => restart(),
        Some(Cmd::Update { check, force }) => self_update(cli.run.url.as_deref(), check, force).await,
    }
}

async fn enroll(url: &str, code: &str, runner_id: Option<String>, test: bool) -> Result<()> {
    let host = hostname();
    let runner_id = match runner_id {
        Some(id) if !config::valid_runner_id(&id) => {
            bail!("--runner-id `{id}` isn't valid: use lowercase letters, digits and dashes (e.g. `{}`)", config::normalize_runner_id(&id))
        }
        Some(id) => id,
        None => config::normalize_runner_id(&host),
    };
    let path = config::path()?;
    // Read before enrolling so a broken file is reported, but don't let it block re-enrolling.
    let previous = Config::load(&path).ok().flatten();
    let mut config = config::enroll(url, &config::normalize_code(code), &runner_id, &host, test).await?;
    // Settings that aren't the enrollment's own stay.
    config.repo_roots = previous.as_ref().and_then(|p| p.repo_roots.clone());
    config.repo_clone_days = previous.as_ref().and_then(|p| p.repo_clone_days);
    config.save(&path)?;
    if let Some(prev) = previous {
        println!("Replaced the previous enrollment ({} at {}) in {}.", prev.runner_id, prev.url, path.display());
    } else {
        println!("Saved {}.", path.display());
    }
    println!("Enrolled as `{}`{} with {}.", config.runner_id, if config.test { " (test runner)" } else { "" }, config.url);
    println!("\nNext: `maple-runner install` to run it at login, or `maple-runner` to run it now.");
    Ok(())
}

fn install(dry_run: bool) -> Result<()> {
    let path = config::path()?;
    let Some(config) = Config::load(&path)? else {
        bail!("{} doesn't exist. Enroll this machine first:\n\n    maple-runner enroll --url https://… --code XXXX-XXXX", path.display());
    };
    let exe = update::current_exe()?;
    let installed = service::installed_exe()?;
    let service = service::Service::detect()?;
    println!("Runner `{}` at {}, running {}", config.runner_id, config.url, installed.display());
    if service::is_installed_copy(&exe, &installed) {
        println!("{} is already the installed copy", exe.display());
    } else if dry_run {
        println!("Would copy {} to {}\n", exe.display(), installed.display());
    } else {
        service::copy_binary(&exe, &installed)?;
        println!("Copied {} to {}", exe.display(), installed.display());
    }
    service.install(&installed, dry_run)
}

/// The control plane for commands other than running: `--url`/`MAPLE_URL`, else runner.json's.
fn server_url(url: Option<&str>) -> Result<Option<String>> {
    Ok(match url {
        Some(url) => Some(url.to_string()),
        None => Config::load(&config::path()?)?.map(|c| c.url),
    })
}

async fn self_update(url: Option<&str>, check: bool, force: bool) -> Result<()> {
    let releases = update::releases_url_from_env(server_url(url)?.as_deref())?;
    let exe = update::current_exe()?;
    if !check && !force && update::is_dev_build(&exe) {
        bail!(
            "{} is a development build (inside a cargo target/ directory); not replacing it.\n\
             `maple-runner install` copies the runner to ~/.local/share/maple/bin, which updates itself;\n\
             or pass --force to replace this file anyway.",
            exe.display()
        );
    }
    let releases = update::Releases::new(releases)?;
    let current = update::current_version();
    println!("Checking {}", releases.base());
    let check_result = releases.check(force).await?;
    let manifest = match &check_result {
        update::Check::UpToDate(m) | update::Check::NoBuild(m, _) | update::Check::Available(m, _) => m,
    };
    let published = manifest.published_at.as_deref().map(|p| format!(" (published {p})")).unwrap_or_default();
    println!("current: {current}");
    println!("latest:  {}{published}", manifest.version);
    match check_result {
        update::Check::UpToDate(_) => println!("maple-runner is up to date."),
        update::Check::NoBuild(m, target) if check => {
            println!("{} has no build for this machine ({target}).", m.version)
        }
        update::Check::NoBuild(m, target) => bail!("release {} has no build for this machine ({target}); nothing to install", m.version),
        update::Check::Available(m, _) if check => {
            if m.version > current {
                println!("An update is available: run `maple-runner update`.");
            } else {
                println!("maple-runner is up to date.");
            }
            if let Some(notes) = m.notes.as_deref().filter(|n| !n.trim().is_empty()) {
                println!("\n{}", notes.trim());
            }
        }
        update::Check::Available(m, asset) => {
            println!("Downloading {}{} ({} bytes)", releases.base(), asset.path, asset.size);
            releases.install(&m, &asset, &exe).await?;
            println!("Updated {} from {current} to {}.", exe.display(), m.version);
            let installed = service::installed_exe()?;
            if service::is_installed_copy(&exe, &installed) {
                println!("The service keeps running {current} until it restarts; `maple-runner install` restarts it now.");
            } else if installed.exists() {
                println!("Note: the service runs {}, which updates itself; this updated a different copy.", installed.display());
            }
        }
    }
    Ok(())
}

fn status(url: Option<&str>) -> Result<()> {
    let path = config::path()?;
    match Config::load(&path)? {
        Some(c) => {
            println!("config:    {}", path.display());
            println!("runner id: {}{}", c.runner_id, if c.test { " (test runner)" } else { "" });
            println!("url:       {}", c.url);
            println!("token:     {}", config::redact(&c.token));
        }
        None => println!("config:    {} (not enrolled; run `maple-runner enroll`)", path.display()),
    }
    let installed = service::installed_exe()?;
    if installed.exists() {
        println!("binary:    {} ({})", installed.display(), service::binary_version(&installed));
    } else {
        println!("binary:    {} (not installed)", installed.display());
    }
    match server_url(url).and_then(|server| update::releases_url_from_env(server.as_deref())) {
        Ok(releases) => println!("updates:   {releases}"),
        Err(e) => println!("updates:   {e:#}"),
    }
    match service::Service::detect() {
        Ok(service) => println!("service:   {}", service.status()),
        Err(e) => println!("service:   {e:#}"),
    }
    Ok(())
}

fn restart() -> Result<()> {
    let service = service::Service::detect()?;
    let manager = service.manager_name();
    let wait = Duration::from_secs(10);
    match service.restart(wait)? {
        Some(runner_id) => println!("Restarted the service ({manager}). It's connected as {runner_id}."),
        None => bail!("restarted the service ({manager}), but it hasn't connected after {}s. Check `maple-runner status` and {}", wait.as_secs(), service.logs()),
    }
    Ok(())
}

async fn run(args: Args) -> Result<()> {
    let host = hostname();
    let config_path = config::path()?;
    let config = Config::load(&config_path)?;
    // Ask launchd/systemd only when the answer could matter.
    if let Some(config) = config.as_ref().filter(|_| args.token.is_none() && !args.force) {
        let service_pid = service::Service::detect().ok().and_then(|s| s.running_pid());
        if let Some(pid) = second_runner(&args, true, service_pid, std::process::id(), launched_by_service()) {
            eprintln!("{}", second_runner_message(&config.runner_id, pid));
            std::process::exit(1);
        }
    }
    if args.token.is_some() && config.is_some() {
        info!("using the token from --token/MAPLE_TOKEN; ignoring {}", config_path.display());
    }
    repos::set_roots(config.as_ref().and_then(|c| c.repo_roots.clone()));
    let settings = settings(&args, config, &host)?;
    let runner_id = settings.runner_id.clone();
    proxy::set_control_url(&settings.url);
    proof::configure(&settings.url, &runner_id, &settings.token);
    info!("maple-runner {}", update::VERSION);

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let dir = config::dir()?;
    std::fs::create_dir_all(&dir)?;
    let tmux = tmux::Tmux::new(&args.tmux_socket, &dir)?;
    info!("sessions live on tmux server `{}` (attach with: tmux -S {} attach)", tmux.socket(), tmux.socket_path().display());
    let hooks = hooks::Hooks::prepare(&dir, &args.tmux_socket)?;
    let socket = hooks.socket.clone();
    let sessions = Sessions::start(tx, tmux, hooks).await?;
    let updater = AutoUpdate::new(args.token.is_some(), &settings.url);
    updater.start(sessions.clone());
    tokio::spawn(health::report(sessions.clone()));
    tokio::spawn(git::report(sessions.clone()));
    tokio::spawn(ports::report(sessions.clone()));
    tokio::spawn(worktrees::report(sessions.clone()));
    tokio::spawn(repos::report(sessions.clone()));
    tokio::spawn(repos::sweep(sessions.clone()));
    tokio::spawn(proof::sweep_daily());
    tokio::spawn(images::sweep_daily());
    tokio::spawn(agent_config::watch(sessions.clone()));
    tokio::spawn(usage::report(sessions.clone()));
    tokio::spawn(thumbs::report(sessions.clone()));
    tokio::spawn({
        let sessions = sessions.clone();
        async move {
            if let Err(e) = hooks::listen(socket, sessions).await {
                warn!("status hooks are off: {e:#}");
            }
        }
    });
    let max_backoff = Duration::from_secs(30);
    let mut backoff = Duration::from_secs(1);

    loop {
        // Output produced while offline is already in each session's scrollback; agent state and
        // exits go in the hello, and reports (ports, git, worktrees, usage) are sent again after it.
        while rx.try_recv().is_ok() {}
        let mut connected = false;
        let result = connect(&settings, &host, &sessions, &updater, &mut rx, &mut connected).await;
        mcp::set_connected(false);
        // A connection that worked and then dropped (a deploy, a network blip) retries quickly;
        // only repeated failures to connect back off.
        if connected {
            backoff = Duration::from_secs(1);
        }
        match result {
            Ok(()) => info!("disconnected"),
            Err(e) if e.is::<Replaced>() => {
                // Two runners with one name would keep kicking each other off. Exit cleanly:
                // the service only restarts after a crash, so it stays stopped.
                error!("another runner connected as {runner_id}; stopping. Give each machine its own --runner-id.");
                std::process::exit(0);
            }
            Err(e) if e.is::<Rejected>() => {
                // Usually a revoked token, but a restarting dev server can say this too,
                // so keep trying, slowly.
                error!("this machine's token was rejected; re-enroll with `maple-runner enroll`");
                backoff = max_backoff;
            }
            Err(e) => warn!("connection failed: {e:#}"),
        }
        info!("reconnecting in {}s", backoff.as_secs());
        tokio::time::sleep(backoff).await;
        if !connected {
            backoff = (backoff * 2).min(max_backoff);
        }
    }
}

async fn connect(
    settings: &Settings,
    host: &str,
    sessions: &Sessions,
    updater: &Arc<AutoUpdate>,
    rx: &mut UnboundedReceiver<Event>,
    connected: &mut bool,
) -> Result<()> {
    let runner_id = settings.runner_id.as_str();
    let mut req = format!("{}?runner={}", settings.url, runner_id).into_client_request()?;
    req.headers_mut().insert("authorization", HeaderValue::from_str(&format!("Bearer {}", settings.token))?);
    let ws = match tokio_tungstenite::connect_async(req).await {
        Ok((ws, _)) => ws,
        // The server refused the upgrade with an ordinary HTTP response.
        Err(tungstenite::Error::Http(res)) if res.status() == 401 => return Err(Rejected.into()),
        Err(tungstenite::Error::Http(res)) => {
            let body = res.body().as_deref().map(String::from_utf8_lossy).unwrap_or_default();
            bail!("connecting: the server answered {}{}{}", res.status(), if body.trim().is_empty() { "" } else { ": " }, body.trim());
        }
        Err(e) => return Err(anyhow::Error::new(e).context("connecting")),
    };
    *connected = true;
    let (mut sink, mut stream) = ws.split();
    info!("connected to {} as {runner_id}", settings.url);

    // What happened while disconnected was dropped with the outbox (see `run`). The hello carries
    // each session's latest agent state and the recent exits instead, so the hub catches up.
    let (live, exits) = sessions.hello();
    let hello = Outbound::Wire(wire::RunnerMessage::Hello {
        runner_id: runner_id.to_string(),
        hostname: host.to_string(),
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        version: update::VERSION.to_string(),
        sessions: live,
        ended: exits,
    });
    sink.send(Message::text(serde_json::to_string(&hello)?)).await?;
    mcp::set_connected(true);
    // Share link requests from before a reconnect went with the old connection.
    proxy::reset();
    // The hub says again which thumbnails its browsers want.
    thumbs::clear();
    ports::resend();
    usage::resend();
    git::resend();
    // A hub that just woke has no worktree report yet.
    worktrees::poke(true);
    repos::poke(true);

    let mut ping = tokio::time::interval(Duration::from_secs(20));
    let mut hub = Quiet::new(HUB_QUIET);
    loop {
        tokio::select! {
            msg = hub.next(&mut stream) => match msg {
                // A half-open socket (a sleeping laptop, a NAT that forgot it) can look connected
                // for hours; drop it and go through the normal reconnect.
                Err(Silent) => {
                    warn!("nothing from the hub for {}s; dropping the connection", HUB_QUIET.as_secs());
                    return Ok(());
                }
                Ok(msg) => match msg {
                    Some(Ok(Message::Text(text))) => {
                        if text.as_str() != "pong" {
                            handle(sessions, updater, text.as_str());
                        }
                    }
                    Some(Ok(Message::Binary(frame))) => {
                        if let Some((id, data)) = protocol::decode_frame(&frame) {
                            sessions.write(id, data);
                        }
                    }
                    Some(Ok(Message::Close(Some(frame)))) if u16::from(frame.code) == 4000 => return Err(Replaced.into()),
                    Some(Ok(Message::Close(_))) | None => return Ok(()),
                    Some(Ok(_)) => {}
                    Some(Err(e)) => return Err(e.into()),
                },
            },
            Some(event) = rx.recv() => match event {
                Event::Text(out) => {
                    if let Some(text) = text_message(&out)? {
                        sink.send(Message::text(text)).await?;
                    }
                }
                // tmux hands over output in small pieces, but never send a frame over the limit.
                Event::Output(id, data) => {
                    for chunk in data.chunks(protocol::MAX_MESSAGE - 16) {
                        sink.send(Message::binary(protocol::encode_frame(id, chunk))).await?;
                    }
                }
            },
            _ = ping.tick() => sink.send(Message::text("ping")).await?,
        }
    }
}

/// `out` as JSON, or what to send instead when it's over `MAX_MESSAGE` (Cloudflare would close
/// the socket for a message over its limit, and big ones are slow to relay anyway).
fn text_message(out: &Outbound) -> Result<Option<String>> {
    let text = serde_json::to_string(out)?;
    if text.len() <= protocol::MAX_MESSAGE {
        return Ok(Some(text));
    }
    let kind = text.get(..60).unwrap_or_default().to_string();
    warn!("not sending a {} byte message (over {}): {kind}…", text.len(), protocol::MAX_MESSAGE);
    out.oversized(text.len()).map(|o| serde_json::to_string(&o)).transpose().map_err(Into::into)
}

/// How long the hub may say nothing before the connection counts as dead. The runner pings
/// every 20s and the hub answers each one, so this is three missed pongs.
const HUB_QUIET: Duration = Duration::from_secs(60);

/// Reads a stream, giving up once nothing has arrived for `limit`.
struct Quiet {
    limit: Duration,
    heard: tokio::time::Instant,
}

/// Nothing arrived within the limit.
#[derive(Debug, PartialEq)]
struct Silent;

impl Quiet {
    fn new(limit: Duration) -> Self {
        Self { limit, heard: tokio::time::Instant::now() }
    }

    /// The stream's next item, or `Silent` if the limit passes since the last one first.
    /// Cancel-safe (for `select!`) because `StreamExt::next` is.
    async fn next<S: futures_util::Stream + Unpin>(&mut self, stream: &mut S) -> Result<Option<S::Item>, Silent> {
        let item = tokio::time::timeout_at(self.heard + self.limit, stream.next()).await.map_err(|_| Silent)?;
        self.heard = tokio::time::Instant::now();
        Ok(item)
    }
}

/// The hub closed this connection because another runner connected with the same name.
#[derive(Debug)]
struct Replaced;

impl std::fmt::Display for Replaced {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("replaced by another runner with the same name")
    }
}

impl std::error::Error for Replaced {}

/// The server refused this runner's token (HTTP 401 on connect).
#[derive(Debug)]
struct Rejected;

impl std::fmt::Display for Rejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the server rejected this runner's token")
    }
}

impl std::error::Error for Rejected {}

fn handle(sessions: &Sessions, updater: &Arc<AutoUpdate>, text: &str) {
    let msg: Inbound = match serde_json::from_str(text) {
        Ok(msg) => msg,
        Err(e) => return warn!("bad message from hub: {e}"),
    };
    match msg {
        Inbound::SessionOpen { id, agent, cwd, prompt, cols, rows, worktree, task, model, unattended, images, resume } => {
            let sessions = sessions.clone();
            tokio::spawn(async move {
                let opened = async {
                    // In a worktree, the session's directory is the worktree. A task's comes from
                    // GitHub's copy of its branch, and its prompt gets its project's settings and its card's images.
                    let (cwd, prompt, images) = match (&task, &worktree) {
                        (Some(t), w) => tasks::open(&sessions, t, &cwd, w.as_ref(), prompt.as_deref(), &images).await?,
                        (None, Some(w)) => (worktrees::create(&cwd, w).await?, prompt, vec![]),
                        (None, None) => (cwd.clone(), prompt, vec![]),
                    };
                    // A task's session can attach evidence to it (`prove`), from its own proof folder.
                    let tag = task
                        .as_ref()
                        .zip(worktree.as_ref())
                        .map(|(t, w)| proof::TaskTag { id: t.id.clone(), branch: format!("{}{}", worktrees::BRANCH_PREFIX, w.name) });
                    sessions.open(id, &agent, &cwd, model.as_deref(), unattended.as_ref(), &images, prompt.as_deref(), resume, cols, rows, tag).await
                };
                match opened.await {
                    Ok(session) => {
                        info!("opened {agent} session {id} in {cwd}");
                        let session = sessions.wire_info(session.id).unwrap_or(wire::SessionInfo {
                            id: session.id,
                            agent: session.agent,
                            cwd: session.cwd,
                            pid: session.pid,
                            started_at: session.started_at,
                            task_id: None,
                        });
                        sessions.emit(Outbound::Wire(wire::RunnerMessage::SessionOpened { session }));
                    }
                    Err(e) => {
                        warn!("could not open {agent} in {cwd}: {e:#}");
                        sessions.emit(Outbound::SessionError { id, message: format!("{e:#}") });
                    }
                }
            });
        }
        Inbound::SessionResize { id, cols, rows } => sessions.resize(id, cols, rows),
        Inbound::SessionKill { id } => {
            let sessions = sessions.clone();
            tokio::spawn(async move { sessions.kill(id).await });
        }
        Inbound::SessionReplay { id, nonce } => sessions.replay(id, nonce),
        Inbound::RunnerUpdate => {
            info!("the hub asked for an update");
            updater.requested(sessions);
        }
        Inbound::RunnerRestart => match updater.blocked() {
            // Nothing would start a dev runner again.
            Some(why) => sessions.emit(Outbound::RunnerRestartStatus { message: format!("Can't restart: {why}") }),
            None => {
                info!("the hub asked for a restart; the service will start this runner again");
                tokio::spawn(async {
                    // Let the socket flush, then exit non-zero so launchd/systemd restart us.
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    std::process::exit(update::EXIT_UPDATED);
                });
            }
        },
        Inbound::PortShare { port } => ports::set_shared(sessions, port, true),
        Inbound::PortUnshare { port } => ports::set_shared(sessions, port, false),
        Inbound::WorktreeRemove { path, session, force } => {
            let sessions = sessions.clone();
            tokio::spawn(async move {
                match worktrees::remove(&sessions, &path, force).await {
                    Ok(done) => {
                        info!("{done}");
                        if let Some(session) = session {
                            sessions.emit(Outbound::WorktreeRemoved { path, session });
                        }
                    }
                    Err(e) => {
                        warn!("could not remove worktree {path}: {e:#}");
                        sessions.emit(Outbound::WorktreeError { path, message: format!("{e:#}"), session });
                    }
                }
            });
        }
        Inbound::FsList { req_id, path, hidden } => {
            let sessions = sessions.clone();
            tokio::task::spawn_blocking(move || {
                let result = fs_browse::home().and_then(|home| fs_browse::list(&path, hidden, &home));
                sessions.emit(fs_listing(req_id, path, result.map(|l| (l, None))));
            });
        }
        Inbound::FsMkdir { req_id, path } => {
            let sessions = sessions.clone();
            tokio::task::spawn_blocking(move || {
                let result = fs_browse::home().and_then(|home| fs_browse::mkdir(&path, &home));
                if let Ok((_, created)) = &result {
                    info!("created folder {created}");
                }
                sessions.emit(fs_listing(req_id, path, result.map(|(l, created)| (l, Some(created)))));
            });
        }
        Inbound::FolderFiles { req_id, path } => folder_request(sessions, req_id, move |home| async move { folder::files(&path, &home).await }),
        Inbound::FolderStatus { req_id, path } => folder_request(sessions, req_id, move |home| async move { folder::status(&path, &home).await }),
        Inbound::FolderDiff { req_id, path, file, old_file } => {
            folder_request(sessions, req_id, move |home| async move { folder::diff(&path, &file, old_file.as_deref(), &home).await })
        }
        Inbound::FolderRead { req_id, path, file } => {
            folder_request(sessions, req_id, move |home| async move { tokio::task::spawn_blocking(move || folder::read(&path, &file, &home)).await? })
        }
        Inbound::FileStat { req_id, path, cwd, session } => {
            let sessions = sessions.clone();
            tokio::spawn(async move {
                let pane = match session {
                    Some(id) => sessions.current_dir(id).await,
                    None => None,
                };
                let stat = tokio::task::spawn_blocking(move || match fs_browse::home() {
                    Ok(home) => {
                        let base = media::base_dir(pane.as_deref(), cwd.as_deref(), &home);
                        media::stat(&path, base.as_deref(), &home)
                    }
                    Err(e) => media::Stat { error: Some(format!("{e:#}")), ..media::Stat::default() },
                })
                .await;
                if let Ok(stat) = stat {
                    sessions.emit(Outbound::FileInfo { req_id, stat });
                }
            });
        }
        Inbound::FileRead { req_id, path, offset, length } => {
            let sessions = sessions.clone();
            tokio::task::spawn_blocking(move || {
                let result = match fs_browse::home().and_then(|home| media::read(&path, offset, length, &home)) {
                    Ok(chunk) => protocol::ChunkReply::Ok(chunk),
                    Err(e) => protocol::ChunkReply::Err { error: format!("{e:#}") },
                };
                sessions.emit(Outbound::FileChunk { req_id, result });
            });
        }
        Inbound::McpResponse { req_id, result, error } => mcp::resolve(&req_id, result, error),
        Inbound::SessionCapture { req_id, id, lines } => {
            let sessions = sessions.clone();
            tokio::spawn(async move {
                let (text, error) = match sessions.capture(id, lines).await {
                    Ok(text) => (text, None),
                    Err(e) => (String::new(), Some(format!("{e:#}"))),
                };
                sessions.emit(Outbound::SessionCaptured { req_id, text, error });
            });
        }
        Inbound::TaskImages { req_id, task_id, files } => {
            info!("fetching {} asked image(s) for task {task_id}", files.len());
            let sessions = sessions.clone();
            tokio::spawn(async move {
                let got = images::answer(&task_id, &files).await;
                sessions.emit(Outbound::TaskImagesFetched { req_id, got, error: None });
            });
        }
        Inbound::HttpRequest(head) => proxy::request(sessions, head),
        Inbound::HttpRequestBody { req_id, data, end } => proxy::request_body(sessions, req_id, &data, end),
        Inbound::HttpAck { req_id, bytes } => proxy::ack(&req_id, bytes),
        Inbound::HttpCancel { req_id } => proxy::cancel(&req_id),
        Inbound::TaskFinish(f) => {
            info!("finishing task {} in {}", f.task_id, f.cwd);
            tokio::spawn(tasks::run(sessions.clone(), f));
        }
        Inbound::TaskHandoff(h) => {
            info!("handing task {} off from {}", h.task_id, h.cwd);
            tokio::spawn(tasks::run_handoff(sessions.clone(), h));
        }
        Inbound::TaskProve(p) => {
            info!("checking task {} in {}", p.task_id, p.cwd);
            tokio::spawn(proof::run_prove(sessions.clone(), p));
        }
        Inbound::TaskCleanup(c) => {
            info!("cleaning up task {} in {}", c.task_id, c.cwd);
            tokio::spawn(tasks::run_cleanup(sessions.clone(), c));
        }
        Inbound::TaskToken { req_id, token, error, code } => tasks::resolve(&req_id, tasks::TokenReply { token, error, code }),
        Inbound::UsageConfig { claude_check } => usage::configure(claude_check),
        Inbound::UsageRefresh { agent } => usage::refresh_now(&agent),
        Inbound::ThumbsWatch { sessions: list, fresh } => thumbs::watch(list, &fresh),
        Inbound::Unknown => {}
    }
}

/// Runs a folder page request off the message loop and answers it by `req_id`.
fn folder_request<F, Fut>(sessions: &Sessions, req_id: String, work: F)
where
    F: FnOnce(std::path::PathBuf) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = Result<folder::Payload>> + Send,
{
    let sessions = sessions.clone();
    tokio::spawn(async move {
        let result = match fs_browse::home() {
            Ok(home) => work(home).await,
            Err(e) => Err(e),
        };
        let result = match result {
            Ok(payload) => protocol::FolderReply::Ok(payload),
            Err(e) => protocol::FolderReply::Err { error: format!("{e:#}") },
        };
        sessions.emit(Outbound::FolderResult { req_id, result });
    });
}

fn fs_listing(req_id: String, asked: String, result: Result<(fs_browse::Listing, Option<String>)>) -> Outbound {
    match result {
        Ok((l, created)) => Outbound::FsListing { req_id, path: l.path, entries: l.entries, truncated: l.truncated, created, error: None },
        Err(e) => Outbound::FsListing { req_id, path: asked, entries: vec![], truncated: false, created: None, error: Some(format!("{e:#}")) },
    }
}

fn hostname() -> String {
    let name = ::hostname::get().map(|h| h.to_string_lossy().into_owned()).unwrap_or_else(|_| "runner".into());
    name.trim_end_matches(".local").to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(cli: &[&str]) -> Args {
        // Parse flags only; the tests mustn't depend on MAPLE_* in the environment.
        let mut argv = vec!["maple-runner"];
        argv.extend_from_slice(cli);
        let mut cmd = <Cli as clap::CommandFactory>::command();
        for id in ["url", "token", "runner_id", "test", "tmux_socket"] {
            cmd = cmd.mut_arg(id, |a| a.env(None::<&str>));
        }
        let matches = cmd.try_get_matches_from(argv).unwrap();
        <Cli as clap::FromArgMatches>::from_arg_matches(&matches).unwrap().run
    }

    fn enrolled() -> Config {
        Config {
            url: "https://factory.acme.dev".into(),
            runner_id: "mbp-14".into(),
            token: "tok".into(),
            test: false,
            repo_roots: None,
            repo_clone_days: None,
        }
    }

    #[test]
    fn enrolled_machine_uses_runner_json() {
        let s = settings(&args(&[]), Some(enrolled()), "Host.local").unwrap();
        assert_eq!(s, Settings { url: "wss://factory.acme.dev/runner/connect".into(), token: "tok".into(), runner_id: "mbp-14".into(), test: false });
        let s = settings(&args(&["--runner-id", "other", "--test", "--url", "http://localhost:9000"]), Some(enrolled()), "h").unwrap();
        assert_eq!((s.url.as_str(), s.runner_id.as_str(), s.test), ("ws://localhost:9000/runner/connect", "other", true));
    }

    #[test]
    fn explicit_token_means_local_dev() {
        // scripts/runner-dev.sh: MAPLE_TOKEN + --runner-id, no MAPLE_URL.
        let s = settings(&args(&["--token", "dev", "--runner-id", "mbp-16"]), Some(enrolled()), "h").unwrap();
        assert_eq!(s.url, LOCAL_DEV_URL);
        assert_eq!((s.token.as_str(), s.runner_id.as_str(), s.test), ("dev", "mbp-16", false));
        let s = settings(&args(&["--token", "dev", "--url", "ws://box:8787/runner/connect"]), None, "Box.local").unwrap();
        assert_eq!((s.url.as_str(), s.runner_id.as_str()), ("ws://box:8787/runner/connect", "box"));
    }

    #[test]
    fn no_token_anywhere() {
        let e = settings(&args(&[]), None, "h").unwrap_err().to_string();
        assert!(e.contains("maple-runner enroll"), "{e}");
        assert!(settings(&args(&["--token", "t", "--runner-id", "Bad Name"]), None, "h").is_err());
    }

    #[test]
    fn subcommands_parse() {
        let cli = Cli::try_parse_from(["maple-runner", "enroll", "--url", "https://x.dev", "--code", "ABCD-EFGH"]).unwrap();
        assert!(matches!(cli.command, Some(Cmd::Enroll { test: false, runner_id: None, .. })));
        assert!(matches!(Cli::try_parse_from(["maple-runner", "install", "--dry-run"]).unwrap().command, Some(Cmd::Install { dry_run: true })));
        assert!(Cli::try_parse_from(["maple-runner", "--runner-id", "x"]).unwrap().command.is_none());
        assert!(matches!(Cli::try_parse_from(["maple-runner", "update", "--check"]).unwrap().command, Some(Cmd::Update { check: true, force: false })));
        assert!(matches!(Cli::try_parse_from(["maple-runner", "update", "--force"]).unwrap().command, Some(Cmd::Update { check: false, force: true })));
        assert!(matches!(Cli::try_parse_from(["maple-runner", "restart"]).unwrap().command, Some(Cmd::Restart)));
        let cli = Cli::try_parse_from(["maple-runner", "--force"]).unwrap();
        assert!(cli.command.is_none() && cli.run.force);
        let help = <Cli as clap::CommandFactory>::command().render_help().to_string();
        assert!(help.contains("restart") && help.contains("--force"), "{help}");
    }

    #[test]
    fn bare_runner_refuses_while_the_service_runs() {
        const ME: u32 = 900;
        let bare = args(&[]);
        // The service is running as another process: refuse, naming it.
        assert_eq!(second_runner(&bare, true, Some(4121), ME, false), Some(4121));
        // Another name still uses the service's token, so it's refused too.
        assert_eq!(second_runner(&args(&["--runner-id", "other"]), true, Some(4121), ME, false), Some(4121));
        // No service running, or nothing says which process it is.
        assert_eq!(second_runner(&bare, true, None, ME, false), None);
        // The service runs this same command: it is never refused by itself.
        assert_eq!(second_runner(&bare, true, Some(ME), ME, false), None);
        assert_eq!(second_runner(&bare, true, Some(4121), ME, true), None);
        // --force runs anyway.
        assert_eq!(second_runner(&args(&["--force"]), true, Some(4121), ME, false), None);
        // Dev runners (scripts/runner-dev.sh passes MAPLE_TOKEN) are never refused.
        assert_eq!(second_runner(&args(&["--token", "dev", "--runner-id", "f1-test"]), true, Some(4121), ME, false), None);
        // Not enrolled: there's no service of this config to collide with.
        assert_eq!(second_runner(&bare, false, Some(4121), ME, false), None);
    }

    #[test]
    fn refusal_says_what_to_do() {
        assert_eq!(
            second_runner_message("mbp-14", 4121),
            "maple-runner: the service is already running as mbp-14 (pid 4121).\n  \
             maple-runner status     what it's doing\n  \
             maple-runner restart    restart it\n  \
             maple-runner --force    run here anyway (the service will stop)"
        );
    }

    /// Frames `gap` apart, `n` of them, then nothing ever again (a half-open socket).
    fn frames(n: usize, gap: Duration) -> impl futures_util::Stream<Item = usize> + Unpin {
        Box::pin(futures_util::stream::unfold(0, move |i| async move {
            if i == n {
                std::future::pending::<()>().await;
            }
            tokio::time::sleep(gap).await;
            Some((i, i + 1))
        }))
    }

    #[tokio::test]
    async fn quiet_hub_drops_the_connection() {
        let limit = Duration::from_millis(150);
        let mut stream = frames(4, Duration::from_millis(50));
        let mut hub = Quiet::new(limit);
        let start = tokio::time::Instant::now();
        // Each frame restarts the clock, so four frames over 200ms (longer than the limit) all arrive.
        for i in 0..4 {
            assert_eq!(hub.next(&mut stream).await, Ok(Some(i)));
        }
        assert!(start.elapsed() > limit);
        // Then silence: it gives up one limit after the last frame.
        let last = tokio::time::Instant::now();
        assert_eq!(hub.next(&mut stream).await, Err(Silent));
        let waited = last.elapsed();
        assert!(waited >= limit && waited < limit * 3, "{waited:?}");
    }

    #[tokio::test]
    async fn closed_stream_is_not_silence() {
        let mut stream = futures_util::stream::empty::<()>();
        assert_eq!(Quiet::new(Duration::from_secs(60)).next(&mut stream).await, Ok(None));
    }
}
