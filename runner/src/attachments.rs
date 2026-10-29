//! A task's attachments: screenshots and files pasted or dropped into its brief or comments.
//!
//! In a brief an attachment is a link `/attachments/<uuid>/<name>` (server/src/attachments.ts), which
//! means nothing to an agent. When `get_task` comes back, the runner finds those links in the task,
//! fetches each with its own token (`GET /runner/attachments/<uuid>/<name>?runner=<id>`) into
//! `~/.cache/maple-attachments/<task>/<uuid>-<name>` (never the worktree, so nothing gets committed)
//! and adds `attachments: [{name, link, path}]` to the result, so the agent can Read them. One that
//! can't be fetched keeps its link and says why (`error`) instead of a path. A file that's already
//! there (the builder after the planner) is kept.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

/// One file's bytes (the control plane's limit).
pub const MAX_ATTACHMENT: u64 = 25 * 1024 * 1024;
/// The most a task's result lists.
pub const MAX_ATTACHMENTS: usize = 20;
const FETCH_TIMEOUT: Duration = Duration::from_secs(60);
const PREFIX: &str = "/attachments/";

/// An attachment a task links to: its id and stored name.
#[derive(Debug, Clone, PartialEq)]
pub struct Link {
    pub id: String,
    pub name: String,
}

impl Link {
    pub fn path(&self) -> String {
        format!("{PREFIX}{}/{}", self.id, self.name)
    }

    /// Its file in a task's folder: `<uuid>-<name>`, so two files of the same name don't collide.
    pub fn file(&self) -> String {
        format!("{}-{}", self.id, self.name)
    }
}

fn is_uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| if matches!(i, 8 | 13 | 18 | 23) { b == b'-' } else { matches!(b, b'0'..=b'9' | b'a'..=b'f') })
}

fn name_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')
}

/// Every `/attachments/<uuid>/<name>` in `text`, each once and in order, at most `MAX_ATTACHMENTS`.
/// Names are what the server stores (letters, digits, `.`, `_`, `-`, no `..`); anything else isn't a link.
pub fn links(text: &str) -> Vec<Link> {
    let mut out: Vec<Link> = Vec::new();
    let mut rest = text;
    while let Some(at) = rest.find(PREFIX) {
        rest = &rest[at + PREFIX.len()..];
        let Some(id) = rest.get(..36).filter(|id| is_uuid(id)) else { continue };
        let Some(after) = rest[36..].strip_prefix('/') else { continue };
        let len = after.bytes().take_while(|b| name_byte(*b)).count();
        // A sentence's full stop after a link isn't part of its name.
        let name = after[..len].trim_end_matches('.');
        if name.is_empty() || name.len() > 120 || name.contains("..") || name.starts_with(['.', '-']) {
            continue;
        }
        let link = Link { id: id.to_string(), name: name.to_string() };
        if !out.contains(&link) && out.len() < MAX_ATTACHMENTS {
            out.push(link);
        }
    }
    out
}

/// A task id that can be a folder's name.
fn valid_task(id: &str) -> bool {
    (1..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// `~/.cache/maple-attachments/<task>/`, or nothing for a task id that would leave it.
pub fn folder(home: &Path, task: &str) -> Option<PathBuf> {
    valid_task(task).then(|| home.join(".cache/maple-attachments").join(task))
}

/// A `get_task` result (`{summary, data: {task, …}}`) with its task's attachments fetched and listed
/// in `data.attachments`. One with no attachment links is left as it is.
pub async fn add_to_task(result: &mut Value) {
    let home = crate::sessions::expand_home("~");
    add_with(result, &home, crate::proof::origin()).await
}

pub async fn add_with(result: &mut Value, home: &Path, origin: Option<(&str, &str, &str)>) {
    let Some(task) = result.pointer("/data/task") else { return };
    let found = links(&task.to_string());
    if found.is_empty() {
        return;
    }
    let id = task.get("id").and_then(Value::as_str).unwrap_or_default().to_string();
    let mut listed = Vec::new();
    let mut saved = 0;
    for link in &found {
        let got = match (folder(home, &id), origin) {
            (None, _) => Err("the task's id isn't a folder name".to_string()),
            (_, None) => Err("the runner doesn't know its control plane".to_string()),
            (Some(dir), Some(origin)) => fetch(origin, &dir, link).await,
        };
        listed.push(match got {
            Ok(path) => {
                saved += 1;
                tracing::info!("task {id}'s attachment {} is at {}", link.name, path.display());
                json!({ "name": link.name, "link": link.path(), "path": path.display().to_string() })
            }
            Err(e) => {
                tracing::warn!("couldn't fetch task {id}'s attachment {}: {e}", link.path());
                json!({ "name": link.name, "link": link.path(), "error": e })
            }
        });
    }
    if let Some(data) = result.get_mut("data").and_then(Value::as_object_mut) {
        data.insert("attachments".into(), Value::Array(listed));
    }
    if let Some(summary) = result.get("summary").and_then(Value::as_str) {
        result["summary"] = json!(format!("{summary} · {}", saved_note(saved, found.len() - saved)));
    }
}

/// What `get_task`'s summary says about a task's attachments.
fn saved_note(saved: usize, failed: usize) -> String {
    let plural = |n: usize| if n == 1 { "" } else { "s" };
    match (saved, failed) {
        (s, 0) => format!("{s} attachment{} saved locally: open each one's path to see it", plural(s)),
        (0, f) => format!("{f} attachment{} couldn't be fetched: see each one's error", plural(f)),
        (s, f) => format!("{s} attachment{} saved locally (open each one's path), {f} couldn't be fetched (see its error)", plural(s)),
    }
}

/// One attachment into `dir` (made 0700), written 0600.
async fn fetch(origin: (&str, &str, &str), dir: &Path, link: &Link) -> Result<PathBuf, String> {
    let path = dir.join(link.file());
    if std::fs::symlink_metadata(&path).is_ok_and(|m| m.is_file() && m.len() > 0 && m.len() <= MAX_ATTACHMENT) {
        return Ok(path);
    }
    let (base, runner_id, token) = origin;
    let mut url = reqwest::Url::parse(&format!("{base}/runner{}", link.path())).map_err(|e| format!("the control plane's URL is wrong: {e}"))?;
    url.query_pairs_mut().append_pair("runner", runner_id);
    let mut res = crate::proof::CLIENT.get(url).bearer_auth(token).timeout(FETCH_TIMEOUT).send().await.map_err(|e| e.without_url().to_string())?;
    let status = res.status();
    if !status.is_success() {
        let body = res.text().await.unwrap_or_default();
        let said = body.trim();
        return Err(if said.is_empty() { format!("the control plane answered {status}") } else { format!("{status}: {said}") });
    }
    let too_big = || format!("it's over {} MB", MAX_ATTACHMENT / 1024 / 1024);
    if res.content_length().is_some_and(|n| n > MAX_ATTACHMENT) {
        return Err(too_big());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = res.chunk().await.map_err(|e| e.without_url().to_string())? {
        if (bytes.len() + chunk.len()) as u64 > MAX_ATTACHMENT {
            return Err(too_big());
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Err("it's empty".into());
    }
    crate::images::write_private(dir, &path, &bytes).map_err(|e| format!("couldn't write {}: {e}", path.display()))?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const A: &str = "6f0d858b-2cc8-4cca-95b7-e0511c15516a";
    const B: &str = "0eaf5268-01b1-47c9-8a42-ff2754bcb0b8";

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("maple-attachments-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A local control plane: each request's path (without the query) picks its answer; the requests' heads are kept.
    async fn server(answers: Vec<(String, &'static str, Vec<u8>)>) -> (String, Arc<Mutex<Vec<String>>>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let heads = Arc::new(Mutex::new(Vec::new()));
        let seen = heads.clone();
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else { return };
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
                    let n = sock.read(&mut chunk).await.unwrap();
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                }
                let head = String::from_utf8_lossy(&buf).to_string();
                seen.lock().unwrap().push(head.clone());
                let path = head.split_whitespace().nth(1).unwrap_or("").split('?').next().unwrap_or("").to_string();
                let (status, body) =
                    answers.iter().find(|(p, _, _)| *p == path).map(|(_, s, b)| (*s, b.clone())).unwrap_or(("404 Not Found", b"Not found.".to_vec()));
                let mut reply = format!("HTTP/1.1 {status}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n", body.len()).into_bytes();
                reply.extend_from_slice(&body);
                let _ = sock.write_all(&reply).await;
            }
        });
        (base, heads)
    }

    #[test]
    fn finds_attachment_links_in_markdown() {
        let brief = format!(
            "It breaks:\n\n![shot.png](/attachments/{A}/shot.png)\n\nLog: [layout-crash.log](/attachments/{B}/layout-crash.log).\n\
             Again ![shot.png](/attachments/{A}/shot.png) and an image on the web ![x](https://example.com/attachments/{A}/shot.png)"
        );
        let found = links(&brief);
        assert_eq!(found, vec![Link { id: A.into(), name: "shot.png".into() }, Link { id: B.into(), name: "layout-crash.log".into() }]);
        assert_eq!(found[1].path(), format!("/attachments/{B}/layout-crash.log"));
        assert_eq!(found[1].file(), format!("{B}-layout-crash.log"));
    }

    #[test]
    fn ignores_what_isnt_an_attachment() {
        for bad in [
            "/attachments/".to_string(),
            "/attachments/not-a-uuid/shot.png".into(),
            format!("/attachments/{}/shot.png", A.to_uppercase()),
            format!("/attachments/{A}/"),
            format!("/attachments/{A}shot.png"),
            format!("/attachments/{A}/../../etc/passwd"),
            format!("/attachments/{A}/.hidden"),
            format!("/attachments/{A}/a..b"),
            format!("/attachments/{A}/{}", "a".repeat(121)),
        ] {
            assert_eq!(links(&bad), vec![], "{bad}");
        }
        // A name stops at the first character a stored name can't have.
        assert_eq!(links(&format!("(/attachments/{A}/a.png)?x"))[0].name, "a.png");
        let many: String = (0..25).map(|i| format!("/attachments/{A}/f{i}.png ")).collect();
        assert_eq!(links(&many).len(), MAX_ATTACHMENTS);
    }

    #[test]
    fn cache_folders_are_under_the_home_and_never_leave_it() {
        let home = Path::new("/Users/mini");
        assert_eq!(folder(home, "MF-3"), Some(PathBuf::from("/Users/mini/.cache/maple-attachments/MF-3")));
        for bad in ["", "../x", "a/b", "MF 3", &"a".repeat(65)] {
            assert_eq!(folder(home, bad), None, "{bad}");
        }
    }

    #[tokio::test]
    async fn get_task_lists_each_attachment_saved_privately() {
        let home = temp();
        let png = b"\x89PNG\r\n\x1a\n-pretend".to_vec();
        let (base, heads) = server(vec![
            (format!("/runner/attachments/{A}/shot.png"), "200 OK", png.clone()),
            (format!("/runner/attachments/{B}/layout-crash.log"), "404 Not Found", b"Not found.".to_vec()),
        ])
        .await;
        let task = json!({
            "id": "MF-3",
            "brief": format!("![shot.png](/attachments/{A}/shot.png)"),
            "comments": [{ "body": format!("[layout-crash.log](/attachments/{B}/layout-crash.log)") }],
        });
        let mut result = json!({ "summary": "MF-3 · Uploads (building)", "data": { "task": task, "goal": null } });
        add_with(&mut result, &home, Some((&base, "mini", "mfr_token"))).await;

        let path = home.join(format!(".cache/maple-attachments/MF-3/{A}-shot.png"));
        assert_eq!(
            result["data"]["attachments"],
            json!([
                { "name": "shot.png", "link": format!("/attachments/{A}/shot.png"), "path": path.display().to_string() },
                { "name": "layout-crash.log", "link": format!("/attachments/{B}/layout-crash.log"), "error": "404 Not Found: Not found." },
            ])
        );
        assert!(result["summary"].as_str().unwrap().ends_with("1 attachment saved locally (open each one's path), 1 couldn't be fetched (see its error)"), "{}", result["summary"]);
        assert_eq!(std::fs::read(&path).unwrap(), png);
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        let first = heads.lock().unwrap().clone();
        assert_eq!(first.len(), 2);
        assert!(first[0].starts_with(&format!("GET /runner/attachments/{A}/shot.png?runner=mini HTTP/1.1")), "{}", first[0]);
        assert!(first[0].to_lowercase().contains("authorization: bearer mfr_token"));

        // Again (the builder after the planner): what's there is kept, so only the missing log is asked for.
        add_with(&mut result, &home, Some((&base, "mini", "mfr_token"))).await;
        let again = heads.lock().unwrap().clone();
        assert_eq!(again.len(), 3);
        assert!(again[2].contains("layout-crash.log"), "{}", again[2]);
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn the_summary_counts_saved_and_failed_apart() {
        assert_eq!(saved_note(2, 0), "2 attachments saved locally: open each one's path to see it");
        assert_eq!(saved_note(0, 1), "1 attachment couldn't be fetched: see each one's error");
    }

    #[tokio::test]
    async fn a_task_without_attachments_is_left_alone() {
        let mut result = json!({ "summary": "MF-1 · x", "data": { "task": { "id": "MF-1", "brief": "No files." } } });
        let before = result.clone();
        add_with(&mut result, Path::new("/nowhere"), None).await;
        assert_eq!(result, before);
    }

    /// Against a real factory: `MAPLE_ATTACHMENTS_E2E="<url> <machine> <runner token> <get_task result .json>"
    /// cargo test real_factory -- --ignored --nocapture`, into the real ~/.cache/maple-attachments.
    #[tokio::test]
    #[ignore]
    async fn real_factory() {
        let config = std::env::var("MAPLE_ATTACHMENTS_E2E").expect("MAPLE_ATTACHMENTS_E2E");
        let [base, machine, token, file] = config.split_whitespace().collect::<Vec<_>>()[..] else { panic!("four values") };
        let mut result: Value = serde_json::from_str(&std::fs::read_to_string(file).unwrap()).unwrap();
        add_with(&mut result, &crate::sessions::expand_home("~"), Some((base, machine, token))).await;
        println!("{}", serde_json::to_string_pretty(&json!({ "summary": result["summary"], "attachments": result["data"]["attachments"] })).unwrap());
        let listed = result["data"]["attachments"].as_array().unwrap();
        assert!(!listed.is_empty() && listed.iter().all(|a| a["path"].is_string()));
    }
}
