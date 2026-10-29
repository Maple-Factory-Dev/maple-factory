//! A task's images: the pictures its card shows (a screenshot, a sketch), as local files for its builder.
//!
//! In a card an image is a line `![name](/api/images/<file>)`, and that URL means nothing to an agent.
//! The hub names the files with `session.open` (`images`); the runner fetches each from the control
//! plane with its own token (`GET /runner/images/<file>`, control/src/images.ts) into
//! `~/.config/maple/images/<task>/<file>`, outside the worktree so they're never committed. The prompt's
//! links then point at those paths, and an "Attached images" list ends it; Codex also gets them as
//! `--image` (agents.rs). An image that can't be fetched never stops the session: it keeps its link and
//! the list says why. A task's builder that opens again finds its files already there.
//!
//! Folders nothing has changed for 30 days are removed when the runner starts and then daily.

use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// One image's bytes (the control plane's limit).
pub const MAX_IMAGE: u64 = 5 * 1024 * 1024;
/// The most images a builder is handed (the hub sends no more either).
pub const MAX_IMAGES: usize = 20;
/// A task's folder untouched this long is removed by the sweep.
pub const KEEP_FOLDER: Duration = Duration::from_secs(30 * 86_400);
const DAY: Duration = Duration::from_secs(86_400);
/// One image's download, so a slow control plane can't hold a session back for long.
const FETCH_TIMEOUT: Duration = Duration::from_secs(30);
const LINK_PREFIX: &str = "/api/images/";

/// An image the hub named, and where it is now or why it isn't.
#[derive(Debug, Clone, PartialEq)]
pub struct Fetched {
    pub file: String,
    pub got: Result<PathBuf, String>,
}

/// A stored image's file name as the control plane makes them (`IMAGE_FILE`): 8 hex, a dash, then
/// 1 to 80 letters, digits, dots, dashes or underscores, and no `..`.
pub fn valid_file(file: &str) -> bool {
    let Some((hex, name)) = file.split_once('-') else { return false };
    hex.len() == 8
        && hex.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        && (1..=80).contains(&name.len())
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        && !file.contains("..")
}

/// A task id that can be a folder's name.
fn valid_task(id: &str) -> bool {
    (1..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// `~/.config/maple/images`.
fn root() -> Result<PathBuf, String> {
    crate::config::dir().map(|d| d.join("images")).map_err(|e| format!("{e:#}"))
}

/// A task's `session.open` with images: fetches them and points the prompt at them. Answers the
/// prompt and the local paths of the images that came, for the agent's own flag.
pub async fn hand(task_id: &str, files: &[String], prompt: Option<String>) -> (Option<String>, Vec<String>) {
    if files.is_empty() {
        return (prompt, vec![]);
    }
    let fetched = fetch_for(task_id, files).await;
    let paths = fetched.iter().filter_map(|f| f.got.as_ref().ok()).map(|p| p.display().to_string()).collect();
    (prompt.map(|p| rewrite(&p, &fetched)), paths)
}

/// `task.images` (images sent with Ask the builder to a running builder): fetches them into the
/// task's folder, and answers each with its path or why it isn't there.
pub async fn answer(task_id: &str, files: &[String]) -> Vec<crate::protocol::ImageGot> {
    fetch_for(task_id, files).await.into_iter().map(as_reply).collect()
}

/// An image fetched (or not) as `task.images.fetched` says it.
pub fn as_reply(f: Fetched) -> crate::protocol::ImageGot {
    let (path, error) = match f.got {
        Ok(p) => (Some(p.display().to_string()), None),
        Err(e) => (None, Some(e)),
    };
    crate::protocol::ImageGot { file: f.file, path, error }
}

/// A task's images into `~/.config/maple/images/<task>/` from this runner's control plane, each logged.
pub async fn fetch_for(task_id: &str, files: &[String]) -> Vec<Fetched> {
    let fetched = match (root(), crate::proof::origin()) {
        (Ok(root), Some(origin)) => fetch_all(origin, &root, task_id, files).await,
        (Err(e), _) => files.iter().map(|f| Fetched { file: f.clone(), got: Err(e.clone()) }).collect(),
        (_, None) => files.iter().map(|f| Fetched { file: f.clone(), got: Err("the runner doesn't know its control plane".into()) }).collect(),
    };
    for f in &fetched {
        match &f.got {
            Ok(path) => tracing::info!("task {task_id}'s image {} is at {}", f.file, path.display()),
            Err(e) => tracing::warn!("couldn't fetch task {task_id}'s image {}: {e}", f.file),
        }
    }
    fetched
}

/// Each image (each once, at most `MAX_IMAGES`) into `<root>/<task>/`, one after another.
pub async fn fetch_all(origin: (&str, &str, &str), root: &Path, task_id: &str, files: &[String]) -> Vec<Fetched> {
    let mut wanted: Vec<&String> = Vec::new();
    for f in files {
        if !wanted.contains(&f) && wanted.len() < MAX_IMAGES {
            wanted.push(f);
        }
    }
    let mut out = Vec::new();
    for file in wanted {
        let got = if valid_task(task_id) { fetch(origin, &root.join(task_id), task_id, file).await } else { Err("the task's id isn't a folder name".into()) };
        out.push(Fetched { file: file.clone(), got });
    }
    out
}

/// One image into `dir` (made 0700), written 0600. One that's already there (the builder again) is kept.
async fn fetch(origin: (&str, &str, &str), dir: &Path, task_id: &str, file: &str) -> Result<PathBuf, String> {
    if !valid_file(file) {
        return Err("not an image's name".into());
    }
    let path = dir.join(file);
    if std::fs::symlink_metadata(&path).is_ok_and(|m| m.is_file() && m.len() > 0 && m.len() <= MAX_IMAGE) {
        return Ok(path);
    }
    let (base, runner_id, token) = origin;
    let mut url = reqwest::Url::parse(&format!("{base}/runner/images/{file}")).map_err(|e| format!("the control plane's URL is wrong: {e}"))?;
    url.query_pairs_mut().append_pair("runner", runner_id).append_pair("task", task_id);
    let mut res = crate::proof::CLIENT.get(url).bearer_auth(token).timeout(FETCH_TIMEOUT).send().await.map_err(|e| e.without_url().to_string())?;
    let status = res.status();
    if !status.is_success() {
        let body = res.text().await.unwrap_or_default();
        let said = body.trim();
        return Err(if said.is_empty() { format!("the control plane answered {status}") } else { format!("{status}: {said}") });
    }
    let too_big = || format!("it's over {} MB", MAX_IMAGE / 1024 / 1024);
    if res.content_length().is_some_and(|n| n > MAX_IMAGE) {
        return Err(too_big());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = res.chunk().await.map_err(|e| e.without_url().to_string())? {
        if (bytes.len() + chunk.len()) as u64 > MAX_IMAGE {
            return Err(too_big());
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Err("it's empty".into());
    }
    write_private(dir, &path, &bytes).map_err(|e| format!("couldn't write {}: {e}", path.display()))?;
    Ok(path)
}

/// Writes `bytes` to `path` (in `dir`, made 0700 if it isn't there) as 0600, through a temporary file.
pub(crate) fn write_private(dir: &Path, path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let tmp = path.with_extension("part");
    let _ = std::fs::remove_file(&tmp);
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    std::fs::rename(&tmp, path)
}

/// The prompt with each fetched image's links pointing at its local path, and an "Attached images"
/// list at the end: every image, its path (or its link and why it isn't here) and its name.
pub fn rewrite(prompt: &str, fetched: &[Fetched]) -> String {
    if fetched.is_empty() {
        return prompt.to_string();
    }
    let mut out = prompt.to_string();
    let mut list = Vec::new();
    for f in fetched {
        let name = f.file.get(9..).unwrap_or(&f.file);
        let link = format!("{LINK_PREFIX}{}", f.file);
        match &f.got {
            Ok(path) => {
                out = out.replace(&format!("]({link})"), &format!("]({})", path.display()));
                list.push(format!("- {} ({name})", path.display()));
            }
            Err(why) => list.push(format!("- {link} ({name}) (couldn't fetch: {why})")),
        }
    }
    format!("{}\n\n### Attached images\nThese are local files; open them to see what the card shows.\n{}\n", out.trim_end(), list.join("\n"))
}

/// Removes the task folders under `root` that haven't changed for `KEEP_FOLDER` before `now`. Returns
/// what it removed.
pub fn sweep(root: &Path, now: std::time::SystemTime) -> Vec<PathBuf> {
    let mut removed = Vec::new();
    let (Some(cutoff), Ok(entries)) = (now.checked_sub(KEEP_FOLDER), std::fs::read_dir(root)) else { return removed };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        if crate::proof::newest(&path).is_some_and(|t| t < cutoff) {
            let gone = if meta.is_dir() { std::fs::remove_dir_all(&path) } else { std::fs::remove_file(&path) };
            if gone.is_ok() {
                removed.push(path);
            }
        }
    }
    removed
}

/// The sweep, when the runner starts and then daily.
pub async fn sweep_daily() {
    loop {
        if let Ok(root) = root() {
            let removed = tokio::task::spawn_blocking(move || sweep(&root, std::time::SystemTime::now())).await.unwrap_or_default();
            for p in removed {
                tracing::info!("removed old task images {}", p.display());
            }
        }
        tokio::time::sleep(DAY).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const PNG: &[u8] = &[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52];
    const TASK: &str = "6f1c6a7e-2f6b-4d55-9b1a-2b7f0f6f0a11";

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("maple-images-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A local control plane: each request's path (without the query) picks its answer; the requests' heads are kept.
    async fn server(answers: Vec<(&'static str, &'static str, Vec<u8>)>) -> (String, Arc<Mutex<Vec<String>>>) {
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
    fn file_names_match_the_control_planes_pattern() {
        for ok in ["3f9c1a2b-wall-empty.png", "77d0e4aa-sketch.jpg", "00000000-a", "abcdef01-A_b.c-d.webp"] {
            assert!(valid_file(ok), "{ok}");
        }
        let long = format!("00000000-{}", "a".repeat(81));
        for bad in [
            "wall.png",
            "3F9C1A2B-wall.png",
            "3f9c1a2-wall.png",
            "3f9c1a2b-",
            "3f9c1a2b-../x",
            "3f9c1a2b-a/b.png",
            "3f9c1a2b-a..png",
            "3f9c1a2b-a b.png",
            &long,
        ] {
            assert!(!valid_file(bad), "{bad}");
        }
    }

    #[tokio::test]
    async fn fetches_each_image_with_the_runners_token_into_the_tasks_folder_privately() {
        let root = temp();
        let big = vec![0u8; MAX_IMAGE as usize + 1];
        let (base, heads) = server(vec![
            ("/runner/images/3f9c1a2b-wall.png", "200 OK", PNG.to_vec()),
            ("/runner/images/77d0e4aa-big.png", "200 OK", big),
            ("/runner/images/aaaaaaaa-ended.png", "404 Not Found", b"No such task on this machine.".to_vec()),
        ])
        .await;
        let files: Vec<String> =
            ["3f9c1a2b-wall.png", "77d0e4aa-big.png", "aaaaaaaa-ended.png", "../../etc/passwd", "3f9c1a2b-wall.png"].iter().map(|s| s.to_string()).collect();
        let got = fetch_all((&base, "mini", "aor_mini-token"), &root, TASK, &files).await;

        let path = root.join(TASK).join("3f9c1a2b-wall.png");
        assert_eq!(
            got,
            vec![
                Fetched { file: "3f9c1a2b-wall.png".into(), got: Ok(path.clone()) },
                Fetched { file: "77d0e4aa-big.png".into(), got: Err("it's over 5 MB".into()) },
                Fetched { file: "aaaaaaaa-ended.png".into(), got: Err("404 Not Found: No such task on this machine.".into()) },
                Fetched { file: "../../etc/passwd".into(), got: Err("not an image's name".into()) },
            ]
        );
        assert_eq!(std::fs::read(&path).unwrap(), PNG);
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::metadata(root.join(TASK)).unwrap().permissions().mode() & 0o777, 0o700);
        // Nothing else was written: not the big one, not a temporary file.
        let names: Vec<_> = std::fs::read_dir(root.join(TASK)).unwrap().flatten().map(|e| e.file_name().into_string().unwrap()).collect();
        assert_eq!(names, ["3f9c1a2b-wall.png"]);
        // Three requests (the bad name never went out), each with the token, the runner and the task.
        let heads = heads.lock().unwrap().clone();
        assert_eq!(heads.len(), 3);
        assert!(heads[0].starts_with(&format!("GET /runner/images/3f9c1a2b-wall.png?runner=mini&task={TASK} HTTP/1.1")), "{}", heads[0]);
        assert!(heads[0].to_lowercase().contains("authorization: bearer aor_mini-token"), "{}", heads[0]);

        // The builder again: what's there is kept, with no request.
        let again = fetch_all((&base, "mini", "aor_mini-token"), &root, TASK, &files[..1]).await;
        assert_eq!(again[0].got, Ok(path));
        assert_eq!(heads.len(), 3);

        // A task id that would leave the folder fetches nothing.
        let bad = fetch_all((&base, "mini", "t"), &root, "../x", &files[..1]).await;
        assert!(bad[0].got.is_err());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn at_most_twenty_images() {
        let root = temp();
        let (base, heads) = server(vec![]).await;
        let files: Vec<String> = (0..25).map(|i| format!("{i:08x}-n.png")).collect();
        let got = fetch_all((&base, "mini", "t"), &root, TASK, &files).await;
        assert_eq!(got.len(), 20);
        assert_eq!(heads.lock().unwrap().len(), 20);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn the_prompt_points_at_the_local_files_and_lists_them_at_the_end() {
        let prompt = "## Fix the wall\n\n### Goal\nThe wall says what to do.\n\n![wall-empty.png](/api/images/3f9c1a2b-wall-empty.png)\n> ![sketch.jpg](/api/images/77d0e4aa-sketch.jpg)\nAgain ![w](/api/images/3f9c1a2b-wall-empty.png)\n";
        let fetched = vec![
            Fetched { file: "3f9c1a2b-wall-empty.png".into(), got: Ok("/Users/a/.config/maple/images/t1/3f9c1a2b-wall-empty.png".into()) },
            Fetched { file: "77d0e4aa-sketch.jpg".into(), got: Err("404 Not Found: Not found.".into()) },
        ];
        assert_eq!(
            rewrite(prompt, &fetched),
            "## Fix the wall\n\n### Goal\nThe wall says what to do.\n\n\
             ![wall-empty.png](/Users/a/.config/maple/images/t1/3f9c1a2b-wall-empty.png)\n\
             > ![sketch.jpg](/api/images/77d0e4aa-sketch.jpg)\n\
             Again ![w](/Users/a/.config/maple/images/t1/3f9c1a2b-wall-empty.png)\n\n\
             ### Attached images\n\
             These are local files; open them to see what the card shows.\n\
             - /Users/a/.config/maple/images/t1/3f9c1a2b-wall-empty.png (wall-empty.png)\n\
             - /api/images/77d0e4aa-sketch.jpg (sketch.jpg) (couldn't fetch: 404 Not Found: Not found.)\n"
        );
        // No images, no list.
        assert_eq!(rewrite(prompt, &[]), prompt);
    }

    #[tokio::test]
    async fn an_asks_images_are_answered_with_each_path_or_why_not() {
        let root = temp();
        let (base, heads) = server(vec![("/runner/images/3f9c1a2b-wall.png", "200 OK", PNG.to_vec())]).await;
        let files: Vec<String> = ["3f9c1a2b-wall.png", "77d0e4aa-gone.png", "../x"].iter().map(|s| s.to_string()).collect();
        let got: Vec<_> = fetch_all((&base, "mini", "t"), &root, TASK, &files).await.into_iter().map(as_reply).collect();
        let path = root.join(TASK).join("3f9c1a2b-wall.png");
        use crate::protocol::ImageGot;
        assert_eq!(
            got,
            vec![
                ImageGot { file: "3f9c1a2b-wall.png".into(), path: Some(path.display().to_string()), error: None },
                ImageGot { file: "77d0e4aa-gone.png".into(), path: None, error: Some("404 Not Found: Not found.".into()) },
                ImageGot { file: "../x".into(), path: None, error: Some("not an image's name".into()) },
            ]
        );
        assert_eq!(std::fs::read(&path).unwrap(), PNG);
        // A task id that isn't a folder name: nothing is fetched, each says why.
        let bad: Vec<_> = fetch_all((&base, "mini", "t"), &root, "../../etc", &files[..1]).await.into_iter().map(as_reply).collect();
        assert_eq!(bad, vec![ImageGot { file: "3f9c1a2b-wall.png".into(), path: None, error: Some("the task's id isn't a folder name".into()) }]);
        assert_eq!(heads.lock().unwrap().len(), 2, "the bad name and the bad task never went out");
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn no_images_leaves_the_prompt_as_it_is() {
        assert_eq!(hand(TASK, &[], Some("go".into())).await, (Some("go".to_string()), vec![]));
    }

    #[test]
    fn the_sweep_removes_task_folders_untouched_for_30_days() {
        let root = temp();
        let now = std::time::SystemTime::now();
        let touch = |p: &Path, days: u64| std::fs::File::open(p).unwrap().set_modified(now - Duration::from_secs(days * 86_400)).unwrap();
        for (task, days) in [("old", 31), ("recent", 29)] {
            let dir = root.join(task);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("3f9c1a2b-a.png"), PNG).unwrap();
            touch(&dir.join("3f9c1a2b-a.png"), days);
            touch(&dir, days);
        }
        // An old folder with one new file stays.
        let mixed = root.join("mixed");
        std::fs::create_dir_all(&mixed).unwrap();
        std::fs::write(mixed.join("aaaaaaaa-old.png"), PNG).unwrap();
        std::fs::write(mixed.join("bbbbbbbb-new.png"), PNG).unwrap();
        touch(&mixed.join("aaaaaaaa-old.png"), 40);
        touch(&mixed, 40);

        assert_eq!(sweep(&root, now), vec![root.join("old")]);
        assert!(root.join("recent").is_dir() && mixed.is_dir());
        assert_eq!(sweep(&root, now + Duration::from_secs(2 * 86_400)), vec![root.join("recent")]);
        assert!(sweep(&root.join("nothing-here"), now).is_empty());
        std::fs::remove_dir_all(&root).unwrap();
    }
}
