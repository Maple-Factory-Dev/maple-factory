//! Folder listings for the New session directory picker (`fs.list`, `fs.mkdir`).
//!
//! The browser only ever sees directories under `$HOME`. Paths are checked lexically:
//! `..` is refused outright rather than normalized, so a request can't climb out, and a
//! path must start with the home directory once `~` is expanded. (Symlinks inside home
//! are followed like any terminal would; the restriction is about what the UI asks for.)

use std::path::{Component, Path, PathBuf};

use anyhow::{Result, bail};
use serde::Serialize;

const MAX_ENTRIES: usize = 200;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub name: String,
    pub is_repo: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Listing {
    /// `~`-abbreviated.
    pub path: String,
    pub entries: Vec<Entry>,
    /// Set when there are more folders than were sent.
    pub truncated: bool,
}

/// `~`, `~/x` or an absolute path under `home`. Empty means home.
pub fn resolve(path: &str, home: &Path) -> Result<PathBuf> {
    let path = path.trim();
    let full = if path.is_empty() || path == "~" {
        home.to_path_buf()
    } else if let Some(rest) = path.strip_prefix("~/") {
        home.join(rest)
    } else if path.starts_with('/') {
        PathBuf::from(path)
    } else {
        bail!("Use a path that starts with ~/ or /.");
    };
    if full.components().any(|c| matches!(c, Component::ParentDir)) {
        bail!("Paths can't contain `..`.");
    }
    // Drops `.` and doubled slashes so the prefix check compares like with like.
    let full: PathBuf = full.components().collect();
    if !full.starts_with(home) {
        bail!("Only folders in your home directory ({}) can be browsed.", home.display());
    }
    Ok(full)
}

/// `/Users/me/x` → `~/x`.
pub fn abbreviate(path: &Path, home: &Path) -> String {
    match path.strip_prefix(home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => path.display().to_string(),
    }
}

/// Folders in `path`, sorted by name. Hidden ones are left out unless asked for
/// (typing `~/.c` in the field); `.git` never shows.
pub fn list(path: &str, hidden: bool, home: &Path) -> Result<Listing> {
    let dir = resolve(path, home)?;
    let read = match std::fs::read_dir(&dir) {
        Ok(read) => read,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => bail!("{} doesn't exist.", abbreviate(&dir, home)),
        Err(e) => bail!("Can't open {}: {e}", abbreviate(&dir, home)),
    };
    let mut entries: Vec<Entry> = read
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if name == ".git" || (name.starts_with('.') && !hidden) {
                return None;
            }
            // Follows symlinks, so a linked folder shows up as a folder.
            let path = e.path();
            path.is_dir().then(|| Entry { is_repo: path.join(".git").exists(), name })
        })
        .collect();
    entries.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()).then(a.name.cmp(&b.name)));
    let truncated = entries.len() > MAX_ENTRIES;
    entries.truncate(MAX_ENTRIES);
    Ok(Listing { path: abbreviate(&dir, home), entries, truncated })
}

/// Creates one folder (its parent must exist) and returns the parent's listing.
pub fn mkdir(path: &str, home: &Path) -> Result<(Listing, String)> {
    let dir = resolve(path, home)?;
    let (Some(parent), Some(name)) = (dir.parent(), dir.file_name().and_then(|n| n.to_str())) else {
        bail!("Choose a name for the folder.");
    };
    valid_folder_name(name)?;
    if !parent.starts_with(home) || dir == home {
        bail!("New folders go inside your home directory.");
    }
    if !parent.is_dir() {
        bail!("{} doesn't exist.", abbreviate(parent, home));
    }
    match std::fs::create_dir(&dir) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => bail!("{} already exists.", abbreviate(&dir, home)),
        Err(e) => bail!("Can't create {}: {e}", abbreviate(&dir, home)),
    }
    let listing = list(&abbreviate(parent, home), name.starts_with('.'), home)?;
    Ok((listing, abbreviate(&dir, home)))
}

pub fn valid_folder_name(name: &str) -> Result<()> {
    if name.is_empty() || name == "." || name == ".." {
        bail!("Choose a name for the folder.");
    }
    if name.contains(['/', '\0']) || name.len() > 255 {
        bail!("Folder names can't contain `/`.");
    }
    Ok(())
}

pub fn home() -> Result<PathBuf> {
    let home = std::env::var("HOME").map_err(|_| anyhow::anyhow!("HOME is not set"))?;
    // Without a trailing slash, so prefix checks and abbreviations line up.
    Ok(PathBuf::from(home).components().collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_under_home_only() {
        let home = Path::new("/home/me");
        assert_eq!(resolve("", home).unwrap(), PathBuf::from("/home/me"));
        assert_eq!(resolve("~", home).unwrap(), PathBuf::from("/home/me"));
        assert_eq!(resolve("~/Projects/", home).unwrap(), PathBuf::from("/home/me/Projects"));
        assert_eq!(resolve("/home/me//a/./b", home).unwrap(), PathBuf::from("/home/me/a/b"));
        assert!(resolve("~/../other", home).is_err());
        assert!(resolve("~/a/../../etc", home).is_err());
        assert!(resolve("/etc", home).is_err());
        assert!(resolve("/home/meme", home).is_err(), "a sibling that shares the prefix isn't home");
        assert!(resolve("Projects", home).is_err());
        assert!(resolve("~other/x", home).is_err());
    }

    #[test]
    fn abbreviates() {
        let home = Path::new("/home/me");
        assert_eq!(abbreviate(Path::new("/home/me"), home), "~");
        assert_eq!(abbreviate(Path::new("/home/me/x/y"), home), "~/x/y");
        assert_eq!(abbreviate(Path::new("/tmp"), home), "/tmp");
    }

    #[test]
    fn folder_names() {
        assert!(valid_folder_name("new-app").is_ok());
        assert!(valid_folder_name(".config").is_ok());
        for bad in ["", ".", "..", "a/b"] {
            assert!(valid_folder_name(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn lists_and_creates_folders() {
        let home = std::env::temp_dir().join(format!("maple-fs-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(home.join("b-repo/.git")).unwrap();
        std::fs::create_dir_all(home.join("A")).unwrap();
        std::fs::create_dir_all(home.join(".hidden")).unwrap();
        std::fs::write(home.join("file.txt"), "x").unwrap();
        let l = list("~", false, &home).unwrap();
        assert_eq!(l.path, "~");
        assert_eq!(l.entries, [Entry { name: "A".into(), is_repo: false }, Entry { name: "b-repo".into(), is_repo: true }]);
        assert_eq!(list("~", true, &home).unwrap().entries.len(), 3);
        assert_eq!(list("~/b-repo", true, &home).unwrap().entries, [], ".git never shows");

        let (l, created) = mkdir("~/A/new", &home).unwrap();
        assert_eq!((l.path.as_str(), created.as_str()), ("~/A", "~/A/new"));
        assert_eq!(l.entries.len(), 1);
        assert!(mkdir("~/A/new", &home).unwrap_err().to_string().contains("already exists"));
        assert!(mkdir("~/missing/new", &home).is_err(), "not recursive");
        assert!(mkdir("~", &home).is_err());
        assert!(mkdir("~/../x", &home).is_err());
        std::fs::remove_dir_all(&home).unwrap();
    }
}
