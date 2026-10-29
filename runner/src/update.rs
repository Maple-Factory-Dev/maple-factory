//! Self-update: finding, verifying and installing newer runner builds.
//!
//! The control plane serves releases at `{base}/releases/`:
//!
//! - `maple-runner/latest.json`: the manifest (version, and per target a path, sha256 and size);
//! - `maple-runner/latest.json.sig`: a base64 Ed25519 signature over the manifest's exact bytes.
//!
//! Trust comes from the signature, not from the server or TLS: the release key is built in,
//! the signature is checked before anything in the manifest is believed, and the binary must
//! then match the manifest's size and sha256. A stolen Worker or bucket can withhold updates
//! but can't push one.
//!
//! A new binary is written next to the running one and renamed over it. The running process
//! keeps the old file (rename swaps the directory entry, not the file being executed), and on
//! macOS that's also what avoids the kernel killing a process whose signed binary changed
//! underneath it, which is what copying over it in place does.

use std::collections::BTreeMap;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use ed25519_dalek::{Signature, VerifyingKey};
use semver::Version;
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::config;

/// The release signing key: a raw 32-byte Ed25519 public key, base64url without padding.
pub const RELEASE_PUBLIC_KEY: &str = "-GzUbxnqGXRDK-1jtr3R8x1RIWORNkg_0CSC2BOG6zQ";

/// The exit status of a runner that has just replaced its own binary. Any non-zero status
/// makes launchd (`KeepAlive.SuccessfulExit = false`) and systemd (`Restart=on-failure`)
/// start it again, now running the new build. 75 is EX_TEMPFAIL: "come back and try again".
pub const EXIT_UPDATED: i32 = 75;

/// This build's version.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The manifest's path under the releases URL.
const MANIFEST: &str = "maple-runner/latest.json";

/// Manifests are small; anything bigger isn't one.
const MAX_MANIFEST_BYTES: usize = 1 << 20;

/// The release target for this build, from the platform it was compiled for.
pub fn target() -> Option<&'static str> {
    target_for(std::env::consts::OS, std::env::consts::ARCH)
}

/// The release target (a Rust target triple) for an OS and architecture.
pub fn target_for(os: &str, arch: &str) -> Option<&'static str> {
    match (os, arch) {
        ("macos", "aarch64") => Some("aarch64-apple-darwin"),
        ("macos", "x86_64") => Some("x86_64-apple-darwin"),
        ("linux", "x86_64") => Some("x86_64-unknown-linux-gnu"),
        ("linux", "aarch64") => Some("aarch64-unknown-linux-gnu"),
        _ => None,
    }
}

/// Where releases come from: `MAPLE_UPDATE_URL` when set (a full releases URL), otherwise
/// `/releases/` on the control plane. `server` may be a base URL or a ws(s):// runner
/// endpoint. Always ends in `/`.
pub fn releases_url(update_url: Option<&str>, server: Option<&str>) -> Result<String> {
    if let Some(url) = update_url.map(str::trim).filter(|u| !u.is_empty()) {
        if !(url.starts_with("https://") || url.starts_with("http://")) {
            bail!("MAPLE_UPDATE_URL `{url}` is not an http(s):// URL");
        }
        return Ok(format!("{}/", url.trim_end_matches('/')));
    }
    let Some(server) = server else {
        bail!("no control plane to update from: enroll this machine (`maple-runner enroll`) or set MAPLE_UPDATE_URL");
    };
    Ok(format!("{}/releases/", config::base_url(server)?))
}

/// [`releases_url`] with `MAPLE_UPDATE_URL` from the environment.
pub fn releases_url_from_env(server: Option<&str>) -> Result<String> {
    releases_url(std::env::var("MAPLE_UPDATE_URL").ok().as_deref(), server)
}

/// Whether `exe` is a development build: one inside a cargo `target/` directory, which
/// `cargo build` would overwrite anyway.
pub fn is_dev_build(exe: &Path) -> bool {
    exe.components().any(|c| c.as_os_str() == "target")
}

/// Reads a base64url (unpadded) raw Ed25519 public key.
pub fn decode_key(text: &str) -> Result<VerifyingKey> {
    let bytes = URL_SAFE_NO_PAD.decode(text.trim()).context("the release key isn't base64url")?;
    let bytes: [u8; 32] = bytes.try_into().map_err(|_| anyhow!("the release key isn't 32 bytes"))?;
    VerifyingKey::from_bytes(&bytes).context("the release key isn't an Ed25519 public key")
}

/// The key releases must be signed with. Debug builds accept `MAPLE_UPDATE_PUBKEY` instead,
/// so the update path can be tested end to end with a throwaway key; release builds ignore it.
fn release_key() -> Result<VerifyingKey> {
    #[cfg(debug_assertions)]
    if let Ok(key) = std::env::var("MAPLE_UPDATE_PUBKEY") {
        return decode_key(&key).context("MAPLE_UPDATE_PUBKEY");
    }
    decode_key(RELEASE_PUBLIC_KEY)
}

/// Checks `sig` (base64, standard alphabet, surrounding whitespace allowed) against the
/// exact bytes of the manifest.
pub fn verify(key: &VerifyingKey, manifest: &[u8], sig: &[u8]) -> Result<()> {
    let sig = std::str::from_utf8(sig).map_err(|_| anyhow!("the release manifest's signature isn't base64"))?;
    let raw = STANDARD.decode(sig.trim()).map_err(|_| anyhow!("the release manifest's signature isn't base64"))?;
    let sig = Signature::from_slice(&raw).map_err(|_| anyhow!("the release manifest's signature isn't 64 bytes"))?;
    key.verify_strict(manifest, &sig).map_err(|_| anyhow!("the release manifest's signature doesn't match the release key; not updating"))
}

/// The release manifest, `maple-runner/latest.json`. Only ever parsed after its signature checks out.
#[derive(Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub version: Version,
    /// release-runner.mjs writes `published_at`; `publishedAt` is what this struct's casing says.
    #[serde(default, alias = "published_at")]
    pub published_at: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
    pub targets: BTreeMap<String, Asset>,
}

/// One target's binary.
#[derive(Deserialize, Debug, Clone, PartialEq)]
pub struct Asset {
    /// Relative to the releases URL.
    pub path: String,
    /// Lowercase or uppercase hex.
    pub sha256: String,
    pub size: u64,
}

impl Manifest {
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        serde_json::from_slice(bytes).context("the release manifest isn't valid")
    }

    /// The binary for `target`, checked enough to be safe to download.
    pub fn asset(&self, target: &str) -> Result<Option<&Asset>> {
        let Some(asset) = self.targets.get(target) else { return Ok(None) };
        let path = &asset.path;
        if path.is_empty() || path.starts_with('/') || path.contains("..") || path.contains("://") || path.contains('\\') {
            bail!("the release manifest's path for {target} (`{path}`) isn't a relative path");
        }
        if asset.sha256.len() != 64 || !asset.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            bail!("the release manifest's sha256 for {target} isn't 64 hex digits");
        }
        if asset.size == 0 {
            bail!("the release manifest's size for {target} is 0");
        }
        Ok(Some(asset))
    }
}

/// Whether to move from `current` to `latest`: only forward, unless forced.
pub fn should_update(current: &Version, latest: &Version, force: bool) -> bool {
    force || latest > current
}

/// This build's version, parsed.
pub fn current_version() -> Version {
    Version::parse(VERSION).expect("CARGO_PKG_VERSION is semver")
}

/// Talks to the releases URL.
pub struct Releases {
    base: String,
    http: reqwest::Client,
    key: VerifyingKey,
}

impl Releases {
    pub fn new(base: String) -> Result<Self> {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            // Downloads are tens of MB; bound reads, not the whole transfer.
            .read_timeout(Duration::from_secs(60))
            .user_agent(concat!("maple-runner/", env!("CARGO_PKG_VERSION")))
            .build()?;
        Ok(Self { base, http, key: release_key()? })
    }

    pub fn base(&self) -> &str {
        &self.base
    }

    /// The latest release's manifest, once its signature checks out.
    pub async fn latest(&self) -> Result<Manifest> {
        let manifest = self.fetch(MANIFEST).await?;
        let sig = self.fetch(&format!("{MANIFEST}.sig")).await?;
        verify(&self.key, &manifest, &sig)?;
        Manifest::parse(&manifest)
    }

    async fn fetch(&self, path: &str) -> Result<Vec<u8>> {
        let url = format!("{}{path}", self.base);
        let mut res = self.http.get(&url).send().await.with_context(|| format!("could not reach {url}"))?;
        if !res.status().is_success() {
            bail!("{url} answered {}", res.status());
        }
        let mut body = Vec::new();
        while let Some(chunk) = res.chunk().await.with_context(|| format!("reading {url}"))? {
            body.extend_from_slice(&chunk);
            if body.len() > MAX_MANIFEST_BYTES {
                bail!("{url} is too big to be a release manifest");
            }
        }
        Ok(body)
    }

    /// Downloads `asset`, checks it, and renames it over `exe`. On any failure `exe` is
    /// left alone and the temporary file removed.
    pub async fn install(&self, manifest: &Manifest, asset: &Asset, exe: &Path) -> Result<()> {
        let dir = exe.parent().context("the runner binary has no directory")?;
        // Same directory, so the rename is atomic (one filesystem).
        let tmp = dir.join(format!(".maple-runner.update-{}", std::process::id()));
        let _ = std::fs::remove_file(&tmp);
        let result = async {
            self.download(asset, &tmp).await?;
            check_version(&tmp, &manifest.version).await?;
            std::fs::rename(&tmp, exe).with_context(|| format!("replacing {}", exe.display()))
        }
        .await;
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        result
    }

    /// Streams the binary into `dest` (mode 0755), checking its size as it goes and its
    /// sha256 at the end.
    async fn download(&self, asset: &Asset, dest: &Path) -> Result<()> {
        let url = format!("{}{}", self.base, asset.path);
        let mut res = self.http.get(&url).send().await.with_context(|| format!("could not reach {url}"))?;
        if !res.status().is_success() {
            bail!("{url} answered {}", res.status());
        }
        let mut file =
            std::fs::OpenOptions::new().write(true).create_new(true).mode(0o755).open(dest).with_context(|| format!("writing {}", dest.display()))?;
        let mut hash = Sha256::new();
        let mut len: u64 = 0;
        while let Some(chunk) = res.chunk().await.with_context(|| format!("downloading {url}"))? {
            len += chunk.len() as u64;
            if len > asset.size {
                bail!("the download is bigger than the manifest's {} bytes", asset.size);
            }
            hash.update(&chunk);
            file.write_all(&chunk).with_context(|| format!("writing {}", dest.display()))?;
        }
        if len != asset.size {
            bail!("the download is {len} bytes, not the manifest's {}; it may have been cut short", asset.size);
        }
        let got = hex(&hash.finalize());
        if !got.eq_ignore_ascii_case(&asset.sha256) {
            bail!("the download's sha256 is {got}, not the manifest's {}", asset.sha256);
        }
        file.sync_all()?;
        Ok(())
    }
}

/// Runs `<exe> --version` and checks it reports `version`. Catches a binary for the wrong
/// architecture or one that won't start, before it replaces a working one.
async fn check_version(exe: &Path, version: &Version) -> Result<()> {
    let run = tokio::process::Command::new(exe).arg("--version").kill_on_drop(true).output();
    let out = tokio::time::timeout(Duration::from_secs(30), run)
        .await
        .map_err(|_| anyhow!("the new binary didn't answer `--version`"))?
        .context("the new binary won't run")?;
    let said = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let want = format!("maple-runner {version}");
    if !out.status.success() || said != want {
        bail!("the new binary says `{said}` to `--version`, not `{want}`");
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The running binary, resolved to the file itself (that's what gets replaced).
pub fn current_exe() -> Result<PathBuf> {
    std::env::current_exe().and_then(|p| p.canonicalize()).context("finding the runner binary")
}

/// What checking for an update found.
pub enum Check {
    /// Already on the latest version (or newer).
    UpToDate(Manifest),
    /// The release has no build for this machine.
    NoBuild(Manifest, &'static str),
    /// There's a newer version (or, forced, any version) to install.
    Available(Manifest, Asset),
}

impl Releases {
    pub async fn check(&self, force: bool) -> Result<Check> {
        let manifest = self.latest().await?;
        let target = target().ok_or_else(|| anyhow!("there are no runner builds for {} on {}", std::env::consts::ARCH, std::env::consts::OS))?;
        if !should_update(&current_version(), &manifest.version, force) {
            return Ok(Check::UpToDate(manifest));
        }
        match manifest.asset(target)?.cloned() {
            Some(asset) => Ok(Check::Available(manifest, asset)),
            None => Ok(Check::NoBuild(manifest, target)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn key() -> SigningKey {
        SigningKey::from_bytes(&[7; 32])
    }

    #[test]
    fn targets() {
        assert_eq!(target_for("macos", "aarch64"), Some("aarch64-apple-darwin"));
        assert_eq!(target_for("macos", "x86_64"), Some("x86_64-apple-darwin"));
        assert_eq!(target_for("linux", "x86_64"), Some("x86_64-unknown-linux-gnu"));
        assert_eq!(target_for("linux", "aarch64"), Some("aarch64-unknown-linux-gnu"));
        assert_eq!(target_for("windows", "x86_64"), None);
        assert_eq!(target_for("linux", "riscv64"), None);
        if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            assert_eq!(target(), Some("aarch64-apple-darwin"));
        }
    }

    #[test]
    fn release_key_is_valid() {
        decode_key(RELEASE_PUBLIC_KEY).unwrap();
        assert!(decode_key("short").is_err());
        assert!(decode_key("not base64!").is_err());
    }

    #[test]
    fn signatures() {
        let signer = key();
        let public = URL_SAFE_NO_PAD.encode(signer.verifying_key().as_bytes());
        let verifier = decode_key(&public).unwrap();
        let manifest = br#"{"version":"0.2.0","targets":{}}"#;
        let sig = STANDARD.encode(signer.sign(manifest).to_bytes());

        verify(&verifier, manifest, sig.as_bytes()).unwrap();
        // A trailing newline from `base64` or `echo` is fine.
        verify(&verifier, manifest, format!("{sig}\n").as_bytes()).unwrap();

        // Any change to the manifest, or another key, or a mangled signature, is rejected.
        let e = verify(&verifier, br#"{"version":"9.9.9","targets":{}}"#, sig.as_bytes()).unwrap_err();
        assert!(e.to_string().contains("doesn't match"), "{e}");
        let other = SigningKey::from_bytes(&[8; 32]).verifying_key();
        assert!(verify(&other, manifest, sig.as_bytes()).is_err());
        assert!(verify(&decode_key(RELEASE_PUBLIC_KEY).unwrap(), manifest, sig.as_bytes()).is_err());
        assert!(verify(&verifier, manifest, b"").is_err());
        assert!(verify(&verifier, manifest, b"%%%").is_err());
        assert!(verify(&verifier, manifest, STANDARD.encode([0u8; 63]).as_bytes()).is_err());
    }

    #[test]
    fn manifests() {
        let m = Manifest::parse(
            br#"{
                "version": "0.2.0",
                "publishedAt": "2026-10-12T10:00:00Z",
                "notes": "Self-update",
                "targets": {
                    "aarch64-apple-darwin": { "path": "maple-runner/0.2.0/maple-runner-aarch64-apple-darwin", "sha256": "ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "size": 12345678 },
                    "x86_64-unknown-linux-gnu": { "path": "../etc/passwd", "sha256": "00", "size": 1 }
                }
            }"#,
        )
        .unwrap();
        assert_eq!(m.version, Version::new(0, 2, 0));
        assert_eq!(m.published_at.as_deref(), Some("2026-10-12T10:00:00Z"));
        assert_eq!(m.notes.as_deref(), Some("Self-update"));
        let a = m.asset("aarch64-apple-darwin").unwrap().unwrap();
        assert_eq!((a.path.as_str(), a.size), ("maple-runner/0.2.0/maple-runner-aarch64-apple-darwin", 12345678));
        assert!(m.asset("x86_64-apple-darwin").unwrap().is_none());
        assert!(m.asset("x86_64-unknown-linux-gnu").is_err());

        // Optional fields may be missing; a version must be semver.
        let m = Manifest::parse(br#"{"version":"1.0.0-beta.1","targets":{}}"#).unwrap();
        assert_eq!((m.notes, m.published_at), (None, None));
        assert!(Manifest::parse(br#"{"version":"1.0","targets":{}}"#).is_err());
        assert!(Manifest::parse(br#"{"version":"1.0.0"}"#).is_err());
        assert!(Manifest::parse(b"not json").is_err());
    }

    #[test]
    fn manifests_as_the_release_script_writes_them() {
        let m = Manifest::parse(br#"{"version":"0.38.0","published_at":"2026-10-29T22:56:07.917Z","notes":"Runner updates show their progress.","targets":{}}"#).unwrap();
        assert_eq!(m.published_at.as_deref(), Some("2026-10-29T22:56:07.917Z"));
        assert_eq!(m.notes.as_deref(), Some("Runner updates show their progress."));
    }

    #[test]
    fn versions() {
        let v = |s| Version::parse(s).unwrap();
        assert!(should_update(&v("0.1.0"), &v("0.2.0"), false));
        assert!(should_update(&v("0.1.9"), &v("0.1.10"), false));
        assert!(should_update(&v("0.2.0-rc.1"), &v("0.2.0"), false));
        assert!(!should_update(&v("0.2.0"), &v("0.2.0"), false));
        assert!(!should_update(&v("0.2.0"), &v("0.1.0"), false));
        assert!(!should_update(&v("0.2.0"), &v("0.2.0-rc.1"), false));
        // --force reinstalls or goes back.
        assert!(should_update(&v("0.2.0"), &v("0.2.0"), true));
        assert!(should_update(&v("0.2.0"), &v("0.1.0"), true));
        current_version();
    }

    #[test]
    fn releases_urls() {
        assert_eq!(releases_url(None, Some("https://factory.acme.dev")).unwrap(), "https://factory.acme.dev/releases/");
        assert_eq!(releases_url(None, Some("http://localhost:8787/")).unwrap(), "http://localhost:8787/releases/");
        assert_eq!(releases_url(None, Some("ws://box:8787/runner/connect")).unwrap(), "http://box:8787/releases/");
        assert_eq!(releases_url(None, Some("wss://x.dev/runner/connect")).unwrap(), "https://x.dev/releases/");
        assert_eq!(releases_url(Some("http://127.0.0.1:18800/releases"), Some("https://x.dev")).unwrap(), "http://127.0.0.1:18800/releases/");
        assert_eq!(releases_url(Some(" "), Some("https://x.dev")).unwrap(), "https://x.dev/releases/");
        assert!(releases_url(Some("file:///tmp"), None).is_err());
        assert!(releases_url(None, None).is_err());
    }

    #[test]
    fn dev_builds() {
        assert!(is_dev_build(Path::new("/Users/a/maple-factory/runner/target/debug/maple-runner")));
        assert!(is_dev_build(Path::new("/tmp/x/target/release/maple-runner")));
        assert!(!is_dev_build(Path::new("/Users/a/.local/share/maple/bin/maple-runner")));
        assert!(!is_dev_build(Path::new("/Users/a/targets/maple-runner")));
    }
}
