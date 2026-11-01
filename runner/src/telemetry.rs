//! Error reports to Maple Factory's Sentry project: panics and `error!` logs, with the runner's version
//! and its factory's org. Release builds carry the DSN (release-runner.mjs sets MAPLE_SENTRY_DSN from
//! server/web/sentry.json); dev builds have none and send nothing. MAPLE_TELEMETRY=off turns it off.
//! Nothing else goes: no info/warn logs, no hostname, and paths under $HOME read `~`.

use sentry::integrations::tracing::ErrorLayer;
use sentry::protocol::Event;
use tracing_subscriber::Layer;
use tracing_subscriber::filter::LevelFilter;

/// The DSN this build reports to, if it reports at all.
fn dsn() -> Option<&'static str> {
    let off = std::env::var("MAPLE_TELEMETRY").is_ok_and(|v| v.eq_ignore_ascii_case("off"));
    option_env!("MAPLE_SENTRY_DSN").filter(|d| !d.is_empty() && !off)
}

/// Starts reporting; keep the guard for as long as the process runs, so it sends what's queued at exit.
pub fn init() -> Option<sentry::ClientInitGuard> {
    let dsn = dsn()?;
    let home = std::env::var("HOME").ok().filter(|h| h.len() > 1);
    let host = hostname::get().ok().map(|h| h.to_string_lossy().into_owned()).filter(|h| !h.is_empty());
    Some(sentry::init(
        sentry::ClientOptions::new()
            .dsn(dsn)
            .release(format!("maple-runner@{}", crate::update::VERSION))
            .environment("production")
            .send_default_pii(false)
            .before_send(move |event| scrub(event, home.as_deref(), host.as_deref())),
    ))
}

/// The tracing layer: `error!` becomes an event; nothing else is sent, not even as a breadcrumb.
pub fn layer<S>() -> impl tracing_subscriber::Layer<S>
where
    S: tracing::Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    ErrorLayer::new().with_filter(LevelFilter::ERROR)
}

/// Tags events with the factory's org, which its /healthz says (the runner's config only has the URL).
pub fn tag_org(url: &str) {
    if dsn().is_some() {
        tokio::spawn(org(url.to_owned()));
    }
}

/// tag_org, waited for.
pub async fn org(url: String) {
    let Some(healthz) = healthz_url(&url) else { return };
    let org = async { crate::http_client().build().ok()?.get(&healthz).send().await.ok()?.json::<serde_json::Value>().await.ok()?.get("org")?.as_str().map(str::to_owned) };
    if let Some(org) = org.await {
        sentry::configure_scope(|scope| scope.set_tag("org", org));
    }
}

/// `maple-runner sentry-test`: one test error, tagged with the factory's org when there is one.
pub async fn test(url: Option<String>) -> anyhow::Result<()> {
    if dsn().is_none() {
        println!("This build doesn't report errors (no MAPLE_SENTRY_DSN at build time, or MAPLE_TELEMETRY=off).");
    }
    let url = url.or_else(|| crate::config::path().ok().and_then(|p| crate::config::Config::load(&p).ok().flatten()).map(|c| c.url));
    if let Some(url) = url {
        org(url).await;
    }
    tracing::error!("maple-runner: Sentry test error");
    Ok(())
}

/// wss://factory.example/runner/connect (or https://factory.example) → https://factory.example/healthz
fn healthz_url(ws_url: &str) -> Option<String> {
    let mut url = reqwest::Url::parse(ws_url).ok()?;
    let scheme = match url.scheme() {
        "wss" => "https",
        "ws" => "http",
        other => other,
    }
    .to_owned();
    url.set_scheme(&scheme).ok()?;
    url.set_path("/healthz");
    url.set_query(None);
    Some(url.to_string())
}

/// The event without the machine's name, and with `~` for the home directory wherever it appears.
fn scrub(mut event: Event<'static>, home: Option<&str>, host: Option<&str>) -> Option<Event<'static>> {
    event.server_name = None;
    event.user = None;
    let mut json = serde_json::to_string(&event).ok()?;
    if let Some(home) = home {
        json = json.replace(&serde_json::to_string(home).ok()?.trim_matches('"').to_owned(), "~");
    }
    if let Some(host) = host {
        json = json.replace(&serde_json::to_string(host).ok()?.trim_matches('"').to_owned(), "<host>");
    }
    serde_json::from_str(&json).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn healthz_from_the_runner_endpoint() {
        assert_eq!(healthz_url("wss://factory.example/runner/connect").as_deref(), Some("https://factory.example/healthz"));
        assert_eq!(healthz_url("ws://localhost:8788/runner/connect?x=1").as_deref(), Some("http://localhost:8788/healthz"));
        assert_eq!(healthz_url("https://factory.example").as_deref(), Some("https://factory.example/healthz"));
    }

    #[test]
    fn scrub_drops_the_host_and_home() {
        let event = Event { server_name: Some("ada-mbp".into()), message: Some("couldn't read /Users/ada/Projects/x on ada-mbp".into()), ..Default::default() };
        let out = scrub(event, Some("/Users/ada"), Some("ada-mbp")).unwrap();
        assert_eq!(out.server_name, None);
        assert_eq!(out.message.as_deref(), Some("couldn't read ~/Projects/x on <host>"));
    }
}
