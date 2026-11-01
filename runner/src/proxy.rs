//! Public share links: HTTP requests the hub relays from `<slug>.share.<app host>`, made here to
//! `127.0.0.1:<port>` and streamed back.
//!
//! hub → runner `http.request` (+ `http.request.body` for a body over one chunk), runner → hub
//! `http.response` then `http.response.body` chunks (the last has `end`), or `http.error`. Bodies are
//! base64 in chunks of at most [`CHUNK`] bytes so every WebSocket message stays under ~512 KB.
//! The runner sends at most [`WINDOW`] bytes ahead of what the hub has acknowledged (`http.ack`,
//! sent once the visitor's browser has taken a chunk), so a slow visitor slows the download
//! instead of filling memory. `http.cancel` stops a request.
//!
//! Only ports this runner currently sees listening on localhost or every interface are reachable
//! (`ports::proxy_host`), never the control plane this runner itself talks to. Redirects aren't
//! followed: they go back to the visitor, with `Location`s pointing at `localhost:<port>` (or the
//! link's local domain and its subdomains) rewritten to the share host. The app sees an ordinary
//! local request: `Host: localhost:<port>`, or whatever the hub asks for (`acme.lvh.me:3000` for
//! `<slug>--acme.share…` on a link whose local domain is `lvh.me`). The connection always goes to
//! this machine; the host is only a header, never looked up.

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex, OnceLock};
use std::time::Duration;

use base64::Engine;
use serde::Deserialize;
use tokio::sync::{Semaphore, mpsc};
use tokio::task::AbortHandle;

use crate::protocol::Outbound;
use crate::sessions::Sessions;

/// Raw body bytes per message (base64 makes that ~342 KB).
pub const CHUNK: usize = 256 * 1024;
/// Request bodies over this are refused (the Worker refuses them first).
const MAX_BODY: usize = 10 * 1024 * 1024;
/// How far the response may run ahead of the visitor.
const WINDOW: usize = 4 * 1024 * 1024;
/// The app has this long to start answering.
const FIRST_BYTE: Duration = Duration::from_secs(30);

/// Headers that belong to one connection, not the request (RFC 9110 §7.6.1), plus `Connection`'s own list.
const HOP_BY_HOP: &[&str] =
    &["connection", "keep-alive", "proxy-connection", "proxy-authenticate", "proxy-authorization", "te", "trailer", "trailers", "transfer-encoding", "upgrade"];
/// Set on every proxied request (to the share link's origin) and never taken from the visitor. A
/// local `wrangler dev` of this app refuses its no-sign-in localhost mode for requests carrying
/// it, so sharing such a port doesn't hand out its API.
const SHARE_HEADER: &str = "x-maple-share-link";
/// The control plane's own cookies; never passed to a shared app (the Worker strips them too).
/// `CF_Authorization` is Cloudflare Access's, when Access guards the share hosts (DEPLOY.md).
const PRIVATE_COOKIES: &[&str] =
    &["maple_session", "__Host-maple_session", "maple_oauth", "__Host-maple_oauth", "maple_share", "__Host-maple_share", "CF_Authorization"];

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Head {
    pub req_id: String,
    pub port: u16,
    pub method: String,
    /// Path and query, starting with `/`.
    pub path: String,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    /// The share host's origin, e.g. `https://k3x9….share.factory.acme.dev` (or
    /// `https://k3x9…--acme.share…` for a subdomain).
    pub origin: String,
    /// The `Host` the app should see, e.g. `acme.lvh.me:3000`. `localhost:<port>` when absent.
    #[serde(default)]
    pub host: Option<String>,
    /// The link's local domain (`lvh.me`), for rewriting redirects to its subdomains. `localhost`
    /// when absent.
    #[serde(default)]
    pub local_domain: Option<String>,
    /// The link's origin without subdomain labels (`https://k3x9….share.factory.acme.dev`).
    /// `origin` when absent.
    #[serde(default)]
    pub base: Option<String>,
    /// The first chunk of the body, base64.
    #[serde(default)]
    pub body: Option<String>,
    /// No more body follows.
    #[serde(default = "yes")]
    pub end: bool,
}

fn yes() -> bool {
    true
}

struct Entry {
    head: Option<Head>,
    body: Vec<u8>,
    window: Arc<Semaphore>,
    task: Option<AbortHandle>,
}

static REQUESTS: LazyLock<Mutex<HashMap<String, Entry>>> = LazyLock::new(Default::default);
/// The control plane's port when it runs on this machine (`wrangler dev`): never reachable through a share.
static CONTROL_PORT: OnceLock<Option<u16>> = OnceLock::new();

static CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    crate::http_client()
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .connect_timeout(Duration::from_secs(5))
        .build()
        .expect("building the HTTP client")
});

/// Remembers which local port is the control plane, so a share can't point back at it.
pub fn set_control_url(url: &str) {
    let port = reqwest::Url::parse(url).ok().and_then(|u| {
        let local = matches!(u.host_str(), Some("localhost" | "127.0.0.1" | "[::1]" | "::1"));
        local.then(|| u.port_or_known_default()).flatten()
    });
    let _ = CONTROL_PORT.set(port);
}

/// Forgets every request: after a reconnect the hub has forgotten them too.
pub fn reset() {
    for (_, e) in REQUESTS.lock().unwrap().drain() {
        if let Some(task) = e.task {
            task.abort();
        }
    }
}

pub fn request(sessions: &Sessions, mut head: Head) {
    let id = head.req_id.clone();
    let body = match head.body.take().map(|b| base64::engine::general_purpose::STANDARD.decode(b)) {
        None => Vec::new(),
        Some(Ok(b)) if b.len() <= MAX_BODY => b,
        Some(Ok(_)) => return fail(sessions, id, 413, "The request body is over 10 MB."),
        Some(Err(_)) => return fail(sessions, id, 400, "The request body wasn't base64."),
    };
    let end = head.end;
    let entry = Entry { head: Some(head), body, window: Arc::new(Semaphore::new(WINDOW)), task: None };
    REQUESTS.lock().unwrap().insert(id.clone(), entry);
    if end {
        start(sessions, &id);
    }
}

pub fn request_body(sessions: &Sessions, req_id: String, data: &str, end: bool) {
    let problem = {
        let mut requests = REQUESTS.lock().unwrap();
        let Some(entry) = requests.get_mut(&req_id) else { return };
        match base64::engine::general_purpose::STANDARD.decode(data) {
            Ok(b) if entry.body.len() + b.len() <= MAX_BODY => {
                entry.body.extend_from_slice(&b);
                None
            }
            Ok(_) => Some((413, "The request body is over 10 MB.")),
            Err(_) => Some((400, "The request body wasn't base64.")),
        }
    };
    match problem {
        Some((status, message)) => {
            REQUESTS.lock().unwrap().remove(&req_id);
            fail(sessions, req_id, status, message);
        }
        None if end => start(sessions, &req_id),
        None => {}
    }
}

pub fn ack(req_id: &str, bytes: u32) {
    if let Some(e) = REQUESTS.lock().unwrap().get(req_id) {
        e.window.add_permits((bytes as usize).min(WINDOW));
    }
}

pub fn cancel(req_id: &str) {
    if let Some(task) = REQUESTS.lock().unwrap().remove(req_id).and_then(|e| e.task) {
        task.abort();
    }
}

fn fail(sessions: &Sessions, req_id: String, status: u16, message: &str) {
    sessions.emit(Outbound::HttpError { req_id, status, message: message.into() });
}

fn start(sessions: &Sessions, id: &str) {
    let (head, body, window) = {
        let mut requests = REQUESTS.lock().unwrap();
        let Some(entry) = requests.get_mut(id) else { return };
        let Some(head) = entry.head.take() else { return };
        (head, std::mem::take(&mut entry.body), entry.window.clone())
    };
    let sessions = sessions.clone();
    let req_id = id.to_string();
    let task = tokio::spawn(async move {
        if let Err((status, message)) = run(&sessions, head, body, window).await {
            sessions.emit(Outbound::HttpError { req_id: req_id.clone(), status, message });
        }
        REQUESTS.lock().unwrap().remove(&req_id);
    });
    if let Some(entry) = REQUESTS.lock().unwrap().get_mut(id) {
        entry.task = Some(task.abort_handle());
    }
}

/// Aborts the body reader when the request ends or is cancelled.
struct AbortOnDrop(AbortHandle);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Where a share link's request goes and how the app should see it.
#[derive(Debug, Clone, PartialEq)]
pub struct Target {
    pub port: u16,
    /// The `Host` header for the app: `localhost:3000`, `admin.acme.lvh.me:3000`.
    pub host: String,
    /// `localhost`, `lvh.me`, `myapp.test`: lowercase.
    pub local_domain: String,
    /// The visitor's origin (the share host they opened).
    pub origin: String,
    /// The link's origin with no subdomain labels.
    pub base: String,
}

impl Target {
    /// From a request head, checking the host and local domain the hub sent (they're only ever
    /// headers, but they must look like a hostname, so nothing else can be smuggled in).
    pub fn new(port: u16, origin: &str, host: Option<&str>, local_domain: Option<&str>, base: Option<&str>) -> Result<Self, String> {
        let local_domain = local_domain.unwrap_or("localhost").to_ascii_lowercase();
        if !valid_hostname(&local_domain) {
            return Err("Bad local domain.".into());
        }
        let host = match host {
            Some(h) if valid_host(h) => h.to_ascii_lowercase(),
            Some(_) => return Err("Bad host.".into()),
            None => format!("localhost:{port}"),
        };
        Ok(Target { port, host, local_domain, origin: origin.into(), base: base.unwrap_or(origin).into() })
    }
}

/// `localhost`, `lvh.me`, `a-b.myapp.test`: letters, digits and inner hyphens, labels of 1 to 63,
/// 253 in all.
pub fn valid_hostname(name: &str) -> bool {
    !name.is_empty() && name.len() <= 253 && name.split('.').all(valid_label)
}

fn valid_label(label: &str) -> bool {
    let b = label.as_bytes();
    !b.is_empty() && b.len() <= 63 && b.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'-') && b[0] != b'-' && b[b.len() - 1] != b'-'
}

/// A hostname with an optional `:<port>`.
pub fn valid_host(host: &str) -> bool {
    match host.rsplit_once(':') {
        Some((name, port)) => valid_hostname(name) && valid_port(port).is_some(),
        None => valid_hostname(host),
    }
}

fn valid_port(port: &str) -> Option<u16> {
    (!port.is_empty() && port.len() <= 5 && port.bytes().all(|c| c.is_ascii_digit())).then(|| port.parse().ok()).flatten()
}

async fn run(sessions: &Sessions, head: Head, body: Vec<u8>, window: Arc<Semaphore>) -> Result<(), (u16, String)> {
    let Head { req_id, port, method, path, headers, origin, host: app_host, local_domain, base, .. } = head;
    let target = Target::new(port, &origin, app_host.as_deref(), local_domain.as_deref(), base.as_deref()).map_err(|m| (400, m))?;
    if CONTROL_PORT.get().copied().flatten() == Some(port) {
        return Err((403, format!("Port {port} is this machine's control plane; it can't be shared.")));
    }
    let host = crate::ports::proxy_host(port).map_err(|m| (502, m))?;
    if !path.starts_with('/') {
        return Err((400, "Bad path.".into()));
    }
    let url = reqwest::Url::parse(&format!("http://{host}:{port}{path}")).map_err(|_| (400, "Bad path.".to_string()))?;
    if url.host_str() != Some(host) || url.port() != Some(port) {
        return Err((400, "Bad path.".into()));
    }
    let method = reqwest::Method::from_bytes(method.as_bytes()).map_err(|_| (405, "Bad method.".to_string()))?;
    let mut req = CLIENT.request(method, url);
    for (k, v) in request_headers(&headers, &target) {
        req = req.header(k, v);
    }
    if !body.is_empty() {
        req = req.body(body);
    }
    let mut resp = match tokio::time::timeout(FIRST_BYTE, req.send()).await {
        Err(_) => return Err((504, format!("The app on port {port} didn't answer within 30 seconds."))),
        Ok(Err(e)) if e.is_connect() => return Err((502, format!("Couldn't connect to port {port}. Is the app still running?"))),
        Ok(Err(e)) => return Err((502, format!("The request to port {port} failed: {e}"))),
        Ok(Ok(resp)) => resp,
    };
    let response = resp.headers().iter().map(|(k, v)| (k.as_str().to_string(), String::from_utf8_lossy(v.as_bytes()).into_owned()));
    let headers = response_headers(response, &target);
    sessions.emit(Outbound::HttpResponse { req_id: req_id.clone(), status: resp.status().as_u16(), headers });

    // Read the body on its own task, so what's already arrived can be sent in bigger pieces.
    let (tx, mut rx) = mpsc::channel::<Result<Vec<u8>, String>>(8);
    let reader = tokio::spawn(async move {
        loop {
            let chunk = match resp.chunk().await {
                Ok(Some(c)) => Ok(c.to_vec()),
                Ok(None) => break,
                Err(e) => Err(format!("The response from port {port} broke off: {e}")),
            };
            let failed = chunk.is_err();
            if tx.send(chunk).await.is_err() || failed {
                break;
            }
        }
    });
    let _reader = AbortOnDrop(reader.abort_handle());
    let b64 = base64::engine::general_purpose::STANDARD;
    let mut pending: Vec<u8> = Vec::new();
    let mut done = false;
    while !done {
        match rx.recv().await {
            None => done = true,
            Some(Err(e)) => return Err((502, e)),
            Some(Ok(c)) => pending.extend_from_slice(&c),
        }
        while !done && pending.len() < CHUNK {
            match rx.try_recv() {
                Ok(Ok(c)) => pending.extend_from_slice(&c),
                Ok(Err(e)) => return Err((502, e)),
                Err(mpsc::error::TryRecvError::Empty) => break,
                Err(mpsc::error::TryRecvError::Disconnected) => done = true,
            }
        }
        loop {
            let n = pending.len().min(CHUNK);
            let last = done && n == pending.len();
            if n == 0 && !last {
                break;
            }
            if n > 0 {
                window.acquire_many(n as u32).await.map_err(|_| (499, "cancelled".to_string()))?.forget();
            }
            let piece: Vec<u8> = pending.drain(..n).collect();
            sessions.emit(Outbound::HttpResponseBody { req_id: req_id.clone(), data: b64.encode(piece), end: last });
            if last || pending.is_empty() {
                break;
            }
        }
    }
    Ok(())
}

fn connection_tokens(headers: &[(String, String)]) -> Vec<String> {
    headers
        .iter()
        .filter(|(k, _)| k.eq_ignore_ascii_case("connection"))
        .flat_map(|(_, v)| v.split(',').map(|t| t.trim().to_ascii_lowercase()))
        .filter(|t| !t.is_empty())
        .collect()
}

fn hop_by_hop(name: &str, listed: &[String]) -> bool {
    HOP_BY_HOP.contains(&name) || listed.iter().any(|t| t == name)
}

/// The visitor's headers as the app should see them: an ordinary request to `target.host`
/// (`localhost:<port>` unless the link has a local domain or the visitor used a subdomain). Drops
/// hop-by-hop headers and the control plane's cookies, asks for an uncompressed body (the edge
/// compresses for the visitor), and points `Origin`/`Referer` at `http://<host>` so CSRF checks pass.
pub fn request_headers(headers: &[(String, String)], target: &Target) -> Vec<(String, String)> {
    let listed = connection_tokens(headers);
    let origin = target.origin.as_str();
    let local = format!("http://{}", target.host);
    let mut out = Vec::new();
    for (k, v) in headers {
        let name = k.to_ascii_lowercase();
        if hop_by_hop(&name, &listed) || matches!(name.as_str(), "host" | "content-length" | "accept-encoding" | SHARE_HEADER) {
            continue;
        }
        let value = match name.as_str() {
            "cookie" => {
                let kept: Vec<&str> =
                    v.split(';').map(str::trim).filter(|c| !c.is_empty() && !PRIVATE_COOKIES.contains(&c.split('=').next().unwrap_or("").trim())).collect();
                if kept.is_empty() {
                    continue;
                }
                kept.join("; ")
            }
            "origin" if v == origin => local.clone(),
            "referer" => match v.strip_prefix(origin) {
                Some(rest) if rest.is_empty() || rest.starts_with('/') => format!("{local}{rest}"),
                _ => v.clone(),
            },
            _ => v.clone(),
        };
        out.push((name, value));
    }
    out.push(("host".into(), target.host.clone()));
    out.push(("accept-encoding".into(), "identity".into()));
    out.push((SHARE_HEADER.into(), origin.into()));
    out
}

/// The app's response headers for the visitor: no hop-by-hop headers, redirects to the app's own
/// hosts sent to the share hosts instead, and cookies kept to the share host.
pub fn response_headers(headers: impl IntoIterator<Item = (String, String)>, target: &Target) -> Vec<(String, String)> {
    let headers: Vec<(String, String)> = headers.into_iter().map(|(k, v)| (k.to_ascii_lowercase(), v)).collect();
    let listed = connection_tokens(&headers);
    headers
        .into_iter()
        .filter(|(k, _)| !hop_by_hop(k, &listed))
        .map(|(k, v)| {
            let v = match k.as_str() {
                "location" | "content-location" | "refresh" => rewrite_location(&v, target),
                "set-cookie" => strip_cookie_domain(&v),
                _ => v,
            };
            (k, v)
        })
        .collect()
}

/// `http://localhost:3000/next?x` → `<base>/next?x`, and with local domain `lvh.me`,
/// `http://admin.acme.lvh.me:3000/x` → `https://<slug>--admin--acme.share…/x`. Also 127.0.0.1,
/// [::1], 0.0.0.0, the bare local domain, https and scheme-relative forms. Anything else (relative
/// paths, other hosts and ports, subdomains that wouldn't fit in one label) is left alone. For
/// `Refresh: 0; url=…` the URL part is rewritten.
pub fn rewrite_location(value: &str, target: &Target) -> String {
    if let Some(i) = value.to_ascii_lowercase().find("url=") {
        let (before, url) = value.split_at(i + 4);
        if !url.is_empty() && !value[..i].contains('/') {
            return format!("{before}{}", rewrite_location(url, target));
        }
    }
    let lower = value.to_ascii_lowercase();
    let Some(start) = ["http://", "https://", "//"].iter().find(|s| lower.starts_with(**s)).map(|s| s.len()) else {
        return value.to_string();
    };
    let rest = &value[start..];
    let (authority, tail) = rest.split_at(rest.find(['/', '?', '#']).unwrap_or(rest.len()));
    // No port means 80 or 443, never the app's; `localhost:3000.evil.com` has no numeric port.
    let Some((host, port)) = authority.rsplit_once(':') else { return value.to_string() };
    if valid_port(port) != Some(target.port) {
        return value.to_string();
    }
    let Some(share) = share_origin(&host.to_ascii_lowercase(), target) else { return value.to_string() };
    match tail.chars().next() {
        None => format!("{share}/"),
        Some('/') => format!("{share}{tail}"),
        _ => format!("{share}/{tail}"),
    }
}

/// The share origin that stands for one of the app's hosts: the base for localhost (and its IPs)
/// and the bare local domain; `<slug>--a--b` for `a.b.<local domain>`.
fn share_origin(host: &str, target: &Target) -> Option<String> {
    if matches!(host, "localhost" | "127.0.0.1" | "[::1]" | "0.0.0.0") || host == target.local_domain {
        return Some(target.base.clone());
    }
    let subs = host.strip_suffix(target.local_domain.as_str())?.strip_suffix('.')?;
    if !subs.split('.').all(|l| valid_label(l) && !l.contains("--")) {
        return None;
    }
    let joined = subs.replace('.', "--");
    // `https://<slug>.share.…`: the labels go right after the slug.
    let after_scheme = target.base.find("://")? + 3;
    let dot = after_scheme + target.base[after_scheme..].find('.')?;
    let slug = &target.base[after_scheme..dot];
    (slug.len() + 2 + joined.len() <= 63).then(|| format!("{}--{joined}{}", &target.base[..dot], &target.base[dot..]))
}

/// Drops `Domain=` from a `Set-Cookie`, so the cookie belongs to the share host alone and can't
/// reach the app host or other shares.
pub fn strip_cookie_domain(value: &str) -> String {
    value.split(';').filter(|part| !part.trim().to_ascii_lowercase().starts_with("domain")).collect::<Vec<_>>().join(";")
}

#[cfg(test)]
mod tests {
    use super::*;

    const ORIGIN: &str = "https://abcdefghij.share.factory.acme.dev";

    /// A link with no local domain, opened at its base host.
    fn local() -> Target {
        Target::new(3000, ORIGIN, None, None, None).unwrap()
    }

    /// A link with local domain `lvh.me`, opened at `<slug>--admin--acme.share…`.
    fn sub() -> Target {
        let origin = "https://abcdefghij--admin--acme.share.factory.acme.dev";
        Target::new(3000, origin, Some("admin.acme.lvh.me:3000"), Some("lvh.me"), Some(ORIGIN)).unwrap()
    }

    fn h(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn request_headers_are_a_local_request() {
        let got = request_headers(
            &h(&[
                ("Host", "abcdefghij.share.factory.acme.dev"),
                ("Connection", "keep-alive, X-Secret-Hop"),
                ("x-secret-hop", "1"),
                ("Keep-Alive", "timeout=5"),
                ("Upgrade", "websocket"),
                ("TE", "trailers"),
                ("Transfer-Encoding", "chunked"),
                ("Content-Length", "12"),
                ("Accept-Encoding", "gzip, br"),
                ("Accept", "text/html"),
                ("Cookie", "theme=dark; __Host-maple_session=abc; maple_share=1.x; maple_session=zzz; CF_Authorization=jwt; sid=42"),
                ("Origin", ORIGIN),
                ("Referer", &format!("{ORIGIN}/page?x=1")),
                ("Authorization", "Basic dTpw"),
                ("X-Maple-Share-Link", "forged"),
            ]),
            &local(),
        );
        assert_eq!(
            got,
            h(&[
                ("accept", "text/html"),
                ("cookie", "theme=dark; sid=42"),
                ("origin", "http://localhost:3000"),
                ("referer", "http://localhost:3000/page?x=1"),
                ("authorization", "Basic dTpw"),
                ("host", "localhost:3000"),
                ("accept-encoding", "identity"),
                ("x-maple-share-link", ORIGIN),
            ])
        );
    }

    #[test]
    fn only_private_cookies_means_no_cookie_header() {
        let got = request_headers(&h(&[("cookie", "__Host-maple_session=a; maple_oauth=b")]), &local());
        assert!(got.iter().all(|(k, _)| k != "cookie"), "{got:?}");
        // Someone else's origin and referer are passed as they are.
        let got = request_headers(&h(&[("origin", "https://evil.example"), ("referer", "https://abcdefghij.share.factory.acme.dev.evil/")]), &local());
        assert_eq!(&got[..2], &h(&[("origin", "https://evil.example"), ("referer", "https://abcdefghij.share.factory.acme.dev.evil/")])[..]);
    }

    #[test]
    fn response_headers_drop_hop_by_hop_and_rewrite() {
        let got = response_headers(
            h(&[
                ("Content-Type", "text/html"),
                ("Connection", "close, x-hop"),
                ("X-Hop", "1"),
                ("Transfer-Encoding", "chunked"),
                ("Keep-Alive", "timeout=5"),
                ("Location", "http://localhost:3000/login?next=%2F"),
                ("Set-Cookie", "sid=1; Path=/; Domain=factory.acme.dev; HttpOnly"),
                ("Set-Cookie", "theme=dark; Path=/"),
                ("Content-Length", "5"),
            ]),
            &local(),
        );
        assert_eq!(
            got,
            h(&[
                ("content-type", "text/html"),
                ("location", "https://abcdefghij.share.factory.acme.dev/login?next=%2F"),
                ("set-cookie", "sid=1; Path=/; HttpOnly"),
                ("set-cookie", "theme=dark; Path=/"),
                ("content-length", "5"),
            ])
        );
    }

    #[test]
    fn rewrites_locations() {
        let t = local();
        let r = |v: &str| rewrite_location(v, &t);
        assert_eq!(r("http://localhost:3000/a"), format!("{ORIGIN}/a"));
        assert_eq!(r("http://127.0.0.1:3000"), format!("{ORIGIN}/"));
        assert_eq!(r("https://[::1]:3000/x#y"), format!("{ORIGIN}/x#y"));
        assert_eq!(r("HTTP://LOCALHOST:3000/A"), format!("{ORIGIN}/A"));
        assert_eq!(r("//0.0.0.0:3000?q=1"), format!("{ORIGIN}/?q=1"));
        assert_eq!(r("0; url=http://localhost:3000/next"), format!("0; url={ORIGIN}/next"));
        // Left alone: relative, another port, another host, a lookalike.
        assert_eq!(r("/login"), "/login");
        assert_eq!(r("next"), "next");
        assert_eq!(r("http://localhost:30001/a"), "http://localhost:30001/a");
        assert_eq!(r("http://localhost:4000/a"), "http://localhost:4000/a");
        assert_eq!(r("https://github.com/login?redirect=http://localhost:3000/"), "https://github.com/login?redirect=http://localhost:3000/");
        assert_eq!(r("http://localhost:3000.evil.com/"), "http://localhost:3000.evil.com/");
        // With no local domain, localhost's subdomains are the app's too.
        assert_eq!(r("http://acme.localhost:3000/x"), "https://abcdefghij--acme.share.factory.acme.dev/x");
    }

    #[test]
    fn subdomain_requests_get_their_host() {
        let got = request_headers(
            &h(&[
                ("Origin", "https://abcdefghij--admin--acme.share.factory.acme.dev"),
                ("Referer", "https://abcdefghij--admin--acme.share.factory.acme.dev/a"),
            ]),
            &sub(),
        );
        assert_eq!(
            got,
            h(&[
                ("origin", "http://admin.acme.lvh.me:3000"),
                ("referer", "http://admin.acme.lvh.me:3000/a"),
                ("host", "admin.acme.lvh.me:3000"),
                ("accept-encoding", "identity"),
                ("x-maple-share-link", "https://abcdefghij--admin--acme.share.factory.acme.dev"),
            ])
        );
    }

    #[test]
    fn rewrites_subdomain_locations() {
        let t = sub();
        let r = |v: &str| rewrite_location(v, &t);
        let share = |labels: &str| format!("https://abcdefghij{labels}.share.factory.acme.dev");
        assert_eq!(r("http://acme.lvh.me:3000/x"), format!("{}/x", share("--acme")));
        assert_eq!(r("https://Admin.Acme.lvh.me:3000?q"), format!("{}/?q", share("--admin--acme")));
        assert_eq!(r("//a.b.c.lvh.me:3000"), format!("{}/", share("--a--b--c")));
        assert_eq!(r("http://lvh.me:3000/home"), format!("{}/home", share("")));
        assert_eq!(r("http://localhost:3000/home"), format!("{}/home", share("")));
        assert_eq!(r("0;url=http://acme.lvh.me:3000/"), format!("0;url={}/", share("--acme")));
        // Left alone: other ports, other domains, lookalikes, labels we can't encode, too long.
        for v in [
            "http://acme.lvh.me:4000/x",
            "http://acme.lvh.me/x",
            "http://acme.lvh.me.evil.com:3000/x",
            "http://acmelvh.me:3000/x",
            "http://acme.localhost:3000/x",
            "http://a--b.lvh.me:3000/x",
            "http://-a.lvh.me:3000/x",
            "http://.lvh.me:3000/x",
            "http://a..b.lvh.me:3000/x",
            "http://user@acme.lvh.me:3000/x",
        ] {
            assert_eq!(r(v), v, "{v}");
        }
        let long = format!("http://{}.lvh.me:3000/", "a".repeat(52));
        assert_eq!(r(&long), long);
        let fits = format!("http://{}.lvh.me:3000/", "a".repeat(51));
        assert_eq!(r(&fits), format!("{}/", share(&format!("--{}", "a".repeat(51)))));
    }

    #[test]
    fn checks_the_host_it_is_given() {
        assert!(Target::new(3000, ORIGIN, Some("acme.lvh.me:3000"), Some("lvh.me"), None).is_ok());
        assert!(Target::new(3000, ORIGIN, Some("myapp.test"), Some("myapp.test"), None).is_ok());
        for bad in
            ["acme.lvh.me:3000\r\nx-evil: 1", "acme lvh.me", "a/b:3000", "acme.lvh.me:", "acme.lvh.me:99999", "", "-a.lvh.me", "a_b.lvh.me", "[::1]:3000"]
        {
            assert!(Target::new(3000, ORIGIN, Some(bad), None, None).is_err(), "{bad:?}");
        }
        assert!(Target::new(3000, ORIGIN, None, Some("lvh.me:3000"), None).is_err());
        assert!(Target::new(3000, ORIGIN, None, Some("evil.com/x"), None).is_err());
        assert_eq!(local().host, "localhost:3000");
        assert_eq!(local().base, ORIGIN);
    }

    #[test]
    fn strips_cookie_domains() {
        assert_eq!(strip_cookie_domain("a=1; Domain=.afomera.dev; Path=/"), "a=1; Path=/");
        assert_eq!(strip_cookie_domain("a=1;domain=x;Secure"), "a=1;Secure");
        assert_eq!(strip_cookie_domain("a=1"), "a=1");
    }
}
