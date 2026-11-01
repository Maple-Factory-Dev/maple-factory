//! Evidence for a task's Done when items: the runner's half of the `prove` tool.
//!
//! A builder calls `prove` with the item's number, the kind, a summary and either text or a file.
//! A file must sit in the session's own proof folder, `~/.cache/maple-proof/<branch>/` (never in the
//! worktree, where it would be committed). Before the call goes on to the hub, the runner checks the
//! file, uploads it over HTTP with its own token (`PUT /runner/proof/<task>`, control/src/proof.ts)
//! and puts the stored key in its place, with the worktree's HEAD. The hub checks the rest and keeps
//! the row.
//!
//! Before a task with evidence is pushed, the runner adds its own: the project's test commands, run
//! in the worktree (`task.prove`, see "checks" below), then screenshots of the project's screens
//! that the diff touches (see "screens" below).

use std::path::{Path, PathBuf};
use std::sync::{LazyLock, OnceLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::process::Command;
use uuid::Uuid;

use crate::protocol::Outbound;
use crate::sessions::{Sessions, expand_home};

/// One file's bytes (the control plane's limit): a screenshot or text capture, full-size Retina ones too.
pub const MAX_FILE: u64 = 20 * 1024 * 1024;
/// A screen recording's bytes (MP4, MOV or WebM).
pub const MAX_VIDEO: u64 = 95 * 1024 * 1024;
/// What a session's task is: kept on its tmux session (`@maple_task`) so a restarted runner knows too.
#[derive(Debug, Clone, PartialEq)]
pub struct TaskTag {
    pub id: String,
    pub branch: String,
}

impl TaskTag {
    /// `<task id> <branch>`, as `@maple_task` holds it (a branch has no spaces).
    pub fn to_meta(&self) -> String {
        format!("{} {}", self.id, self.branch)
    }

    pub fn parse(meta: &str) -> Option<Self> {
        let (id, branch) = meta.trim().split_once(' ')?;
        (!id.is_empty() && !branch.is_empty() && !branch.contains(' ')).then(|| Self { id: id.into(), branch: branch.into() })
    }
}

/// Where the control plane is and who this runner is, for uploads.
struct Origin {
    base: String,
    runner_id: String,
    token: String,
}

static ORIGIN: OnceLock<Origin> = OnceLock::new();

pub(crate) static CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    crate::http_client()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(50))
        .build()
        .expect("building the HTTP client")
});

/// Remembers the control plane (its ws:// or http:// URL) and this runner's token.
pub fn configure(url: &str, runner_id: &str, token: &str) {
    if let Ok(base) = crate::config::base_url(url) {
        let _ = ORIGIN.set(Origin { base, runner_id: runner_id.into(), token: token.into() });
    }
}

/// The control plane's base URL, this runner's id and its token, once `configure` has run (images.rs uses them too).
pub(crate) fn origin() -> Option<(&'static str, &'static str, &'static str)> {
    ORIGIN.get().map(|o| (o.base.as_str(), o.runner_id.as_str(), o.token.as_str()))
}

/// `~/.cache/maple-proof/<branch>/`: a branch's slashes stay folders.
pub fn folder(home: &Path, branch: &str) -> PathBuf {
    home.join(".cache/maple-proof").join(branch)
}

// ---- forgetting proof folders ----
//
// A task's folder goes once its worktree is cleaned up (`task.cleanup`, tasks.rs): its files were
// uploaded long before. Folders nothing cleans up (a task that failed, one cleaned up by hand) go 14 days
// after anything in them last changed, when the runner starts and then daily.

/// A proof folder untouched this long is removed by the sweep.
pub const KEEP_FOLDER: Duration = Duration::from_secs(14 * 86_400);
const DAY: Duration = Duration::from_secs(86_400);

/// Removes `branch`'s proof folder, and the folders above it that are left empty (never `maple-proof` itself).
/// A branch that would lead out of `maple-proof` is ignored. Returns whether there was one.
pub fn forget_folder(home: &Path, branch: &str) -> std::io::Result<bool> {
    if branch.is_empty() || branch.starts_with('/') || branch.split('/').any(|c| c.is_empty() || c == "." || c == "..") {
        return Ok(false);
    }
    let root = home.join(".cache/maple-proof");
    let dir = root.join(branch);
    match std::fs::symlink_metadata(&dir) {
        Ok(m) if m.is_dir() => std::fs::remove_dir_all(&dir)?,
        Ok(_) => std::fs::remove_file(&dir)?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(e),
    }
    let mut parent = dir.parent().map(Path::to_path_buf);
    while let Some(p) = parent {
        if p == root || !p.starts_with(&root) || std::fs::remove_dir(&p).is_err() {
            break;
        }
        parent = p.parent().map(Path::to_path_buf);
    }
    Ok(true)
}

/// The newest modification time of `path` and, for a folder, everything in it (symlinks aren't followed).
pub(crate) fn newest(path: &Path) -> Option<std::time::SystemTime> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    let mut at = meta.modified().ok()?;
    if meta.is_dir() {
        for entry in std::fs::read_dir(path).ok()?.flatten() {
            if let Some(t) = newest(&entry.path()) {
                at = at.max(t);
            }
        }
    }
    Some(at)
}

/// Removes what under `~/.cache/maple-proof` hasn't changed for `KEEP_FOLDER` before `now`. A folder that
/// holds files is one task's and goes whole; one that holds only folders (`agent/`) is looked into.
/// Returns what it removed.
pub fn sweep(home: &Path, now: std::time::SystemTime) -> Vec<PathBuf> {
    let mut removed = Vec::new();
    if let Some(cutoff) = now.checked_sub(KEEP_FOLDER) {
        sweep_dir(&home.join(".cache/maple-proof"), cutoff, &mut removed);
    }
    removed
}

fn sweep_dir(dir: &Path, cutoff: std::time::SystemTime, removed: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        if newest(&path).is_some_and(|t| t < cutoff) {
            let gone = if meta.is_dir() { std::fs::remove_dir_all(&path) } else { std::fs::remove_file(&path) };
            if gone.is_ok() {
                removed.push(path);
            }
        } else if meta.is_dir() && only_folders(&path) {
            sweep_dir(&path, cutoff, removed);
        }
    }
}

/// Whether a folder holds nothing but folders (a branch's leading part, like `agent/`).
fn only_folders(dir: &Path) -> bool {
    std::fs::read_dir(dir).is_ok_and(|entries| entries.flatten().all(|e| e.file_type().is_ok_and(|t| t.is_dir())))
}

/// The sweep, when the runner starts and then daily.
pub async fn sweep_daily() {
    loop {
        if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
            let removed = tokio::task::spawn_blocking(move || sweep(&home, std::time::SystemTime::now())).await.unwrap_or_default();
            for p in removed {
                tracing::info!("removed old proof folder {}", p.display());
            }
        }
        tokio::time::sleep(DAY).await;
    }
}

/// A file that passed `check_file`.
#[derive(Debug, PartialEq)]
pub struct Checked {
    pub path: PathBuf,
    /// The name it's stored under: `[A-Za-z0-9._-]{1,80}`.
    pub name: String,
    pub kind: &'static str,
    pub bytes: Vec<u8>,
}

/// Checks the file a `prove` call names: `~` expanded and symlinks resolved, it must be inside
/// `folder`, and PNG, JPEG, WebP or text (at most 20 MB) or MP4, MOV or WebM (at most 95 MB). The message says what to do instead.
pub fn check_file(file: &str, home: &Path, folder: &Path) -> Result<Checked, String> {
    let (path, bytes) = read_in_folder(file, home, folder, "Evidence files", MAX_VIDEO, |len| {
        format!("{file} is {} MB; a video is at most 95 MB and any other file at most 20 MB. Record a shorter clip.", len / 1024 / 1024)
    })?;
    let kind = sniff(&bytes).ok_or_else(|| {
        format!(
            "{file} isn't PNG, JPEG, WebP, MP4, MOV, WebM or text. Save screenshots as PNG, recordings as MP4, and output as a .txt file (or pass it as text)."
        )
    })?;
    if !kind.starts_with("video/") && bytes.len() as u64 > MAX_FILE {
        return Err(format!(
            "{file} is {} KB; a screenshot or text file is at most 20 MB. Save a smaller one (a PNG of one screen, or the end of the output).",
            bytes.len() / 1024
        ));
    }
    let name = path.file_name().map(|n| stored_name(&n.to_string_lossy())).unwrap_or_else(|| "evidence".into());
    Ok(Checked { path, name, kind, bytes })
}

/// A file a tool call names, read: `~` expanded and symlinks resolved, it must be a non-empty file
/// inside `folder` and at most `max` bytes (`too_big` says so otherwise). `what` names the files in
/// the message for one outside the folder.
fn read_in_folder(file: &str, home: &Path, folder: &Path, what: &str, max: u64, too_big: impl Fn(u64) -> String) -> Result<(PathBuf, Vec<u8>), String> {
    let shown = folder.strip_prefix(home).map(|p| format!("~/{}/", p.display())).unwrap_or_else(|_| format!("{}/", folder.display()));
    let file = file.trim();
    let given = match file.strip_prefix("~/") {
        Some(rest) => home.join(rest),
        None => PathBuf::from(file),
    };
    if !given.is_absolute() {
        return Err(format!("file must be a full path under {shown} (like {shown}tasks-390.png)."));
    }
    let path = std::fs::canonicalize(&given).map_err(|_| format!("There's no file at {file}. Save it under {shown} first."))?;
    let inside = std::fs::canonicalize(folder).is_ok_and(|f| path.starts_with(&f) && path != f);
    if !inside {
        return Err(format!("{what} go under {shown} (this task's proof folder, outside the worktree); {file} isn't there."));
    }
    let meta = std::fs::metadata(&path).map_err(|e| format!("Couldn't read {file}: {e}"))?;
    if !meta.is_file() {
        return Err(format!("{file} isn't a file."));
    }
    if meta.len() > max {
        return Err(too_big(meta.len()));
    }
    let bytes = std::fs::read(&path).map_err(|e| format!("Couldn't read {file}: {e}"))?;
    if bytes.is_empty() {
        return Err(format!("{file} is empty."));
    }
    Ok((path, bytes))
}

/// An artifact file's bytes (the control plane's `MAX_ARTIFACT`).
pub const MAX_ARTIFACT: u64 = 10 * 1024 * 1024;

/// Checks the file a `share_artifact` call names: inside `folder` like a proof (`read_in_folder`), at
/// most 10 MB, and one of the kinds `sniff_artifact` knows.
pub fn check_artifact(file: &str, home: &Path, folder: &Path) -> Result<Checked, String> {
    let (path, bytes) = read_in_folder(file, home, folder, "Artifact files", MAX_ARTIFACT, |len| {
        format!("{file} is {} MB; an artifact is at most 10 MB. Save a smaller one.", len / 1024 / 1024)
    })?;
    let name = path.file_name().map(|n| stored_name(&n.to_string_lossy())).unwrap_or_else(|| "artifact".into());
    let kind = sniff_artifact(&bytes, &name)
        .ok_or_else(|| format!("{file} isn't HTML, SVG, PNG, JPEG, WebP, GIF, PDF, Markdown, CSV, JSON or text. Save a chart as HTML, SVG or PNG."))?;
    Ok(Checked { path, name, kind, bytes })
}

/// What an artifact file is, from its first bytes and (for text) its name, as the control plane decides
/// it (`sniffArtifact` in server/src/attachments.ts). Text that isn't a named kind is plain text.
pub fn sniff_artifact(b: &[u8], name: &str) -> Option<&'static str> {
    if b.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]) {
        return Some("image/png");
    }
    if b.starts_with(&[0xff, 0xd8, 0xff]) {
        return Some("image/jpeg");
    }
    if b.starts_with(b"RIFF") && b.get(8..12) == Some(b"WEBP") {
        return Some("image/webp");
    }
    if b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if b.starts_with(b"%PDF-") {
        return Some("application/pdf");
    }
    if b.contains(&0) {
        return None;
    }
    let text = std::str::from_utf8(b).ok()?;
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    let head: String = text.chars().take(1024).collect::<String>().trim_start().trim_start_matches('\u{feff}').to_ascii_lowercase();
    Some(if ext == "svg" || head.starts_with("<svg") || (head.starts_with("<?xml") && head.contains("<svg")) {
        "image/svg+xml"
    } else if ext == "html" || ext == "htm" || head.starts_with("<!doctype html") || head.starts_with("<html") {
        "text/html"
    } else if ext == "md" || ext == "markdown" {
        "text/markdown"
    } else if ext == "csv" {
        "text/csv"
    } else if ext == "json" {
        "application/json"
    } else {
        "text/plain"
    })
}

/// A file's name as the control plane takes it: other characters become `-`, at most 80 kept.
fn stored_name(name: &str) -> String {
    let clean: String = name.chars().map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') { c } else { '-' }).collect();
    let clean: String = clean.chars().rev().take(80).collect::<Vec<_>>().into_iter().rev().collect();
    if clean.is_empty() { "evidence".into() } else { clean }
}

/// What a file is from its first bytes, as the control plane decides it (`sniff` in proof.ts).
pub fn sniff(b: &[u8]) -> Option<&'static str> {
    if b.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]) {
        Some("image/png")
    } else if b.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("image/jpeg")
    } else if b.starts_with(b"RIFF") && b.get(8..12) == Some(b"WEBP") {
        Some("image/webp")
    } else if b.get(4..8) == Some(b"ftyp") {
        match b.get(8..12) {
            Some(b"qt  ") => Some("video/quicktime"),
            // Audio only.
            Some(b"M4A " | b"M4B " | b"M4P ") => None,
            _ => Some("video/mp4"),
        }
    } else if b.starts_with(&[0x1a, 0x45, 0xdf, 0xa3]) {
        Some("video/webm")
    } else if !b.contains(&0) && std::str::from_utf8(b).is_ok() {
        Some("text/plain")
    } else {
        None
    }
}

/// Uploads one file for a task; the answer is the control plane's `{key, type, bytes}`.
async fn upload(base: &str, runner_id: &str, token: &str, task_id: &str, file: &Checked) -> Result<Value, String> {
    upload_to(base, "proof", runner_id, token, task_id, file).await
}

/// Uploads one file to `/runner/<route>/<task>`: `proof` or `artifact`.
async fn upload_to(base: &str, route: &str, runner_id: &str, token: &str, task_id: &str, file: &Checked) -> Result<Value, String> {
    let mut url = reqwest::Url::parse(&format!("{base}/runner/{route}/{task_id}")).map_err(|e| format!("The control plane's URL is wrong: {e}"))?;
    url.query_pairs_mut().append_pair("runner", runner_id).append_pair("name", &file.name);
    let res = CLIENT
        .put(url)
        // A 95 MB recording over a slow uplink takes longer than the client's usual 50 s.
        .timeout(Duration::from_secs(300))
        .bearer_auth(token)
        .header("content-type", file.kind)
        .body(file.bytes.clone())
        .send()
        .await
        .map_err(|e| format!("Couldn't upload {}: {e}", file.name))?;
    let status = res.status();
    let body = res.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(format!("The control plane refused {}: {}", file.name, body.trim()));
    }
    let answer: Value = serde_json::from_str(&body).map_err(|_| "The control plane's answer to the upload wasn't understood.".to_string())?;
    match answer.get("key").and_then(Value::as_str) {
        Some(_) => Ok(answer),
        None => Err("The control plane's answer to the upload had no key.".into()),
    }
}

/// The worktree's HEAD, if it has one.
async fn head(dir: &Path) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(dir).args(["rev-parse", "HEAD"]).env("GIT_OPTIONAL_LOCKS", "0").output().await.ok()?;
    let sha = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && sha.len() >= 7 && sha.bytes().all(|c| c.is_ascii_hexdigit())).then_some(sha)
}

/// A `prove` call on its way to the hub: a file is checked and uploaded and its key put in its
/// place, and `head` is added. A session that isn't running a task goes on as it is (the hub says no).
pub async fn prepare(sessions: &Sessions, session: Uuid, args: Value) -> Result<Value, String> {
    let home = expand_home("~");
    let Some((tag, cwd)) = sessions.task_of(session) else {
        if args.get("file").is_some_and(|f| !f.is_null()) {
            return Err(
                "prove is for a task's own session, and this session isn't running a task (or it started before this runner could attach files).".into()
            );
        }
        return Ok(args);
    };
    prepare_with(args, &tag, &expand_home(&cwd), &home, origin()).await
}

async fn prepare_with(mut args: Value, tag: &TaskTag, worktree: &Path, home: &Path, origin: Option<(&str, &str, &str)>) -> Result<Value, String> {
    match args.get("file") {
        None | Some(Value::Null) => {}
        Some(Value::String(file)) => {
            let checked = check_file(file, home, &folder(home, &tag.branch))?;
            let (base, runner_id, token) = origin.ok_or("The runner doesn't know its control plane, so it can't upload files.")?;
            let stored = upload(base, runner_id, token, &tag.id, &checked).await?;
            args["file"] = json!({ "key": stored["key"], "name": checked.name, "type": stored["type"], "bytes": stored["bytes"] });
        }
        Some(_) => return Err("file must be the path of a file under the task's proof folder.".into()),
    }
    if let Some(sha) = head(worktree).await {
        args["head"] = json!(sha);
    }
    Ok(args)
}

/// A `share_artifact` call on its way to the hub: its file is checked and uploaded to
/// `/runner/artifact/<task>`, and the stored `{key, name, type, bytes}` put in its place.
pub async fn prepare_artifact(sessions: &Sessions, session: Uuid, args: Value) -> Result<Value, String> {
    let Some((tag, _)) = sessions.task_of(session) else {
        return Err(
            "share_artifact is for a task's own session, and this session isn't running a task (or it started before this runner could attach files).".into()
        );
    };
    prepare_artifact_with(args, &tag, &expand_home("~"), origin()).await
}

async fn prepare_artifact_with(mut args: Value, tag: &TaskTag, home: &Path, origin: Option<(&str, &str, &str)>) -> Result<Value, String> {
    let Some(Value::String(file)) = args.get("file") else {
        return Err("file must be the full path of a file under the task's proof folder.".into());
    };
    let checked = check_artifact(file, home, &folder(home, &tag.branch))?;
    let (base, runner_id, token) = origin.ok_or("The runner doesn't know its control plane, so it can't upload files.")?;
    let stored = upload_to(base, "artifact", runner_id, token, &tag.id, &checked).await?;
    args["file"] = json!({ "key": stored["key"], "name": checked.name, "type": stored["type"], "bytes": stored["bytes"] });
    Ok(args)
}

// ---- checks: the project's test commands, before the push ----
//
// Once every item has evidence, the hub sends `task.prove` instead of `task.finish`. The runner
// fetches the base branch again, takes the project's settings with `.factory.toml` as it is there
// (`factory::settings_at`, never the branch's copy), and runs each `test` command with `sh -c` in
// the worktree, one after another, until one fails. Each runs in its own process group, which is
// killed when the command ends (so nothing it started stays behind) or after 10 minutes. The hub
// hears which command is running (`task.check`) and then every result (`task.proved`), and turns
// each into a `command` row.

/// How long one check may run.
pub const CHECK_TIMEOUT: Duration = Duration::from_secs(600);
/// The lines of a check's output that are kept: its end.
pub const TAIL_LINES: usize = 200;
/// A line longer than this is cut; the whole tail is at most `TAIL_BYTES`.
const LINE_CHARS: usize = 500;
const TAIL_BYTES: usize = 60 * 1024;

/// `task.prove` from the hub.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Prove {
    pub task_id: String,
    /// The worktree, `~`-abbreviated.
    pub cwd: String,
    /// The branch the PR goes into (None: GitHub's default).
    #[serde(default)]
    pub base: Option<String>,
    #[serde(default)]
    pub projects: Vec<crate::factory::Project>,
}

/// How one check went.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckResult {
    pub command: String,
    /// The exit code; None when it was killed (a signal, or the time limit).
    pub code: Option<i32>,
    pub ms: u64,
    pub timed_out: bool,
    /// The output's last 200 lines, stdout and stderr together.
    pub tail: String,
}

impl CheckResult {
    pub fn passed(&self) -> bool {
        self.code == Some(0) && !self.timed_out
    }
}

/// Tasks whose checks are running here, so a `task.prove` sent again on hello doesn't start a second run.
static PROVING: LazyLock<std::sync::Mutex<std::collections::HashSet<String>>> = LazyLock::new(Default::default);

/// Runs a task's checks and answers with `task.proved`.
pub async fn run_prove(sessions: Sessions, p: Prove) {
    if !PROVING.lock().unwrap().insert(p.task_id.clone()) {
        tracing::info!("task {}: its checks are already running", p.task_id);
        return;
    }
    let emit = |m: Outbound| sessions.emit(m);
    let fetch = std::env::var(crate::tasks::FETCH_URL_ENV).ok();
    let origin = ORIGIN.get().map(|o| (o.base.as_str(), o.runner_id.as_str(), o.token.as_str()));
    let ports = || sessions.spare_ports().map_err(|e| format!("{e:#}"));
    let shots = Shots { home: expand_home("~"), origin, ports: &ports, capture: &playwright, install: Some(&install_once), ready_limit: READY_TIMEOUT };
    let msg = prove_task(&emit, &p, fetch.as_deref(), login_path().await.as_deref(), CHECK_TIMEOUT, Some(&shots)).await;
    PROVING.lock().unwrap().remove(&p.task_id);
    sessions.emit(msg);
}

async fn prove_task(
    emit: crate::tasks::Emit<'_>,
    p: &Prove,
    fetch_override: Option<&str>,
    path: Option<&str>,
    limit: Duration,
    shots: Option<&Shots<'_>>,
) -> Outbound {
    let proved =
        |results, not_run, screens, head, error: Option<String>| Outbound::TaskProved { task_id: p.task_id.clone(), results, not_run, screens, head, error };
    let dir = expand_home(&p.cwd);
    if !dir.is_dir() {
        return proved(vec![], vec![], vec![], None, Some(format!("The task's worktree {} is gone.", p.cwd)));
    }
    // The base as it is on GitHub now: what the checks are is read from there.
    let base = match crate::tasks::fetch_base(emit, &p.task_id, &dir, p.base.as_deref(), None, fetch_override).await {
        Ok(b) => b,
        Err(e) => return proved(vec![], vec![], vec![], None, Some(format!("{e:#}"))),
    };
    let base = format!("origin/{base}");
    let settings = crate::factory::settings_at(&dir, &base, &p.projects).await.unwrap_or_default();
    let commands: Vec<String> = settings.test.clone().unwrap_or_default().lines().map(str::trim).filter(|l| !l.is_empty()).map(String::from).collect();
    let total = commands.len();
    let (results, not_run) = run_checks(&dir, &commands, path, limit, |n, command| {
        tracing::info!("task {}: check {n} of {total}: {command}", p.task_id);
        emit(Outbound::TaskCheck { task_id: p.task_id.clone(), command: command.to_string(), n, of: total });
    })
    .await;
    // Screens only once every check passed: a failure goes back to the builder first.
    let screens = match shots {
        Some(shots) if not_run.is_empty() && results.iter().all(CheckResult::passed) => {
            capture_screens(emit, &p.task_id, &dir, &settings, &base, path, shots).await
        }
        _ => vec![],
    };
    proved(results, not_run, screens, head(&dir).await, None)
}

/// Runs `commands` in `dir` one after another and stops at the first that fails; the results, and
/// the commands that didn't run. `started` hears each one (numbered from 1) as it starts.
pub async fn run_checks(
    dir: &Path,
    commands: &[String],
    path: Option<&str>,
    limit: Duration,
    started: impl Fn(usize, &str),
) -> (Vec<CheckResult>, Vec<String>) {
    let mut results = Vec::new();
    for (i, command) in commands.iter().enumerate() {
        started(i + 1, command);
        let result = run_check(dir, command, path, limit).await;
        let passed = result.passed();
        results.push(result);
        if !passed {
            return (results, commands[i + 1..].to_vec());
        }
    }
    (results, vec![])
}

/// One check: `sh -c <command>` in `dir`, in a process group of its own, with stdout and stderr
/// together and only their end kept. The group is killed once the command ends, or at `limit`.
pub async fn run_check(dir: &Path, command: &str, path: Option<&str>, limit: Duration) -> CheckResult {
    run_check_env(dir, command, path, &[], limit).await
}

/// `run_check` with `env` added to the command's environment.
pub async fn run_check_env(dir: &Path, command: &str, path: Option<&str>, env: &[(String, String)], limit: Duration) -> CheckResult {
    let began = std::time::Instant::now();
    let mut cmd = Command::new("sh");
    // `exec 2>&1` first, so both streams come through one pipe, in order.
    cmd.arg("-c").arg(format!("exec 2>&1\n{command}")).current_dir(dir).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped());
    cmd.process_group(0).kill_on_drop(true);
    if let Some(p) = path {
        cmd.env("PATH", p);
    }
    for var in crate::agents::INHERITED_SESSION_MARKERS {
        cmd.env_remove(var);
    }
    cmd.envs(env.iter().map(|(k, v)| (k, v)));
    let ms = |b: std::time::Instant| b.elapsed().as_millis() as u64;
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return CheckResult { command: command.into(), code: None, ms: ms(began), timed_out: false, tail: format!("Couldn't start sh: {e}") },
    };
    let group = child.id().map(|id| id as i32);
    let reader = child.stdout.take().map(|out| tokio::spawn(tail_of(out)));
    let waited = tokio::time::timeout(limit, child.wait()).await;
    // Whatever it left running goes too (and with it, the pipe's other ends).
    if let Some(g) = group {
        unsafe { libc::killpg(g, libc::SIGKILL) };
    }
    let (code, timed_out) = match waited {
        Ok(Ok(status)) => (status.code(), false),
        Ok(Err(_)) => (None, false),
        Err(_) => {
            let _ = child.kill().await;
            (None, true)
        }
    };
    let elapsed = ms(began);
    let mut tail = match reader {
        Some(r) => tokio::time::timeout(Duration::from_secs(5), r).await.ok().and_then(Result::ok).unwrap_or_default(),
        None => String::new(),
    };
    if timed_out {
        let after = if limit.as_secs() >= 60 { format!("{} minutes", limit.as_secs() / 60) } else { format!("{} seconds", limit.as_secs()) };
        tail.push_str(&format!("{}Stopped after {after}.", if tail.is_empty() { "" } else { "\n" }));
    }
    CheckResult { command: command.into(), code, ms: elapsed, timed_out, tail }
}

/// The last `TAIL_LINES` lines read, each cut at `LINE_CHARS`, and at most `TAIL_BYTES` in all.
async fn tail_of(out: tokio::process::ChildStdout) -> String {
    use tokio::io::AsyncBufReadExt;
    let mut reader = tokio::io::BufReader::new(out);
    let mut lines = std::collections::VecDeque::with_capacity(TAIL_LINES);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                let line = String::from_utf8_lossy(&buf);
                let line = line.trim_end_matches(['\n', '\r']);
                if lines.len() == TAIL_LINES {
                    lines.pop_front();
                }
                lines.push_back(line.chars().take(LINE_CHARS).collect::<String>());
            }
        }
    }
    let mut size: usize = lines.iter().map(|l| l.len() + 1).sum();
    while size > TAIL_BYTES
        && let Some(l) = lines.pop_front()
    {
        size -= l.len() + 1;
    }
    Vec::from(lines).join("\n")
}

/// The PATH of the user's login shell, so checks find what a terminal would (`npm`, `cargo`) even
/// when the runner is started by launchd. Read once.
pub(crate) async fn login_path() -> Option<String> {
    static PATH: tokio::sync::OnceCell<Option<String>> = tokio::sync::OnceCell::const_new();
    PATH.get_or_init(|| async {
        const MARK: &str = "__maple_path__=";
        let shell = crate::agents::login_shell();
        let out = Command::new(&shell)
            .args(["-l", "-i", "-c", &format!("printf '\\n{MARK}%s\\n' \"$PATH\"")])
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .output();
        let out = tokio::time::timeout(Duration::from_secs(10), out).await.ok()?.ok()?;
        String::from_utf8_lossy(&out.stdout).lines().find_map(|l| l.strip_prefix(MARK)).map(str::to_string).filter(|p| !p.is_empty())
    })
    .await
    .clone()
}

// ---- screens: the project's routes that the diff touches, captured with Playwright ----
//
// Once the checks pass, a project with the `screen` proof kind, a `dev` command and `screens` gets
// screenshots too. Each `screens` line that starts with `/` or `#` is a route, followed by the globs
// of the files it shows (`#tasks web/src/tasks.ts web/src/style.css`). A route is captured when the
// task changed one of those files, or on every task when it lists none; any other line is prose for
// the prompt, except `widths 1280 390`, the widths to capture at (those two by default). The runner
// starts `dev` in the worktree on two fresh ports (`PORT`, `MAPLE_API_PORT`) in a process group of its
// own, waits for `http://localhost:$PORT/`, screenshots each route at each width with a pinned
// Playwright run through npx, uploads them as `screen` rows for item 0, and always stops the group.
// A dev server that never answers, or a machine without Playwright's browser, is one `command` row
// that says why. Screens never hold up the push: the builder's own evidence is what the gate counts.

/// The Playwright the runner runs (`npx --yes playwright@<this>`); each machine installs its Chromium once.
pub const PLAYWRIGHT: &str = "1.63.0";
/// How long `dev` gets to answer on `http://localhost:$PORT/`.
pub const READY_TIMEOUT: Duration = Duration::from_secs(60);
/// How long one screenshot may take (npx fetches Playwright the first time).
const CAPTURE_TIMEOUT: Duration = Duration::from_secs(180);
/// Widths captured when the project names none.
pub const DEFAULT_WIDTHS: [u32; 2] = [1280, 390];
/// The dev log's lines kept in a row that says why there are no screens.
const DEV_LOG_LINES: usize = 50;

/// The install command a machine without Playwright's browser needs.
pub fn install_command() -> String {
    format!("npx --yes playwright@{PLAYWRIGHT} install chromium")
}

/// The command that installs the system libraries Playwright's Chromium needs (Linux; needs root).
pub fn install_deps_command() -> String {
    format!("npx --yes playwright@{PLAYWRIGHT} install-deps chromium")
}

/// How long installing Playwright's Chromium may take (a download of a couple hundred MB).
const INSTALL_TIMEOUT: Duration = Duration::from_secs(600);

/// The runner installs Playwright's browser itself, once per run, the first time a screenshot finds
/// it missing, so a new machine needs no one at its keyboard; a failed install isn't tried again
/// until the runner restarts.
fn install_once() -> Option<String> {
    static TRIED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    (!TRIED.swap(true, std::sync::atomic::Ordering::SeqCst)).then(install_command)
}

fn missing_browser(tail: &str) -> bool {
    tail.contains("Executable doesn't exist") || tail.contains("playwright install")
}

/// The project's `screens` setting, read: each route with its globs, and the widths.
#[derive(Debug, PartialEq)]
pub struct ScreenSpec {
    pub routes: Vec<(String, Vec<String>)>,
    pub widths: Vec<u32>,
}

pub fn parse_screens(setting: &str) -> ScreenSpec {
    let mut routes = Vec::new();
    let mut widths = Vec::new();
    for line in setting.lines() {
        let mut words = line.split_whitespace();
        let Some(first) = words.next() else { continue };
        if first.starts_with('/') || first.starts_with('#') {
            routes.push((first.to_string(), words.map(String::from).collect()));
        } else if first.trim_end_matches(':').eq_ignore_ascii_case("widths") {
            // `widths 1280 390`, `widths: 1280px, 390px`; a line with anything else is prose.
            let nums: Option<Vec<u32>> = words
                .flat_map(|w| w.split(','))
                .filter(|w| !w.is_empty())
                .map(|w| w.trim_end_matches("px").parse().ok().filter(|n| (200..=4000).contains(n)))
                .collect();
            if let Some(nums) = nums.filter(|n| !n.is_empty()) {
                widths = nums;
            }
        }
    }
    widths.dedup();
    ScreenSpec { routes, widths: if widths.is_empty() { DEFAULT_WIDTHS.to_vec() } else { widths } }
}

/// The routes to capture for a task that changed `changed`: those with a glob that matches one of
/// them, and those with no globs at all.
pub fn screens_for(setting: &str, changed: &[String]) -> Vec<String> {
    parse_screens(setting)
        .routes
        .into_iter()
        .filter(|(_, globs)| globs.is_empty() || globs.iter().any(|g| changed.iter().any(|c| glob_match(g, c))))
        .map(|(route, _)| route)
        .collect()
}

/// Whether `path` matches `glob`, as `globMatch` in control/src/card-format.ts: `**` is any run of
/// characters (slashes too), `*` any run within one part of the path, `?` one character. A trailing
/// `/**` also matches the folder itself, and a glob with no slash matches a file of that name in any folder.
pub fn glob_match(glob: &str, path: &str) -> bool {
    enum Tok {
        Char(char),
        One,
        Star,
        Any,
        /// `**/`: any number of folders, none included.
        Dirs,
        /// A final `/**`: the folder itself, or anything in it.
        Within,
    }
    fn matches(t: &[Tok], s: &[char]) -> bool {
        match t.first() {
            None => s.is_empty(),
            Some(Tok::Char(c)) => s.first() == Some(c) && matches(&t[1..], &s[1..]),
            Some(Tok::One) => s.first().is_some_and(|c| *c != '/') && matches(&t[1..], &s[1..]),
            Some(Tok::Star) => (0..=s.len()).take_while(|&i| i == 0 || s[i - 1] != '/').any(|i| matches(&t[1..], &s[i..])),
            Some(Tok::Any) => (0..=s.len()).any(|i| matches(&t[1..], &s[i..])),
            Some(Tok::Dirs) => matches(&t[1..], s) || (0..s.len()).any(|i| s[i] == '/' && matches(&t[1..], &s[i + 1..])),
            Some(Tok::Within) => s.first().is_none_or(|c| *c == '/'),
        }
    }
    let clean = |s: &str| {
        let s = s.trim();
        s.strip_prefix("./").or_else(|| s.strip_prefix('/')).unwrap_or(s).to_string()
    };
    let (g, p) = (clean(glob), clean(path));
    if g.is_empty() {
        return false;
    }
    let chars: Vec<char> = g.chars().collect();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            '*' if chars.get(i + 1) == Some(&'*') => {
                if i + 2 == chars.len() && i > 0 && chars[i - 1] == '/' {
                    toks.pop();
                    toks.push(Tok::Within);
                    i += 2;
                } else if chars.get(i + 2) == Some(&'/') {
                    toks.push(Tok::Dirs);
                    i += 3;
                } else {
                    toks.push(Tok::Any);
                    i += 2;
                }
            }
            '*' => {
                toks.push(Tok::Star);
                i += 1;
            }
            '?' => {
                toks.push(Tok::One);
                i += 1;
            }
            c => {
                toks.push(Tok::Char(c));
                i += 1;
            }
        }
    }
    let path: Vec<char> = p.chars().collect();
    let name: Vec<char> = p.rsplit('/').next().unwrap_or("").chars().collect();
    matches(&toks, &path) || (!g.contains('/') && matches(&toks, &name))
}

/// A piece of the runner's screen evidence, for `task.proved`: a screenshot it uploaded (`screen`,
/// with the file's key), or why there's none (`command`, with the reason as text).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ScreenProof {
    pub kind: &'static str,
    pub summary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// The key the control plane stored the file under.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

impl ScreenProof {
    fn note(summary: String, text: String) -> Self {
        Self { kind: "command", summary, text: Some(text), file: None }
    }
}

/// What capturing screens needs from the machine; tests stand in their own.
pub struct Shots<'a> {
    pub home: PathBuf,
    /// The control plane, this runner and its token, for uploads.
    pub origin: Option<(&'a str, &'a str, &'a str)>,
    /// Two free ports (`PORT`, `MAPLE_API_PORT`) no session holds.
    pub ports: &'a (dyn Fn() -> Result<(u16, u16), String> + Sync),
    /// The shell command that saves `url` at `width`×`height`, full page, as the PNG `out`.
    pub capture: &'a (dyn Fn(&str, u32, u32, &Path) -> String + Sync),
    /// The command that installs Playwright's browser, the first time a capture finds it missing
    /// (`None` from then on, or always: then the task gets a row saying what to run).
    pub install: Option<&'a (dyn Fn() -> Option<String> + Sync)>,
    pub ready_limit: Duration,
}

/// The pinned Playwright's screenshot command.
fn playwright(url: &str, width: u32, height: u32, out: &Path) -> String {
    format!(
        "npx --yes playwright@{PLAYWRIGHT} screenshot --browser=chromium --full-page --wait-for-timeout=1000 --viewport-size={width},{height} {} {}",
        quote(url),
        quote(&out.to_string_lossy())
    )
}

/// `s` as one word for `sh`.
fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// The viewport's height for a width: a laptop's below a phone's.
fn height_for(width: u32) -> u32 {
    if width >= 768 { 800 } else { 844 }
}

/// `#tasks` → `tasks`, `/settings/projects` → `settings-projects`, `/` → `home`.
fn slug(route: &str) -> String {
    let s: String = route.chars().map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' }).collect();
    let s: String = s.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-").chars().take(60).collect();
    if s.is_empty() { "home".into() } else { s }
}

/// The files a task changed against the base: committed, staged, unstaged and new, since the runner
/// captures before it commits.
async fn changed_files(dir: &Path, base: &str) -> Vec<String> {
    let git = |args: &[&str]| {
        let mut cmd = Command::new("git");
        cmd.arg("-C").arg(dir).args(args).env("GIT_OPTIONAL_LOCKS", "0").stdin(std::process::Stdio::null());
        cmd
    };
    let lines = |o: std::process::Output| -> Vec<String> {
        if !o.status.success() {
            return vec![];
        }
        String::from_utf8_lossy(&o.stdout).lines().map(str::trim).filter(|l| !l.is_empty()).map(String::from).collect()
    };
    let Some(fork) = git(&["merge-base", base, "HEAD"]).output().await.ok().map(lines).and_then(|l| l.into_iter().next()) else {
        return vec![];
    };
    let mut out = git(&["diff", "--name-only", &fork]).output().await.map(lines).unwrap_or_default();
    out.extend(git(&["ls-files", "--others", "--exclude-standard"]).output().await.map(lines).unwrap_or_default());
    out.sort();
    out.dedup();
    out
}

/// The worktree's branch (the task's), for its proof folder.
async fn branch_of(dir: &Path) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(dir).args(["symbolic-ref", "--short", "HEAD"]).env("GIT_OPTIONAL_LOCKS", "0").output().await.ok()?;
    let b = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !b.is_empty() && !b.contains("..")).then_some(b)
}

/// The last `n` lines of a file.
fn last_lines(path: &Path, n: usize) -> String {
    let text = std::fs::read(path).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
    let lines: Vec<&str> = text.lines().collect();
    lines[lines.len().saturating_sub(n)..].join("\n")
}

/// A process group to stop: SIGTERM, a moment to exit, then SIGKILL. Dropped without `stop` (a run
/// cut short), it's killed at once, so nothing stays behind either way.
struct Group(Option<i32>);

impl Group {
    async fn stop(mut self, child: &mut tokio::process::Child) {
        if let Some(g) = self.0.take() {
            unsafe { libc::killpg(g, libc::SIGTERM) };
            let _ = tokio::time::timeout(Duration::from_secs(5), child.wait()).await;
            unsafe { libc::killpg(g, libc::SIGKILL) };
        }
    }
}

impl Drop for Group {
    fn drop(&mut self) {
        if let Some(g) = self.0 {
            unsafe { libc::killpg(g, libc::SIGKILL) };
        }
    }
}

/// Starts `dev`, captures the routes the diff touches at each width, uploads them and stops `dev`.
/// Nothing when the project has no screens to capture, or none that this task touched.
async fn capture_screens(
    emit: crate::tasks::Emit<'_>,
    task_id: &str,
    dir: &Path,
    settings: &crate::factory::Settings,
    base: &str,
    path: Option<&str>,
    shots: &Shots<'_>,
) -> Vec<ScreenProof> {
    let set = |v: &Option<String>| v.as_deref().map(str::trim).filter(|v| !v.is_empty()).map(String::from);
    let screen = settings.proof_kinds.iter().flatten().any(|k| k == "screen");
    let (Some(dev), Some(setting), true) = (set(&settings.dev), set(&settings.screens), screen) else {
        return vec![];
    };
    let changed = changed_files(dir, base).await;
    let routes = screens_for(&setting, &changed);
    tracing::info!("task {task_id}: screens {routes:?}; the diff touches {}", changed.join(", "));
    if routes.is_empty() {
        return vec![];
    }
    let widths = parse_screens(&setting).widths;
    let branch = branch_of(dir).await.unwrap_or_else(|| task_id.to_string());
    let proof = folder(&shots.home, &branch);
    let out_dir = proof.join("runner");
    let _ = std::fs::remove_dir_all(&out_dir);
    if let Err(e) = std::fs::create_dir_all(&out_dir) {
        return vec![ScreenProof::note("Screens not captured: no proof folder".into(), format!("Couldn't make {}: {e}", out_dir.display()))];
    }
    let (web, api) = match (shots.ports)() {
        Ok(p) => p,
        Err(e) => return vec![ScreenProof::note("Screens not captured: no free ports".into(), format!("Couldn't find two free ports for `{dev}`: {e}"))],
    };
    let log_path = out_dir.join("dev.log");
    let log = match std::fs::File::create(&log_path).and_then(|f| Ok((f.try_clone()?, f))) {
        Ok(l) => l,
        Err(e) => return vec![ScreenProof::note("Screens not captured: no dev log".into(), format!("Couldn't write {}: {e}", log_path.display()))],
    };
    let started = format!("$ {dev}   (PORT={web} MAPLE_API_PORT={api})");
    let dev_log = || format!("{started}\n{}", last_lines(&log_path, DEV_LOG_LINES));

    // `dev`, in a process group of its own, its output to the log.
    emit(Outbound::TaskCheck { task_id: task_id.into(), command: dev.clone(), n: 1, of: 1 });
    let mut cmd = Command::new("sh");
    cmd.arg("-c").arg(&dev).current_dir(dir).stdin(std::process::Stdio::null()).stdout(log.0).stderr(log.1);
    cmd.env("PORT", web.to_string()).env("MAPLE_API_PORT", api.to_string()).process_group(0).kill_on_drop(true);
    if let Some(p) = path {
        cmd.env("PATH", p);
    }
    for var in crate::agents::INHERITED_SESSION_MARKERS {
        cmd.env_remove(var);
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return vec![ScreenProof::note("Screens not captured: dev didn't start".into(), format!("Couldn't start sh: {e}"))],
    };
    let group = Group(child.id().map(|id| id as i32));
    let base_url = format!("http://localhost:{web}");
    let began = std::time::Instant::now();
    let out = match wait_ready(&base_url, &mut child, shots.ready_limit).await {
        Err(why) => {
            vec![ScreenProof::note(format!("Screens not captured: `{dev}` {why}"), format!("`{dev}` {why}, so no screens were captured.\n\n{}", dev_log()))]
        }
        Ok(()) => {
            tracing::info!("task {task_id}: {base_url} ready in {:.1}s", began.elapsed().as_secs_f32());
            let at = Place { dir, base_url: &base_url, out_dir: &out_dir, proof: &proof, path };
            capture_routes(emit, task_id, &routes, &widths, &at, shots, &dev_log).await
        }
    };
    group.stop(&mut child).await;
    tracing::info!("task {task_id}: dev server stopped · {} screenshots", out.iter().filter(|r| r.kind == "screen").count());
    out
}

/// Waits until `url/` answers at all (any status), or says why it didn't: `dev` ended, or the time ran out.
async fn wait_ready(url: &str, child: &mut tokio::process::Child, limit: Duration) -> Result<(), String> {
    let deadline = std::time::Instant::now() + limit;
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            return Err(match status.code() {
                Some(code) => format!("exited (code {code}) before {url}/ answered"),
                None => format!("was stopped before {url}/ answered"),
            });
        }
        if CLIENT.get(format!("{url}/")).timeout(Duration::from_secs(2)).send().await.is_ok() {
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            return Err(format!("didn't answer on {url}/ in {} seconds", limit.as_secs()));
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

/// Where a task's screens are captured: the worktree, the dev server, and where the files go.
struct Place<'a> {
    dir: &'a Path,
    base_url: &'a str,
    /// `<proof>/runner/`.
    out_dir: &'a Path,
    /// The task's proof folder.
    proof: &'a Path,
    path: Option<&'a str>,
}

/// Each route at each width: saved, uploaded, and a row for each. A machine without Playwright's
/// browser is one row for them all.
async fn capture_routes(
    emit: crate::tasks::Emit<'_>,
    task_id: &str,
    routes: &[String],
    widths: &[u32],
    at: &Place<'_>,
    shots: &Shots<'_>,
    dev_log: &(dyn Fn() -> String + Sync),
) -> Vec<ScreenProof> {
    let mut out = Vec::new();
    let mut names = std::collections::HashSet::new();
    let of = routes.len() * widths.len();
    let mut n = 0;
    for route in routes {
        let mut name = slug(route);
        while !names.insert(name.clone()) {
            name.push('-');
        }
        for &width in widths {
            n += 1;
            let what = format!("{route} at {width}px");
            emit(Outbound::TaskCheck { task_id: task_id.into(), command: format!("screenshot {what}"), n, of });
            let url = if route.starts_with('#') { format!("{}/{route}", at.base_url) } else { format!("{}{route}", at.base_url) };
            let file = at.out_dir.join(format!("{name}-{width}.png"));
            let capture = (shots.capture)(&url, width, height_for(width), &file);
            let mut r = run_check(at.dir, &capture, at.path, CAPTURE_TIMEOUT).await;
            let mut installed = None;
            if !r.passed()
                && missing_browser(&r.tail)
                && let Some(install) = shots.install.and_then(|f| f())
            {
                emit(Outbound::TaskCheck { task_id: task_id.into(), command: install.clone(), n, of });
                let i = run_check(at.dir, &install, at.path, INSTALL_TIMEOUT).await;
                if i.passed() {
                    r = run_check(at.dir, &capture, at.path, CAPTURE_TIMEOUT).await;
                }
                installed = Some(i);
            }
            if !r.passed() {
                if missing_browser(&r.tail) {
                    let tried = match &installed {
                        Some(i) => format!("\n\nThe runner tried to install it and couldn't:\n$ {}\n{}", i.command, i.tail),
                        None => String::new(),
                    };
                    let text = format!(
                        "Playwright's Chromium isn't installed on this machine. Run this there once:\n\n    {}{tried}\n\n$ {}\n{}\n\n{}",
                        install_command(),
                        r.command,
                        r.tail,
                        dev_log()
                    );
                    out.push(ScreenProof::note("Screens not captured: Playwright has no browser on this machine".into(), text));
                    return out;
                }
                out.push(ScreenProof::note(format!("Couldn't capture {what}"), format!("$ {}\n{}", r.command, r.tail)));
                continue;
            }
            let stored = match (check_file(&file.to_string_lossy(), &shots.home, at.proof), shots.origin) {
                (Err(e), _) => Err(e),
                (Ok(_), None) => Err("The runner doesn't know its control plane, so it can't upload files.".into()),
                (Ok(checked), Some((base, runner, token))) => upload(base, runner, token, task_id, &checked).await,
            };
            out.push(match stored {
                Ok(v) => ScreenProof { kind: "screen", summary: what, text: None, file: v.get("key").and_then(Value::as_str).map(String::from) },
                Err(e) => ScreenProof::note(format!("Couldn't upload {what}"), e),
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, b'I', b'H', b'D', b'R'];

    /// A home with a proof folder for `agent/cleanup-badge`, and a file outside it.
    fn home() -> (PathBuf, PathBuf) {
        let home = std::env::temp_dir().join(format!("maple-proof-{}", Uuid::new_v4()));
        let dir = folder(&home, "agent/cleanup-badge");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::create_dir_all(home.join("src/app")).unwrap();
        (std::fs::canonicalize(&home).unwrap(), dir)
    }

    #[test]
    fn task_tags_round_trip() {
        let tag = TaskTag { id: "00000000-0000-4000-8000-000000000001".into(), branch: "agent/x-1a2b".into() };
        assert_eq!(TaskTag::parse(&tag.to_meta()), Some(tag));
        assert_eq!(TaskTag::parse(""), None);
        assert_eq!(TaskTag::parse("only-an-id"), None);
    }

    /// Sets a file's or folder's modification time.
    fn touch(path: &Path, at: std::time::SystemTime) {
        std::fs::File::open(path).unwrap().set_modified(at).unwrap();
    }

    #[test]
    fn a_cleaned_up_tasks_proof_folder_goes_and_empty_parents_with_it() {
        let (home, dir) = home();
        std::fs::write(dir.join("tasks-390.png"), PNG).unwrap();
        std::fs::create_dir_all(dir.join("runner")).unwrap();
        std::fs::write(dir.join("runner/tasks-1280.png"), PNG).unwrap();
        let other = folder(&home, "agent/other-3c4d");
        std::fs::create_dir_all(&other).unwrap();
        std::fs::write(other.join("a.txt"), "ok").unwrap();

        assert!(forget_folder(&home, "agent/cleanup-badge").unwrap());
        assert!(!dir.exists());
        assert!(other.join("a.txt").exists(), "another task's folder stays");
        assert!(home.join(".cache/maple-proof/agent").is_dir(), "agent/ still holds one");
        // The last one goes, and agent/ with it; maple-proof itself stays.
        assert!(forget_folder(&home, "agent/other-3c4d").unwrap());
        assert!(!home.join(".cache/maple-proof/agent").exists());
        assert!(home.join(".cache/maple-proof").is_dir());
        // Already gone, or a branch that leads out of maple-proof: nothing.
        assert!(!forget_folder(&home, "agent/cleanup-badge").unwrap());
        for bad in ["", "/etc", "../src", "agent/../../src", "agent//x", "agent/./x"] {
            assert!(!forget_folder(&home, bad).unwrap(), "{bad}");
        }
        assert!(home.join("src/app").is_dir());
    }

    #[test]
    fn the_sweep_removes_folders_untouched_for_14_days_and_keeps_the_rest() {
        let (home, dir) = home();
        let now = std::time::SystemTime::now();
        let old = now - KEEP_FOLDER - DAY;
        // An old task's folder: files and folder all 15 days old.
        std::fs::create_dir_all(dir.join("runner")).unwrap();
        std::fs::write(dir.join("runner/tasks-390.png"), PNG).unwrap();
        std::fs::write(dir.join("a.txt"), "ok").unwrap();
        for p in [dir.join("runner/tasks-390.png"), dir.join("a.txt"), dir.join("runner"), dir.clone()] {
            touch(&p, old);
        }
        // A task still at work: an old screenshot, but a file from today.
        let live = folder(&home, "agent/live-1a2b");
        std::fs::create_dir_all(&live).unwrap();
        std::fs::write(live.join("old.png"), PNG).unwrap();
        touch(&live.join("old.png"), old);
        std::fs::write(live.join("today.txt"), "ok").unwrap();

        assert_eq!(sweep(&home, now), vec![folder(&home, "agent/cleanup-badge")]);
        assert!(!dir.exists());
        assert!(live.join("old.png").exists() && live.join("today.txt").exists(), "a folder goes whole or not at all");
        assert!(home.join("src/app").is_dir(), "nothing outside maple-proof");
        // 14 days on, the live one goes too, and the empty agent/ with it.
        let later = now + KEEP_FOLDER + DAY;
        assert_eq!(sweep(&home, later), vec![home.join(".cache/maple-proof/agent")]);
        assert!(home.join(".cache/maple-proof").is_dir());
        // No maple-proof at all is fine.
        let empty = std::env::temp_dir().join(format!("maple-proof-{}", Uuid::new_v4()));
        assert!(sweep(&empty, now).is_empty());
    }

    #[test]
    fn the_folder_keeps_a_branchs_slashes() {
        assert_eq!(folder(Path::new("/Users/a"), "agent/x-1a2b"), PathBuf::from("/Users/a/.cache/maple-proof/agent/x-1a2b"));
    }

    #[test]
    fn files_must_be_in_the_sessions_own_proof_folder() {
        let (home, dir) = home();
        let dir = std::fs::canonicalize(dir).unwrap();
        std::fs::write(dir.join("tasks 390.png"), PNG).unwrap();
        std::fs::write(dir.join("out.txt"), "✔ cleanup keeps a dirty worktree\n").unwrap();
        let ok = check_file("~/.cache/maple-proof/agent/cleanup-badge/tasks 390.png", &home, &dir).unwrap();
        assert_eq!((ok.name.as_str(), ok.kind, ok.bytes.len()), ("tasks-390.png", "image/png", PNG.len()));
        let ok = check_file(&dir.join("out.txt").to_string_lossy(), &home, &dir).unwrap();
        assert_eq!(ok.kind, "text/plain");

        // Outside the folder: in the worktree, another branch's folder, or up and out with `..`.
        std::fs::write(home.join("src/app/shot.png"), PNG).unwrap();
        assert!(check_file("~/src/app/shot.png", &home, &dir).unwrap_err().contains("go under ~/.cache/maple-proof/agent/cleanup-badge/"));
        let other = folder(&home, "agent/other");
        std::fs::create_dir_all(&other).unwrap();
        std::fs::write(other.join("a.png"), PNG).unwrap();
        assert!(check_file("~/.cache/maple-proof/agent/other/a.png", &home, &dir).is_err());
        assert!(check_file("~/.cache/maple-proof/agent/cleanup-badge/../other/a.png", &home, &dir).is_err());
        // The folder itself isn't a file in it.
        assert!(check_file("~/.cache/maple-proof/agent/cleanup-badge", &home, &dir).is_err());

        // A symlink in the folder that points out of it is refused; one that stays inside is fine.
        std::os::unix::fs::symlink(home.join("src/app/shot.png"), dir.join("sneaky.png")).unwrap();
        assert!(check_file("~/.cache/maple-proof/agent/cleanup-badge/sneaky.png", &home, &dir).unwrap_err().contains("isn't there"));
        std::os::unix::fs::symlink(dir.join("out.txt"), dir.join("link.txt")).unwrap();
        assert_eq!(check_file("~/.cache/maple-proof/agent/cleanup-badge/link.txt", &home, &dir).unwrap().name, "out.txt");
        // A symlinked folder pointing out is refused too.
        std::os::unix::fs::symlink(home.join("src/app"), dir.join("app")).unwrap();
        assert!(check_file("~/.cache/maple-proof/agent/cleanup-badge/app/shot.png", &home, &dir).is_err());

        // Missing, relative, too big, or not an image or text.
        assert!(check_file("~/.cache/maple-proof/agent/cleanup-badge/nope.png", &home, &dir).unwrap_err().contains("no file"));
        assert!(check_file("tasks-390.png", &home, &dir).unwrap_err().contains("full path"));
        std::fs::write(dir.join("big.txt"), vec![b'a'; MAX_FILE as usize + 1]).unwrap();
        assert!(check_file("~/.cache/maple-proof/agent/cleanup-badge/big.txt", &home, &dir).unwrap_err().contains("at most 20 MB"));
        // A full-size Retina screenshot goes as it is: 15 MB is fine, 21 MB is over.
        let mut png = PNG.to_vec();
        png.resize(15 * 1024 * 1024, 0);
        std::fs::write(dir.join("retina.png"), &png).unwrap();
        assert_eq!(check_file("~/.cache/maple-proof/agent/cleanup-badge/retina.png", &home, &dir).unwrap().kind, "image/png");
        png.resize(21 * 1024 * 1024, 0);
        std::fs::write(dir.join("huge.png"), &png).unwrap();
        let err = check_file("~/.cache/maple-proof/agent/cleanup-badge/huge.png", &home, &dir).unwrap_err();
        assert!(err.contains("at most 20 MB") && err.contains("smaller one"), "{err}");
        // A video may be bigger, up to 95 MB.
        let mut mp4 = b"\0\0\0\x20ftypisom\0\0\x02\0".to_vec();
        mp4.resize(60 * 1024 * 1024, 0);
        std::fs::write(dir.join("flow.mp4"), &mp4).unwrap();
        let ok = check_file("~/.cache/maple-proof/agent/cleanup-badge/flow.mp4", &home, &dir).unwrap();
        assert_eq!((ok.name.as_str(), ok.kind), ("flow.mp4", "video/mp4"));
        let mut webm = b"\x1a\x45\xdf\xa3".to_vec();
        webm.resize(96 * 1024 * 1024, 0);
        std::fs::write(dir.join("long.webm"), &webm).unwrap();
        let err = check_file("~/.cache/maple-proof/agent/cleanup-badge/long.webm", &home, &dir).unwrap_err();
        assert!(err.contains("at most 95 MB") && err.contains("shorter clip"), "{err}");
        std::fs::write(dir.join("clip.gif"), b"GIF89a\x01\x00\x00").unwrap();
        assert!(check_file("~/.cache/maple-proof/agent/cleanup-badge/clip.gif", &home, &dir).unwrap_err().contains("isn't PNG"));
        std::fs::write(dir.join("empty.txt"), b"").unwrap();
        assert!(check_file("~/.cache/maple-proof/agent/cleanup-badge/empty.txt", &home, &dir).unwrap_err().contains("empty"));
        std::fs::remove_dir_all(&home).unwrap();
    }

    /// The prove path against a real control plane, with real files: `MAPLE_LIVE_BASE`, `MAPLE_LIVE_RUNNER`,
    /// `MAPLE_LIVE_TOKEN` (an enrolled runner's), `MAPLE_LIVE_TASK` and `MAPLE_LIVE_FILES` (paths under
    /// ~/.cache/maple-proof/<MAPLE_LIVE_BRANCH>/, comma-separated). Prints each stored key and size.
    #[tokio::test]
    #[ignore = "needs a running control plane (wrangler dev)"]
    async fn live_prove_uploads_files_as_they_are() {
        let env = |k: &str| std::env::var(k).unwrap_or_else(|_| panic!("set {k}"));
        let home = PathBuf::from(env("HOME"));
        let tag = TaskTag { id: env("MAPLE_LIVE_TASK"), branch: env("MAPLE_LIVE_BRANCH") };
        let (base, runner, token) = (env("MAPLE_LIVE_BASE"), env("MAPLE_LIVE_RUNNER"), env("MAPLE_LIVE_TOKEN"));
        for (i, file) in env("MAPLE_LIVE_FILES").split(',').enumerate() {
            let size = std::fs::metadata(expand_home(file)).unwrap().len();
            let args = json!({ "item": i + 1, "kind": "screenshot", "summary": "live", "file": file });
            let out = prepare_with(args, &tag, &home, &home, Some((&base, &runner, &token))).await.unwrap();
            println!("{file}: {size} bytes on disk -> {} {} {} bytes", out["file"]["key"], out["file"]["type"], out["file"]["bytes"]);
            assert_eq!(out["file"]["bytes"], json!(size));
        }
    }

    #[test]
    fn sniffs_like_the_control_plane() {
        assert_eq!(sniff(PNG), Some("image/png"));
        assert_eq!(sniff(&[0xff, 0xd8, 0xff, 0xe0]), Some("image/jpeg"));
        assert_eq!(sniff(b"RIFF\x24\0\0\0WEBPVP8 "), Some("image/webp"));
        assert_eq!(sniff("ℹ tests 41".as_bytes()), Some("text/plain"));
        assert_eq!(sniff(&[0x50, 0x4b, 0x03, 0x04, 0xff, 0xfe]), None);
        assert_eq!(sniff(b"\0\0\0\x20ftypisom\0\0\x02\0"), Some("video/mp4"));
        assert_eq!(sniff(b"\0\0\0\x14ftypqt  \0\0\0\0"), Some("video/quicktime"));
        assert_eq!(sniff(b"\x1a\x45\xdf\xa3\x01\0\0\0"), Some("video/webm"));
        assert_eq!(sniff(b"\0\0\0\x20ftypM4A \0\0\0\0"), None);
    }

    #[test]
    fn names_are_cleaned_for_the_store() {
        assert_eq!(stored_name("tasks-390.png"), "tasks-390.png");
        assert_eq!(stored_name("Screen Shot (2).png"), "Screen-Shot--2-.png");
        assert_eq!(stored_name(&format!("{}.png", "a".repeat(100))).len(), 80);
        assert!(stored_name(&format!("{}.png", "a".repeat(100))).ends_with(".png"));
    }

    /// One HTTP request on a local port, answered with `status` and `body`; the request comes back as text.
    async fn server(status: &'static str, body: &'static str) -> (String, tokio::task::JoinHandle<(String, Vec<u8>)>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let handle = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            let mut buf = Vec::new();
            let mut chunk = [0u8; 4096];
            let (head, len) = loop {
                let n = sock.read(&mut chunk).await.unwrap();
                buf.extend_from_slice(&chunk[..n]);
                if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    let head = String::from_utf8_lossy(&buf[..end]).to_string();
                    let len =
                        head.lines().find_map(|l| l.to_lowercase().strip_prefix("content-length: ").map(|v| v.trim().parse::<usize>().unwrap())).unwrap_or(0);
                    buf.drain(..end + 4);
                    break (head, len);
                }
            };
            while buf.len() < len {
                let n = sock.read(&mut chunk).await.unwrap();
                buf.extend_from_slice(&chunk[..n]);
            }
            let reply = format!("HTTP/1.1 {status}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
            sock.write_all(reply.as_bytes()).await.unwrap();
            (head, buf)
        });
        (base, handle)
    }

    #[tokio::test]
    async fn uploads_the_file_with_the_runners_token_and_passes_the_key_on() {
        let (home, dir) = home();
        std::fs::write(dir.join("tasks-390.png"), PNG).unwrap();
        let tag = TaskTag { id: "00000000-0000-4000-8000-000000000001".into(), branch: "agent/cleanup-badge".into() };
        let (base, req) =
            server("200 OK", r#"{"key":"tasks/00000000-0000-4000-8000-000000000001/0123456789ab-tasks-390.png","type":"image/png","bytes":16}"#).await;
        let args = json!({ "criterion": 2, "kind": "screen", "summary": "Tasks at 390px", "file": "~/.cache/maple-proof/agent/cleanup-badge/tasks-390.png" });
        let out = prepare_with(args, &tag, &home, &home, Some((&base, "mini", "aor_mini-token"))).await.unwrap();
        assert_eq!(
            out["file"],
            json!({ "key": "tasks/00000000-0000-4000-8000-000000000001/0123456789ab-tasks-390.png", "name": "tasks-390.png", "type": "image/png", "bytes": 16 })
        );
        assert_eq!((out["criterion"].as_u64(), out["kind"].as_str()), (Some(2), Some("screen")));
        // Not a git repository: no head.
        assert!(out.get("head").is_none());
        let (head, body) = req.await.unwrap();
        assert!(head.starts_with("PUT /runner/proof/00000000-0000-4000-8000-000000000001?runner=mini&name=tasks-390.png HTTP/1.1"), "{head}");
        let lower = head.to_lowercase();
        assert!(lower.contains("authorization: bearer aor_mini-token"), "{head}");
        assert!(lower.contains("content-type: image/png"), "{head}");
        assert_eq!(body, PNG);

        // The control plane's refusal is the agent's error; text goes on with no upload at all.
        std::fs::write(dir.join("again.png"), PNG).unwrap();
        let (base, _req) = server("409 Conflict", "The task is merged; it takes no more evidence.").await;
        let args = json!({ "criterion": 1, "kind": "screen", "summary": "s", "file": "~/.cache/maple-proof/agent/cleanup-badge/again.png" });
        let err = prepare_with(args, &tag, &home, &home, Some((&base, "mini", "t"))).await.unwrap_err();
        assert_eq!(err, "The control plane refused again.png: The task is merged; it takes no more evidence.");
        let text = json!({ "criterion": 3, "kind": "test", "summary": "s", "text": "ok" });
        assert_eq!(prepare_with(text.clone(), &tag, &home, &home, None).await.unwrap(), text);
        assert!(prepare_with(json!({ "file": 5 }), &tag, &home, &home, None).await.is_err());
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn artifact_files_are_the_shareable_kinds_inside_the_folder() {
        let (home, dir) = home();
        let at = |name: &str| format!("~/.cache/maple-proof/agent/cleanup-badge/{name}");
        let cases: &[(&str, &[u8], &str)] = &[
            ("chart.html", b"<!doctype html><script>draw()</script>", "text/html"),
            ("page.txt", b"  <html><body>hi</body></html>", "text/html"),
            ("bars.svg", b"<svg xmlns='http://www.w3.org/2000/svg'/>", "image/svg+xml"),
            ("drawing.xml", b"<?xml version='1.0'?><svg/>", "image/svg+xml"),
            ("shot.png", PNG, "image/png"),
            ("anim.gif", b"GIF89a\x01\x00\x01\x00", "image/gif"),
            ("repro.pdf", b"%PDF-1.7\n", "application/pdf"),
            ("notes.md", b"# How to review", "text/markdown"),
            ("results.csv", b"run,ms\n1,20\n", "text/csv"),
            ("results.json", b"{\"ms\":20}", "application/json"),
            ("log.txt", b"plain output", "text/plain"),
        ];
        for (name, bytes, kind) in cases {
            std::fs::write(dir.join(name), bytes).unwrap();
            let ok = check_artifact(&at(name), &home, &dir).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_eq!((ok.kind, ok.name.as_str()), (*kind, *name), "{name}");
        }
        // A binary blob, a video (a proof, not an artifact), and an empty file.
        std::fs::write(dir.join("blob.bin"), [0u8, 1, 2, 3, 0xff]).unwrap();
        assert!(check_artifact(&at("blob.bin"), &home, &dir).unwrap_err().contains("isn't HTML"));
        std::fs::write(dir.join("clip.mp4"), [0, 0, 0, 0x18, b'f', b't', b'y', b'p', b'i', b's', b'o', b'm', 0]).unwrap();
        assert!(check_artifact(&at("clip.mp4"), &home, &dir).is_err());
        std::fs::write(dir.join("empty.html"), b"").unwrap();
        assert!(check_artifact(&at("empty.html"), &home, &dir).unwrap_err().contains("empty"));
        // 10 MB and no more.
        std::fs::write(dir.join("edge.txt"), vec![b'a'; MAX_ARTIFACT as usize]).unwrap();
        assert!(check_artifact(&at("edge.txt"), &home, &dir).is_ok());
        std::fs::write(dir.join("big.html"), vec![b'a'; MAX_ARTIFACT as usize + 1]).unwrap();
        assert!(check_artifact(&at("big.html"), &home, &dir).unwrap_err().contains("at most 10 MB"));
        // Outside the folder: the worktree, another task's folder, `..`, or a symlink out.
        std::fs::write(home.join("src/app/chart.html"), b"<html></html>").unwrap();
        assert!(check_artifact("~/src/app/chart.html", &home, &dir).unwrap_err().contains("Artifact files go under"));
        assert!(check_artifact("~/.cache/maple-proof/agent/cleanup-badge/../../../src/app/chart.html", &home, &dir).is_err());
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(home.join("src/app/chart.html"), dir.join("sneaky.html")).unwrap();
            assert!(check_artifact(&at("sneaky.html"), &home, &dir).unwrap_err().contains("isn't there"));
        }
        assert!(check_artifact("chart.html", &home, &dir).unwrap_err().contains("full path"));
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[tokio::test]
    async fn shares_an_artifact_through_the_artifact_route() {
        let (home, dir) = home();
        std::fs::write(dir.join("chart.html"), b"<!doctype html><p>chart</p>").unwrap();
        let tag = TaskTag { id: "MF-205".into(), branch: "agent/cleanup-badge".into() };
        let (base, req) =
            server("201 Created", r#"{"key":"/attachments/0f0e0d0c-0b0a-4908-8706-050403020100/chart.html","type":"text/html","bytes":27}"#).await;
        let args = json!({ "title": "Chart", "file": "~/.cache/maple-proof/agent/cleanup-badge/chart.html" });
        let out = prepare_artifact_with(args, &tag, &home, Some((&base, "mini", "aor_mini-token"))).await.unwrap();
        assert_eq!(out["file"]["key"], json!("/attachments/0f0e0d0c-0b0a-4908-8706-050403020100/chart.html"));
        assert_eq!((out["file"]["name"].as_str(), out["title"].as_str()), (Some("chart.html"), Some("Chart")));
        let (head, _) = req.await.unwrap();
        assert!(head.starts_with("PUT /runner/artifact/MF-205?runner=mini&name=chart.html HTTP/1.1"), "{head}");
        assert!(head.to_lowercase().contains("content-type: text/html"), "{head}");
        // No file, or not a path: refused before any upload.
        assert!(prepare_artifact_with(json!({ "title": "x" }), &tag, &home, None).await.is_err());
        assert!(prepare_artifact_with(json!({ "title": "x", "file": 5 }), &tag, &home, None).await.is_err());
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[tokio::test]
    async fn adds_the_worktrees_head() {
        let (home, _) = home();
        let repo = home.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        let git = |args: &[&str]| std::process::Command::new("git").arg("-C").arg(&repo).args(args).output().unwrap();
        git(&["init", "-q"]);
        git(&["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"]);
        let sha = String::from_utf8(git(&["rev-parse", "HEAD"]).stdout).unwrap().trim().to_string();
        let tag = TaskTag { id: "t".into(), branch: "agent/cleanup-badge".into() };
        let out = prepare_with(json!({ "text": "ok" }), &tag, &repo, &home, None).await.unwrap();
        assert_eq!(out["head"], json!(sha));
        std::fs::remove_dir_all(&home).unwrap();
    }

    // ---- checks ----

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("maple-{name}-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::canonicalize(dir).unwrap()
    }

    #[tokio::test]
    async fn checks_run_one_after_another_and_stop_at_the_first_failure() {
        let dir = temp("checks");
        let commands: Vec<String> = ["true", "echo out; echo err >&2; pwd", "false", "touch never"].map(String::from).to_vec();
        let started = std::sync::Mutex::new(vec![]);
        let (results, not_run) = run_checks(&dir, &commands, None, Duration::from_secs(30), |n, c| started.lock().unwrap().push(format!("{n} {c}"))).await;
        assert_eq!(started.into_inner().unwrap(), ["1 true", "2 echo out; echo err >&2; pwd", "3 false"]);
        assert_eq!(
            results.iter().map(|r| (r.command.as_str(), r.code, r.passed())).collect::<Vec<_>>(),
            [("true", Some(0), true), ("echo out; echo err >&2; pwd", Some(0), true), ("false", Some(1), false)]
        );
        // stdout and stderr together, in the worktree.
        assert_eq!(results[1].tail, format!("out\nerr\n{}", dir.display()));
        assert_eq!(not_run, ["touch never"]);
        assert!(!dir.join("never").exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn a_check_keeps_the_end_of_its_output_and_its_exit_code() {
        let dir = temp("checks");
        let r = run_check(&dir, "seq 1 500; exit 3", None, Duration::from_secs(30)).await;
        assert_eq!((r.code, r.timed_out, r.passed()), (Some(3), false, false));
        let lines: Vec<&str> = r.tail.lines().collect();
        assert_eq!((lines.len(), lines[0], lines[199]), (TAIL_LINES, "301", "500"));
        // A long line is cut, and the whole tail stays under its limit.
        let r = run_check(&dir, "yes abcdefghij | tr -d '\\n' | head -c 2000; echo; yes x | head -n 300", None, Duration::from_secs(30)).await;
        assert!(r.passed());
        assert!(r.tail.len() <= TAIL_BYTES && r.tail.lines().all(|l| l.chars().count() <= LINE_CHARS));
        // A PATH of its own (the login shell's, on a machine).
        let r = run_check(&dir, "echo $PATH", Some("/usr/bin:/bin"), Duration::from_secs(30)).await;
        assert_eq!(r.tail, "/usr/bin:/bin");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn alive(pid: i32) -> bool {
        unsafe { libc::kill(pid, 0) == 0 }
    }

    #[tokio::test]
    async fn a_check_that_runs_too_long_is_killed_with_everything_it_started() {
        let dir = temp("checks");
        let began = std::time::Instant::now();
        let r = run_check(&dir, "echo starting; sleep 60 & echo $! > child.pid; sleep 60", None, Duration::from_secs(1)).await;
        assert!(began.elapsed() < Duration::from_secs(10), "{:?}", began.elapsed());
        assert_eq!((r.code, r.timed_out, r.passed()), (None, true, false));
        assert_eq!(r.tail, "starting\nStopped after 1 seconds.");
        let child: i32 = std::fs::read_to_string(dir.join("child.pid")).unwrap().trim().parse().unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(!alive(child), "the background sleep is still running");

        // One that ends but leaves something behind holding its output: it's done, and that goes too.
        let began = std::time::Instant::now();
        let r = run_check(&dir, "sleep 60 & echo $! > left.pid; echo done", None, Duration::from_secs(30)).await;
        assert!(began.elapsed() < Duration::from_secs(10), "{:?}", began.elapsed());
        assert_eq!((r.code, r.tail.as_str()), (Some(0), "done"));
        let left: i32 = std::fs::read_to_string(dir.join("left.pid")).unwrap().trim().parse().unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(!alive(left));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A GitHub repo (a local bare one standing in for it) whose main has a `.factory.toml`, and a
    /// task's worktree whose branch rewrites it to weaken the checks.
    #[tokio::test]
    async fn the_commands_come_from_the_base_never_the_branch() {
        let root = temp("prove");
        let sh = |dir: &Path, args: &[&str]| {
            let out = std::process::Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
            assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        };
        let bare = root.join("remotes/acme/widgets.git");
        let seed = root.join("seed");
        std::fs::create_dir_all(&bare).unwrap();
        std::fs::create_dir_all(&seed).unwrap();
        sh(&bare, &["init", "--quiet", "--bare"]);
        sh(&seed, &["init", "--quiet", "-b", "main"]);
        std::fs::write(seed.join(crate::factory::FILE), "test = [\"echo from the base\", \"exit 3\", \"echo not reached\"]\n").unwrap();
        sh(&seed, &["add", "-A"]);
        sh(&seed, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "factory"]);
        sh(&seed, &["push", "--quiet", bare.to_str().unwrap(), "main"]);

        // The machine's checkout, with GitHub as origin, and the task's worktree on its own branch.
        let work = root.join("work");
        std::fs::create_dir_all(&work).unwrap();
        sh(&work, &["init", "--quiet"]);
        sh(&work, &["remote", "add", "origin", "https://github.com/acme/widgets.git"]);
        sh(&work, &["fetch", "--quiet", bare.to_str().unwrap(), "+refs/heads/main:refs/remotes/origin/main"]);
        sh(&work, &["checkout", "--quiet", "-b", "agent/weaker-1a2b", "origin/main"]);
        std::fs::write(work.join(crate::factory::FILE), "test = \"true\"\n").unwrap();
        sh(&work, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-am", "weaker checks"]);
        // Someone moves the local copy of main too: the base is fetched again first.
        sh(&work, &["update-ref", "refs/remotes/origin/main", "HEAD"]);

        let projects = vec![crate::factory::Project {
            repo: "acme/widgets".into(),
            name: "Widgets".into(),
            settings: crate::factory::Settings { test: Some("echo from the project".into()), ..Default::default() },
        }];
        let p = Prove { task_id: "t1".into(), cwd: work.to_string_lossy().into(), base: Some("main".into()), projects };
        let sent = std::sync::Mutex::new(vec![]);
        // The hub answers the token request at once.
        let emit = |m: Outbound| {
            if let Outbound::TaskTokenRequest { req_id, purpose, .. } = &m {
                assert_eq!(*purpose, Some("fetch"));
                crate::tasks::resolve(req_id, crate::tasks::TokenReply { token: Some("ghs_test-token".into()), error: None, code: None, settings_url: None });
            }
            sent.lock().unwrap().push(serde_json::to_value(&m).unwrap());
        };
        let fetch = format!("{}/remotes/{{owner}}/{{repo}}.git", root.display());
        let out = serde_json::to_value(prove_task(&emit, &p, Some(&fetch), None, Duration::from_secs(30), None).await).unwrap();
        assert_eq!(out["type"], "task.proved");
        let ran: Vec<(&str, i64)> = out["results"].as_array().unwrap().iter().map(|r| (r["command"].as_str().unwrap(), r["code"].as_i64().unwrap())).collect();
        assert_eq!(ran, [("echo from the base", 0), ("exit 3", 3)]);
        assert_eq!(out["results"][0]["tail"], "from the base");
        assert_eq!(out["notRun"], json!(["echo not reached"]));
        assert_eq!(out["head"].as_str().map(str::len), Some(40));
        let checks: Vec<String> =
            sent.lock().unwrap().iter().filter(|m| m["type"] == "task.check").map(|m| format!("{} of {}: {}", m["n"], m["of"], m["command"])).collect();
        assert_eq!(checks, ["1 of 3: \"echo from the base\"", "2 of 3: \"exit 3\""]);

        // Without a .factory.toml at the base: the project's commands. Without a project: none at all.
        std::fs::remove_file(seed.join(crate::factory::FILE)).unwrap();
        sh(&seed, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-am", "no factory"]);
        sh(&seed, &["push", "--quiet", bare.to_str().unwrap(), "main"]);
        let out = serde_json::to_value(prove_task(&emit, &p, Some(&fetch), None, Duration::from_secs(30), None).await).unwrap();
        assert_eq!(out["results"][0]["command"], "echo from the project");
        let none = Prove { projects: vec![], ..p.clone() };
        let out = serde_json::to_value(prove_task(&emit, &none, Some(&fetch), None, Duration::from_secs(30), None).await).unwrap();
        assert_eq!((out["results"].clone(), out["notRun"].clone()), (json!([]), json!([])));

        // A base that can't be fetched, or a worktree that's gone: why, and nothing ran.
        let gone = Prove { base: Some("nope".into()), ..p.clone() };
        let out = serde_json::to_value(prove_task(&emit, &gone, Some(&fetch), None, Duration::from_secs(30), None).await).unwrap();
        assert!(out["error"].as_str().unwrap().contains("Couldn't fetch nope"), "{out}");
        let gone = Prove { cwd: root.join("missing").to_string_lossy().into(), ..p.clone() };
        let out = serde_json::to_value(prove_task(&emit, &gone, Some(&fetch), None, Duration::from_secs(30), None).await).unwrap();
        assert!(out["error"].as_str().unwrap().contains("is gone"));
        std::fs::remove_dir_all(&root).unwrap();
    }

    // ---- screens ----

    #[test]
    fn screens_are_routes_with_globs_and_the_rest_is_prose() {
        let setting = "The Tasks page, at both widths.\n#tasks web/src/tasks.ts web/src/style.css\n#cards  web/src/card*.ts\n\
                       #settings web/src/main.ts\n/\nwidths: 1280px, 390px, 768\nscreens in dark mode too";
        let spec = parse_screens(setting);
        assert_eq!(spec.routes.iter().map(|(r, g)| (r.as_str(), g.len())).collect::<Vec<_>>(), [("#tasks", 2), ("#cards", 1), ("#settings", 1), ("/", 0)]);
        assert_eq!(spec.widths, [1280, 390, 768]);
        // No widths line, or one that isn't all widths: 1280 and 390.
        assert_eq!(parse_screens("#tasks").widths, DEFAULT_WIDTHS);
        assert_eq!(parse_screens("widths are 1280 and 390").widths, DEFAULT_WIDTHS);
        assert_eq!(parse_screens("widths 1280 99999").widths, DEFAULT_WIDTHS);

        let changed = |files: &[&str]| files.iter().map(|f| f.to_string()).collect::<Vec<_>>();
        // A route is captured when the diff touches one of its paths; one with none, always.
        assert_eq!(screens_for(setting, &changed(&["web/src/tasks.ts", "runner/src/proof.rs"])), ["#tasks", "/"]);
        assert_eq!(screens_for(setting, &changed(&["web/src/style.css"])), ["#tasks", "/"]);
        assert_eq!(screens_for(setting, &changed(&["web/src/card-view.ts"])), ["#cards", "/"]);
        assert_eq!(screens_for(setting, &changed(&["README.md"])), ["/"]);
        assert_eq!(screens_for(setting, &changed(&[])), ["/"]);
        assert!(screens_for("Just prose.\nwidths 390", &changed(&["web/src/tasks.ts"])).is_empty());
        assert_eq!(screens_for("/settings/projects web/src/projects.ts", &changed(&["web/src/projects.ts"])), ["/settings/projects"]);
    }

    #[test]
    fn globs_match_like_the_control_plane() {
        let yes = [
            ("web/src/tasks.ts", "web/src/tasks.ts"),
            ("./web/src/tasks.ts", "web/src/tasks.ts"),
            ("web/src/*.ts", "web/src/tasks.ts"),
            ("web/**", "web/src/deep/x.ts"),
            ("web/**", "web"),
            ("web/**/*.css", "web/style.css"),
            ("web/**/*.css", "web/src/a/style.css"),
            ("**/*.css", "web/src/style.css"),
            ("web/src/task?.ts", "web/src/tasks.ts"),
            ("*.css", "web/src/style.css"),
            ("style.css", "web/src/style.css"),
            ("control/migrations/**", "control/migrations/0023_x.sql"),
            ("web/src/**.ts", "web/src/a/b.ts"),
        ];
        for (g, p) in yes {
            assert!(glob_match(g, p), "{g} should match {p}");
        }
        let no = [
            ("web/src/*.ts", "web/src/a/tasks.ts"),
            ("web/src/tasks.ts", "web/src/tasks.tsx"),
            ("web/**", "webby/x.ts"),
            ("web/src/task?.ts", "web/src/task/.ts"),
            ("src/*.ts", "web/src/tasks.ts"),
            ("", "web/src/tasks.ts"),
            ("web/src/tasks.ts", "control/src/tasks.ts"),
        ];
        for (g, p) in no {
            assert!(!glob_match(g, p), "{g} shouldn't match {p}");
        }
    }

    #[test]
    fn the_pinned_playwright_captures_full_pages() {
        let cmd = playwright("http://localhost:52411/#tasks", 390, 844, Path::new("/Users/a/.cache/maple-proof/agent/x/runner/it's-390.png"));
        assert_eq!(
            cmd,
            format!(
                "npx --yes playwright@{PLAYWRIGHT} screenshot --browser=chromium --full-page --wait-for-timeout=1000 --viewport-size=390,844 \
                 'http://localhost:52411/#tasks' '/Users/a/.cache/maple-proof/agent/x/runner/it'\\''s-390.png'"
            )
        );
        assert_eq!((height_for(1280), height_for(390)), (800, 844));
        assert_eq!((slug("#tasks"), slug("/settings/projects"), slug("/")), ("tasks".to_string(), "settings-projects".to_string(), "home".to_string()));
        assert_eq!(install_command(), format!("npx --yes playwright@{PLAYWRIGHT} install chromium"));
        assert_eq!(install_deps_command(), format!("npx --yes playwright@{PLAYWRIGHT} install-deps chromium"));
    }

    /// Answers every upload with a key made from its name, and keeps the names in order.
    async fn uploads() -> (String, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let names = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
        let seen = names.clone();
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else { return };
                let mut buf = Vec::new();
                let mut chunk = [0u8; 8192];
                let head = loop {
                    let n = sock.read(&mut chunk).await.unwrap();
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buf[..end]).to_string();
                        let len = head
                            .lines()
                            .find_map(|l| l.to_lowercase().strip_prefix("content-length: ").map(|v| v.trim().parse::<usize>().unwrap()))
                            .unwrap_or(0);
                        while buf.len() < end + 4 + len {
                            let n = sock.read(&mut chunk).await.unwrap();
                            buf.extend_from_slice(&chunk[..n]);
                        }
                        break head;
                    }
                };
                let name = head.split("name=").nth(1).and_then(|r| r.split([' ', '&']).next()).unwrap_or("").to_string();
                let body = format!(r#"{{"key":"tasks/t1/0123456789ab-{name}","type":"image/png","bytes":16}}"#);
                seen.lock().unwrap().push(name);
                let reply = format!("HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
                sock.write_all(reply.as_bytes()).await.unwrap();
            }
        });
        (base, names)
    }

    /// A repo on `main` with a task branch that changed `web/src/tasks.ts` (committed) and
    /// `web/src/new.ts` (not yet), as a task's worktree is when its checks pass.
    fn task_repo(root: &Path) -> PathBuf {
        let repo = root.join("work");
        std::fs::create_dir_all(repo.join("web/src")).unwrap();
        let git = |args: &[&str]| {
            let out = std::process::Command::new("git").arg("-C").arg(&repo).args(args).output().unwrap();
            assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        };
        git(&["init", "--quiet", "-b", "main"]);
        std::fs::write(repo.join("web/src/tasks.ts"), "a\n").unwrap();
        std::fs::write(repo.join("web/src/cards.ts"), "a\n").unwrap();
        git(&["add", "-A"]);
        git(&["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "base"]);
        git(&["checkout", "--quiet", "-b", "agent/tasks-badge-3f2a"]);
        std::fs::write(repo.join("web/src/tasks.ts"), "b\n").unwrap();
        git(&["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-am", "badge"]);
        std::fs::write(repo.join("web/src/new.ts"), "c\n").unwrap();
        repo
    }

    fn screen_settings(dev: &str) -> crate::factory::Settings {
        crate::factory::Settings {
            dev: Some(dev.into()),
            proof_kinds: Some(vec!["test".into(), "screen".into()]),
            screens: Some("#tasks web/src/tasks.ts\n#cards web/src/cards.ts\n#new web/src/new.ts\n/".into()),
            ..Default::default()
        }
    }

    fn free_ports() -> Result<(u16, u16), String> {
        let a = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let b = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        Ok((a.local_addr().unwrap().port(), b.local_addr().unwrap().port()))
    }

    #[tokio::test]
    async fn screens_start_dev_on_fresh_ports_capture_the_touched_routes_and_always_stop_it() {
        let root = temp("screens");
        let repo = task_repo(&root);
        let home = root.join("home");
        let fixture = root.join("fixture.png");
        std::fs::write(&fixture, PNG).unwrap();
        let calls = root.join("calls.txt");
        let pid = root.join("dev.pid");
        // A dev server that's a plain HTTP server on $PORT; it says which ports it got.
        let dev = format!("echo $$ > {}; echo \"api on $MAPLE_API_PORT\"; exec python3 -m http.server $PORT --bind 127.0.0.1", pid.display());
        let capture = |url: &str, w: u32, h: u32, out: &Path| {
            format!("echo '{url} {w}x{h}' >> {}; cp {} {}", calls.display(), fixture.display(), quote(&out.to_string_lossy()))
        };
        let (base, names) = uploads().await;
        let ports = free_ports().unwrap();
        let fixed = move || Ok(ports);
        let shots = Shots {
            home: home.clone(),
            origin: Some((&base, "mini", "t")),
            ports: &fixed,
            capture: &capture,
            install: None,
            ready_limit: Duration::from_secs(20),
        };
        let sent = std::sync::Mutex::new(vec![]);
        let emit = |m: Outbound| sent.lock().unwrap().push(serde_json::to_value(&m).unwrap());

        let rows = capture_screens(&emit, "t1", &repo, &screen_settings(&dev), "main", None, &shots).await;
        // #tasks (committed) and #new (not yet committed) were touched, / always counts; #cards wasn't.
        assert_eq!(
            rows.iter().map(|r| (r.kind, r.summary.as_str(), r.file.as_deref())).collect::<Vec<_>>(),
            [
                ("screen", "#tasks at 1280px", Some("tasks/t1/0123456789ab-tasks-1280.png")),
                ("screen", "#tasks at 390px", Some("tasks/t1/0123456789ab-tasks-390.png")),
                ("screen", "#new at 1280px", Some("tasks/t1/0123456789ab-new-1280.png")),
                ("screen", "#new at 390px", Some("tasks/t1/0123456789ab-new-390.png")),
                ("screen", "/ at 1280px", Some("tasks/t1/0123456789ab-home-1280.png")),
                ("screen", "/ at 390px", Some("tasks/t1/0123456789ab-home-390.png")),
            ]
        );
        assert_eq!(*names.lock().unwrap(), ["tasks-1280.png", "tasks-390.png", "new-1280.png", "new-390.png", "home-1280.png", "home-390.png"]);
        let (web, api) = ports;
        assert_eq!(
            std::fs::read_to_string(&calls).unwrap().lines().collect::<Vec<_>>(),
            [
                format!("http://localhost:{web}/#tasks 1280x800"),
                format!("http://localhost:{web}/#tasks 390x844"),
                format!("http://localhost:{web}/#new 1280x800"),
                format!("http://localhost:{web}/#new 390x844"),
                format!("http://localhost:{web}/ 1280x800"),
                format!("http://localhost:{web}/ 390x844"),
            ]
        );
        // Saved in the task's proof folder, under runner/, with dev's log.
        let out = folder(&home, "agent/tasks-badge-3f2a").join("runner");
        assert!(out.join("tasks-390.png").is_file() && out.join("home-1280.png").is_file());
        assert!(std::fs::read_to_string(out.join("dev.log")).unwrap().contains(&format!("api on {api}")));
        // The Tasks list heard dev, then each screenshot.
        let checks: Vec<String> = sent.lock().unwrap().iter().map(|m| format!("{} {}/{}", m["command"].as_str().unwrap(), m["n"], m["of"])).collect();
        assert_eq!(checks[..2], [format!("{dev} 1/1"), "screenshot #tasks at 1280px 1/6".to_string()]);
        // The server is gone.
        let pid: i32 = std::fs::read_to_string(&pid).unwrap().trim().parse().unwrap();
        assert!(!alive(pid), "dev is still running");
        assert!(std::net::TcpStream::connect(("127.0.0.1", web)).is_err());

        // Nothing to capture: no route touched, no screen kind, or no dev command; dev never starts.
        let only_cards = crate::factory::Settings { screens: Some("#cards web/src/cards.ts".into()), ..screen_settings(&dev) };
        assert!(capture_screens(&emit, "t1", &repo, &only_cards, "main", None, &shots).await.is_empty());
        let no_kind = crate::factory::Settings { proof_kinds: Some(vec!["test".into()]), ..screen_settings(&dev) };
        assert!(capture_screens(&emit, "t1", &repo, &no_kind, "main", None, &shots).await.is_empty());
        let no_dev = crate::factory::Settings { dev: None, ..screen_settings(&dev) };
        assert!(capture_screens(&emit, "t1", &repo, &no_dev, "main", None, &shots).await.is_empty());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn a_dev_server_that_never_answers_is_one_row_with_its_log_and_is_stopped() {
        let root = temp("screens");
        let repo = task_repo(&root);
        let pid = root.join("dev.pid");
        let capture = |_: &str, _: u32, _: u32, _: &Path| "exit 9".to_string();
        let fixed = || free_ports();
        let shots = Shots { home: root.join("home"), origin: None, ports: &fixed, capture: &capture, install: None, ready_limit: Duration::from_secs(1) };
        let emit = |_: Outbound| {};

        // It starts something in the background and never listens.
        let dev = format!("seq 1 80; sleep 60 & echo $! > {}; wait", pid.display());
        let began = std::time::Instant::now();
        let rows = capture_screens(&emit, "t1", &repo, &screen_settings(&dev), "main", None, &shots).await;
        assert!(began.elapsed() < Duration::from_secs(15), "{:?}", began.elapsed());
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].kind, "command");
        assert!(rows[0].summary.starts_with(&format!("Screens not captured: `{dev}` didn't answer on http://localhost:")), "{}", rows[0].summary);
        let text = rows[0].text.as_deref().unwrap();
        // The dev log's last 50 lines.
        assert!(text.contains("\n31\n") && text.ends_with("\n80") && !text.contains("\n30\n"), "{text}");
        let child: i32 = std::fs::read_to_string(&pid).unwrap().trim().parse().unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(!alive(child), "what dev started is still running");

        // One that exits says so.
        let rows = capture_screens(&emit, "t1", &repo, &screen_settings("echo boom; exit 2"), "main", None, &shots).await;
        assert!(rows[0].summary.contains("exited (code 2)"), "{}", rows[0].summary);
        assert!(rows[0].text.as_deref().unwrap().contains("boom"));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn playwright_without_its_browser_is_one_row_with_the_install_command() {
        let root = temp("screens");
        let repo = task_repo(&root);
        // What Playwright prints when its Chromium isn't there.
        let capture = |_: &str, _: u32, _: u32, _: &Path| {
            "echo \"Error: browserType.launch: Executable doesn't exist at /Users/a/Library/Caches/ms-playwright/chromium-1243\"; exit 1".to_string()
        };
        let fixed = || free_ports();
        let shots = Shots { home: root.join("home"), origin: None, ports: &fixed, capture: &capture, install: None, ready_limit: Duration::from_secs(20) };
        let emit = |_: Outbound| {};
        let dev = "echo serving; exec python3 -m http.server $PORT --bind 127.0.0.1";
        let rows = capture_screens(&emit, "t1", &repo, &screen_settings(dev), "main", None, &shots).await;
        // One row for every route and width, with the command to run on this machine and dev's log.
        assert_eq!(rows.len(), 1);
        assert_eq!((rows[0].kind, rows[0].summary.as_str()), ("command", "Screens not captured: Playwright has no browser on this machine"));
        let text = rows[0].text.as_deref().unwrap();
        assert!(text.contains(&format!("    {}\n", install_command())), "{text}");
        assert!(text.contains("Executable doesn't exist") && text.contains("serving"), "{text}");

        // Any other failure is that screenshot's row, and the rest go on.
        let flaky = |url: &str, _: u32, _: u32, _: &Path| format!("echo 'timed out on {url}'; exit 1");
        let shots = Shots { capture: &flaky, ..shots };
        let rows = capture_screens(&emit, "t1", &repo, &screen_settings(dev), "main", None, &shots).await;
        assert_eq!(rows.len(), 6);
        assert_eq!(rows[0].summary, "Couldn't capture #tasks at 1280px");
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn a_missing_browser_is_installed_once_and_the_screenshots_go_on() {
        let root = temp("screens");
        let repo = task_repo(&root);
        let fixture = root.join("fixture.png");
        std::fs::write(&fixture, PNG).unwrap();
        let browser = root.join("chromium");
        // Like Playwright: no browser, no screenshot; once "installed", it saves one.
        let capture = |_: &str, _: u32, _: u32, out: &Path| {
            format!(
                "[ -e {b} ] || {{ echo \"Error: browserType.launch: Executable doesn't exist at {b}\"; exit 1; }}; cp {} {}",
                fixture.display(),
                quote(&out.to_string_lossy()),
                b = browser.display()
            )
        };
        let tried = std::sync::atomic::AtomicUsize::new(0);
        let install = || (tried.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0).then(|| format!("echo installing; touch {}", browser.display()));
        let (base, _) = uploads().await;
        let fixed = || free_ports();
        let shots = Shots {
            home: root.join("home"),
            origin: Some((&base, "mini", "t")),
            ports: &fixed,
            capture: &capture,
            install: Some(&install),
            ready_limit: Duration::from_secs(20),
        };
        let sent = std::sync::Mutex::new(vec![]);
        let emit = |m: Outbound| sent.lock().unwrap().push(serde_json::to_value(&m).unwrap());
        let dev = "exec python3 -m http.server $PORT --bind 127.0.0.1";
        let rows = capture_screens(&emit, "t1", &repo, &screen_settings(dev), "main", None, &shots).await;
        // Every screenshot is there, none says the browser is missing, and the install ran once.
        assert!(!rows.is_empty() && rows.iter().all(|r| r.kind == "screen"), "{:?}", rows.iter().map(|r| &r.summary).collect::<Vec<_>>());
        assert_eq!(tried.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert!(sent.lock().unwrap().iter().any(|m| m["command"].as_str().is_some_and(|c| c.contains("echo installing"))));

        // An install that fails says so in the one row, with what it printed.
        std::fs::remove_file(&browser).unwrap();
        let broken = || Some("echo 'no network'; exit 1".to_string());
        let shots = Shots { install: Some(&broken), ..shots };
        let rows = capture_screens(&emit, "t1", &repo, &screen_settings(dev), "main", None, &shots).await;
        assert_eq!(rows.len(), 1);
        let text = rows[0].text.as_deref().unwrap();
        assert!(text.contains("The runner tried to install it and couldn't") && text.contains("no network"), "{text}");
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn screens_follow_checks_that_all_passed() {
        let root = temp("screens");
        let repo = task_repo(&root);
        std::process::Command::new("git").arg("-C").arg(&repo).args(["remote", "add", "origin", "https://github.com/acme/widgets.git"]).output().unwrap();
        std::process::Command::new("git").arg("-C").arg(&repo).args(["update-ref", "refs/remotes/origin/main", "main"]).output().unwrap();
        let fixture = root.join("fixture.png");
        std::fs::write(&fixture, PNG).unwrap();
        let capture = |_: &str, _: u32, _: u32, out: &Path| format!("cp {} {}", fixture.display(), quote(&out.to_string_lossy()));
        let (base, _) = uploads().await;
        let fixed = || free_ports();
        let shots = Shots {
            home: root.join("home"),
            origin: Some((&base, "mini", "t")),
            ports: &fixed,
            capture: &capture,
            install: None,
            ready_limit: Duration::from_secs(20),
        };
        let settings = |test: &str| crate::factory::Settings {
            test: Some(test.into()),
            screens: Some("/".into()),
            ..screen_settings("exec python3 -m http.server $PORT --bind 127.0.0.1")
        };
        let p = |test: &str| Prove {
            task_id: "t1".into(),
            cwd: repo.to_string_lossy().into(),
            base: Some("main".into()),
            projects: vec![crate::factory::Project { repo: "acme/widgets".into(), name: "Widgets".into(), settings: settings(test) }],
        };
        // The fetch is answered from the repo itself.
        let emit = |m: Outbound| {
            if let Outbound::TaskTokenRequest { req_id, .. } = &m {
                crate::tasks::resolve(req_id, crate::tasks::TokenReply { token: Some("ghs_test-token".into()), error: None, code: None, settings_url: None });
            }
        };
        let fetch = repo.to_string_lossy().to_string();
        let out = serde_json::to_value(prove_task(&emit, &p("true"), Some(&fetch), None, Duration::from_secs(30), Some(&shots)).await).unwrap();
        assert_eq!(out["screens"].as_array().map(Vec::len), Some(2), "{out}");
        assert_eq!(out["screens"][1], json!({ "kind": "screen", "summary": "/ at 390px", "file": "tasks/t1/0123456789ab-home-390.png" }));
        // A failed check: no screens at all.
        let out = serde_json::to_value(prove_task(&emit, &p("false"), Some(&fetch), None, Duration::from_secs(30), Some(&shots)).await).unwrap();
        assert!(out.get("screens").is_none(), "{out}");
        std::fs::remove_dir_all(&root).unwrap();
    }
}
