//! The folder page: a folder's files, its git changes, one file's diff, one file's contents
//! (`folder.files`, `folder.status`, `folder.diff`, `folder.read`).
//!
//! Folders follow the directory picker's rules (`fs_browse::resolve`: under $HOME, no `..`).
//! A file is named relative to its folder and has to stay inside it: no `..`, no absolute
//! paths, and no symlink (in the file or a parent) that leads out of the folder.

use std::ffi::OsStr;
use std::path::{Component, Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use serde::Serialize;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

use crate::fs_browse;
use crate::protocol::{fit_items, fit_text, json_len};

/// Paths sent for the tree.
pub const MAX_PATHS: usize = 20_000;
/// Changed files listed in `folder.status`.
pub const MAX_CHANGES: usize = 2_000;
/// Diff text for one file (then cut further if escaping it for JSON would go over `BUDGET`).
pub const MAX_DIFF: usize = 2 * 1024 * 1024;
/// What one answer's big field (paths, changes, diff, contents) may take as JSON, so the whole
/// `folder.result` stays under the WebSocket message limit.
const BUDGET: usize = crate::protocol::MAX_MESSAGE - crate::protocol::ENVELOPE;
/// Files shown in the viewer.
pub const MAX_READ: u64 = 1024 * 1024;
/// Untracked files whose lines are counted for `+N`.
const MAX_COUNTED: usize = 300;
/// Folders a non-repo walk looks into before giving up.
const MAX_WALK_DIRS: usize = 20_000;
const SKIP_DIRS: &[&str] = &["node_modules", ".git", "target", "dist", "build"];
const GIT_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "lowercase", rename_all_fields = "camelCase")]
pub enum Payload {
    Files {
        /// The folder, `~`-abbreviated.
        path: String,
        repo: bool,
        /// Relative to the folder; directories (only empty ones) end with `/`.
        paths: Vec<String>,
        truncated: bool,
    },
    Status {
        path: String,
        repo: bool,
        #[serde(flatten)]
        branch: Branch,
        files: Vec<Change>,
        truncated: bool,
    },
    Diff {
        path: String,
        file: String,
        /// Unified diff text (`git diff` output), empty when nothing changed.
        diff: String,
        untracked: bool,
        truncated: bool,
    },
    Read {
        path: String,
        file: String,
        /// Empty for a binary file.
        contents: String,
        size: u64,
        binary: bool,
    },
}

#[derive(Debug, Default, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Branch {
    /// None when detached (or not a repo).
    pub branch: Option<String>,
    pub detached: bool,
    pub ahead: u32,
    pub behind: u32,
    /// Has no commits yet.
    pub unborn: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Change {
    /// Relative to the folder.
    pub path: String,
    /// A staged rename's old path, when it's inside the folder too.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
    /// added | modified | deleted | renamed | untracked | conflicted
    pub status: &'static str,
    /// Some of the change is in the index.
    pub staged: bool,
    /// Lines, against HEAD. None for binary files (or when not counted).
    pub additions: Option<u32>,
    pub deletions: Option<u32>,
}

// ---- paths ----

/// The folder: under home (fs_browse's rules), and an existing directory.
pub fn folder(path: &str, home: &Path) -> Result<PathBuf> {
    let dir = fs_browse::resolve(path, home)?;
    if !dir.is_dir() {
        bail!("{} isn't a folder (or doesn't exist).", fs_browse::abbreviate(&dir, home));
    }
    Ok(dir)
}

/// A file named relative to a folder, checked lexically: no `..`, not absolute, not empty.
pub fn relative_file(file: &str) -> Result<PathBuf> {
    if file.is_empty() || file.len() > 4096 || file.contains('\0') {
        bail!("Choose a file.");
    }
    let path = Path::new(file);
    let mut clean = PathBuf::new();
    for c in path.components() {
        match c {
            Component::Normal(part) => clean.push(part),
            Component::CurDir => {}
            Component::ParentDir => bail!("File paths can't contain `..`."),
            Component::RootDir | Component::Prefix(_) => bail!("Use a path inside the folder, not an absolute one."),
        }
    }
    if clean.as_os_str().is_empty() {
        bail!("Choose a file.");
    }
    Ok(clean)
}

/// `dir/file`, after checking that symlinks along the way don't lead out of `dir`. The file
/// itself may not exist (a deleted file's diff); its nearest existing ancestor is checked.
pub fn contained(dir: &Path, file: &str) -> Result<PathBuf> {
    let rel = relative_file(file)?;
    let full = dir.join(&rel);
    let real_dir = std::fs::canonicalize(dir).with_context(|| format!("can't open {}", dir.display()))?;
    let mut probe = full.as_path();
    loop {
        match std::fs::symlink_metadata(probe) {
            Ok(_) => {
                // Resolves every symlink, including a dangling one's parents.
                let real = match std::fs::canonicalize(probe) {
                    Ok(real) => real,
                    Err(_) => bail!("{file} is a link that leads nowhere."),
                };
                if !real.starts_with(&real_dir) {
                    bail!("{file} leads outside this folder.");
                }
                return Ok(full);
            }
            Err(_) => match probe.parent() {
                Some(parent) if parent.starts_with(dir) && parent != probe => probe = parent,
                _ => return Ok(full),
            },
        }
    }
}

// ---- requests ----

pub async fn files(path: &str, home: &Path) -> Result<Payload> {
    let dir = folder(path, home)?;
    let abbreviated = fs_browse::abbreviate(&dir, home);
    if repo_prefix(&dir).await.is_some() {
        let out = git_capped(&dir, &["ls-files", "-z", "--cached", "--others", "--exclude-standard"], 32 * 1024 * 1024).await?;
        let mut seen = std::collections::HashSet::new();
        let mut paths: Vec<String> = Vec::new();
        let mut truncated = out.truncated;
        for p in split_z(&out.stdout) {
            // Unmerged files are listed once per stage.
            if !p.is_empty() && seen.insert(p.clone()) {
                if paths.len() == MAX_PATHS {
                    truncated = true;
                    break;
                }
                paths.push(p);
            }
        }
        truncated |= fit_items(&mut paths, BUDGET);
        return Ok(Payload::Files { path: abbreviated, repo: true, paths, truncated });
    }
    let (mut paths, mut truncated) = tokio::task::spawn_blocking(move || walk(&dir)).await?;
    truncated |= fit_items(&mut paths, BUDGET);
    Ok(Payload::Files { path: abbreviated, repo: false, paths, truncated })
}

/// Files under `dir`, breadth first, without following symlinks into folders. Skips build
/// output and dependencies. Empty folders are listed as `name/`.
fn walk(dir: &Path) -> (Vec<String>, bool) {
    let mut paths = Vec::new();
    let mut queue = std::collections::VecDeque::from([PathBuf::new()]);
    let mut visited = 0;
    while let Some(rel) = queue.pop_front() {
        visited += 1;
        if visited > MAX_WALK_DIRS {
            return (paths, true);
        }
        let Ok(read) = std::fs::read_dir(dir.join(&rel)) else { continue };
        let mut entries: Vec<_> = read.filter_map(|e| e.ok()).collect();
        entries.sort_by_key(|e| e.file_name());
        if entries.is_empty() && !rel.as_os_str().is_empty() {
            paths.push(format!("{}/", rel.to_string_lossy()));
        }
        for e in entries {
            let name = e.file_name();
            let Ok(kind) = e.file_type() else { continue };
            let child = rel.join(&name);
            if kind.is_dir() {
                if !SKIP_DIRS.iter().any(|s| OsStr::new(s) == name) {
                    queue.push_back(child);
                }
            } else {
                if paths.len() == MAX_PATHS {
                    return (paths, true);
                }
                paths.push(child.to_string_lossy().into_owned());
            }
        }
    }
    (paths, false)
}

pub async fn status(path: &str, home: &Path) -> Result<Payload> {
    let dir = folder(path, home)?;
    let abbreviated = fs_browse::abbreviate(&dir, home);
    let Some(prefix) = repo_prefix(&dir).await else {
        return Ok(Payload::Status { path: abbreviated, repo: false, branch: Branch::default(), files: vec![], truncated: false });
    };
    let out = git_capped(&dir, &["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--", "."], 16 * 1024 * 1024).await?.ok()?;
    let (branch, mut files) = parse_status(&out, &prefix);
    let base = diff_base(&dir, branch.unborn).await?;
    if let Ok(out) = git_capped(&dir, &["diff", &base, "--numstat", "-z", "--relative", "-M", "--no-ext-diff", "--"], 16 * 1024 * 1024).await
        && let Ok(stdout) = out.ok()
    {
        apply_numstat(&mut files, &parse_numstat(&stdout));
    }
    // Untracked files aren't in the diff: count their lines while it's cheap.
    let to_count: Vec<(usize, PathBuf)> =
        files.iter().enumerate().filter(|(_, c)| c.status == "untracked").take(MAX_COUNTED).map(|(i, c)| (i, dir.join(&c.path))).collect();
    let counts = tokio::task::spawn_blocking(move || to_count.into_iter().map(|(i, p)| (i, count_lines(&p))).collect::<Vec<_>>()).await?;
    for (i, n) in counts {
        files[i].additions = n;
        files[i].deletions = n.map(|_| 0);
    }
    let mut truncated = files.len() > MAX_CHANGES;
    files.truncate(MAX_CHANGES);
    truncated |= fit_items(&mut files, BUDGET);
    Ok(Payload::Status { path: abbreviated, repo: true, branch, files, truncated })
}

pub async fn diff(path: &str, file: &str, old_file: Option<&str>, home: &Path) -> Result<Payload> {
    let dir = folder(path, home)?;
    let abbreviated = fs_browse::abbreviate(&dir, home);
    contained(&dir, file)?;
    if let Some(old) = old_file {
        contained(&dir, old)?;
    }
    let Some(_) = repo_prefix(&dir).await else { bail!("This folder isn't a git repository.") };
    let unborn = git_ok(&dir, &["rev-parse", "--verify", "-q", "HEAD"]).await.is_none();
    let base = diff_base(&dir, unborn).await?;
    let mut args = vec!["diff", base.as_str(), "--relative", "-M", "--no-color", "--no-ext-diff", "--"];
    args.push(file);
    if let Some(old) = old_file {
        args.push(old);
    }
    let out = git_capped(&dir, &args, MAX_DIFF).await?;
    let truncated = out.truncated;
    let text = if truncated { out.stdout } else { out.ok()? };
    if !text.is_empty() {
        let mut diff = lossy(text);
        let cut = fit_text(&mut diff, BUDGET);
        return Ok(Payload::Diff { path: abbreviated, file: file.into(), diff, untracked: false, truncated: truncated || cut });
    }
    // Not changed against HEAD: an untracked file diffs against nothing.
    let untracked = git_capped(&dir, &["ls-files", "-z", "--others", "--exclude-standard", "--", file], 64 * 1024).await?.ok()?;
    if untracked.is_empty() {
        return Ok(Payload::Diff { path: abbreviated, file: file.into(), diff: String::new(), untracked: false, truncated: false });
    }
    // Exits 1 when there are differences, which there always are.
    let out = git_capped(&dir, &["diff", "--no-index", "--no-color", "--no-ext-diff", "--", "/dev/null", file], MAX_DIFF).await?;
    let mut diff = lossy(out.stdout);
    let cut = fit_text(&mut diff, BUDGET);
    Ok(Payload::Diff { path: abbreviated, file: file.into(), diff, untracked: true, truncated: out.truncated || cut })
}

pub fn read(path: &str, file: &str, home: &Path) -> Result<Payload> {
    let dir = folder(path, home)?;
    let full = contained(&dir, file)?;
    let meta = std::fs::metadata(&full).map_err(|_| anyhow!("{file} doesn't exist."))?;
    if !meta.is_file() {
        bail!("{file} isn't a file.");
    }
    if meta.len() > MAX_READ {
        bail!("{file} is {}. Files over 1 MB aren't shown.", size_label(meta.len()));
    }
    let mut bytes = Vec::with_capacity(meta.len() as usize);
    use std::io::Read;
    std::fs::File::open(&full).and_then(|f| f.take(MAX_READ + 1).read_to_end(&mut bytes)).map_err(|e| anyhow!("Can't read {file}: {e}"))?;
    if bytes.len() as u64 > MAX_READ {
        bail!("{file} is over 1 MB. Files that big aren't shown.");
    }
    let binary = is_binary(&bytes);
    let contents = if binary { String::new() } else { lossy(bytes) };
    // Only text full of control characters grows this much when escaped for JSON.
    if json_len(&contents) > BUDGET {
        bail!("{file} is too big to show here once it's encoded for sending.");
    }
    Ok(Payload::Read { path: fs_browse::abbreviate(&dir, home), file: file.into(), contents, size: meta.len(), binary })
}

fn size_label(n: u64) -> String {
    if n >= 1024 * 1024 { format!("{:.1} MB", n as f64 / (1024.0 * 1024.0)) } else { format!("{} KB", n.div_ceil(1024)) }
}

/// Git's own test: a NUL in the first 8000 bytes.
fn is_binary(bytes: &[u8]) -> bool {
    bytes[..bytes.len().min(8000)].contains(&0)
}

fn count_lines(path: &Path) -> Option<u32> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || meta.len() > MAX_READ {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    if is_binary(&bytes) {
        return None;
    }
    let lines = bytes.iter().filter(|&&b| b == b'\n').count() + usize::from(bytes.last().is_some_and(|&b| b != b'\n'));
    Some(lines as u32)
}

fn lossy(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
}

// ---- git ----

/// The folder's path inside its repository (`sub/dir/`, or empty at the top), or None
/// when it isn't in one.
async fn repo_prefix(dir: &Path) -> Option<String> {
    git_ok(dir, &["rev-parse", "--show-prefix"]).await.map(|s| s.trim_end_matches('\n').to_string())
}

/// What changes are measured against: HEAD, or the empty tree in a repo with no commits.
async fn diff_base(dir: &Path, unborn: bool) -> Result<String> {
    if !unborn {
        return Ok("HEAD".into());
    }
    // The empty tree's id depends on the repo's hash (sha1 or sha256).
    git_ok(dir, &["hash-object", "-t", "tree", "/dev/null"]).await.map(|s| s.trim().to_string()).ok_or_else(|| anyhow!("git couldn't hash the empty tree"))
}

struct Output {
    stdout: Vec<u8>,
    truncated: bool,
    success: bool,
    stderr: String,
}

impl Output {
    /// stdout, or git's complaint. `git diff --no-index` exits 1 for "there are differences".
    fn ok(self) -> Result<Vec<u8>> {
        if self.success {
            return Ok(self.stdout);
        }
        let msg = self.stderr.lines().map(|l| l.trim_start_matches("fatal: ").trim_start_matches("error: ")).collect::<Vec<_>>().join(" ");
        Err(anyhow!("{}", if msg.trim().is_empty() { "git failed".to_string() } else { msg.trim().to_string() }))
    }
}

async fn git_ok(dir: &Path, args: &[&str]) -> Option<String> {
    let out = git_capped(dir, args, 1024 * 1024).await.ok()?;
    out.success.then(|| lossy(out.stdout))
}

/// Runs git with no prompts and no optional locks, keeping at most `cap` bytes of stdout
/// (it's stopped once there's more) and giving up after a while.
async fn git_capped(dir: &Path, args: &[&str], cap: usize) -> Result<Output> {
    let mut cmd = Command::new("git");
    cmd.arg("-C")
        .arg(dir)
        .args(["-c", "core.quotePath=false", "-c", "color.ui=false"])
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        // Pathspecs are file names, never `:(glob)` magic or wildcards.
        .env("GIT_LITERAL_PATHSPECS", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = cmd.spawn().context("can't run git")?;
    let mut stdout = child.stdout.take().expect("piped");
    let mut stderr = child.stderr.take().expect("piped");
    let run = async {
        // Owns stdout, so stopping early closes the pipe and git stops too (stderr then ends).
        let read_out = async move {
            let mut buf = Vec::new();
            let mut chunk = vec![0u8; 64 * 1024];
            loop {
                let n = stdout.read(&mut chunk).await?;
                if n == 0 {
                    return Ok::<_, std::io::Error>((buf, false));
                }
                if buf.len() + n > cap {
                    buf.extend_from_slice(&chunk[..cap - buf.len()]);
                    return Ok((buf, true));
                }
                buf.extend_from_slice(&chunk[..n]);
            }
        };
        let read_err = async {
            let mut buf = Vec::new();
            let _ = (&mut stderr).take(64 * 1024).read_to_end(&mut buf).await;
            buf
        };
        let (out, err) = tokio::join!(read_out, read_err);
        let (stdout, truncated) = out?;
        if truncated {
            let _ = child.start_kill();
        }
        let status = child.wait().await?;
        Ok::<_, anyhow::Error>(Output { stdout, truncated, success: status.success(), stderr: String::from_utf8_lossy(&err).into_owned() })
    };
    match tokio::time::timeout(GIT_TIMEOUT, run).await {
        Ok(out) => out,
        Err(_) => Err(anyhow!("git {} took too long", args.first().unwrap_or(&""))),
    }
}

fn split_z(bytes: &[u8]) -> Vec<String> {
    bytes.split(|&b| b == 0).filter(|s| !s.is_empty()).map(|s| String::from_utf8_lossy(s).into_owned()).collect()
}

/// `git status --porcelain=v2 -z --branch`. Its paths are relative to the repository's top;
/// `prefix` (the folder's place in it) is cut off, and anything outside is dropped.
fn parse_status(out: &[u8], prefix: &str) -> (Branch, Vec<Change>) {
    let mut branch = Branch::default();
    let mut files = Vec::new();
    let mut fields = out.split(|&b| b == 0).map(|f| String::from_utf8_lossy(f).into_owned());
    let strip = |p: &str| p.strip_prefix(prefix).map(str::to_string);
    while let Some(entry) = fields.next() {
        if let Some(head) = entry.strip_prefix("# branch.head ") {
            branch.detached = head == "(detached)";
            branch.branch = (!branch.detached).then(|| head.to_string());
        } else if let Some(oid) = entry.strip_prefix("# branch.oid ") {
            branch.unborn = oid == "(initial)";
        } else if let Some(ab) = entry.strip_prefix("# branch.ab ") {
            for part in ab.split_whitespace() {
                if let Some(n) = part.strip_prefix('+') {
                    branch.ahead = n.parse().unwrap_or(0);
                } else if let Some(n) = part.strip_prefix('-') {
                    branch.behind = n.parse().unwrap_or(0);
                }
            }
        } else if let Some(rest) = entry.strip_prefix("1 ") {
            // 1 XY sub mH mI mW hH hI path
            let mut parts = rest.splitn(8, ' ');
            let xy = parts.next().unwrap_or("..");
            if let Some(path) = parts.nth(6).and_then(strip) {
                files.push(change(path, None, xy));
            }
        } else if let Some(rest) = entry.strip_prefix("2 ") {
            // 2 XY sub mH mI mW hH hI Xscore path, then the original path as its own field
            let mut parts = rest.splitn(9, ' ');
            let xy = parts.next().unwrap_or("..");
            let path = parts.nth(7).map(str::to_string);
            let orig = fields.next();
            if let Some(path) = path.as_deref().and_then(strip) {
                let old = orig.as_deref().and_then(strip);
                // A rename from outside the folder is an addition, as far as the folder goes.
                let xy = if old.is_none() { "A." } else { xy };
                files.push(change(path, old, xy));
            }
        } else if let Some(rest) = entry.strip_prefix("u ") {
            // u XY sub m1 m2 m3 mW h1 h2 h3 path
            if let Some(path) = rest.splitn(10, ' ').nth(9).and_then(strip) {
                files.push(Change { path, old_path: None, status: "conflicted", staged: false, additions: None, deletions: None });
            }
        } else if let Some(path) = entry.strip_prefix("? ").and_then(strip) {
            files.push(Change { path, old_path: None, status: "untracked", staged: false, additions: None, deletions: None });
        }
    }
    (branch, files)
}

/// One tracked change from its two-letter XY code (index, worktree), as it compares with HEAD.
fn change(path: String, old_path: Option<String>, xy: &str) -> Change {
    let mut chars = xy.chars();
    let (x, y) = (chars.next().unwrap_or('.'), chars.next().unwrap_or('.'));
    let status = match (x, y) {
        ('A', _) => "added",
        (_, 'D') | ('D', _) => "deleted",
        ('R' | 'C', _) => "renamed",
        _ => "modified",
    };
    let old_path = if status == "renamed" { old_path } else { None };
    Change { path, old_path, status, staged: x != '.', additions: None, deletions: None }
}

/// `git diff --numstat -z`: `add\tdel\tpath\0`, or for a rename `add\tdel\t\0old\0new\0`.
/// Binary files show `-` for both counts.
fn parse_numstat(out: &[u8]) -> Vec<(String, Option<u32>, Option<u32>)> {
    let mut stats = Vec::new();
    let mut fields = out.split(|&b| b == 0).map(|f| String::from_utf8_lossy(f).into_owned());
    while let Some(entry) = fields.next() {
        let mut parts = entry.splitn(3, '\t');
        let (Some(add), Some(del), Some(path)) = (parts.next(), parts.next(), parts.next()) else { continue };
        let path = if path.is_empty() {
            let _old = fields.next();
            match fields.next() {
                Some(new) => new,
                None => continue,
            }
        } else {
            path.to_string()
        };
        stats.push((path, add.parse().ok(), del.parse().ok()));
    }
    stats
}

fn apply_numstat(files: &mut [Change], stats: &[(String, Option<u32>, Option<u32>)]) {
    let by_path: std::collections::HashMap<&str, (Option<u32>, Option<u32>)> = stats.iter().map(|(p, a, d)| (p.as_str(), (*a, *d))).collect();
    for f in files.iter_mut() {
        if let Some(&(a, d)) = by_path.get(f.path.as_str()) {
            f.additions = a;
            f.deletions = d;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn files_stay_relative() {
        assert_eq!(relative_file("src/a.rs").unwrap(), PathBuf::from("src/a.rs"));
        assert_eq!(relative_file("./src//a.rs").unwrap(), PathBuf::from("src/a.rs"));
        for bad in ["", ".", "../x", "a/../../x", "a/..", "/etc/passwd", "a\0b"] {
            assert!(relative_file(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn symlinks_must_stay_inside() {
        let root = std::env::temp_dir().join(format!("maple-folder-{}", uuid::Uuid::new_v4()));
        let dir = root.join("proj");
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join("src/a.rs"), "fn main() {}\n").unwrap();
        std::fs::write(root.join("secret"), "x").unwrap();
        std::os::unix::fs::symlink("../secret", dir.join("leak")).unwrap();
        std::os::unix::fs::symlink("..", dir.join("up")).unwrap();
        std::os::unix::fs::symlink("src/a.rs", dir.join("inside")).unwrap();
        std::os::unix::fs::symlink("nowhere", dir.join("dangling")).unwrap();
        assert!(contained(&dir, "src/a.rs").is_ok());
        assert!(contained(&dir, "inside").is_ok());
        assert!(contained(&dir, "src/deleted.rs").is_ok(), "a file that's gone can still be diffed");
        assert!(contained(&dir, "leak").unwrap_err().to_string().contains("outside"));
        assert!(contained(&dir, "up/secret").unwrap_err().to_string().contains("outside"));
        assert!(contained(&dir, "up/missing").is_err(), "a missing file under an escaping link");
        assert!(contained(&dir, "dangling").is_err());
        assert!(contained(&dir, "../secret").is_err());

        let home = root.clone();
        assert!(read("~/proj", "leak", &home).is_err());
        let Payload::Read { contents, binary, size, .. } = read("~/proj", "src/a.rs", &home).unwrap() else { panic!() };
        assert_eq!((contents.as_str(), binary, size), ("fn main() {}\n", false, 13));
        std::fs::write(dir.join("bin"), [1u8, 0, 2]).unwrap();
        assert!(matches!(read("~/proj", "bin", &home).unwrap(), Payload::Read { binary: true, ref contents, .. } if contents.is_empty()));
        std::fs::write(dir.join("big"), vec![b'a'; MAX_READ as usize + 1]).unwrap();
        assert!(read("~/proj", "big", &home).unwrap_err().to_string().contains("over 1 MB"));
        assert!(read("~/proj", "src", &home).is_err());
        assert!(read("~/../etc", "passwd", &home).is_err());
        assert!(folder("/etc", &home).is_err());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn parses_status_in_a_subfolder() {
        let out = b"# branch.oid abc\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0\
1 .M N... 100644 100644 100644 a b sub/a b.txt\0\
1 M. N... 100644 100644 100644 a b sub/staged.rs\0\
1 AM N... 000000 100644 100644 0 b sub/new.rs\0\
1 .D N... 100644 100644 000000 a a sub/gone.rs\0\
1 .M N... 100644 100644 100644 a b elsewhere.txt\0\
2 R. N... 100644 100644 100644 a a R100 sub/moved.rs\0sub/old.rs\0\
2 R. N... 100644 100644 100644 a a R100 sub/in.rs\0top.rs\0\
u UU N... 100644 100644 100644 100644 a b c sub/conflict.rs\0\
? sub/untracked dir/x.txt\0";
        let (branch, files) = parse_status(out, "sub/");
        assert_eq!(branch, Branch { branch: Some("main".into()), detached: false, ahead: 2, behind: 1, unborn: false });
        let got: Vec<_> = files.iter().map(|c| (c.path.as_str(), c.old_path.as_deref(), c.status, c.staged)).collect();
        assert_eq!(
            got,
            [
                ("a b.txt", None, "modified", false),
                ("staged.rs", None, "modified", true),
                ("new.rs", None, "added", true),
                ("gone.rs", None, "deleted", false),
                ("moved.rs", Some("old.rs"), "renamed", true),
                ("in.rs", None, "added", true),
                ("conflict.rs", None, "conflicted", false),
                ("untracked dir/x.txt", None, "untracked", false),
            ]
        );
        let (branch, files) = parse_status(b"# branch.oid (initial)\0# branch.head main\0? a.txt\0", "");
        assert!(branch.unborn);
        assert_eq!(files[0].status, "untracked");
        let (branch, _) = parse_status(b"# branch.oid abc\0# branch.head (detached)\0", "");
        assert!(branch.detached && branch.branch.is_none());
    }

    #[test]
    fn parses_numstat() {
        let out = b"3\t1\ta.rs\0-\t-\timage.png\0\x30\t0\t\0old.rs\0new.rs\0";
        let stats = parse_numstat(out);
        assert_eq!(stats, [("a.rs".to_string(), Some(3), Some(1)), ("image.png".to_string(), None, None), ("new.rs".to_string(), Some(0), Some(0))]);
        let mut files = vec![change("a.rs".into(), None, ".M"), change("z.rs".into(), None, ".M")];
        apply_numstat(&mut files, &stats);
        assert_eq!((files[0].additions, files[0].deletions, files[1].additions), (Some(3), Some(1), None));
    }

    #[test]
    fn walks_without_build_output() {
        let dir = std::env::temp_dir().join(format!("maple-walk-{}", uuid::Uuid::new_v4()));
        for d in ["src/deep", "node_modules/x", "target/debug", "empty"] {
            std::fs::create_dir_all(dir.join(d)).unwrap();
        }
        for f in ["README.md", "src/a.rs", "src/deep/b.rs", "node_modules/x/i.js", "target/debug/bin"] {
            std::fs::write(dir.join(f), "x").unwrap();
        }
        let (paths, truncated) = walk(&dir);
        assert_eq!(paths, ["README.md", "empty/", "src/a.rs", "src/deep/b.rs"]);
        assert!(!truncated);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn serializes_replies() {
        let v = serde_json::to_value(Payload::Status {
            path: "~/x".into(),
            repo: true,
            branch: Branch { branch: Some("main".into()), ..Default::default() },
            files: vec![Change { path: "a".into(), old_path: None, status: "modified", staged: false, additions: Some(1), deletions: Some(0) }],
            truncated: false,
        })
        .unwrap();
        assert_eq!(
            v,
            serde_json::json!({"kind":"status","path":"~/x","repo":true,"branch":"main","detached":false,"ahead":0,"behind":0,"unborn":false,
                "files":[{"path":"a","status":"modified","staged":false,"additions":1,"deletions":0}],"truncated":false})
        );
    }

    /// Runs the real thing against a scratch repository.
    #[tokio::test]
    async fn git_end_to_end() {
        let home = std::env::temp_dir().join(format!("maple-git-{}", uuid::Uuid::new_v4()));
        let repo = home.join("repo");
        std::fs::create_dir_all(repo.join("sub")).unwrap();
        let git = |args: &[&str]| {
            let ok = std::process::Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(["-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main"])
                .args(args)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success();
            assert!(ok, "git {args:?}");
        };
        git(&["init", "-q"]);
        std::fs::write(repo.join("sub/a.txt"), "one\n").unwrap();
        git(&["add", "."]);
        // A repo with no commits: everything staged is an addition.
        let Payload::Status { files, branch, .. } = super::status("~/repo", &home).await.unwrap() else { panic!() };
        assert!(branch.unborn);
        assert_eq!((files[0].path.as_str(), files[0].status, files[0].additions), ("sub/a.txt", "added", Some(1)));
        let Payload::Diff { diff, .. } = super::diff("~/repo", "sub/a.txt", None, &home).await.unwrap() else { panic!() };
        assert!(diff.contains("+one"), "{diff}");

        git(&["commit", "-qm", "one"]);
        std::fs::write(repo.join("sub/a.txt"), "one\ntwo\n").unwrap();
        std::fs::write(repo.join("sub/new.txt"), "new\nfile\n").unwrap();
        let Payload::Files { paths, repo: true, .. } = super::files("~/repo/sub", &home).await.unwrap() else { panic!() };
        let mut paths = paths;
        paths.sort();
        assert_eq!(paths, ["a.txt", "new.txt"]);
        let Payload::Status { files, .. } = super::status("~/repo/sub", &home).await.unwrap() else { panic!() };
        let got: Vec<_> = files.iter().map(|c| (c.path.as_str(), c.status, c.additions, c.deletions)).collect();
        assert_eq!(got, [("a.txt", "modified", Some(1), Some(0)), ("new.txt", "untracked", Some(2), Some(0))]);
        let Payload::Diff { diff, untracked, .. } = super::diff("~/repo/sub", "a.txt", None, &home).await.unwrap() else { panic!() };
        assert!(!untracked && diff.contains("+two"), "{diff}");
        let Payload::Diff { diff, untracked, .. } = super::diff("~/repo/sub", "new.txt", None, &home).await.unwrap() else { panic!() };
        assert!(untracked && diff.contains("+file") && diff.contains("/dev/null"), "{diff}");
        assert!(super::diff("~/repo/sub", "../x", None, &home).await.is_err());
        // Wildcards are file names, not patterns.
        let Payload::Diff { diff, .. } = super::diff("~/repo/sub", "*.txt", None, &home).await.unwrap() else { panic!() };
        assert!(diff.is_empty());

        // A diff over the cap stops early and says so.
        std::fs::write(repo.join("sub/huge.txt"), (0..40_000).map(|i| format!("line {i} {}\n", "y".repeat(50))).collect::<String>()).unwrap();
        let Payload::Diff { diff, truncated, .. } = super::diff("~/repo/sub", "huge.txt", None, &home).await.unwrap() else { panic!() };
        assert!(truncated && diff.len() == MAX_DIFF, "{} bytes", diff.len());
        // Control characters take six bytes each in JSON: the diff is cut again so the message fits.
        std::fs::write(repo.join("sub/ctl.txt"), (0..20_000).map(|_| format!("{}\n", "\u{1}".repeat(60))).collect::<String>()).unwrap();
        let payload = super::diff("~/repo/sub", "ctl.txt", None, &home).await.unwrap();
        let Payload::Diff { ref diff, truncated, .. } = payload else { panic!() };
        assert!(truncated && json_len(diff) <= BUDGET && diff.ends_with('\n'), "{} JSON bytes", json_len(diff));
        let msg = crate::protocol::Outbound::FolderResult { req_id: "r".into(), result: crate::protocol::FolderReply::Ok(payload) };
        assert!(serde_json::to_string(&msg).unwrap().len() <= crate::protocol::MAX_MESSAGE);

        let Payload::Files { repo: false, .. } = super::files("~", &home).await.unwrap() else { panic!("home isn't a repo") };
        let Payload::Status { repo: false, .. } = super::status("~", &home).await.unwrap() else { panic!() };
        assert!(super::diff("~", "repo/sub/a.txt", None, &home).await.is_err());
        std::fs::remove_dir_all(&home).unwrap();
    }
}
