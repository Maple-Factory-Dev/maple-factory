//! Files named in a terminal: what a path is (`file.stat`) and its bytes in pieces
//! (`file.read`), for the browser's link provider and media viewer.
//!
//! The rules match the folder page's: only paths under $HOME, and nothing that leads out of it
//! through a symlink. A path is absolute, `~/…`, or relative to the session's directory (the
//! shell's current one, from tmux, when the browser names the session). `..` is folded away
//! against that directory before the checks, so `../x` can't climb out of $HOME either.

use std::io::{Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};

use anyhow::{Result, anyhow, bail};
use base64::Engine;
use serde::Serialize;

use crate::fs_browse;

/// The most one `file.chunk` carries. Base64 makes it about 700 KB on the wire, well under
/// the 1 MB WebSocket messages Cloudflare passes.
pub const MAX_CHUNK: u64 = 512 * 1024;
/// The most the viewer downloads of one file.
pub const MAX_TOTAL: u64 = 200 * 1024 * 1024;
/// Bytes looked at to tell what a file is.
const SNIFF: usize = 4096;

#[derive(Debug, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Stat {
    pub exists: bool,
    /// image | video | audio | pdf | text | other | dir
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime: Option<&'static str>,
    /// The path as the runner understood it, `~`-abbreviated (what `file.read` takes).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolved: Option<String>,
    /// The directory a relative path was resolved against, `~`-abbreviated.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// Why the path can't be looked at (outside home, a link that leads out).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Chunk {
    /// The whole file's size.
    pub size: u64,
    pub mime: &'static str,
    pub offset: u64,
    /// Base64.
    pub data: String,
    pub eof: bool,
}

/// `path` as a place under home: `~/x`, `/abs/x`, or `x` relative to `cwd` (an absolute
/// directory). `..` is folded lexically. Paths through the home directory's real location
/// (`/private/var/…` for `/var/…` on macOS) are mapped back onto `home`.
pub fn locate(path: &str, cwd: Option<&Path>, home: &Path) -> Result<PathBuf> {
    let path = path.trim();
    if path.is_empty() || path.len() > 4096 || path.contains('\0') {
        bail!("Choose a file.");
    }
    let joined = if path == "~" {
        home.to_path_buf()
    } else if let Some(rest) = path.strip_prefix("~/") {
        home.join(rest)
    } else if path.starts_with('/') {
        PathBuf::from(path)
    } else {
        match cwd {
            Some(dir) => dir.join(path),
            None => bail!("A relative path needs the session's folder."),
        }
    };
    let mut clean = PathBuf::new();
    for c in joined.components() {
        match c {
            Component::ParentDir => {
                if !clean.pop() {
                    bail!("That path climbs out of the file system.");
                }
            }
            Component::CurDir => {}
            other => clean.push(other),
        }
    }
    let clean = rehome(clean, home);
    if !clean.starts_with(home) {
        bail!("Only files in your home directory can be opened.");
    }
    Ok(clean)
}

/// A path under home's real (symlink-resolved) location, put back under `home`.
fn rehome(path: PathBuf, home: &Path) -> PathBuf {
    if path.starts_with(home) {
        return path;
    }
    match std::fs::canonicalize(home) {
        Ok(real) if real != home => match path.strip_prefix(&real) {
            Ok(rest) => home.join(rest),
            Err(_) => path,
        },
        _ => path,
    }
}

/// The real file behind `path`, which has to stay under home's real location. None when
/// nothing is there.
fn real_path(path: &Path, home: &Path) -> Result<Option<PathBuf>> {
    if std::fs::symlink_metadata(path).is_err() {
        return Ok(None);
    }
    let real = std::fs::canonicalize(path).map_err(|_| anyhow!("That's a link that leads nowhere."))?;
    let real_home = std::fs::canonicalize(home).unwrap_or_else(|_| home.to_path_buf());
    if !real.starts_with(&real_home) {
        bail!("That leads outside your home directory.");
    }
    Ok(Some(real))
}

/// The directory relative paths are resolved against: the shell's own (from tmux), else the
/// session's starting folder. Either has to be under home.
pub fn base_dir(pane_dir: Option<&str>, cwd: Option<&str>, home: &Path) -> Option<PathBuf> {
    if let Some(dir) = pane_dir.map(str::trim).filter(|d| d.starts_with('/'))
        && let Ok(dir) = locate(dir, None, home)
    {
        return Some(dir);
    }
    cwd.and_then(|c| fs_browse::resolve(c, home).ok())
}

pub fn stat(path: &str, cwd: Option<&Path>, home: &Path) -> Stat {
    let abbreviated_cwd = cwd.map(|c| fs_browse::abbreviate(c, home));
    let missing = |error: Option<String>, resolved: Option<String>| Stat { resolved, cwd: abbreviated_cwd.clone(), error, ..Stat::default() };
    let full = match locate(path, cwd, home) {
        Ok(full) => full,
        Err(e) => return missing(Some(e.to_string()), None),
    };
    let resolved = fs_browse::abbreviate(&full, home);
    let real = match real_path(&full, home) {
        Ok(Some(real)) => real,
        Ok(None) => return missing(None, Some(resolved)),
        Err(e) => return missing(Some(e.to_string()), Some(resolved)),
    };
    let Ok(meta) = std::fs::metadata(&real) else { return missing(None, Some(resolved)) };
    let (kind, mime) = if meta.is_dir() {
        ("dir", "inode/directory")
    } else if !meta.is_file() {
        ("other", "application/octet-stream")
    } else {
        let mut head = Vec::with_capacity(SNIFF);
        let _ = std::fs::File::open(&real).and_then(|f| f.take(SNIFF as u64).read_to_end(&mut head));
        sniff(&full, &head)
    };
    Stat { exists: true, kind: Some(kind), size: Some(meta.len()), mime: Some(mime), resolved: Some(resolved), cwd: abbreviated_cwd, error: None }
}

/// Up to `length` bytes (at most `MAX_CHUNK`) of the file at `path` from `offset`.
pub fn read(path: &str, offset: u64, length: u64, home: &Path) -> Result<Chunk> {
    let full = locate(path, None, home)?;
    let real = real_path(&full, home)?.ok_or_else(|| anyhow!("{} doesn't exist.", fs_browse::abbreviate(&full, home)))?;
    let mut file = std::fs::File::open(&real).map_err(|e| anyhow!("Can't open {}: {e}", fs_browse::abbreviate(&full, home)))?;
    let meta = file.metadata()?;
    if !meta.is_file() {
        bail!("{} isn't a file.", fs_browse::abbreviate(&full, home));
    }
    let size = meta.len();
    if offset >= MAX_TOTAL {
        bail!("Only the first 200 MB of a file can be read here.");
    }
    let mut head = Vec::with_capacity(SNIFF);
    (&mut file).take(SNIFF as u64).read_to_end(&mut head)?;
    let (_, mime) = sniff(&full, &head);
    let length = length.clamp(1, MAX_CHUNK).min(MAX_TOTAL - offset);
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::with_capacity(length.min(size.saturating_sub(offset)) as usize);
    file.take(length).read_to_end(&mut bytes)?;
    let end = offset + bytes.len() as u64;
    Ok(Chunk { size, mime, offset, data: base64::engine::general_purpose::STANDARD.encode(&bytes), eof: end >= size || bytes.is_empty() })
}

/// What a file is, from its first bytes, then its extension. Bytes win: a `.png` that's
/// really text is text, and only real PDFs are PDFs.
pub fn sniff(path: &Path, head: &[u8]) -> (&'static str, &'static str) {
    if let Some(found) = magic(head) {
        return found;
    }
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    let text = !head[..head.len().min(8000)].contains(&0);
    match ext.as_str() {
        // Formats whose first bytes aren't distinctive enough to insist on.
        "mp3" if !head.is_empty() => return ("audio", "audio/mpeg"),
        "aac" if !head.is_empty() => return ("audio", "audio/aac"),
        "svg" if text && looks_like_svg(head) => return ("image", "image/svg+xml"),
        _ => {}
    }
    if text { ("text", "text/plain") } else { ("other", "application/octet-stream") }
}

fn magic(h: &[u8]) -> Option<(&'static str, &'static str)> {
    let at = |i: usize, sig: &[u8]| h.len() >= i + sig.len() && &h[i..i + sig.len()] == sig;
    Some(if at(0, b"\x89PNG\r\n\x1a\n") {
        ("image", "image/png")
    } else if at(0, b"\xff\xd8\xff") {
        ("image", "image/jpeg")
    } else if at(0, b"GIF87a") || at(0, b"GIF89a") {
        ("image", "image/gif")
    } else if at(0, b"RIFF") && at(8, b"WEBP") {
        ("image", "image/webp")
    } else if at(0, b"RIFF") && at(8, b"WAVE") {
        ("audio", "audio/wav")
    } else if at(4, b"ftyp") {
        // ISO media: the brand says what's inside.
        match h.get(8..12) {
            Some(b"qt  ") => ("video", "video/quicktime"),
            Some(b"M4A " | b"M4B " | b"M4P ") => ("audio", "audio/mp4"),
            Some(b"avif" | b"avis") => ("image", "image/avif"),
            Some(b"heic" | b"heix" | b"mif1" | b"msf1") => return None,
            _ => ("video", "video/mp4"),
        }
    } else if at(0, b"\x1a\x45\xdf\xa3") {
        ("video", "video/webm")
    } else if at(0, b"%PDF-") {
        ("pdf", "application/pdf")
    } else if at(0, b"OggS") {
        ("audio", "audio/ogg")
    } else if at(0, b"fLaC") {
        ("audio", "audio/flac")
    } else if at(0, b"ID3") {
        ("audio", "audio/mpeg")
    } else {
        return None;
    })
}

fn looks_like_svg(head: &[u8]) -> bool {
    let s = String::from_utf8_lossy(head).to_ascii_lowercase();
    s.contains("<svg")
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";

    #[test]
    fn locates_under_home() {
        let home = Path::new("/home/me");
        let cwd = Path::new("/home/me/app");
        assert_eq!(locate("~/a.png", None, home).unwrap(), PathBuf::from("/home/me/a.png"));
        assert_eq!(locate("/home/me/x/./y.mp4", None, home).unwrap(), PathBuf::from("/home/me/x/y.mp4"));
        assert_eq!(locate("out/a.png", Some(cwd), home).unwrap(), PathBuf::from("/home/me/app/out/a.png"));
        assert_eq!(locate("./a.png", Some(cwd), home).unwrap(), PathBuf::from("/home/me/app/a.png"));
        assert_eq!(locate("../other/a.png", Some(cwd), home).unwrap(), PathBuf::from("/home/me/other/a.png"));
        assert!(locate("../../etc/passwd", Some(cwd), home).is_err());
        assert!(locate("~/../other/x", None, home).is_err());
        assert!(locate("/etc/passwd", None, home).is_err());
        assert!(locate("/home/meme/x", None, home).is_err());
        assert!(locate("a.png", None, home).is_err(), "relative without a folder");
        assert!(locate("", Some(cwd), home).is_err());
        assert!(locate("a\0b", Some(cwd), home).is_err());
    }

    #[test]
    fn sniffs_by_bytes_then_extension() {
        let p = |s: &str| PathBuf::from(s);
        assert_eq!(sniff(&p("a.png"), PNG), ("image", "image/png"));
        assert_eq!(sniff(&p("no-extension"), PNG), ("image", "image/png"));
        assert_eq!(sniff(&p("a.jpg"), b"\xff\xd8\xff\xe0"), ("image", "image/jpeg"));
        assert_eq!(sniff(&p("a.gif"), b"GIF89a.."), ("image", "image/gif"));
        assert_eq!(sniff(&p("a.webp"), b"RIFF\0\0\0\0WEBPVP8 "), ("image", "image/webp"));
        assert_eq!(sniff(&p("a.mp4"), b"\0\0\0\x20ftypisom\0\0"), ("video", "video/mp4"));
        assert_eq!(sniff(&p("a.mov"), b"\0\0\0\x14ftypqt  \0\0"), ("video", "video/quicktime"));
        assert_eq!(sniff(&p("a.m4a"), b"\0\0\0\x20ftypM4A \0\0"), ("audio", "audio/mp4"));
        assert_eq!(sniff(&p("a.webm"), b"\x1a\x45\xdf\xa3\x01"), ("video", "video/webm"));
        assert_eq!(sniff(&p("a.pdf"), b"%PDF-1.7\n"), ("pdf", "application/pdf"));
        assert_eq!(sniff(&p("a.wav"), b"RIFF\0\0\0\0WAVEfmt "), ("audio", "audio/wav"));
        assert_eq!(sniff(&p("a.mp3"), b"ID3\x04"), ("audio", "audio/mpeg"));
        assert_eq!(sniff(&p("a.mp3"), b"\xff\xfb\x90\x00"), ("audio", "audio/mpeg"));
        assert_eq!(sniff(&p("a.svg"), b"<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\">"), ("image", "image/svg+xml"));
        // The extension alone doesn't make an image or a PDF.
        assert_eq!(sniff(&p("fake.png"), b"just text\n"), ("text", "text/plain"));
        assert_eq!(sniff(&p("fake.pdf"), b"<html><script>"), ("text", "text/plain"));
        assert_eq!(sniff(&p("fake.svg"), b"hello"), ("text", "text/plain"));
        assert_eq!(sniff(&p("main.rs"), b"fn main() {}\n"), ("text", "text/plain"));
        assert_eq!(sniff(&p("blob.bin"), b"\x01\x00\x02"), ("other", "application/octet-stream"));
        assert_eq!(sniff(&p("empty.txt"), b""), ("text", "text/plain"));
    }

    #[test]
    fn stats_and_reads_in_chunks() {
        let root = std::env::temp_dir().join(format!("maple-media-{}", uuid::Uuid::new_v4()));
        let home = root.join("home");
        std::fs::create_dir_all(home.join("app/out")).unwrap();
        std::fs::write(root.join("secret.png"), PNG).unwrap();
        std::fs::write(home.join("app/out/shot.png"), PNG).unwrap();
        std::fs::write(home.join("app/notes.md"), "# hi\n").unwrap();
        std::os::unix::fs::symlink("../secret.png", home.join("leak.png")).unwrap();
        std::os::unix::fs::symlink("/", home.join("root")).unwrap();
        std::os::unix::fs::symlink("app/out/shot.png", home.join("inside.png")).unwrap();
        let big: Vec<u8> = (0..(MAX_CHUNK as usize * 2 + 100)).map(|i| (i % 251) as u8).collect();
        std::fs::write(home.join("big.bin"), &big).unwrap();

        let cwd = home.join("app");
        let s = stat("out/shot.png", Some(&cwd), &home);
        assert_eq!(
            (s.exists, s.kind, s.size, s.mime, s.resolved.as_deref(), s.cwd.as_deref()),
            (true, Some("image"), Some(PNG.len() as u64), Some("image/png"), Some("~/app/out/shot.png"), Some("~/app"))
        );
        assert_eq!(stat("notes.md", Some(&cwd), &home).kind, Some("text"));
        assert_eq!(stat("~/app", None, &home).kind, Some("dir"));
        assert_eq!(stat("~/inside.png", None, &home).kind, Some("image"));
        let gone = stat("missing.png", Some(&cwd), &home);
        assert!(!gone.exists && gone.error.is_none() && gone.resolved.as_deref() == Some("~/app/missing.png"));
        // Escapes say why and never exist.
        for bad in ["~/leak.png", "~/root/etc/hosts", "../../secret.png"] {
            let s = stat(bad, Some(&cwd), &home);
            assert!(!s.exists && s.error.is_some(), "{bad}: {s:?}");
        }
        assert!(read("~/leak.png", 0, 10, &home).is_err());
        assert!(read("~/root/etc/hosts", 0, 10, &home).is_err());
        assert!(read("~/app", 0, 10, &home).is_err());
        assert!(read("~/nope", 0, 10, &home).is_err());

        // Chunks: capped at MAX_CHUNK, eof on the last one, bytes intact.
        let mut got = Vec::new();
        let mut offset = 0;
        let mut chunks = 0;
        loop {
            let c = read("~/big.bin", offset, u64::MAX, &home).unwrap();
            assert_eq!((c.size, c.offset, c.mime), (big.len() as u64, offset, "application/octet-stream"));
            let bytes = base64::engine::general_purpose::STANDARD.decode(&c.data).unwrap();
            assert!(bytes.len() as u64 <= MAX_CHUNK);
            got.extend_from_slice(&bytes);
            offset += bytes.len() as u64;
            chunks += 1;
            if c.eof {
                break;
            }
        }
        assert_eq!((chunks, got == big), (3, true));
        let c = read("~/app/out/shot.png", 0, 4, &home).unwrap();
        assert_eq!((c.mime, c.eof, c.data.as_str()), ("image/png", false, "iVBORw=="));
        let past = read("~/app/out/shot.png", 1000, 4, &home).unwrap();
        assert!(past.eof && past.data.is_empty());
        assert!(read("~/big.bin", MAX_TOTAL, 4, &home).is_err());

        // A shell that cd'ed: tmux reports the real path; it maps back under home.
        let real_home = std::fs::canonicalize(&home).unwrap();
        let pane = real_home.join("app/out");
        assert_eq!(base_dir(pane.to_str(), Some("~"), &home), Some(home.join("app/out")));
        assert_eq!(base_dir(Some("/"), Some("~/app"), &home), Some(home.join("app")), "a pane outside home falls back");
        assert_eq!(base_dir(None, Some("/etc"), &home), None);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn serializes() {
        assert_eq!(serde_json::to_value(Stat::default()).unwrap(), serde_json::json!({"exists": false}));
    }
}
