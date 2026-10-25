//! Where this machine keeps each GitHub repository.
//!
//! A task names a project (`owner/name`), not a folder, since every machine lays out its folders
//! differently. The runner looks for git checkouts with a GitHub `origin` under its roots (by default
//! `~/Projects`, `~/code`, `~/src` and `~/dev`; `repoRoots` in runner.json), at most two levels down,
//! plus the ones it cloned itself under `~/.local/share/maple/repos/<owner>/<name>`, and reports
//! `owner/name → path` when it connects and when the list changes. A task in a repo the machine
//! doesn't have clones it into that managed folder (see `tasks::start`). A managed clone nothing has
//! used for `repoCloneDays` (default 14) is removed again (`sweep`).

use std::collections::BTreeMap;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tokio::sync::Notify;

use crate::protocol::Outbound;
use crate::sessions::{Sessions, expand_home};
use crate::worktrees::{abbreviate, canonical};

pub const DEFAULT_ROOTS: [&str; 4] = ["~/Projects", "~/code", "~/src", "~/dev"];
/// The runner's own clones, `<owner>/<name>` below it.
pub const MANAGED: &str = "~/.local/share/maple/repos";
/// Folders below a root that are looked at: `root/a` and `root/a/b`.
const DEPTH: u32 = 2;
/// The most checkouts one report carries.
const MAX_CHECKOUTS: usize = 500;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Checkout {
    /// owner/name on GitHub.
    pub repo: String,
    /// `~`-abbreviated.
    pub path: String,
    /// The runner cloned it (under `MANAGED`).
    pub managed: bool,
    /// When it last fetched from its remote (ms), if ever.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fetched_at: Option<u64>,
}

static ROOTS: Mutex<Option<Vec<String>>> = Mutex::new(None);
static POKE: Notify = Notify::const_new();
static FORCE: AtomicBool = AtomicBool::new(false);

/// The roots from runner.json (`repoRoots`), or the defaults.
pub fn set_roots(roots: Option<Vec<String>>) {
    *ROOTS.lock().unwrap() = roots;
}

pub fn roots() -> Vec<PathBuf> {
    let set = ROOTS.lock().unwrap().clone();
    set.unwrap_or_else(|| DEFAULT_ROOTS.iter().map(|r| r.to_string()).collect()).iter().map(|r| expand_home(r)).collect()
}

pub fn managed_dir() -> PathBuf {
    expand_home(MANAGED)
}

/// Rescan now; with `force`, report even if nothing changed (a hub just connected).
pub fn poke(force: bool) {
    if force {
        FORCE.store(true, Ordering::Relaxed);
    }
    POKE.notify_one();
}

/// Scans every minute (and when poked) and reports when the list changed, or when forced.
pub async fn report(sessions: Sessions) {
    let mut last: Option<Vec<Checkout>> = None;
    let mut last_sent = Instant::now();
    loop {
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(60)) => {}
            _ = POKE.notified() => {}
        }
        let repos = scan(&roots(), &managed_dir()).await;
        // Fetch times move on their own; only a different set of checkouts is news, plus a full report every 10 minutes.
        let key = |l: &[Checkout]| l.iter().map(|c| (c.repo.clone(), c.path.clone(), c.managed)).collect::<Vec<_>>();
        let force = FORCE.swap(false, Ordering::Relaxed) || last_sent.elapsed() >= Duration::from_secs(600);
        if force || last.as_deref().map(key) != Some(key(&repos)) {
            sessions.emit(Outbound::Repos { repos: repos.clone() });
            last = Some(repos);
            last_sent = Instant::now();
        }
    }
}

// ---- removing unused clones ----

/// How long a managed clone may go unused before the sweep removes it, unless runner.json says otherwise.
pub const DEFAULT_CLONE_DAYS: u32 = 14;
const DAY: Duration = Duration::from_secs(24 * 60 * 60);

/// `repoCloneDays` from runner.json (0: never remove), else `DEFAULT_CLONE_DAYS`.
pub fn clone_days(config: Option<&crate::config::Config>) -> u32 {
    config.and_then(|c| c.repo_clone_days).unwrap_or(DEFAULT_CLONE_DAYS)
}

/// Removes managed clones nothing uses any more, when the runner starts and then daily (see `sweep_once`).
/// runner.json is read each time, so a changed `repoCloneDays` counts from the next sweep.
pub async fn sweep(sessions: Sessions) {
    every(DAY, || async {
        let config = crate::config::path().ok().and_then(|p| crate::config::Config::load(&p).ok().flatten());
        let live = live_dirs(&sessions).await;
        sweep_and_report(&managed_dir(), clone_days(config.as_ref()), &live, SystemTime::now()).await;
    })
    .await
}

/// Runs `f` now, then every `period`.
async fn every<F: Future<Output = ()>>(period: Duration, mut f: impl FnMut() -> F) {
    loop {
        f().await;
        tokio::time::sleep(period).await;
    }
}

/// Where live sessions are: where they started and where their shell is now.
async fn live_dirs(sessions: &Sessions) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    for s in sessions.list() {
        dirs.push(expand_home(&s.cwd));
        if let Some(now) = sessions.current_dir(s.id).await {
            dirs.push(expand_home(&now));
        }
    }
    dirs
}

/// `sweep_once`, then a fresh `repos` report if anything went.
async fn sweep_and_report(managed: &Path, days: u32, live: &[PathBuf], now: SystemTime) -> Vec<PathBuf> {
    let removed = sweep_once(managed, days, live, now).await;
    if !removed.is_empty() {
        poke(true);
    }
    removed
}

/// Removes each clone under `managed` (`<owner>/<name>`) with no linked worktree, no live session in
/// it, and no use for `days` days: the newest of its fetches and its worktrees' comings and goings.
/// Nothing outside `managed` is touched, a symlink in it included. Waits for a clone in progress
/// (`.partial`), since clones hold `tasks::CLONING`, and holds it so no task picks a clone mid-removal.
pub async fn sweep_once(managed: &Path, days: u32, live: &[PathBuf], now: SystemTime) -> Vec<PathBuf> {
    let mut removed = Vec::new();
    if days == 0 {
        return removed;
    }
    let _one = crate::tasks::CLONING.lock().await;
    let Ok(base) = std::fs::canonicalize(managed) else { return removed };
    let live: Vec<PathBuf> = live.iter().map(|d| canonical(d)).collect();
    let limit = DAY * days;
    let mut dirs = checkouts_under(managed, 2);
    dirs.sort();
    for dir in dirs {
        let is_link = std::fs::symlink_metadata(&dir).map(|m| m.file_type().is_symlink()).unwrap_or(true);
        let real = canonical(&dir);
        if is_link || !real.starts_with(&base) || real == base {
            continue;
        }
        if live.iter().any(|d| d.starts_with(&real)) {
            continue;
        }
        // Read before the prune below, which changes `.git/worktrees`.
        let Some(used) = last_used(&real) else { continue };
        let idle = now.duration_since(UNIX_EPOCH + Duration::from_millis(used)).unwrap_or_default();
        if idle < limit {
            continue;
        }
        // A worktree whose folder is gone doesn't count; a locked one does (prune keeps it).
        if git_quiet(&real, &["worktree", "prune"]).await.is_none() {
            continue;
        }
        let Some(list) = git_quiet(&real, &["worktree", "list", "--porcelain"]).await else { continue };
        if list.lines().filter(|l| l.starts_with("worktree ")).count() > 1 {
            continue;
        }
        if let Err(e) = std::fs::remove_dir_all(&real) {
            tracing::warn!("couldn't remove the unused clone {}: {e}", abbreviate(&real));
            continue;
        }
        // Its worktree folder and owner folder go too, once empty.
        if let (Some(owner), Some(name)) = (real.parent(), real.file_name()) {
            let _ = std::fs::remove_dir(owner.join(".worktrees").join(name));
            let _ = std::fs::remove_dir(owner.join(".worktrees"));
            let _ = std::fs::remove_dir(owner);
        }
        let ago = idle.as_secs() / DAY.as_secs();
        tracing::info!("removed the unused clone {} (last used {ago} day{} ago)", abbreviate(&real), if ago == 1 { "" } else { "s" });
        removed.push(real);
    }
    removed
}

/// When a clone was last used (ms): its newest fetch or worktree change, else when its `.git` last changed.
fn last_used(dir: &Path) -> Option<u64> {
    let worktrees = dir.join(".git/worktrees");
    let mut newest = fetched_at(dir).max(mtime(&worktrees));
    for entry in std::fs::read_dir(&worktrees).into_iter().flatten().flatten() {
        newest = newest.max(mtime(&entry.path()));
    }
    newest.or_else(|| mtime(&dir.join(".git")))
}

/// git's stdout, or `None` when it fails.
async fn git_quiet(dir: &Path, args: &[&str]) -> Option<String> {
    let out = tokio::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .ok()
        .filter(|o| o.status.success())?;
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Every checkout with a GitHub origin under `roots` (two levels down) and in `managed` (`<owner>/<name>`).
pub async fn scan(roots: &[PathBuf], managed: &Path) -> Vec<Checkout> {
    let mut found: BTreeMap<PathBuf, bool> = BTreeMap::new();
    for root in roots {
        for dir in checkouts_under(root, DEPTH) {
            found.entry(canonical(&dir)).or_insert(false);
        }
    }
    for dir in checkouts_under(managed, 2) {
        found.insert(canonical(&dir), true);
    }
    let mut out = Vec::new();
    for (dir, managed) in found {
        let Some(repo) = github_repo(&dir).await else { continue };
        out.push(Checkout { repo, path: abbreviate(&dir), managed, fetched_at: fetched_at(&dir) });
        if out.len() >= MAX_CHECKOUTS {
            tracing::warn!("over {MAX_CHECKOUTS} checkouts under the repo roots; reporting the first {MAX_CHECKOUTS}");
            break;
        }
    }
    out.sort_by(|a, b| a.repo.to_lowercase().cmp(&b.repo.to_lowercase()).then(a.path.cmp(&b.path)));
    out
}

/// The checkout a task in `repo` uses: the one the runner manages if there is one, else the one
/// fetched most recently.
pub fn pick<'a>(checkouts: &'a [Checkout], repo: &str) -> Option<&'a Checkout> {
    let mut mine: Vec<&Checkout> = checkouts.iter().filter(|c| c.repo.eq_ignore_ascii_case(repo)).collect();
    // Stable: on a tie the first (by path) wins.
    mine.sort_by_key(|c| std::cmp::Reverse((c.managed, c.fetched_at.unwrap_or(0))));
    mine.first().copied()
}

/// Folders at most `depth` levels below `dir` that are checkouts (a `.git` folder; linked worktrees
/// have a `.git` file and are skipped). Dot folders aren't looked in, and a checkout isn't looked inside.
fn checkouts_under(dir: &Path, depth: u32) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(read) = std::fs::read_dir(dir) else { return out };
    for entry in read.flatten() {
        let path = entry.path();
        if entry.file_name().to_string_lossy().starts_with('.') || !path.is_dir() {
            continue;
        }
        if path.join(".git").is_dir() {
            out.push(path);
        } else if depth > 1 {
            out.extend(checkouts_under(&path, depth - 1));
        }
    }
    out
}

/// owner/name of `dir`'s origin, when it's on GitHub.
pub async fn github_repo(dir: &Path) -> Option<String> {
    let out = tokio::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["config", "--get", "remote.origin.url"])
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .ok()
        .filter(|o| o.status.success())?;
    crate::tasks::parse_github(&String::from_utf8_lossy(&out.stdout)).map(|(o, r)| format!("{o}/{r}"))
}

/// The last fetch: FETCH_HEAD, or a remote-tracking ref's reflog (a fetch that didn't write FETCH_HEAD).
fn fetched_at(dir: &Path) -> Option<u64> {
    let git = dir.join(".git");
    let mut newest = mtime(&git.join("FETCH_HEAD"));
    let mut stack = vec![git.join("logs/refs/remotes")];
    while let Some(d) = stack.pop() {
        for entry in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let p = entry.path();
            if p.is_dir() {
                stack.push(p);
            } else {
                newest = newest.max(mtime(&p));
            }
        }
    }
    newest
}

fn mtime(path: &Path) -> Option<u64> {
    let t = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(t.duration_since(UNIX_EPOCH).ok()?.as_millis() as u64)
}

#[cfg(test)]
pub mod tests {
    use super::*;

    pub fn sh(dir: &Path, args: &[&str]) -> String {
        let out = std::process::Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn checkout(dir: &Path, origin: Option<&str>) {
        std::fs::create_dir_all(dir).unwrap();
        sh(dir, &["init", "--quiet"]);
        if let Some(o) = origin {
            sh(dir, &["remote", "add", "origin", o]);
        }
    }

    #[tokio::test]
    async fn finds_github_checkouts_two_levels_down() {
        let tmp = std::env::temp_dir().join(format!("maple-repos-{}", uuid::Uuid::new_v4()));
        let (projects, code, managed) = (tmp.join("Projects"), tmp.join("code"), tmp.join("managed"));
        checkout(&projects.join("widgets"), Some("git@github.com:acme/widgets.git"));
        checkout(&code.join("clients/gadgets"), Some("https://github.com/acme/gadgets"));
        checkout(&code.join("a/b/too-deep"), Some("git@github.com:acme/deep.git"));
        checkout(&code.join("gitlab"), Some("git@gitlab.com:acme/elsewhere.git"));
        checkout(&code.join("no-origin"), None);
        checkout(&code.join(".hidden"), Some("git@github.com:acme/hidden.git"));
        // Inside a checkout isn't looked at.
        checkout(&projects.join("widgets/vendor"), Some("git@github.com:acme/vendored.git"));
        // A linked worktree has a .git file, not a folder.
        let widgets = projects.join("widgets");
        sh(&widgets, &["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "x"]);
        sh(&widgets, &["worktree", "add", "--quiet", "-b", "agent/x", projects.join("widgets-x").to_str().unwrap()]);
        checkout(&managed.join("acme/widgets"), Some("https://github.com/acme/widgets.git"));

        let found = scan(&[projects.clone(), code.clone(), tmp.join("missing")], &managed).await;
        let got: Vec<(&str, bool)> = found.iter().map(|c| (c.repo.as_str(), c.managed)).collect();
        assert_eq!(got, vec![("acme/gadgets", false), ("acme/widgets", false), ("acme/widgets", true)], "{found:?}");
        assert!(found.iter().all(|c| c.fetched_at.is_none()));

        // The managed one wins, else the most recently fetched.
        assert!(pick(&found, "ACME/widgets").unwrap().managed);
        let mut theirs: Vec<Checkout> = found.iter().filter(|c| !c.managed).cloned().collect();
        theirs.push(Checkout { repo: "acme/widgets".into(), path: "~/other/widgets".into(), managed: false, fetched_at: Some(5) });
        assert_eq!(pick(&theirs, "acme/widgets").unwrap().path, "~/other/widgets");
        assert!(pick(&theirs, "acme/nope").is_none());
        std::fs::remove_dir_all(&tmp).unwrap();
    }

    /// A temporary HOME with the runner's managed folder in it; the real one is never looked at.
    fn temp_home() -> (PathBuf, PathBuf) {
        let home = std::env::temp_dir().join(format!("maple-home-{}", uuid::Uuid::new_v4()));
        let managed = home.join(".local/share/maple/repos");
        std::fs::create_dir_all(&managed).unwrap();
        (home, managed)
    }

    /// A clone like `tasks::clone` makes: a commit, fetched into origin/main.
    fn clone_at(dir: &Path) {
        checkout(dir, Some(&format!("https://github.com/acme/{}.git", dir.file_name().unwrap().to_string_lossy())));
        sh(dir, &["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "x"]);
        sh(dir, &["update-ref", "refs/remotes/origin/main", "HEAD"]);
    }

    /// Sets the mtime of `dir` and everything in it to `days` ago, as if nothing had touched it since.
    fn backdate(dir: &Path, days: u64) {
        let t = SystemTime::now() - DAY * days as u32;
        let mut stack = vec![dir.to_path_buf()];
        while let Some(p) = stack.pop() {
            if p.is_dir() && !p.is_symlink() {
                stack.extend(std::fs::read_dir(&p).unwrap().flatten().map(|e| e.path()));
            }
            if !p.is_symlink() {
                std::fs::File::open(&p).unwrap().set_modified(t).unwrap();
            }
        }
    }

    /// Log output, kept for a test to read.
    #[derive(Clone, Default)]
    struct Log(std::sync::Arc<Mutex<Vec<u8>>>);

    impl std::io::Write for Log {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn sweep_removes_only_unused_managed_clones() {
        let (home, managed) = temp_home();
        let acme = managed.join("acme");
        // Unused for 20 days: goes.
        clone_at(&acme.join("old"));
        // Its one worktree's folder was deleted by hand: the stale record doesn't keep it.
        clone_at(&acme.join("stale"));
        sh(&acme.join("stale"), &["worktree", "add", "--quiet", "-b", "agent/x", acme.join(".worktrees/stale/x").to_str().unwrap()]);
        std::fs::remove_dir_all(acme.join(".worktrees/stale/x")).unwrap();
        // A linked worktree keeps it, however old.
        clone_at(&acme.join("linked"));
        sh(&acme.join("linked"), &["worktree", "add", "--quiet", "-b", "agent/y", acme.join(".worktrees/linked/y").to_str().unwrap()]);
        // So does a live session in it.
        clone_at(&acme.join("live"));
        std::fs::create_dir_all(acme.join("live/src")).unwrap();
        // The user's own checkout, old and unused, and a symlink to it in the managed folder.
        let mine = home.join("Projects/mine");
        clone_at(&mine);
        std::os::unix::fs::symlink(&mine, acme.join("mine")).unwrap();
        backdate(&home, 20);
        // Fetched 3 days ago: kept.
        clone_at(&acme.join("recent"));
        backdate(&acme.join("recent"), 3);
        // A clone in progress is in a dot folder and never looked at.
        clone_at(&managed.join(".partial/0000"));
        backdate(&managed.join(".partial"), 30);

        let live = [acme.join("live/src")];
        let log = Log::default();
        let removed = {
            let writer = log.clone();
            let _guard = tracing::subscriber::set_default(tracing_subscriber::fmt().with_ansi(false).with_writer(move || writer.clone()).finish());
            sweep_and_report(&managed, DEFAULT_CLONE_DAYS, &live, SystemTime::now()).await
        };
        let names: Vec<String> = removed.iter().map(|d| d.file_name().unwrap().to_string_lossy().into_owned()).collect();
        assert_eq!(names, vec!["old", "stale"]);
        let log = String::from_utf8(log.0.lock().unwrap().clone()).unwrap();
        let line = log.lines().find(|l| l.contains("acme/old")).unwrap_or_default();
        assert!(line.contains("INFO") && line.contains("removed the unused clone") && line.ends_with("(last used 20 days ago)"), "{log}");
        assert!(!acme.join("old").exists() && !acme.join("stale").exists() && !acme.join(".worktrees/stale").exists());
        for kept in ["linked", "live", "recent", ".worktrees/linked/y", "mine"] {
            assert!(acme.join(kept).exists(), "{kept}");
        }
        assert!(acme.join("mine").is_symlink() && mine.join(".git/HEAD").exists());
        assert!(managed.join(".partial/0000/.git").exists());
        // The hub hears the new list.
        assert!(FORCE.load(Ordering::Relaxed));

        // Nothing left to remove; once the session and the worktree are gone, those go too.
        assert!(sweep_once(&managed, DEFAULT_CLONE_DAYS, &live, SystemTime::now()).await.is_empty());
        sh(&acme.join("linked"), &["worktree", "remove", acme.join(".worktrees/linked/y").to_str().unwrap()]);
        backdate(&acme.join("linked"), 20);
        let removed = sweep_once(&managed, DEFAULT_CLONE_DAYS, &[], SystemTime::now()).await;
        assert_eq!(removed.len(), 2, "{removed:?}");
        assert!(!acme.join("linked").exists() && !acme.join("live").exists() && acme.join("recent").exists());
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[tokio::test]
    async fn repo_clone_days_sets_the_threshold() {
        let parse = |json: &str| serde_json::from_str::<crate::config::Config>(json).unwrap();
        let base = r#""url":"http://localhost:8787","runnerId":"a","token":"t""#;
        assert_eq!(clone_days(None), 14);
        assert_eq!(clone_days(Some(&parse(&format!("{{{base}}}")))), 14);
        assert_eq!(clone_days(Some(&parse(&format!("{{{base},\"repoCloneDays\":30}}")))), 30);
        assert_eq!(clone_days(Some(&parse(&format!("{{{base},\"repoCloneDays\":0}}")))), 0);

        let (home, managed) = temp_home();
        clone_at(&managed.join("acme/widgets"));
        backdate(&home, 20);
        let now = SystemTime::now();
        assert!(sweep_once(&managed, 30, &[], now).await.is_empty());
        // 0 never removes, however old.
        assert!(sweep_once(&managed, 0, &[], now + DAY * 400).await.is_empty());
        assert_eq!(sweep_once(&managed, 30, &[], now + DAY * 11).await.len(), 1);
        assert!(!managed.join("acme").exists());
        std::fs::remove_dir_all(&home).unwrap();
    }

    /// `sweep` runs through `every(DAY, …)`: once right away (the runner starting), then each period.
    #[tokio::test]
    async fn sweeps_on_start_and_then_every_period() {
        let runs = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = runs.clone();
        let task = tokio::spawn(every(Duration::from_millis(200), move || {
            counter.fetch_add(1, Ordering::SeqCst);
            async {}
        }));
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(runs.load(Ordering::SeqCst), 1);
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(runs.load(Ordering::SeqCst), 2);
        task.abort();
    }
}
