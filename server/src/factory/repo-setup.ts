// Set up with AI: a repo's worktree scripts and prompt additions, suggested by an agent. An admin
// starts it from Settings › Repositories; an agent on one of their machines reads the repo on its
// default branch, unable to change anything (the runner's `draft.run`, under a `setup-` id), and
// answers with scripts, per-role prompt additions and a few notes. The suggestion fills the app's
// form for the admin to review and save; nothing is saved here. A repo's latest run lives in the
// OrgHub's kv.

import type { Machine, PromptAdditions, RepoSetupRun, RepoSetupSuggestion, ServerToClient, ServerToRunner, WorktreeScripts } from "../wire.ts";
import { lastJson } from "./drafts.ts";
import { cleanPrompts } from "./prompts.ts";
import { TAG } from "../machines.ts";
import type { Store } from "./store.ts";

/** The id a setup run goes by on the runner (its token requests and its worktree's name). */
export const SETUP_PREFIX = "setup-";

/** A run that's said nothing for this long is taken as lost, so the repo can be set up again. */
export const STALE_MS = 30 * 60_000;

/** The longest command kept for one worktree script. */
export const MAX_SCRIPT = 4096;

/** The script commands, in the order the runner uses them. */
export const SCRIPT_COMMANDS = ["create", "preflight", "setup", "teardown", "archive"] as const;

/** The most files preflightWatch may name. */
export const MAX_WATCH = 20;

/** The most checks a repo may have. */
export const MAX_CHECKS = 20;

/** The MAPLE_* variables every worktree script gets, and what each holds. */
export const SCRIPT_VARIABLES: Record<string, string> = {
  MAPLE_REPO: "owner/name",
  MAPLE_REPO_ROOT: "the repo's main checkout (where the script runs, except preflight)",
  MAPLE_WORKTREE: "the task's worktree folder",
  MAPLE_BRANCH: "the task's branch, agent/<task>",
  MAPLE_BASE: "the branch it starts from (create, preflight and setup)",
  MAPLE_TASK_ID: "the task, like MF-74",
  MAPLE_PHASE: "create, preflight, setup, teardown or archive",
};

const MAX_NOTES = 8;
const NOTE_CHARS = 300;

/** preflightWatch's paths: one per line, trimmed, blank lines dropped. */
function watchPaths(s: WorktreeScripts): string[] {
  return typeof s.preflightWatch === "string" ? s.preflightWatch.split("\n").map((l) => l.trim()).filter(Boolean) : [];
}

/** A repo's checks: one command per line, trimmed, blank lines dropped. */
export function checkCommands(s: WorktreeScripts | null | undefined): string[] {
  return typeof s?.checks === "string" ? s.checks.split("\n").map((l) => l.trim()).filter(Boolean) : [];
}

/** The most path rules a repo may have. */
export const MAX_PATH_RULES = 20;

/** One check line read: its command and the machine tags it needs (from a leading `[macos] ` or `[xcode,macos] `), or why the prefix can't be read. */
export function parseCheck(line: string): { command: string; requires: string[] } | { error: string } {
  const l = line.trim();
  if (!l.startsWith("[")) return { command: l, requires: [] };
  const close = l.indexOf("]");
  if (close < 0) return { error: `The check \`${l}\` opens a [ for its machine tags but never closes it; write it like \`[macos] xcodebuild test\`.` };
  const tags = l.slice(1, close).split(",").map((t) => t.trim());
  const command = l.slice(close + 1).trim();
  if (tags.every((t) => !t)) return { error: `The check \`${l}\` has an empty [ ]; name the machine tags it needs, like [macos].` };
  const bad = tags.find((t) => !TAG.test(t) || t.length > 32);
  if (bad != null) return { error: `The check \`${l}\` asks for the tag "${bad}"; a tag is lowercase a-z, 0-9 and dashes, like macos or xcode.` };
  if (!command) return { error: `The check \`${l}\` has machine tags but no command after them.` };
  return { command, requires: [...new Set(tags)].sort() };
}

/** A repo's checks split for a machine with these tags: the commands it runs (prefixes stripped), and those it skips with the tags it lacks. A line that can't be read runs as written, so the check fails loudly instead of vanishing. Tags of null (a machine the factory can't see) runs every check: one that can't run there fails loudly rather than being skipped unseen. */
export function checksFor(s: WorktreeScripts | null | undefined, tags: readonly string[] | null): { run: string[]; skipped: { command: string; missing: string[] }[] } {
  const have = new Set(tags ?? []);
  const run: string[] = [];
  const skipped: { command: string; missing: string[] }[] = [];
  for (const line of checkCommands(s)) {
    const c = parseCheck(line);
    if ("error" in c) { run.push(line); continue; }
    const missing = tags ? c.requires.filter((t) => !have.has(t)) : [];
    if (missing.length) skipped.push({ command: c.command, missing });
    else run.push(c.command);
  }
  return { run, skipped };
}

/** One path rule: a repo-relative glob and the tags a file matching it needs. */
export type PathRule = { glob: string; tags: string[] };

/** A repo's path rules, one `glob tag[,tag]` per line, or why one can't be read. */
function readPathRules(s: WorktreeScripts | null | undefined): { rules: PathRule[] } | { error: string } {
  const lines = typeof s?.requirePaths === "string" ? s.requirePaths.split("\n").map((l) => l.trim()).filter(Boolean) : [];
  if (lines.length > MAX_PATH_RULES) return { error: `A repo has at most ${MAX_PATH_RULES} path rules.` };
  const rules: PathRule[] = [];
  for (const line of lines) {
    const m = /^(\S+)\s+(\S+)$/.exec(line);
    if (!m) return { error: `The path rule \`${line}\` should be a path and its tags, like \`apps/mac/** macos\`.` };
    const [, glob, list] = m;
    if (glob!.startsWith("/") || glob!.startsWith("~") || glob!.split(/[\\/]/).includes("..")) return { error: `The path rule's ${glob} isn't inside the repo; use a path relative to its root.` };
    const tags = list!.split(",").map((t) => t.trim());
    const bad = tags.find((t) => !TAG.test(t) || t.length > 32);
    if (bad != null) return { error: `The path rule \`${line}\` asks for the tag "${bad}"; a tag is lowercase a-z, 0-9 and dashes, like macos.` };
    rules.push({ glob: glob!, tags: [...new Set(tags)].sort() });
  }
  return { rules };
}

/** A repo's path rules; none when they can't be read (scriptsProblem refuses those when saved). */
export function pathRules(s: WorktreeScripts | null | undefined): PathRule[] {
  const r = readPathRules(s);
  return "rules" in r ? r.rules : [];
}

/** A glob as a regex: `**` any path, `*` within one folder, `?` one character. A path with no wildcard also matches everything under it. */
function globRegex(glob: string): RegExp {
  const g = glob.replace(/^\.\//, "").replace(/\/+$/, "");
  let re = "";
  for (let i = 0; i < g.length; i++) {
    const c = g[i]!;
    if (c === "*" && g[i + 1] === "*") {
      i++;
      if (g[i + 1] === "/") { i++; re += "(?:.*/)?"; } else re += ".*";
    } else if (c === "*") re += "[^/]*";
    else if (c === "?") re += "[^/]";
    else re += c.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(/[*?]/.test(g) ? `^${re}$` : `^${re}(?:/.*)?$`);
}

/** The tags these repo-relative files need under the rules: sorted, once each. */
export function requiresFor(files: readonly string[], rules: readonly PathRule[]): string[] {
  const out = new Set<string>();
  for (const r of rules) {
    const re = globRegex(r.glob);
    if (files.some((f) => re.test(f.trim().replace(/^\.\//, "")))) for (const t of r.tags) out.add(t);
  }
  return [...out].sort();
}

/** What's wrong with a repo's worktree scripts, or none: each command at most 4 KB, at most 20 repo-relative watch paths, at most 20 checks, the timeout 1–3600 seconds. */
export function scriptsProblem(s: WorktreeScripts): string | null {
  for (const f of SCRIPT_COMMANDS) {
    const command = typeof s[f] === "string" ? s[f]!.trim() : "";
    if (new TextEncoder().encode(command).length > MAX_SCRIPT) return `The ${f} script is over 4 KB; put it in a file in the repo and run that.`;
  }
  const checks = checkCommands(s);
  if (checks.length > MAX_CHECKS) return `A repo has at most ${MAX_CHECKS} checks.`;
  if (checks.some((c) => new TextEncoder().encode(c).length > MAX_SCRIPT)) return "A check is over 4 KB; put it in a file in the repo and run that.";
  for (const c of checks) {
    const r = parseCheck(c);
    if ("error" in r) return r.error;
  }
  const rules = readPathRules(s);
  if ("error" in rules) return rules.error;
  const watch = watchPaths(s);
  if (watch.length > MAX_WATCH) return `Preflight watches at most ${MAX_WATCH} files.`;
  const outside = watch.find((p) => p.startsWith("/") || p.startsWith("~") || p.split(/[\\/]/).includes(".."));
  if (outside) return `Preflight's watched file ${outside} isn't inside the repo; use a path relative to its root.`;
  if (s.timeoutSecs != null && (!Number.isSafeInteger(s.timeoutSecs) || s.timeoutSecs < 1 || s.timeoutSecs > 3600)) return "A worktree script's timeout is 1–3600 seconds.";
  return null;
}

/** Scripts as stored (call scriptsProblem first): commands and checks trimmed, blank ones dropped, none when nothing's left. */
export function tidyScripts(s: WorktreeScripts): WorktreeScripts | null {
  const out: WorktreeScripts = {};
  for (const f of SCRIPT_COMMANDS) {
    const command = typeof s[f] === "string" ? s[f]!.trim() : "";
    if (command) out[f] = command;
  }
  const watch = watchPaths(s);
  if (watch.length) out.preflightWatch = watch.join("\n");
  const checks = checkCommands(s);
  if (checks.length) out.checks = checks.join("\n");
  const rules = typeof s.requirePaths === "string" ? s.requirePaths.split("\n").map((l) => l.trim()).filter(Boolean) : [];
  if (rules.length) out.requirePaths = rules.join("\n");
  if (s.timeoutSecs != null) out.timeoutSecs = s.timeoutSecs;
  return SCRIPT_COMMANDS.some((f) => out[f]) || out.checks || out.requirePaths ? out : null;
}

/** The agent's suggestion from its reply, or why it can't be used. */
export function parseSetup(output: string): { suggestion: RepoSetupSuggestion } | { error: string } {
  const reply = lastJson(output);
  if (!reply) return { error: "The agent didn't answer with a setup. Try again, or fill it in yourself." };
  const rawScripts = reply.scripts && typeof reply.scripts === "object" ? (reply.scripts as Record<string, unknown>) : {};
  const scripts: WorktreeScripts = {};
  for (const f of SCRIPT_COMMANDS) if (typeof rawScripts[f] === "string") scripts[f] = rawScripts[f] as string;
  const watch = rawScripts.preflightWatch;
  if (typeof watch === "string") scripts.preflightWatch = watch;
  else if (Array.isArray(watch)) scripts.preflightWatch = watch.filter((w) => typeof w === "string").join("\n");
  const checks = rawScripts.checks;
  if (typeof checks === "string") scripts.checks = checks;
  else if (Array.isArray(checks)) scripts.checks = checks.filter((c) => typeof c === "string").join("\n");
  const timeout = rawScripts.timeoutSecs ?? rawScripts.timeout;
  if (timeout != null) scripts.timeoutSecs = typeof timeout === "number" ? timeout : Number.NaN;
  const problem = scriptsProblem(scripts);
  if (problem) return { error: `The agent's suggestion can't be used: ${problem}` };
  const rawPrompts = reply.prompts && typeof reply.prompts === "object" ? (reply.prompts as Record<string, unknown>) : {};
  const text = (v: unknown) => (typeof v === "string" ? v : "");
  const prompts: PromptAdditions = cleanPrompts({ planner: text(rawPrompts.planner), builder: text(rawPrompts.builder), reviewer: text(rawPrompts.reviewer) });
  const notes = (Array.isArray(reply.notes) ? reply.notes : typeof reply.notes === "string" ? [reply.notes] : [])
    .filter((n): n is string => typeof n === "string" && !!n.trim())
    .map((n) => n.trim().slice(0, NOTE_CHARS))
    .slice(0, MAX_NOTES);
  return { suggestion: { scripts: tidyScripts(scripts) ?? {}, prompts, notes } };
}

type Deps = {
  broadcast(message: ServerToClient): void;
  machines(): Promise<Machine[]>;
  hasAgent(machine: Machine, agent: string): boolean;
  paused(machine: Machine): boolean;
  isAdmin(login: string): Promise<boolean>;
  toRunner(machine: string, command: ServerToRunner): Promise<boolean>;
};

type Saved = { run: RepoSetupRun; id: string; machine: string | null };

export class RepoSetup {
  constructor(private store: Store, private deps: Deps) {}

  private load(repo: string): Saved | null {
    const raw = this.store.get(`setup:${repo.toLowerCase()}`);
    return raw ? (JSON.parse(raw) as Saved) : null;
  }

  private save(saved: Saved) {
    this.store.set(`setup:${saved.run.repo.toLowerCase()}`, JSON.stringify(saved));
    this.deps.broadcast({ type: "repo.setup.updated", run: saved.run });
  }

  /** The run a runner's `setup-<id>` is, if that machine is the one running it. */
  forRun(runId: string, machine: string): Saved | null {
    if (!runId.startsWith(SETUP_PREFIX)) return null;
    for (const r of this.store.repos()) {
      const saved = this.load(r.name);
      if (saved?.id === runId) return saved.machine === machine ? saved : null;
    }
    return null;
  }

  /** Whether a run may have a read-only token for owner/repo: only the repo it's setting up, while it runs. */
  mayFetch(runId: string, machine: string, repo: string): boolean {
    const saved = this.forRun(runId, machine);
    return Boolean(saved && saved.run.state === "running" && saved.run.repo.toLowerCase() === repo.toLowerCase());
  }

  /** Every repo's latest run, for an app that's just connected. */
  runs(): RepoSetupRun[] {
    const lost = (r: RepoSetupRun): RepoSetupRun => r.state === "running" && Date.now() - r.startedAt >= STALE_MS ? { ...r, state: "failed", progress: null, error: "Its agent stopped answering." } : r;
    return this.store.repos().map((r) => this.load(r.name)?.run).filter((r): r is RepoSetupRun => !!r).map(lost);
  }

  async start(by: string, name: string, agentWanted: string | null) {
    if (!(await this.deps.isAdmin(by))) throw new Error("Only admins can set a repo up with AI.");
    const known = this.store.repos().find((r) => r.name.toLowerCase() === name.trim().toLowerCase());
    if (!known) throw new Error(`${name} isn't one of the org's repos.`);
    const was = this.load(known.name);
    if (was?.run.state === "running" && Date.now() - was.run.startedAt < STALE_MS) throw new Error(`${known.name} is already being set up.`);
    const run: RepoSetupRun = { repo: known.name, by, state: "running", startedAt: Date.now(), progress: "Starting…", suggestion: null, error: null };
    const saved: Saved = { run, id: SETUP_PREFIX + crypto.randomUUID(), machine: null };
    const mine = (await this.deps.machines()).filter((m) => m.owner === by && m.online && !this.deps.paused(m));
    const agents = agentWanted ? [agentWanted] : ["claude", "codex"];
    const agent = agents.find((a) => mine.some((m) => this.deps.hasAgent(m, a)));
    const machine = agent && mine.find((m) => this.deps.hasAgent(m, agent));
    if (!agent || !machine) {
      Object.assign(run, { state: "failed", progress: null, error: `Set up with AI runs on one of your machines, and none of them is online, unpaused and has ${agentWanted ?? "an agent"}.` });
      return this.save(saved);
    }
    saved.machine = machine.id;
    this.save(saved);
    const current = this.store.repoSetup(known.name);
    const command: ServerToRunner = { type: "draft.run", id: saved.id, agent, prompt: setupPrompt(known.name, current?.scripts ?? null, current?.prompts ?? null), repo: known.name, folder: null, base: known.defaultBranch ?? null };
    if (!(await this.deps.toRunner(machine.id, command))) {
      Object.assign(run, { state: "failed", progress: null, error: "Couldn't reach your machine." });
      this.save(saved);
    }
  }

  async cancel(by: string, name: string) {
    const saved = this.load(name.trim());
    if (!saved || saved.run.state !== "running") return;
    if (saved.run.by !== by && !(await this.deps.isAdmin(by))) throw new Error(`Only ${saved.run.by}, who started it, or an admin can stop it.`);
    if (saved.machine) await this.deps.toRunner(saved.machine, { type: "draft.cancel", id: saved.id });
    Object.assign(saved.run, { state: "failed", progress: null, error: "Stopped." });
    this.save(saved);
  }

  progress(runId: string, machine: string, text: string, kind: string) {
    const saved = this.forRun(runId, machine);
    const line = text.trim().split("\n")[0].slice(0, 200);
    if (!saved || saved.run.state !== "running" || kind !== "tool" || !line || line === saved.run.progress) return;
    saved.run.progress = line;
    this.save(saved);
  }

  done(runId: string, machine: string, output: string | null, error: string | null) {
    const saved = this.forRun(runId, machine);
    if (!saved || saved.run.state !== "running") return;
    const parsed = output ? parseSetup(output) : { error: error ?? "The agent didn't answer with a setup." };
    if ("error" in parsed) Object.assign(saved.run, { state: "failed", progress: null, error: parsed.error });
    else Object.assign(saved.run, { state: "done", progress: null, suggestion: parsed.suggestion });
    this.save(saved);
  }
}

function setupPrompt(repo: string, scripts: WorktreeScripts | null, prompts: PromptAdditions | null): string {
  const vars = Object.entries(SCRIPT_VARIABLES).map(([k, v]) => `- ${k}: ${v}`).join("\n");
  const now = scripts || prompts ? `\n\nWhat it has now (keep what's right, improve the rest):\n${JSON.stringify({ scripts: scripts ?? {}, prompts: prompts ?? {} }, null, 2)}` : "";
  return `You're setting up the repo ${repo} for a software factory. You're in its code, as it is on the default branch. You can only read; don't try to change anything.

The factory runs agents in a git worktree per task: a planner (writes the plan, no code), a builder (changes the code and proves it works: tests, command output, screenshots) and a reviewer (reviews the diff). Work out how this repo is built, run and tested. Read the README, CLAUDE.md or AGENTS.md, the package manifests (package.json, Cargo.toml, Gemfile, go.mod, pyproject.toml, Package.swift, …), bin/ and scripts/, .env.example and any CI config.

Then suggest:
1. Worktree scripts, run by the runner with \`/bin/sh -c\` in the repo's main checkout, with these in the environment:
${vars}
   - create: only if a plain \`git worktree add\` isn't enough (it must leave a git worktree on $MAPLE_BRANCH at $MAPLE_WORKTREE). Usually leave it out.
   - preflight: machine-level setup that every worktree shares: install the language runtimes the repo pins (mise install, rbenv install, nvm install), \`brew bundle\`, start services it needs (databases, Redis). It runs in the new worktree before setup, the first time a machine uses the repo, and again when the command or a watched file changes; it should be safe to run again.
   - preflightWatch: files, one per line, relative to the repo's root, that re-run preflight when they change. Leave it out to watch .ruby-version, .tool-versions, .node-version, .nvmrc, .python-version, Brewfile and mise.toml.
   - setup: makes each fresh worktree ready to work in (per-worktree work, not machine-level): install dependencies, copy .env files from $MAPLE_REPO_ROOT, generate code, prepare a database. Run things in "$MAPLE_WORKTREE".
   - checks: commands, one per line, that must exit 0 in the worktree before a builder's work is committed and pushed: the repo's linters, formatters and git hooks, run over the whole tree. Look for lefthook.yml (\`lefthook run pre-commit --all-files\`), .husky/, lint, format or typecheck scripts in package.json (\`npm run lint\`), .rubocop.yml (\`bundle exec rubocop\`), .golangci.yml, rustfmt/clippy, ruff or black config, .pre-commit-config.yaml (\`pre-commit run --all-files\`) and what CI runs. Use check modes that don't rewrite files (\`prettier --check\`, \`cargo fmt --check\`). Leave it out when the repo has none; at most 20.
   - teardown: cleans up what setup made outside the worktree (databases, containers), if anything.
   - archive: only if the repo has its own way of removing worktrees. Usually leave it out.
   - timeoutSecs: how long each may run (1–3600), only if setup needs more than 600.
   Each command is at most 4 KB; prefer calling a script that's already in the repo.
2. Prompt additions per role, in Markdown, each under 4000 characters, only what's specific to this repo and not already in its CLAUDE.md or AGENTS.md (the agents read those anyway): for the planner, where things live and what a plan must cover; for the builder, how to run, test and prove changes (commands, dev servers, test accounts); for the reviewer, what to check. Leave one empty when there's nothing worth adding.
3. Notes for the admin: 1–5 short lines on what you found and anything they should check.${now}

Answer with only a JSON object:
{"scripts": {"preflight": "<command>", "setup": "<command>", "checks": "<command>\\n<command>", "teardown": "<command>"}, "prompts": {"planner": "<markdown>", "builder": "<markdown>", "reviewer": "<markdown>"}, "notes": ["<one line>"]}`;
}
