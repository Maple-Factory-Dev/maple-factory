//! A task's project: the factory settings for its repository, put in front of its prompt.
//!
//! Projects live on the control plane (Settings → Projects), keyed by GitHub `owner/name`, never by
//! a folder. The hub sends them with a task's `session.open`; once the worktree exists, the runner
//! works out the repo from its `origin`, takes that project's settings, lets the repo's own
//! `.factory.toml` override them key by key, and renders a "Project" block in front of the prompt.
//! A task in a repo without a project starts with its prompt unchanged. Either way the hub hears
//! what was found (`task.started`, from `tasks::open`), so the project page can say whether a
//! `.factory.toml` wins.
//!
//! `.factory.toml` uses the same keys in snake_case. Commands and lists may be one string (one
//! item per line) or an array of strings:
//!
//! ```toml
//! setup = "npm ci"
//! test = ["npm run typecheck", "npm test"]
//! proof_kinds = ["test", "command"]
//! high_risk_paths = ["migrations/**"]
//! max_diff_lines = 400
//! auto_merge = false
//! definition_of_done = "Every item is proven."
//! ```

use std::path::Path;

use serde::{Deserialize, Serialize};

pub const FILE: &str = ".factory.toml";
/// What a task can be proven with, in the order they're listed.
const PROOF_KINDS: [&str; 4] = ["test", "command", "terminal", "screen"];
/// A `.factory.toml` bigger than this isn't read.
const MAX_FILE: u64 = 64 * 1024;

/// A project's settings, as the control plane stores them (`ProjectSettings` in protocol.ts).
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// Commands, one per line.
    pub setup: Option<String>,
    pub test: Option<String>,
    pub lint: Option<String>,
    pub dev: Option<String>,
    pub proof_kinds: Option<Vec<String>>,
    pub screens: Option<String>,
    pub high_risk_paths: Option<Vec<String>>,
    pub max_diff_lines: Option<u64>,
    /// False: its tasks' PRs never merge on their own (gate.ts). None is on.
    pub auto_merge: Option<bool>,
    pub areas: Option<Vec<String>>,
    pub definition_of_done: Option<String>,
}

/// One project, as `session.open`'s `task.projects` carries it.
#[derive(Debug, Clone, Deserialize)]
pub struct Project {
    /// owner/name on GitHub.
    pub repo: String,
    pub name: String,
    #[serde(default)]
    pub settings: Settings,
}

/// `session.open`'s `task`: the task a session runs, and the projects to look its repo up in.
#[derive(Debug, Clone, Deserialize)]
pub struct TaskStart {
    pub id: String,
    /// owner/name, for a task that names a project instead of a folder.
    #[serde(default)]
    pub repo: Option<String>,
    #[serde(default)]
    pub projects: Vec<Project>,
    /// The repo's worktree scripts (see `worktree_scripts`).
    #[serde(default)]
    pub scripts: Option<crate::worktree_scripts::WorktreeScripts>,
}

/// What the repo's `.factory.toml` did, for the project page.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct FileReport {
    pub found: bool,
    /// The settings keys it set (camelCase, as the control plane names them).
    pub keys: Vec<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// A string, or a list of them (one per line).
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum Lines {
    One(String),
    Many(Vec<String>),
}

impl Lines {
    fn items(self) -> Vec<String> {
        let all = match self {
            Lines::One(s) => s.lines().map(str::to_string).collect(),
            Lines::Many(v) => v,
        };
        all.into_iter().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
    }
    fn text(self) -> String {
        self.items().join("\n")
    }
}

/// `.factory.toml` as written. Unknown keys are ignored, so a newer file still works here.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct FileSettings {
    setup: Option<Lines>,
    test: Option<Lines>,
    lint: Option<Lines>,
    dev: Option<Lines>,
    proof_kinds: Option<Lines>,
    screens: Option<Lines>,
    high_risk_paths: Option<Lines>,
    max_diff_lines: Option<u64>,
    auto_merge: Option<bool>,
    areas: Option<Lines>,
    definition_of_done: Option<String>,
}

/// `project` with the keys `file` sets replaced by the file's; also which keys those were.
fn merge(project: &Settings, file: &str) -> Result<(Settings, Vec<&'static str>), String> {
    let f: FileSettings = toml::from_str(file).map_err(|e| format!("{FILE} isn't valid TOML: {}", e.message()))?;
    let mut out = project.clone();
    let mut keys = Vec::new();
    macro_rules! take {
        ($field:ident, $key:literal, $conv:expr) => {
            if let Some(v) = f.$field {
                out.$field = Some($conv(v));
                keys.push($key);
            }
        };
    }
    take!(setup, "setup", Lines::text);
    take!(test, "test", Lines::text);
    take!(lint, "lint", Lines::text);
    take!(dev, "dev", Lines::text);
    take!(proof_kinds, "proofKinds", |l: Lines| {
        let given = l.items();
        PROOF_KINDS.iter().filter(|k| given.iter().any(|g| g.eq_ignore_ascii_case(k))).map(|k| k.to_string()).collect()
    });
    take!(screens, "screens", Lines::text);
    take!(high_risk_paths, "highRiskPaths", Lines::items);
    take!(max_diff_lines, "maxDiffLines", |n| n);
    take!(auto_merge, "autoMerge", |b| b);
    take!(areas, "areas", Lines::items);
    take!(definition_of_done, "definitionOfDone", |s: String| s.trim().to_string());
    Ok((out, keys))
}

fn some(v: &Option<String>) -> Option<&str> {
    v.as_deref().map(str::trim).filter(|v| !v.is_empty())
}

/// The "Project" block, modelled on a factory note's preamble.
pub fn render(repo: &str, name: &str, s: &Settings) -> String {
    let commands = |v: &str| v.lines().map(str::trim).filter(|l| !l.is_empty()).map(|l| format!("`{l}`")).collect::<Vec<_>>().join(", ");
    let kinds: Vec<&str> = s.proof_kinds.iter().flatten().map(String::as_str).filter(|k| PROOF_KINDS.contains(k)).collect();
    let screen = kinds.contains(&"screen");
    let mut lines = vec![if name.is_empty() || name.eq_ignore_ascii_case(repo) || repo.to_lowercase().ends_with(&format!("/{}", name.to_lowercase())) {
        format!("- Repo: {repo} on GitHub.")
    } else {
        format!("- Repo: {repo} on GitHub ({name}).")
    }];
    let areas: Vec<&String> = s.areas.iter().flatten().collect();
    if !areas.is_empty() {
        lines.push("- Areas:".into());
        lines.extend(areas.iter().map(|a| format!("  - {a}")));
    }
    if let Some(v) = some(&s.setup) {
        lines.push(format!("- Setup in a fresh worktree: {}", commands(v)));
    }
    if let Some(v) = some(&s.test) {
        lines.push(format!("- Checks, all must pass: {}", commands(v)));
    }
    if let Some(v) = some(&s.lint) {
        lines.push(format!("- Lint: {}", commands(v)));
    }
    if let Some(v) = some(&s.dev) {
        lines.push(format!("- Dev{}: {}", if screen { ", only when the task asks for a screen" } else { "" }, commands(v)));
        if screen {
            // Each session has its own ports, so parallel tasks don't screenshot each other's server.
            lines.push("  The dev server listens on `$PORT` (API on `$MAPLE_API_PORT`); screenshot `http://localhost:$PORT`.".into());
        }
    }
    if !kinds.is_empty() {
        lines.push(format!("- Proof kinds this project can produce: {}.", kinds.join(", ")));
    }
    if screen && let Some(v) = some(&s.screens) {
        lines.push(format!("- Screens to capture: {}", v.replace('\n', " ")));
    }
    let risky: Vec<String> = s.high_risk_paths.iter().flatten().map(|p| format!("`{p}`")).collect();
    let max = s.max_diff_lines.filter(|n| *n > 0);
    match (risky.is_empty(), max) {
        (false, Some(n)) => lines.push(format!(
            "- High-risk paths: {}. A diff over {n} changed lines also counts as high risk. You may touch these when the task needs it. Say so under Risk.",
            risky.join(", ")
        )),
        (false, None) => lines.push(format!("- High-risk paths: {}. You may touch these when the task needs it. Say so under Risk.", risky.join(", "))),
        (true, Some(n)) => lines.push(format!("- A diff over {n} changed lines counts as high risk. Say so under Risk.")),
        (true, None) => {}
    }
    let mut out = format!("### Project\n\n{}\n", lines.join("\n"));
    if let Some(v) = some(&s.definition_of_done) {
        out.push_str(&format!("\n### Definition of done\n\n{v}\n"));
    }
    out
}

/// The rules a task's PR risk is held to, from the merged settings (`RiskRules` in risk.ts). The hub
/// stores them from `task.started`; without them it takes the project's own settings.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Rules {
    pub high_risk_paths: Vec<String>,
    /// None: the hub's default limit.
    pub max_diff_lines: Option<u64>,
    /// Some(false) when auto-merge is off for the project (the base branch's `.factory.toml` over the
    /// project's setting); left out when it's on.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub auto_merge: Option<bool>,
}

impl Rules {
    pub fn of(s: &Settings) -> Rules {
        Rules {
            high_risk_paths: s.high_risk_paths.clone().unwrap_or_default(),
            max_diff_lines: s.max_diff_lines.filter(|n| *n > 0),
            auto_merge: s.auto_merge.filter(|on| !on),
        }
    }
}

/// What starting a task in `worktree` comes to: the prompt to give the agent, the repo, the
/// project it matched, what its `.factory.toml` did and the rules in effect (all None without a project).
#[derive(Debug, PartialEq)]
pub struct Prepared {
    pub prompt: Option<String>,
    pub repo: Option<String>,
    pub project: Option<String>,
    pub factory: Option<FileReport>,
    pub rules: Option<Rules>,
}

pub async fn prepare(worktree: &Path, prompt: Option<&str>, projects: &[Project]) -> Prepared {
    let repo = origin_repo(worktree).await;
    let unchanged = |repo| Prepared { prompt: prompt.map(str::to_string), repo, project: None, factory: None, rules: None };
    let Some(project) = project_for(repo.as_deref(), projects) else {
        return unchanged(repo);
    };
    let path = worktree.join(FILE);
    let file = match std::fs::metadata(&path) {
        Err(_) => Ok(None),
        Ok(m) if m.len() > MAX_FILE => Err(format!("{FILE} is over {} KB", MAX_FILE / 1024)),
        Ok(_) => std::fs::read_to_string(&path).map(Some).map_err(|e| format!("couldn't read {FILE}: {e}")),
    };
    let (settings, report) = with_file(project, file);
    let block = render(&project.repo, &project.name, &settings);
    let prompt = match prompt.map(str::trim).filter(|p| !p.is_empty()) {
        Some(p) => format!("{block}\n{p}"),
        None => block,
    };
    Prepared { prompt: Some(prompt), repo, project: Some(project.repo.clone()), factory: Some(report), rules: Some(Rules::of(&settings)) }
}

/// The settings a task's checks run with: its project's, with `.factory.toml` as it is at `base`
/// (`origin/<base>`), never the worktree's copy, so a task can't change what checks its own work.
/// None when the repo has no project.
pub async fn settings_at(worktree: &Path, base: &str, projects: &[Project]) -> Option<Settings> {
    let project = project_for(origin_repo(worktree).await.as_deref(), projects)?;
    let spec = format!("{base}:{FILE}");
    let git = |args: &[&str]| {
        let mut cmd = tokio::process::Command::new("git");
        cmd.arg("-C").arg(worktree).args(args).env("GIT_OPTIONAL_LOCKS", "0").stdin(std::process::Stdio::null());
        cmd
    };
    // Not there at the base: the project's settings.
    let size = git(&["cat-file", "-s", &spec]).output().await.ok().filter(|o| o.status.success());
    let file = match size.map(|o| String::from_utf8_lossy(&o.stdout).trim().parse::<u64>().unwrap_or(0)) {
        None => Ok(None),
        Some(n) if n > MAX_FILE => Err(format!("{FILE} is over {} KB", MAX_FILE / 1024)),
        Some(_) => match git(&["cat-file", "blob", &spec]).output().await {
            Ok(o) if o.status.success() => String::from_utf8(o.stdout).map(Some).map_err(|_| format!("{FILE} isn't UTF-8")),
            _ => Err(format!("couldn't read {FILE} at {base}")),
        },
    };
    Some(with_file(project, file).0)
}

/// owner/name of the GitHub repo behind `worktree`'s origin.
async fn origin_repo(worktree: &Path) -> Option<String> {
    let origin = tokio::process::Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args(["config", "--get", "remote.origin.url"])
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    origin.as_deref().and_then(crate::tasks::parse_github).map(|(o, r)| format!("{o}/{r}"))
}

fn project_for<'a>(repo: Option<&str>, projects: &'a [Project]) -> Option<&'a Project> {
    repo.and_then(|r| projects.iter().find(|p| p.repo.eq_ignore_ascii_case(r)))
}

/// The project's settings with a `.factory.toml` (its text, if there is one) applied, and what it
/// did. A file that can't be read or parsed leaves the project's settings as they are.
fn with_file(project: &Project, file: Result<Option<String>, String>) -> (Settings, FileReport) {
    match file.and_then(|t| t.map(|t| merge(&project.settings, &t)).transpose()) {
        Ok(None) => (project.settings.clone(), FileReport { found: false, keys: vec![], error: None }),
        Ok(Some((s, keys))) => (s, FileReport { found: true, keys, error: None }),
        Err(e) => {
            tracing::warn!("{}: {e}; using the project's settings", project.repo);
            (project.settings.clone(), FileReport { found: true, keys: vec![], error: Some(e) })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings() -> Settings {
        Settings {
            setup: Some("npm ci".into()),
            test: Some("npm run typecheck\nnpm test".into()),
            proof_kinds: Some(vec!["test".into(), "command".into()]),
            screens: Some("the Tasks page at 390px".into()),
            high_risk_paths: Some(vec!["migrations/**".into()]),
            max_diff_lines: Some(400),
            areas: Some(vec!["web/ is Vite".into()]),
            definition_of_done: Some("Every item is proven.".into()),
            ..Default::default()
        }
    }

    #[test]
    fn renders_like_a_preamble() {
        let block = render("acme/widgets", "Widgets Co", &settings());
        assert_eq!(
            block,
            "### Project\n\n- Repo: acme/widgets on GitHub (Widgets Co).\n- Areas:\n  - web/ is Vite\n- Setup in a fresh worktree: `npm ci`\n\
             - Checks, all must pass: `npm run typecheck`, `npm test`\n- Proof kinds this project can produce: test, command.\n\
             - High-risk paths: `migrations/**`. A diff over 400 changed lines also counts as high risk. You may touch these when the task needs it. Say so under Risk.\n\
             \n### Definition of done\n\nEvery item is proven.\n"
        );
        // Screens only with the screen proof kind.
        assert!(!block.contains("Screens"));
        let s = Settings { proof_kinds: Some(vec!["screen".into()]), dev: Some("npm run dev".into()), ..settings() };
        let block = render("acme/widgets", "widgets", &s);
        assert!(block.contains("- Repo: acme/widgets on GitHub.\n"));
        assert!(block.contains("- Screens to capture: the Tasks page at 390px"));
        assert!(block.contains("- Dev, only when the task asks for a screen: `npm run dev`\n  The dev server listens on `$PORT` (API on `$MAPLE_API_PORT`); screenshot `http://localhost:$PORT`.\n"));
        // An empty project still says which repo it is.
        assert_eq!(render("acme/widgets", "", &Settings::default()), "### Project\n\n- Repo: acme/widgets on GitHub.\n");
    }

    #[test]
    fn the_file_wins_key_by_key() {
        let file = "test = [\"cargo test\"]\nproof_kinds = \"terminal\\nTEST\\nbogus\"\nmax_diff_lines = 200\nroles = \"later\"\n";
        let (s, keys) = merge(&settings(), file).unwrap();
        assert_eq!(keys, vec!["test", "proofKinds", "maxDiffLines"]);
        assert_eq!(s.test.as_deref(), Some("cargo test"));
        assert_eq!(s.proof_kinds, Some(vec!["test".to_string(), "terminal".to_string()]));
        assert_eq!(s.max_diff_lines, Some(200));
        // Everything else is the project's.
        assert_eq!((s.setup, s.high_risk_paths, s.definition_of_done), (settings().setup, settings().high_risk_paths, settings().definition_of_done));
        assert!(merge(&settings(), "test = [").unwrap_err().contains("isn't valid TOML"));
        assert!(merge(&settings(), "max_diff_lines = \"lots\"").is_err());
    }

    #[test]
    fn task_started_carries_the_rules_in_effect() {
        let (s, _) = merge(&settings(), "high_risk_paths = [\"grammar/**\", \"Cargo.toml\"]\n").unwrap();
        let msg = crate::protocol::Outbound::TaskStarted {
            task_id: "t1".into(),
            repo: Some("acme/widgets".into()),
            repo_dir: "~/src/widgets".into(),
            base: "main".into(),
            project: Some("acme/widgets".into()),
            factory: None,
            rules: Some(Rules::of(&s)),
        };
        let j = serde_json::to_value(&msg).unwrap();
        assert_eq!(j["type"], "task.started");
        // The file's paths, the project's limit.
        assert_eq!(j["rules"], serde_json::json!({ "highRiskPaths": ["grammar/**", "Cargo.toml"], "maxDiffLines": 400 }));
        // Nothing set: no paths, and the hub's default limit.
        assert_eq!(serde_json::to_value(Rules::of(&Settings::default())).unwrap(), serde_json::json!({ "highRiskPaths": [], "maxDiffLines": null }));
    }

    #[test]
    fn auto_merge_off_in_the_file_or_the_project_goes_with_the_rules() {
        // The base branch's file turns it off over the project's (on) setting.
        let (s, keys) = merge(&settings(), "auto_merge = false\n").unwrap();
        assert_eq!(keys, vec!["autoMerge"]);
        assert_eq!(serde_json::to_value(Rules::of(&s)).unwrap()["autoMerge"], serde_json::json!(false));
        // The project's own `autoMerge: false`, with no file.
        let off: Settings = serde_json::from_str(r#"{"autoMerge":false}"#).unwrap();
        assert_eq!(Rules::of(&off).auto_merge, Some(false));
        // On (or not said) leaves it out, and the file can turn the project's off back on.
        let (on, _) = merge(&off, "auto_merge = true\n").unwrap();
        assert_eq!(serde_json::to_value(Rules::of(&on)).unwrap().get("autoMerge"), None);
        assert!(merge(&settings(), "auto_merge = \"no\"").is_err());
    }

    #[test]
    fn task_start_parses() {
        let t: TaskStart = serde_json::from_str(
            r#"{"id":"t1","projects":[{"repo":"acme/widgets","name":"Widgets","settings":{"test":"npm test","proofKinds":["test"],"maxDiffLines":400}}]}"#,
        )
        .unwrap();
        assert_eq!(t.projects[0].settings.test.as_deref(), Some("npm test"));
        assert_eq!(t.projects[0].settings.max_diff_lines, Some(400));
        let bare: TaskStart = serde_json::from_str(r#"{"id":"t1"}"#).unwrap();
        assert!(bare.projects.is_empty());
    }

    /// The whole thing in a real checkout: matched by origin, the file read from the worktree.
    #[tokio::test]
    async fn a_task_in_a_project_gets_the_block_in_front_of_its_prompt() {
        let dir = std::env::temp_dir().join(format!("maple-factory-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let sh = |args: &[&str]| assert!(std::process::Command::new("git").arg("-C").arg(&dir).args(args).status().unwrap().success());
        sh(&["init", "--quiet"]);
        sh(&["remote", "add", "origin", "git@github.com:Acme/Widgets.git"]);
        let projects = vec![
            Project { repo: "other/thing".into(), name: "Thing".into(), settings: Settings::default() },
            Project { repo: "acme/widgets".into(), name: "Widgets".into(), settings: settings() },
        ];

        // No .factory.toml: the project's settings.
        let p = prepare(&dir, Some("Fix the flaky test."), &projects).await;
        let prompt = p.prompt.unwrap();
        assert!(prompt.starts_with("### Project\n\n- Repo: acme/widgets on GitHub.\n"), "{prompt}");
        assert!(prompt.contains("- Checks, all must pass: `npm run typecheck`, `npm test`\n"));
        assert!(prompt.ends_with("Every item is proven.\n\nFix the flaky test."), "{prompt}");
        assert_eq!((p.repo.as_deref(), p.project.as_deref()), (Some("Acme/Widgets"), Some("acme/widgets")));
        assert_eq!(p.factory, Some(FileReport { found: false, keys: vec![], error: None }));

        // The repo's .factory.toml, read when the task starts, overrides `test` only.
        std::fs::write(dir.join(FILE), "test = \"cargo test\"\n").unwrap();
        let p = prepare(&dir, Some("Fix the flaky test."), &projects).await;
        let prompt = p.prompt.unwrap();
        assert!(prompt.contains("- Checks, all must pass: `cargo test`\n") && prompt.contains("- Setup in a fresh worktree: `npm ci`\n"), "{prompt}");
        assert_eq!(p.factory, Some(FileReport { found: true, keys: vec!["test"], error: None }));
        assert_eq!(p.rules, Some(Rules { high_risk_paths: vec!["migrations/**".into()], max_diff_lines: Some(400), auto_merge: None }));

        // Its rules for the PR's risk are merged the same way.
        std::fs::write(dir.join(FILE), "high_risk_paths = \"grammar/**\"\nmax_diff_lines = 200\n").unwrap();
        let p = prepare(&dir, Some("Fix the flaky test."), &projects).await;
        assert_eq!(p.rules, Some(Rules { high_risk_paths: vec!["grammar/**".into()], max_diff_lines: Some(200), auto_merge: None }));

        // A broken file: the project's settings, and the error for the page.
        std::fs::write(dir.join(FILE), "test = [").unwrap();
        let p = prepare(&dir, Some("Fix it."), &projects).await;
        assert!(p.prompt.unwrap().contains("`npm run typecheck`, `npm test`"));
        assert!(p.factory.unwrap().error.unwrap().contains("isn't valid TOML"));

        // No project for this repo: the prompt is unchanged, .factory.toml or not.
        let p = prepare(&dir, Some("Fix it."), &projects[..1]).await;
        assert_eq!(p, Prepared { prompt: Some("Fix it.".into()), repo: Some("Acme/Widgets".into()), project: None, factory: None, rules: None });
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
