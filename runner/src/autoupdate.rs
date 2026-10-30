//! Updating a running runner: on a timer, and when the hub asks (`runner.update`).
//!
//! Only the service updates itself: a runner running the installed copy
//! (`~/.local/share/maple/bin/maple-runner`) with settings from runner.json. A dev runner
//! (`scripts/runner-dev.sh`: `cargo run` with an explicit token) never does; replacing a
//! build under `target/` would fight cargo, and it isn't what the service runs anyway.
//!
//! After installing a new build the runner exits with [`EXIT_UPDATED`] and the service
//! manager starts the new one. Sessions live in tmux, so they carry on and the new runner
//! reattaches to them on startup.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tracing::{info, warn};

use crate::protocol::{Outbound, UpdateState};
use crate::service;
use crate::sessions::Sessions;
use crate::update::{self, Check, EXIT_UPDATED, Releases};

/// How often the service looks for a new release: hourly, like the hub's check that tells the apps.
const CHECK_EVERY: Duration = Duration::from_secs(60 * 60);

pub struct AutoUpdate {
    exe: PathBuf,
    /// The releases URL, or why there isn't one.
    releases: Result<String, String>,
    /// Why this runner mustn't replace itself, if it mustn't.
    blocked: Option<String>,
    /// Set while an update is being checked or installed, so two never overlap.
    busy: AtomicBool,
}

/// Why a runner mustn't update itself, or `None` if it may.
pub fn blocked_reason(explicit_token: bool, installed_copy: bool, installed: &Path) -> Option<String> {
    if explicit_token {
        return Some("this runner was started with --token/MAPLE_TOKEN (a dev runner); dev runners don't update themselves".into());
    }
    if !installed_copy {
        return Some(format!("this runner isn't the installed copy ({}); `maple-runner install` sets that up, or use `maple-runner update`", installed.display()));
    }
    None
}

/// What one update attempt came to.
enum Outcome {
    UpToDate(String),
    Installed(String),
    Failed(Option<String>, String),
}

impl AutoUpdate {
    /// `server` is the control plane the runner connects to (any form `config::base_url` takes).
    pub fn new(explicit_token: bool, server: &str) -> Arc<Self> {
        let exe = update::current_exe();
        let installed = service::installed_exe();
        let blocked = match (&exe, &installed) {
            (Ok(exe), Ok(installed)) => blocked_reason(explicit_token, service::is_installed_copy(exe, installed), installed),
            (Err(e), _) | (_, Err(e)) => Some(format!("{e:#}")),
        };
        Arc::new(Self {
            exe: exe.unwrap_or_default(),
            releases: update::releases_url_from_env(Some(server)).map_err(|e| format!("{e:#}")),
            blocked,
            busy: AtomicBool::new(false),
        })
    }

    /// Checks shortly after startup (jittered, so machines restarted together don't all
    /// ask at once) and then every few hours. `MAPLE_AUTO_UPDATE=0` turns this off.
    pub fn start(self: &Arc<Self>, sessions: Sessions) {
        if let Some(why) = &self.blocked {
            return info!("automatic updates are off: {why}");
        }
        if std::env::var("MAPLE_AUTO_UPDATE").is_ok_and(|v| v.trim() == "0") {
            return info!("automatic updates are off (MAPLE_AUTO_UPDATE=0)");
        }
        info!("checking {} for updates every {}h", self.releases.as_deref().unwrap_or("?"), CHECK_EVERY.as_secs() / 3600);
        let this = self.clone();
        tokio::spawn(async move {
            let jitter = (uuid::Uuid::new_v4().as_u128() % 31) as u64;
            tokio::time::sleep(Duration::from_secs(30 + jitter)).await;
            loop {
                this.run(&sessions, false).await;
                tokio::time::sleep(CHECK_EVERY).await;
            }
        });
    }

    /// Why this runner can't replace or restart itself, if it can't.
    pub fn blocked(&self) -> Option<&str> {
        self.blocked.as_deref()
    }

    /// The hub asked for an update now.
    pub fn requested(self: &Arc<Self>, sessions: &Sessions) {
        let (this, sessions) = (self.clone(), sessions.clone());
        tokio::spawn(async move { this.run(&sessions, true).await });
    }

    /// One update attempt. Progress goes to the hub when it asked for this; a timed
    /// check only tells it when the runner is about to restart.
    async fn run(&self, sessions: &Sessions, asked: bool) {
        let report = |state: UpdateState, version: Option<String>, message: Option<String>| {
            if asked || state == UpdateState::Updating {
                sessions.emit(Outbound::RunnerUpdateStatus { state, version, message });
            }
        };
        if let Some(why) = &self.blocked {
            warn!("not updating: {why}");
            return report(UpdateState::Failed, None, Some(why.clone()));
        }
        if self.busy.swap(true, Ordering::SeqCst) {
            return report(UpdateState::Failed, None, Some("an update is already in progress".into()));
        }
        report(UpdateState::Checking, None, None);
        let outcome = self.attempt(|version| report(UpdateState::Installing, Some(version.to_string()), None)).await;
        self.busy.store(false, Ordering::SeqCst);
        match outcome {
            Outcome::UpToDate(latest) => {
                info!("up to date (running {}, latest {latest})", update::VERSION);
                report(UpdateState::UpToDate, Some(latest), Some(format!("maple-runner {} is up to date", update::VERSION)));
            }
            Outcome::Installed(version) => {
                info!("updated {} from {} to {version}; exiting with {EXIT_UPDATED} so the service restarts it", self.exe.display(), update::VERSION);
                // Hold the update flag until exit, and give the status a moment to reach the hub.
                self.busy.store(true, Ordering::SeqCst);
                report(UpdateState::Updating, Some(version.clone()), Some(format!("installed {version}; restarting")));
                tokio::time::sleep(Duration::from_secs(1)).await;
                std::process::exit(EXIT_UPDATED);
            }
            Outcome::Failed(version, message) => {
                warn!("update failed: {message}");
                report(UpdateState::Failed, version, Some(message));
            }
        }
    }

    /// `installing` hears the version before it's downloaded, so the app can say what's coming.
    async fn attempt(&self, installing: impl Fn(&str)) -> Outcome {
        let releases = match self.releases.clone().and_then(|url| Releases::new(url).map_err(|e| format!("{e:#}"))) {
            Ok(releases) => releases,
            Err(e) => return Outcome::Failed(None, e),
        };
        match releases.check(false).await {
            Err(e) => Outcome::Failed(None, format!("{e:#}")),
            Ok(Check::UpToDate(m)) => Outcome::UpToDate(m.version.to_string()),
            Ok(Check::NoBuild(m, target)) => Outcome::Failed(Some(m.version.to_string()), format!("release {} has no build for {target}", m.version)),
            Ok(Check::Available(m, asset)) => {
                info!("installing maple-runner {} over {}", m.version, self.exe.display());
                installing(&m.version.to_string());
                match releases.install(&m, &asset, &self.exe).await {
                    Ok(()) => Outcome::Installed(m.version.to_string()),
                    Err(e) => Outcome::Failed(Some(m.version.to_string()), format!("installing {}: {e:#}", m.version)),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_installed_service_updates_itself() {
        let installed = Path::new("/Users/a/.local/share/maple/bin/maple-runner");
        assert_eq!(blocked_reason(false, true, installed), None);
        let dev = blocked_reason(true, false, installed).unwrap();
        assert!(dev.contains("MAPLE_TOKEN"), "{dev}");
        // An explicit token wins even when running the installed copy.
        assert!(blocked_reason(true, true, installed).is_some());
        let elsewhere = blocked_reason(false, false, installed).unwrap();
        assert!(elsewhere.contains("maple-runner install") && elsewhere.contains("/.local/share/maple/bin/maple-runner"), "{elsewhere}");
    }
}
