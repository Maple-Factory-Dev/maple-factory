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
//! The CLI can't open a second hub connection (the hub keeps the newest runner with a name), so
//! `secrets pull` and `secrets list` ask the running runner over its local hook socket, one line
//! `{"secrets":{"repo":"owner/name"}}`, answered with `{"values":{…}}` or `{"error":"…"}`.

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
/// tmux sends a whole command to its server as one message (16 KB at most), so the `-e`s of a
/// session's secrets have to fit in what's left of it; any that don't are left out with a warning.
pub const ENV_BUDGET: usize = 12 * 1024;
/// The session option naming the secrets in its environment.
pub const OPTION: &str = "@maple_secrets";

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

/// The `-e NAME=value` pairs for a session, within `ENV_BUDGET`, and the names left out.
pub fn session_env(values: &BTreeMap<String, String>) -> (Vec<(String, String)>, Vec<String>) {
    let (mut env, mut skipped, mut used) = (vec![], vec![], 0);
    for (name, value) in values {
        let size = name.len() + value.len() + 8;
        if used + size > ENV_BUDGET {
            skipped.push(name.clone());
            continue;
        }
        used += size;
        env.push((name.clone(), value.clone()));
    }
    (env, skipped)
}

/// A task's secrets for its session's environment. Never fails the task: anything that goes wrong
/// is a warning in the runner's log, and the session starts without them.
pub async fn for_task(emit: Emit<'_>, task_id: &str, repo: Option<&str>) -> Vec<(String, String)> {
    let Some(repo) = repo.filter(|r| r.contains('/')) else { return vec![] };
    match request(emit, repo, Some(task_id)).await {
        Ok(values) if values.is_empty() => vec![],
        Ok(values) => {
            let (env, skipped) = session_env(&values);
            if !skipped.is_empty() {
                tracing::warn!("task {task_id}: {} too big for the session's environment, left out", skipped.join(", "));
            }
            tracing::info!("task {task_id}: {} secret{} from {repo} in its session's environment", env.len(), if env.len() == 1 { "" } else { "s" });
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

/// After a restart: the values in an adopted session's environment, remembered for `scrub` again.
pub async fn recover(tmux: &crate::tmux::Tmux, session: &str) {
    let Ok(names) = tmux.run(&["show-options", "-v", "-t", session, OPTION]).await else { return };
    let names: HashSet<&str> = names.split_whitespace().collect();
    if names.is_empty() {
        return;
    }
    let Ok(env) = tmux.run(&["show-environment", "-t", session]).await else { return };
    let values: Vec<String> = env.lines().filter_map(|l| l.split_once('=')).filter(|(k, _)| names.contains(k)).map(|(_, v)| v.to_string()).collect();
    remember(values.iter());
}

/// A `{"secrets":{"repo"}}` line from the hook socket: the CLI's pull, for the machine's owner.
pub async fn serve(sessions: &crate::sessions::Sessions, line: &Value) -> Value {
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

    #[test]
    fn env_fits_tmux() {
        let mut values = BTreeMap::new();
        values.insert("A_KEY".to_string(), "x".repeat(100));
        values.insert("B_BIG".to_string(), "y".repeat(ENV_BUDGET));
        values.insert("C_KEY".to_string(), "z".repeat(100));
        let (env, skipped) = session_env(&values);
        assert_eq!(env.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(), ["A_KEY", "C_KEY"]);
        assert_eq!(skipped, ["B_BIG"]);
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

    /// A task session's secrets are in its environment (the shell sees them) and named on the tmux
    /// session, the worktree gets no file, and a restarted runner finds them again for `scrub`.
    #[tokio::test]
    async fn a_task_session_gets_them_in_its_environment_only() {
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
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let tmux = crate::tmux::Tmux::new(&format!("t{tag}"), &home).unwrap();
        let hooks = crate::hooks::Hooks::prepare(&home, &format!("t{tag}")).unwrap();
        let sessions = crate::sessions::Sessions::start(tx, tmux, hooks).await.unwrap();
        let id = Uuid::new_v4();
        let env = vec![("API_KEY".to_string(), value.clone()), ("DB_URL".to_string(), "postgres://u:p@h/db".to_string())];
        sessions.open(id, "shell", wt.to_str().unwrap(), None, None, &[], None, false, 120, 30, None, &env).await.unwrap();

        let tmux = crate::tmux::Tmux::new(&format!("t{tag}"), &home).unwrap();
        let name = format!("maple-{id}");
        assert_eq!(tmux.run(&["show-environment", "-t", &name, "API_KEY"]).await.unwrap().trim(), format!("API_KEY={value}"));
        assert_eq!(tmux.run(&["show-options", "-v", "-t", &name, OPTION]).await.unwrap().trim(), "API_KEY DB_URL");
        // The shell in the session has it: the typed line says `$API_KEY`, only its output has the value.
        tmux.run(&["send-keys", "-t", &name, "echo \"got:$API_KEY\"", "Enter"]).await.unwrap();
        let mut screen = String::new();
        for _ in 0..50 {
            tokio::time::sleep(Duration::from_millis(100)).await;
            screen = tmux.run(&["capture-pane", "-p", "-t", &name]).await.unwrap();
            if screen.contains(&format!("got:{value}")) {
                break;
            }
        }
        assert!(screen.contains(&format!("got:{value}")), "{screen}");
        // Nothing new in the worktree, not even an ignored file.
        assert_eq!(git(&wt, &["status", "--porcelain", "--ignored", "--untracked-files=all"]).unwrap(), before);

        // A restarted runner reads them back from the session, so it keeps scrubbing them.
        assert_eq!(scrub(&value), value);
        recover(&tmux, &name).await;
        assert_eq!(scrub(&format!("leaked {value}")), "leaked ***");

        let _ = tmux.run(&["kill-server"]).await;
        let _ = std::fs::remove_dir_all(&home);
        let _ = std::fs::remove_dir_all(&wt);
    }
}
