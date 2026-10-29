//! Enrollment and the runner's config file.
//!
//! `maple-runner enroll` trades a one-time code from the web UI for a long-lived runner
//! token and saves it in `~/.config/maple/runner.json`. `maple-runner run` (and the
//! installed service, which runs `maple-runner run` too) then reads its server, name and
//! token from there, so nothing secret has to live in a launchd plist or systemd unit.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};

/// What enrollment leaves behind: everything a runner needs to connect.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    /// Base URL of the control plane (`https://…`), not the WebSocket endpoint.
    pub url: String,
    pub runner_id: String,
    pub token: String,
    #[serde(default)]
    pub test: bool,
    /// Folders to look for repositories in (see `repos`). Unset: `~/Projects`, `~/code`, `~/src`, `~/dev`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo_roots: Option<Vec<String>>,
    /// Days a clone the runner made may go unused before it's removed (see `repos::sweep`). Unset: 14; 0: never.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo_clone_days: Option<u32>,
}

/// `~/.config/maple`, where the runner keeps its config, tmux.conf and hook socket.
pub fn dir() -> Result<PathBuf> {
    Ok(PathBuf::from(std::env::var("HOME").context("HOME is not set")?).join(".config/maple"))
}

pub fn path() -> Result<PathBuf> {
    Ok(dir()?.join("runner.json"))
}

impl Config {
    /// Reads the config, or `None` if this machine hasn't been enrolled.
    pub fn load(path: &Path) -> Result<Option<Self>> {
        match std::fs::read(path) {
            Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes).with_context(|| format!("reading {}", path.display()))?)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
        }
    }

    /// Writes the config readable only by this user (it holds the token). The file is
    /// written next to the old one and renamed over it, so a crash never leaves half a token.
    pub fn save(&self, path: &Path) -> Result<()> {
        use std::os::unix::fs::OpenOptionsExt;
        let dir = path.parent().ok_or_else(|| anyhow!("bad config path {}", path.display()))?;
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        let tmp = path.with_extension("json.tmp");
        let _ = std::fs::remove_file(&tmp);
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp).with_context(|| format!("writing {}", tmp.display()))?;
        file.write_all(&serde_json::to_vec_pretty(self)?)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        std::fs::rename(&tmp, path).with_context(|| format!("writing {}", path.display()))?;
        Ok(())
    }
}

/// The token as safe to print: its first few characters only.
pub fn redact(token: &str) -> String {
    let head: String = token.chars().take(4).collect();
    format!("{head}…")
}

/// Turns a control plane URL into its runner WebSocket endpoint. Accepts the base URL
/// saved at enrollment (`https://host` → `wss://host/runner/connect`) as well as a full
/// `ws://`/`wss://` endpoint, which is used as is.
pub fn ws_endpoint(url: &str) -> Result<String> {
    let url = url.trim();
    if url.starts_with("ws://") || url.starts_with("wss://") {
        return Ok(url.to_string());
    }
    let (scheme, rest) = if let Some(rest) = url.strip_prefix("https://") {
        ("wss", rest)
    } else if let Some(rest) = url.strip_prefix("http://") {
        ("ws", rest)
    } else {
        bail!("`{url}` is not an http(s):// or ws(s):// URL");
    };
    let rest = rest.trim_end_matches('/');
    if rest.is_empty() {
        bail!("`{url}` has no host");
    }
    Ok(format!("{scheme}://{rest}/runner/connect"))
}

/// The base http(s) URL for a control plane URL, so `--url` can be given either way.
pub fn base_url(url: &str) -> Result<String> {
    let url = url.trim().trim_end_matches('/');
    let url = if let Some(rest) = url.strip_prefix("wss://") {
        format!("https://{rest}")
    } else if let Some(rest) = url.strip_prefix("ws://") {
        format!("http://{rest}")
    } else if url.starts_with("https://") || url.starts_with("http://") {
        url.to_string()
    } else {
        bail!("`{url}` is not an http(s):// URL");
    };
    let url = url.strip_suffix("/runner/connect").unwrap_or(&url).to_string();
    if url.ends_with("://") {
        bail!("`{url}` has no host");
    }
    Ok(url)
}

/// Whether `id` is a valid runner name: `^[a-z0-9][a-z0-9-]{0,62}$`, same as the server.
pub fn valid_runner_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 63
        && (bytes[0].is_ascii_lowercase() || bytes[0].is_ascii_digit())
        && bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

/// Makes a runner name out of a hostname: the short name (before the first dot, so
/// `.local` and tailnet suffixes go), lowercased, anything else replaced with `-`.
pub fn normalize_runner_id(host: &str) -> String {
    let short = host.trim().split('.').next().unwrap_or("");
    let mapped: String = short.chars().map(|c| c.to_ascii_lowercase()).map(|c| if c.is_ascii_lowercase() || c.is_ascii_digit() { c } else { '-' }).collect();
    let mut id: String = mapped.trim_start_matches('-').chars().take(63).collect();
    while id.ends_with('-') {
        id.pop();
    }
    if id.is_empty() { "runner".into() } else { id }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EnrollRequest<'a> {
    code: &'a str,
    runner_id: &'a str,
    hostname: &'a str,
    os: &'a str,
    arch: &'a str,
    version: &'a str,
    test: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EnrollResponse {
    runner_id: String,
    token: String,
}

/// Redeems a one-time enrollment code. The server explains failures (expired code,
/// name taken) in a plain-text body, which is passed on to the user as the error.
pub async fn enroll(url: &str, code: &str, runner_id: &str, hostname: &str, test: bool) -> Result<Config> {
    let base = base_url(url)?;
    let endpoint = format!("{base}/runner/enroll");
    let client = reqwest::Client::builder().timeout(Duration::from_secs(30)).user_agent(concat!("maple-runner/", env!("CARGO_PKG_VERSION"))).build()?;
    let body = EnrollRequest { code, runner_id, hostname, os: std::env::consts::OS, arch: std::env::consts::ARCH, version: env!("CARGO_PKG_VERSION"), test };
    let res = client.post(&endpoint).json(&body).send().await.with_context(|| format!("could not reach {endpoint}"))?;
    let status = res.status();
    if !status.is_success() {
        let text = res.text().await.unwrap_or_default();
        let text = text.trim();
        if text.is_empty() {
            bail!("enrollment failed: the server answered {status}");
        }
        bail!("enrollment failed ({}): {text}", status.as_u16());
    }
    let res: EnrollResponse = res.json().await.context("the server's enrollment response was not understood")?;
    if res.token.is_empty() || !valid_runner_id(&res.runner_id) {
        bail!("the server's enrollment response was not understood");
    }
    Ok(Config { url: base, runner_id: res.runner_id, token: res.token, test, repo_roots: None, repo_clone_days: None })
}

/// Tidies up a code as typed: `abcd efgh` or `abcdefgh` → `ABCD-EFGH`.
pub fn normalize_code(code: &str) -> String {
    let chars: String = code.chars().filter(|c| c.is_ascii_alphanumeric()).map(|c| c.to_ascii_uppercase()).collect();
    if chars.len() == 8 { format!("{}-{}", &chars[..4], &chars[4..]) } else { code.trim().to_ascii_uppercase() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runner_ids_from_hostnames() {
        assert_eq!(normalize_runner_id("Andreas-MacBook-Pro.local"), "andreas-macbook-pro");
        assert_eq!(normalize_runner_id("mbp-14"), "mbp-14");
        assert_eq!(normalize_runner_id("mbp-16.tail1234.ts.net"), "mbp-16");
        assert_eq!(normalize_runner_id("Andrea’s MacBook_Air"), "andrea-s-macbook-air");
        assert_eq!(normalize_runner_id("--box--"), "box");
        assert_eq!(normalize_runner_id(""), "runner");
        assert_eq!(normalize_runner_id("..."), "runner");
        let long = normalize_runner_id(&"a".repeat(100));
        assert_eq!(long.len(), 63);
        for id in ["Andreas-MacBook-Pro.local", "x_y z", &"a-".repeat(40)] {
            assert!(valid_runner_id(&normalize_runner_id(id)), "{id}");
        }
    }

    #[test]
    fn validates_runner_ids() {
        assert!(valid_runner_id("mbp-14"));
        assert!(valid_runner_id("0"));
        assert!(!valid_runner_id(""));
        assert!(!valid_runner_id("-mbp"));
        assert!(!valid_runner_id("MBP"));
        assert!(!valid_runner_id("mbp.local"));
        assert!(valid_runner_id(&"a".repeat(63)));
        assert!(!valid_runner_id(&"a".repeat(64)));
    }

    #[test]
    fn websocket_endpoints() {
        assert_eq!(ws_endpoint("https://factory.acme.dev").unwrap(), "wss://factory.acme.dev/runner/connect");
        assert_eq!(ws_endpoint("https://factory.acme.dev/").unwrap(), "wss://factory.acme.dev/runner/connect");
        assert_eq!(ws_endpoint("http://localhost:8787").unwrap(), "ws://localhost:8787/runner/connect");
        assert_eq!(ws_endpoint("ws://localhost:8787/runner/connect").unwrap(), "ws://localhost:8787/runner/connect");
        assert_eq!(ws_endpoint("wss://x.dev/runner/connect").unwrap(), "wss://x.dev/runner/connect");
        assert!(ws_endpoint("factory.acme.dev").is_err());
        assert!(ws_endpoint("https://").is_err());
    }

    #[test]
    fn base_urls() {
        assert_eq!(base_url("https://factory.acme.dev/").unwrap(), "https://factory.acme.dev");
        assert_eq!(base_url("http://localhost:8787").unwrap(), "http://localhost:8787");
        assert_eq!(base_url("ws://localhost:8787/runner/connect").unwrap(), "http://localhost:8787");
        assert_eq!(base_url("wss://x.dev/runner/connect").unwrap(), "https://x.dev");
        assert!(base_url("x.dev").is_err());
    }

    #[test]
    fn codes() {
        assert_eq!(normalize_code(" abcd-efgh "), "ABCD-EFGH");
        assert_eq!(normalize_code("abcdefgh"), "ABCD-EFGH");
        assert_eq!(normalize_code("abcd efgh"), "ABCD-EFGH");
        assert_eq!(normalize_code("abc"), "ABC");
    }

    #[test]
    fn config_round_trip() {
        let dir = std::env::temp_dir().join(format!("maple-config-test-{}", uuid::Uuid::new_v4()));
        let path = dir.join("nested/runner.json");
        assert_eq!(Config::load(&path).unwrap(), None);
        let config = Config {
            url: "https://factory.acme.dev".into(),
            runner_id: "mbp-14".into(),
            token: "secret".into(),
            test: false,
            repo_roots: None,
            repo_clone_days: None,
        };
        config.save(&path).unwrap();
        assert_eq!(Config::load(&path).unwrap(), Some(config.clone()));
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("\"runnerId\": \"mbp-14\""), "{text}");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);

        // Re-enrolling replaces the file.
        assert!(!text.contains("repoRoots"), "{text}");
        let again = Config { token: "newer".into(), test: true, repo_roots: Some(vec!["~/work".into()]), ..config };
        again.save(&path).unwrap();
        assert_eq!(Config::load(&path).unwrap(), Some(again));
        assert!(!path.with_extension("json.tmp").exists());

        // Older files without `test` still load.
        std::fs::write(&path, r#"{"url":"http://localhost:8787","runnerId":"a","token":"t"}"#).unwrap();
        assert!(!Config::load(&path).unwrap().unwrap().test);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn redacts_tokens() {
        assert_eq!(redact("abcdefgh"), "abcd…");
        assert_eq!(redact("ab"), "ab…");
    }
}
