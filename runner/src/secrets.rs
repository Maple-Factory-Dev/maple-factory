//! A repo's secrets from the factory: as environment variables in a task's sessions, or as a
//! gitignored `.env.local` in the owner's own checkout (`maple-runner secrets pull`).
//!
//! The hub hands a repo's values (`secrets.request` / `secrets.reply`) only to the machine a task on
//! that repo is assigned to, or, with no task, to a machine whose owner is one of the org's members.
//! A task's session gets them in its tmux session's environment (`new-session -e`), never as a file,
//! so nothing lands in the worktree where it could be committed. The session's `@maple_secrets`
//! option names them, so a restarted runner can find their values again.
//!
//! Every value the runner has been given is remembered for `scrub`: it's replaced by `***` in
//! everything the runner sends the hub (agents' MCP calls and proofs, session ends' last output,
//! activity) and in git's error messages (`tasks::scrub`).
//!
//! The tmux command that starts such a session goes to tmux on its stdin, not in its argv, which
//! any user on the machine can read with `ps`.
//!
//! The CLI can't open a second hub connection (the hub keeps the newest runner with a name), so
//! `secrets pull` and `secrets list` ask the running runner over its local hook socket, one line
//! `{"secrets":{"repo":"owner/name"}}`, answered with `{"values":{…}}` or `{"error":"…"}`. Every
//! session can reach that socket, so the runner refuses a request from a process in one of its
//! sessions (found by walking up from the socket peer's pid): an agent, prompt-injected or not,
//! can't use the owner's pull to read another repo's values. A process that detaches itself from
//! its session (double-forks to launchd/init) gets past that check; the socket is only as private
//! as the user account it runs under.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex, RwLock};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use tokio::sync::oneshot;
use uuid::Uuid;

use crate::protocol::Outbound;
use crate::tasks::Emit;

/// How long a starting task waits for its secrets before it starts without them.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
/// Shorter values aren't scrubbed: replacing every "abc" in a log would mangle it and hide nothing.
const MIN_SCRUB: usize = 6;
/// The session option naming the secrets its pane was given.
pub const OPTION: &str = "@maple_secrets";
/// The session option naming the repo they came from, so an adopting runner can ask for them again.
pub const REPO_OPTION: &str = "@maple_secrets_repo";
/// Names the one-shot file (`env_file`) a session's shell reads its secrets from.
pub const FILE_ENV: &str = "MAPLE_SECRETS_FILE";

/// The hub's answer.
pub struct Reply {
    pub values: Option<BTreeMap<String, String>>,
    pub error: Option<String>,
    pub code: Option<String>,
}

static PENDING: LazyLock<Mutex<HashMap<String, oneshot::Sender<Reply>>>> = LazyLock::new(Mutex::default);
static KNOWN: LazyLock<RwLock<HashSet<String>>> = LazyLock::new(RwLock::default);

/// The hub's `secrets.reply`.
pub fn resolve(req_id: &str, reply: Reply) {
    if let Some(tx) = PENDING.lock().unwrap().remove(req_id) {
        let _ = tx.send(reply);
    }
}

/// Why the hub didn't hand them over.
#[derive(Debug)]
pub struct Refused {
    pub message: String,
    pub code: Option<String>,
}

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Refused {}

/// A repo's values, by name; they're remembered for `scrub` before they're returned.
pub async fn request(emit: Emit<'_>, repo: &str, task_id: Option<&str>) -> Result<BTreeMap<String, String>> {
    let req_id = Uuid::new_v4().to_string();
    let (tx, rx) = oneshot::channel();
    PENDING.lock().unwrap().insert(req_id.clone(), tx);
    emit(Outbound::SecretsRequest { req_id: req_id.clone(), task_id: task_id.map(str::to_string), repo: repo.to_string() });
    let reply = tokio::time::timeout(REQUEST_TIMEOUT, rx).await;
    PENDING.lock().unwrap().remove(&req_id);
    let reply = match reply {
        Ok(Ok(r)) => r,
        _ => bail!("The factory didn't answer in time."),
    };
    match (reply.values, reply.error) {
        (_, Some(message)) => Err(Refused { message, code: reply.code }.into()),
        (Some(values), None) => {
            remember(values.values());
            Ok(values)
        }
        (None, None) => Ok(BTreeMap::new()),
    }
}

/// Values for `scrub` to take out from now on.
pub fn remember<'a>(values: impl IntoIterator<Item = &'a String>) {
    let mut known = KNOWN.write().unwrap();
    for v in values {
        if v.chars().count() >= MIN_SCRUB {
            known.insert(v.clone());
        }
    }
}

/// `text` with every remembered value replaced by `***`, longest first (so one inside another goes whole).
pub fn scrub(text: &str) -> String {
    let known = KNOWN.read().unwrap();
    if known.is_empty() {
        return text.to_string();
    }
    let mut values: Vec<&String> = known.iter().filter(|v| text.contains(v.as_str())).collect();
    values.sort_by_key(|v| std::cmp::Reverse(v.len()));
    values.into_iter().fold(text.to_string(), |t, v| t.replace(v.as_str(), "***"))
}

/// The remembered values as bytes, longest first.
fn known_bytes() -> Vec<Vec<u8>> {
    let mut values: Vec<Vec<u8>> = KNOWN.read().unwrap().iter().map(|v| v.as_bytes().to_vec()).collect();
    values.sort_by_key(|v| std::cmp::Reverse(v.len()));
    values
}

/// `data` with every one of `values` (longest first) replaced by `***`, in one pass.
fn replace_bytes(data: &[u8], values: &[Vec<u8>]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let mut i = 0;
    while i < data.len() {
        match values.iter().find(|v| data[i..].starts_with(v)) {
            Some(v) => {
                out.extend_from_slice(b"***");
                i += v.len();
            }
            None => {
                out.push(data[i]);
                i += 1;
            }
        }
    }
    out
}

/// `scrub` on bytes, for something sent whole (a session's replay).
pub fn scrub_bytes(data: &[u8]) -> Vec<u8> {
    let values = known_bytes();
    if values.is_empty() { data.to_vec() } else { replace_bytes(data, &values) }
}

/// Scrubs a stream (a session's terminal output) that comes in pieces: a value split between two
/// pieces is still replaced. It holds back only the end of a piece that could be the start of a
/// remembered value (at most the longest value's length less one), until the next piece or `flush`.
/// It reads the remembered values on every piece, so ones remembered later count too.
#[derive(Default)]
pub struct Scrubber {
    held: Vec<u8>,
}

impl Scrubber {
    /// What of `held` + `chunk` can go out now, scrubbed.
    pub fn feed(&mut self, chunk: &[u8]) -> Vec<u8> {
        let mut buf = std::mem::take(&mut self.held);
        buf.extend_from_slice(chunk);
        let values = known_bytes();
        if values.is_empty() {
            return buf;
        }
        let mut out = replace_bytes(&buf, &values);
        let longest = values[0].len();
        let keep = (1..longest.min(out.len() + 1)).rev().find(|&n| {
            let tail = &out[out.len() - n..];
            values.iter().any(|v| v.len() > n && v.starts_with(tail))
        });
        if let Some(n) = keep {
            self.held = out.split_off(out.len() - n);
        }
        out
    }

    /// Whether it's holding anything back.
    pub fn holding(&self) -> bool {
        !self.held.is_empty()
    }

    /// What it held back: only ever the start of a value, never a whole one.
    pub fn flush(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.held)
    }
}

/// Whether anything is remembered (so a message needs scrubbing at all).
pub fn any() -> bool {
    !KNOWN.read().unwrap().is_empty()
}

/// Every string in `value`, scrubbed in place.
pub fn scrub_json(value: &mut Value) {
    match value {
        Value::String(s) => {
            let clean = scrub(s);
            if clean != *s {
                *s = clean;
            }
        }
        Value::Array(items) => items.iter_mut().for_each(scrub_json),
        Value::Object(map) => map.values_mut().for_each(scrub_json),
        _ => {}
    }
}

/// A task's secrets for its session. Never fails the task: anything that goes wrong is a warning in
/// the runner's log, and the session starts without them.
pub async fn for_task(emit: Emit<'_>, task_id: &str, repo: Option<&str>) -> Vec<(String, String)> {
    let Some(repo) = repo.filter(|r| r.contains('/')) else { return vec![] };
    match request(emit, repo, Some(task_id)).await {
        Ok(values) => {
            let env: Vec<(String, String)> = values.into_iter().filter(|(name, _)| usable_name(name)).collect();
            if !env.is_empty() {
                tracing::info!("task {task_id}: {} secret{} from {repo} for its session", env.len(), if env.len() == 1 { "" } else { "s" });
            }
            env
        }
        // A repo the factory doesn't list has none to give.
        Err(e) if e.downcast_ref::<Refused>().is_some_and(|r| r.code.as_deref() == Some("unknown_repo")) => vec![],
        Err(e) => {
            tracing::warn!("task {task_id}: starting without {repo}'s secrets: {e:#}");
            vec![]
        }
    }
}

/// A name a shell can take as a variable (the hub only allows those, but the file is sourced).
fn usable_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_') && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Where session `id`'s one-shot secrets file goes: in the runner's config folder, never the worktree.
pub fn env_path(id: Uuid) -> Result<PathBuf> {
    Ok(crate::config::dir()?.join("secrets").join(format!("{id}.env")))
}

/// Writes `values` as `NAME='value'` lines for session `id`'s shell to source and remove (`source_first`),
/// readable only by this user.
pub fn env_file(id: Uuid, values: &[(String, String)]) -> Result<PathBuf> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let path = env_path(id)?;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(path.parent().unwrap())?;
    let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&path)?;
    let mut text = String::new();
    for (name, value) in values.iter().filter(|(n, _)| usable_name(n)) {
        text.push_str(&format!("{name}='{}'\n", value.replace('\'', r"'\''")));
    }
    f.write_all(text.as_bytes())?;
    Ok(path)
}

/// `argv` (a login shell starting an agent, `agents::argv`) made to read the file `MAPLE_SECRETS_FILE`
/// names into its environment, and remove it, before anything else runs: the values are then only in
/// the pane's processes, not in tmux's session environment where any client of the server can read them.
pub fn source_first(mut argv: Vec<String>) -> Vec<String> {
    let prefix = format!(
        r#"if [ -n "${FILE_ENV}" ]; then set -a; . "${FILE_ENV}"; set +a; rm -f -- "${FILE_ENV}"; fi; unset {FILE_ENV}; "#
    );
    if argv.len() > 4 && argv[3] == "-c" {
        argv[4] = format!("{prefix}{}", argv[4]);
        return argv;
    }
    // A bare shell (`[shell, -l]`): a short script that reads the file, then becomes that shell.
    let shell = argv.remove(0);
    let mut wrapped = vec![shell.clone(), "-c".into(), format!(r#"{prefix}exec "$0" "$@""#), shell];
    wrapped.extend(argv);
    wrapped
}

/// What an adopted session's secrets need from the hub again: the task they were released to, and its repo.
#[derive(Debug, Clone, PartialEq)]
pub struct Pending {
    pub task: String,
    pub repo: String,
}

/// After a restart: an adopted session's secrets, remembered for `scrub` again. A session an older
/// runner started still has them in tmux's environment: they're read from there whole (a value can
/// span lines) and then taken out of it. A newer one's are only in its pane, so the hub is asked
/// again with its task (`refetch`), once connected; that's what's returned.
pub async fn recover(tmux: &crate::tmux::Tmux, session: &str, task: Option<&str>) -> Option<Pending> {
    let names = tmux.run(&["show-options", "-v", "-t", session, OPTION]).await.ok()?;
    let names: Vec<&str> = names.split_whitespace().collect();
    if names.is_empty() {
        return None;
    }
    let mut values = vec![];
    for name in &names {
        let Ok(line) = tmux.run(&["show-environment", "-t", session, name]).await else { continue };
        // `NAME=value\n`; a removed one shows as `-NAME`.
        let Some(value) = line.strip_prefix(&format!("{name}=")) else { continue };
        values.push(value.strip_suffix('\n').unwrap_or(value).to_string());
        let _ = tmux.run(&["set-environment", "-u", "-t", session, name]).await;
    }
    remember(values.iter());
    let repo = tmux.run(&["show-options", "-v", "-t", session, REPO_OPTION]).await.ok()?;
    let (task, repo) = (task?, repo.trim());
    (!repo.is_empty()).then(|| Pending { task: task.to_string(), repo: repo.to_string() })
}

/// Asks the hub again for an adopted session's secrets (`recover`), so they're scrubbed. Whether it answered.
pub async fn refetch(emit: Emit<'_>, pending: &Pending) -> bool {
    match request(emit, &pending.repo, Some(&pending.task)).await {
        Ok(_) => true,
        Err(e) if e.downcast_ref::<Refused>().is_some() => {
            tracing::info!("task {}: the factory won't release {}'s secrets again: {e:#}", pending.task, pending.repo);
            true
        }
        Err(e) => {
            tracing::warn!("task {}: couldn't get {}'s secrets again: {e:#}", pending.task, pending.repo);
            false
        }
    }
}

/// A `{"secrets":{"repo"}}` line from the hook socket: the CLI's pull, for the machine's owner.
/// `peer` is the asking process; one inside a session (an agent, or anything it ran) is refused,
/// so a task's agent gets its own repo's values in its environment and no other repo's.
pub async fn serve(sessions: &crate::sessions::Sessions, peer: Option<u32>, line: &Value) -> Value {
    let Some(peer) = peer else {
        return json!({ "error": "The runner couldn't tell which process asked, so it won't answer." });
    };
    if sessions.hosts(peer).await {
        return json!({ "error": "Secrets can't be pulled from inside a factory session; run `maple-runner secrets pull` in your own terminal." });
    }
    let Some(repo) = line.get("repo").and_then(Value::as_str).filter(|r| r.contains('/')) else {
        return json!({ "error": "Which repo? Give it as owner/name." });
    };
    if !crate::mcp::connected() {
        return json!({ "error": "The runner isn't connected to the factory right now." });
    }
    let emit = |m: Outbound| sessions.emit(m);
    match request(&emit, repo, None).await {
        Ok(values) => json!({ "values": values }),
        Err(e) => json!({ "error": format!("{e:#}") }),
    }
}

// ---- the CLI ----

/// `maple-runner secrets pull|list`: asks the running runner for `repo`'s secrets (the one behind
/// the current folder's origin when not given).
pub fn cli(list: bool, repo: Option<String>, out: Option<PathBuf>, force: bool, tmux_socket: &str) -> Result<()> {
    let here = std::env::current_dir()?;
    let checkout = git_root(&here);
    let repo = match repo {
        Some(r) => r,
        None => {
            let root = checkout.as_deref().ok_or_else(|| anyhow!("{} isn't in a git checkout; name the repo (owner/name).", here.display()))?;
            let origin =
                git(root, &["config", "--get", "remote.origin.url"]).map_err(|_| anyhow!("This checkout has no origin; name the repo (owner/name)."))?;
            let (owner, name) = crate::tasks::parse_github(&origin).ok_or_else(|| anyhow!("origin isn't on GitHub; name the repo (owner/name)."))?;
            format!("{owner}/{name}")
        }
    };
    let values = ask(&socket_path(tmux_socket)?, &repo)?;
    if list {
        if values.is_empty() {
            println!("{repo} has no secrets.");
        }
        for name in values.keys() {
            println!("{name}");
        }
        return Ok(());
    }
    let path = match out {
        Some(p) if p.is_absolute() => p,
        Some(p) => here.join(p),
        None => checkout.unwrap_or(here).join(".env.local"),
    };
    if !force {
        ignored(&path)?;
    }
    write_env(&path, &values)?;
    println!("Wrote {} secret{} from {repo} to {} (mode 0600).", values.len(), if values.len() == 1 { "" } else { "s" }, path.display());
    Ok(())
}

/// The running runner's hook socket.
fn socket_path(tmux_socket: &str) -> Result<PathBuf> {
    let path = crate::config::dir()?.join(format!("runner-{tmux_socket}.sock"));
    if !path.exists() {
        bail!("The runner isn't running here (no {}). Start it with `maple-runner run` or `maple-runner install`.", path.display());
    }
    Ok(path)
}

fn ask(socket: &Path, repo: &str) -> Result<BTreeMap<String, String>> {
    use std::io::{BufRead, BufReader, Write};
    let mut stream = std::os::unix::net::UnixStream::connect(socket).context("connecting to the runner")?;
    stream.set_read_timeout(Some(REQUEST_TIMEOUT + Duration::from_secs(5)))?;
    let mut line = serde_json::to_vec(&json!({ "secrets": { "repo": repo } }))?;
    line.push(b'\n');
    stream.write_all(&line)?;
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).context("waiting for the runner")?;
    let answer: Value = serde_json::from_str(&answer).map_err(|_| anyhow!("The runner didn't answer (is it older than this command?)."))?;
    if let Some(e) = answer.get("error").and_then(Value::as_str) {
        bail!("{e}");
    }
    Ok(serde_json::from_value(answer.get("values").cloned().unwrap_or_default()).unwrap_or_default())
}

/// Refuses a path git would commit: `git check-ignore` must say it's ignored.
pub fn ignored(path: &Path) -> Result<()> {
    let dir = path.parent().filter(|d| d.is_dir()).ok_or_else(|| anyhow!("{} isn't a folder.", path.parent().unwrap_or(path).display()))?;
    let status = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["check-ignore", "-q", "--"])
        .arg(path)
        .stderr(std::process::Stdio::null())
        .status()
        .context("running git check-ignore")?;
    match status.code() {
        Some(0) => Ok(()),
        Some(1) => bail!("{} isn't gitignored, so the secrets could be committed. Add it to .gitignore (or pass --force).", path.display()),
        _ => bail!("{} isn't in a git checkout, so git can't say it's ignored (pass --force to write it anyway).", path.display()),
    }
}

/// Writes `NAME="value"` lines, readable only by this user (0600, even over an existing file).
pub fn write_env(path: &Path, values: &BTreeMap<String, String>) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let mut f =
        std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path).with_context(|| format!("writing {}", path.display()))?;
    f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    let mut text = String::from("# From the factory's secrets (maple-runner secrets pull). Don't commit this file.\n");
    for (name, value) in values {
        text.push_str(&format!("{name}={}\n", dotenv_quote(value)));
    }
    f.write_all(text.as_bytes())?;
    Ok(())
}

/// A double-quoted dotenv value: backslashes, quotes, `$` and newlines escaped.
fn dotenv_quote(value: &str) -> String {
    let mut out = String::from("\"");
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '$' => out.push_str("\\$"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn git_root(dir: &Path) -> Option<PathBuf> {
    git(dir, &["rev-parse", "--show-toplevel"]).ok().map(PathBuf::from)
}

fn git(dir: &Path, args: &[&str]) -> Result<String> {
    let out = std::process::Command::new("git").arg("-C").arg(dir).args(args).output()?;
    if !out.status.success() {
        bail!("{}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrubs_remembered_values() {
        remember([&"sk-live-abcdef123".to_string(), &"sk-live-abcdef123-longer".to_string(), &"abc".to_string()]);
        assert_eq!(scrub("key sk-live-abcdef123-longer and sk-live-abcdef123, abc"), "key *** and ***, abc");
        let mut v = json!({ "type": "mcp.request", "args": { "output": ["ok", "token=sk-live-abcdef123"] }, "n": 3 });
        scrub_json(&mut v);
        assert_eq!(v, json!({ "type": "mcp.request", "args": { "output": ["ok", "token=***"] }, "n": 3 }));
        // git's errors too.
        assert_eq!(crate::tasks::scrub("fatal: sk-live-abcdef123", None), "fatal: ***");
    }

    /// Everything a scrubber lets out for `chunks`, then its flush.
    fn stream(chunks: &[&[u8]]) -> Vec<u8> {
        let mut scrubber = Scrubber::default();
        let mut out: Vec<u8> = chunks.iter().flat_map(|c| scrubber.feed(c)).collect();
        out.extend(scrubber.flush());
        out
    }

    #[test]
    fn scrubber_catches_a_value_split_anywhere() {
        let value = "sk-split-0123456789";
        remember([&value.to_string()]);
        let text = format!("token: {value}\r\n$ ");
        let bytes = text.as_bytes();
        let want = b"token: ***\r\n$ ".to_vec();
        for i in 0..=bytes.len() {
            assert_eq!(stream(&[&bytes[..i], &bytes[i..]]), want, "split at {i}");
            for j in i..=bytes.len() {
                assert_eq!(stream(&[&bytes[..i], &bytes[i..j], &bytes[j..]]), want, "split at {i} and {j}");
            }
        }
        // One byte at a time.
        assert_eq!(stream(&bytes.chunks(1).collect::<Vec<_>>()), want);
        // It holds back the start of the value until the rest comes, and no more than that.
        let mut scrubber = Scrubber::default();
        assert_eq!(scrubber.feed(b"key=sk-split-01"), b"key=");
        assert!(scrubber.holding());
        assert_eq!(scrubber.feed(b"23456789!"), b"***!");
        assert!(!scrubber.holding());
        // A start that never finishes goes out as it was.
        assert_eq!(scrubber.feed(b"sk-split"), b"");
        assert_eq!(scrubber.flush(), b"sk-split");
    }

    #[test]
    fn scrubber_leaves_other_output_alone() {
        remember([&"sk-other-0123456789".to_string()]);
        // Bytes that aren't UTF-8, escapes, and a near miss, split every way: out byte for byte.
        let text: &[u8] = b"\x1b[1;32mok\x1b[0m \xff\xfe sk-other-012345678X done\r\n";
        for i in 0..=text.len() {
            assert_eq!(stream(&[&text[..i], &text[i..]]), text, "split at {i}");
        }
        assert_eq!(scrub_bytes(text), text);
        assert_eq!(scrub_bytes(b"a sk-other-0123456789 b"), b"a *** b");
    }

    #[test]
    fn env_file_quotes_for_the_shell() {
        let id = Uuid::new_v4();
        let values = vec![("API_KEY".to_string(), "it's \"p$w\\d\"\nline 2".to_string()), ("bad name".to_string(), "x".to_string())];
        let path = env_file(id, &values).unwrap();
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        let out = std::process::Command::new("sh")
            .args(["-c", r#"set -a; . "$F"; set +a; printf %s "$API_KEY""#])
            .env("F", &path)
            .output()
            .unwrap();
        assert_eq!(String::from_utf8(out.stdout).unwrap(), values[0].1);
        assert!(!std::fs::read_to_string(&path).unwrap().contains("bad name"));
        std::fs::remove_file(&path).unwrap();
        // A shell agent's argv gets a script in front; an agent's `-c` script gets it prepended.
        assert_eq!(source_first(vec!["/bin/zsh".into(), "-l".into()])[..2], ["/bin/zsh", "-c"]);
        assert_eq!(source_first(vec!["/bin/zsh".into(), "-l".into()])[3..], ["/bin/zsh", "-l"]);
        let agent = source_first(vec!["/bin/zsh".into(), "-l".into(), "-i".into(), "-c".into(), r#"exec "$0" "$@""#.into(), "claude".into()]);
        assert!(agent[4].starts_with("if [ -n \"$MAPLE_SECRETS_FILE\" ]") && agent[4].ends_with(r#"exec "$0" "$@""#), "{}", agent[4]);
    }

    #[test]
    fn quotes_dotenv_values() {
        assert_eq!(dotenv_quote("plain"), "\"plain\"");
        assert_eq!(dotenv_quote("a\"b\\c$d\ne"), r#""a\"b\\c\$d\ne""#);
    }

    fn temp(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("maple-secrets-{tag}-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn repo(tag: &str) -> PathBuf {
        let dir = temp(tag);
        git(&dir, &["init", "-q"]).unwrap();
        std::fs::write(dir.join(".gitignore"), ".env.local\n").unwrap();
        dir
    }

    #[test]
    fn pull_refuses_a_path_that_isnt_ignored() {
        let dir = repo("ignored");
        let err = ignored(&dir.join(".env")).unwrap_err().to_string();
        assert!(err.contains("isn't gitignored"), "{err}");
        assert!(!dir.join(".env").exists());
        ignored(&dir.join(".env.local")).unwrap();
        let outside = temp("outside");
        assert!(ignored(&outside.join(".env.local")).unwrap_err().to_string().contains("isn't in a git checkout"));
    }

    #[test]
    fn pull_writes_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = repo("write");
        let path = dir.join(".env.local");
        // Even over a file someone left world-readable.
        std::fs::write(&path, "old").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let values = BTreeMap::from([("API_KEY".to_string(), "sk-1".to_string()), ("DB_URL".to_string(), "postgres://u:p@h/db".to_string())]);
        write_env(&path, &values).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("API_KEY=\"sk-1\"\nDB_URL=\"postgres://u:p@h/db\"\n"), "{text}");
    }

    /// A starting task asks for its own repo's secrets with its id; a refusal or no answer starts it without them.
    #[tokio::test]
    async fn a_starting_task_asks_with_its_id() {
        let sent = Mutex::new(vec![]);
        let hub = |m: Outbound| {
            sent.lock().unwrap().push(serde_json::to_value(&m).unwrap());
            if let Outbound::SecretsRequest { req_id, task_id, .. } = m {
                let reply = match task_id.as_deref() {
                    Some("MF-1") => Reply { values: Some(BTreeMap::from([("API_KEY".into(), "sk-task-value-1".into())])), error: None, code: None },
                    _ => Reply { values: None, error: Some("That task isn't assigned to this machine.".into()), code: Some("forbidden".into()) },
                };
                resolve(&req_id, reply);
            }
        };
        assert_eq!(for_task(&hub, "MF-1", Some("acme/web")).await, [("API_KEY".to_string(), "sk-task-value-1".to_string())]);
        let asked = sent.lock().unwrap()[0].clone();
        assert_eq!((asked["type"].as_str(), asked["taskId"].as_str(), asked["repo"].as_str()), (Some("secrets.request"), Some("MF-1"), Some("acme/web")));
        // Remembered, so it's scrubbed from then on.
        assert_eq!(scrub("echo sk-task-value-1"), "echo ***");
        assert!(for_task(&hub, "MF-2", Some("acme/web")).await.is_empty());
        // No repo: nothing to ask for.
        assert!(for_task(&hub, "MF-3", None).await.is_empty());
        assert_eq!(sent.lock().unwrap().len(), 2);
    }

    /// Output from the session, as the hub would get it, until `want` shows up.
    async fn output_until(rx: &mut tokio::sync::mpsc::UnboundedReceiver<crate::sessions::Event>, id: Uuid, want: &str) -> String {
        let mut seen = vec![];
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while !String::from_utf8_lossy(&seen).contains(want) {
            match tokio::time::timeout_at(deadline, rx.recv()).await {
                Ok(Some(crate::sessions::Event::Output(from, data))) if from == id => seen.extend(data),
                Ok(Some(_)) => {}
                _ => break,
            }
        }
        String::from_utf8_lossy(&seen).into_owned()
    }

    /// A task session's secrets reach its pane's shell through a one-shot file outside the worktree:
    /// not tmux's environment (any client of the server could read that), not the worktree. Once
    /// remembered, they're scrubbed from its terminal output and replays, and a restarted runner
    /// asks the hub for them again with the session's task.
    #[tokio::test]
    async fn a_task_session_gets_them_in_its_pane_only() {
        let tag = &Uuid::new_v4().to_string()[..8];
        // Short: the tmux socket path must stay under 104 bytes.
        let home = PathBuf::from(format!("/tmp/mfs-{tag}"));
        std::fs::create_dir_all(&home).unwrap();
        let wt = repo("session");
        git(&wt, &["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"]).unwrap();
        git(&wt, &["add", ".gitignore"]).unwrap();
        git(&wt, &["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "ignore"]).unwrap();
        let before = git(&wt, &["status", "--porcelain", "--ignored", "--untracked-files=all"]).unwrap();

        let value = format!("sk-env-{tag}-value");
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let tmux = crate::tmux::Tmux::new(&format!("t{tag}"), &home).unwrap();
        let hooks = crate::hooks::Hooks::prepare(&home, &format!("t{tag}")).unwrap();
        let sessions = crate::sessions::Sessions::start(tx, tmux, hooks).await.unwrap();
        let id = Uuid::new_v4();
        // Sourced by the shell, so quotes, `$`, `\` and newlines must survive.
        let tricky = "it's \"p$w\\d\"\nline 2 #{x};";
        let env = vec![("API_KEY".to_string(), value.clone()), ("DB_URL".to_string(), tricky.to_string())];
        let info = sessions.open(id, "shell", wt.to_str().unwrap(), None, None, &[], None, false, 120, 30, None, Some(("acme/web", &env))).await.unwrap();

        let tmux = crate::tmux::Tmux::new(&format!("t{tag}"), &home).unwrap();
        let name = format!("maple-{id}");
        assert_eq!(tmux.run(&["show-options", "-v", "-t", &name, OPTION]).await.unwrap().trim(), "API_KEY DB_URL");
        assert_eq!(tmux.run(&["show-options", "-v", "-t", &name, REPO_OPTION]).await.unwrap().trim(), "acme/web");
        // The hook socket won't hand a session (its pane, or anything under it) the owner's pull.
        let pane = info.pid.unwrap();
        assert!(sessions.hosts(pane).await);
        assert!(!sessions.hosts(std::process::id()).await);
        let refused = serve(&sessions, Some(pane), &json!({ "repo": "acme/other" })).await;
        assert!(refused["error"].as_str().unwrap().contains("inside a factory session"), "{refused}");
        assert!(serve(&sessions, None, &json!({ "repo": "acme/other" })).await.get("error").is_some());
        // The shell in the session has them: the typed line says `$API_KEY`, only its output has the value.
        tmux.run(&["send-keys", "-t", &name, r#"echo "got:$API_KEY"; [ "$DB_URL" = "$(printf 'it'"'"'s "p$w\\d"\nline 2 #{x};')" ] && echo db:ok"#, "Enter"]).await.unwrap();
        let mut screen = String::new();
        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(100)).await;
            screen = tmux.run(&["capture-pane", "-p", "-t", &name]).await.unwrap();
            if screen.contains(&format!("got:{value}")) && screen.contains("db:ok") {
                break;
            }
        }
        assert!(screen.contains(&format!("got:{value}")), "{screen}");
        assert!(screen.lines().any(|l| l == "db:ok"), "{screen}");
        // …but tmux's environment, which any client of its server can read, has neither them nor their names.
        for scope in [["show-environment", "-t", &name], ["show-environment", "-g", ""]] {
            let shown = tmux.run(&scope.iter().filter(|a| !a.is_empty()).collect::<Vec<_>>()).await.unwrap();
            for gone in ["API_KEY", "DB_URL", value.as_str(), "line 2"] {
                assert!(!shown.contains(gone), "{scope:?} shows {gone}: {shown}");
            }
        }
        // The one-shot file is gone, and nothing new is in the worktree, not even an ignored file.
        assert!(!env_path(id).unwrap().exists());
        assert_eq!(git(&wt, &["status", "--porcelain", "--ignored", "--untracked-files=all"]).unwrap(), before);

        // A restarted runner finds nothing in tmux to read, so it asks the hub again with the task's id.
        assert_eq!(scrub(&value), value);
        let pending = recover(&tmux, &name, Some("MF-9")).await.unwrap();
        assert_eq!(pending, Pending { task: "MF-9".into(), repo: "acme/web".into() });
        assert_eq!(scrub(&value), value);
        let asked = Mutex::new(vec![]);
        let hub = |m: Outbound| {
            if let Outbound::SecretsRequest { req_id, task_id, repo } = m {
                asked.lock().unwrap().push((task_id.clone(), repo));
                resolve(&req_id, Reply { values: Some(BTreeMap::from([("API_KEY".into(), value.clone())])), error: None, code: None });
            }
        };
        assert!(refetch(&hub, &pending).await);
        assert_eq!(*asked.lock().unwrap(), [(Some("MF-9".to_string()), "acme/web".to_string())]);
        assert_eq!(scrub(&format!("leaked {value}")), "leaked ***");

        // Remembered, it's scrubbed from the terminal's bytes on their way to the hub…
        while rx.try_recv().is_ok() {}
        tmux.run(&["send-keys", "-t", &name, "echo \"again=${API_KEY}=end\"", "Enter"]).await.unwrap();
        let out = output_until(&mut rx, id, "again=***=end").await;
        assert!(out.contains("again=***=end") && !out.contains(&value), "{out:?}");
        // …and from a replay, before it's base64'd.
        sessions.replay(id, "n1".into());
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        let replay = loop {
            match tokio::time::timeout_at(deadline, rx.recv()).await.unwrap().unwrap() {
                crate::sessions::Event::Text(Outbound::SessionReplay { id: from, data, .. }) if from == id => break data,
                _ => {}
            }
        };
        use base64::Engine;
        let replay = String::from_utf8_lossy(&base64::engine::general_purpose::STANDARD.decode(replay).unwrap()).into_owned();
        assert!(replay.contains("got:***") && replay.contains("again=***=end") && !replay.contains(&value), "{replay:?}");

        let _ = tmux.run(&["kill-server"]).await;
        let _ = std::fs::remove_dir_all(&home);
        let _ = std::fs::remove_dir_all(&wt);
    }

    /// A session an older runner started holds its secrets in tmux's environment: a restarted runner
    /// reads them back whole, multi-line ones too, then takes them out of it.
    #[tokio::test]
    async fn recover_reads_an_older_session_whole_and_unsets_it() {
        let tag = &Uuid::new_v4().to_string()[..8];
        let home = PathBuf::from(format!("/tmp/mfo-{tag}"));
        std::fs::create_dir_all(&home).unwrap();
        let tmux = crate::tmux::Tmux::new(&format!("o{tag}"), &home).unwrap();
        let name = format!("maple-{}", Uuid::new_v4());
        let key = format!("-----BEGIN KEY {tag}-----\nline=two\n-----END KEY-----");
        let short = format!("sk-old-{tag}");
        tmux.run(&["new-session", "-d", "-s", &name, "-e", &format!("PEM={key}"), "-e", &format!("API_KEY={short}"), "sh"]).await.unwrap();
        tmux.run(&["set-option", "-t", &name, OPTION, "PEM API_KEY MISSING"]).await.unwrap();
        assert_eq!(scrub(&key), key);

        // No repo named: nothing to ask the hub for.
        assert_eq!(recover(&tmux, &name, Some("MF-3")).await, None);
        assert_eq!(scrub(&format!("cat: {key}\nok")), "cat: ***\nok");
        // Not its lines one by one: "line=two" alone is left alone.
        assert_eq!(scrub("line=two"), "line=two");
        assert_eq!(scrub(&short), "***");
        let shown = tmux.run(&["show-environment", "-t", &name]).await.unwrap();
        assert!(!shown.contains("BEGIN KEY") && !shown.contains(&short), "{shown}");

        let _ = tmux.run(&["kill-server"]).await;
        let _ = std::fs::remove_dir_all(&home);
    }
}
