// Set up with AI: a repo's worktree scripts and prompt additions, suggested by an agent. An admin
// starts it from Settings › Repositories; an agent on one of their machines reads the repo on its
// default branch, unable to change anything (the runner's `draft.run`, under a `setup-` id), and
// answers with scripts, per-role prompt additions and a few notes. The suggestion fills the app's
// form for the admin to review and save; nothing is saved here. A repo's latest run lives in the
// OrgHub's kv.

import type { Machine, PromptAdditions, RepoSetupRun, RepoSetupSuggestion, ServerToClient, ServerToRunner, WorktreeScripts } from "../wire.ts";
import { lastJson } from "./drafts.ts";
import { cleanPrompts } from "./prompts.ts";
import type { Store } from "./store.ts";

/** The id a setup run goes by on the runner (its token requests and its worktree's name). */
export const SETUP_PREFIX = "setup-";

/** A run that's said nothing for this long is taken as lost, so the repo can be set up again. */
export const STALE_MS = 30 * 60_000;

/** The longest command kept for one worktree script. */
export const MAX_SCRIPT = 4096;

/** The script commands, in the order the runner uses them. */
export const SCRIPT_COMMANDS = ["create", "setup", "teardown", "archive"] as const;

/** The MAPLE_* variables every worktree script gets, and what each holds. */
export const SCRIPT_VARIABLES: Record<string, string> = {
  MAPLE_REPO: "owner/name",
  MAPLE_REPO_ROOT: "the repo's main checkout (where the script runs)",
  MAPLE_WORKTREE: "the task's worktree folder",
  MAPLE_BRANCH: "the task's branch, agent/<task>",
  MAPLE_BASE: "the branch it starts from (create and setup)",
  MAPLE_TASK_ID: "the task, like MF-74",
  MAPLE_PHASE: "create, setup, teardown or archive",
};

const MAX_NOTES = 8;
const NOTE_CHARS = 300;

/** What's wrong with a repo's worktree scripts, or none: each command at most 4 KB, the timeout 1–3600 seconds. */
export function scriptsProblem(s: WorktreeScripts): string | null {
  for (const f of SCRIPT_COMMANDS) {
    const command = typeof s[f] === "string" ? s[f]!.trim() : "";
    if (new TextEncoder().encode(command).length > MAX_SCRIPT) return `The ${f} script is over 4 KB; put it in a file in the repo and run that.`;
  }
  if (s.timeoutSecs != null && (!Number.isSafeInteger(s.timeoutSecs) || s.timeoutSecs < 1 || s.timeoutSecs > 3600)) return "A worktree script's timeout is 1–3600 seconds.";
  return null;
}

/** Scripts as stored (call scriptsProblem first): commands trimmed, blank ones dropped, none when nothing's left. */
export function tidyScripts(s: WorktreeScripts): WorktreeScripts | null {
  const out: WorktreeScripts = {};
  for (const f of SCRIPT_COMMANDS) {
    const command = typeof s[f] === "string" ? s[f]!.trim() : "";
    if (command) out[f] = command;
  }
  if (s.timeoutSecs != null) out.timeoutSecs = s.timeoutSecs;
  return out.create || out.setup || out.teardown || out.archive ? out : null;
}

/** The agent's suggestion from its reply, or why it can't be used. */
export function parseSetup(output: string): { suggestion: RepoSetupSuggestion } | { error: string } {
  const reply = lastJson(output);
  if (!reply) return { error: "The agent didn't answer with a setup. Try again, or fill it in yourself." };
  const rawScripts = reply.scripts && typeof reply.scripts === "object" ? (reply.scripts as Record<string, unknown>) : {};
  const scripts: WorktreeScripts = {};
  for (const f of SCRIPT_COMMANDS) if (typeof rawScripts[f] === "string") scripts[f] = rawScripts[f] as string;
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
   - setup: makes a fresh worktree ready to work in: install dependencies, copy .env files from $MAPLE_REPO_ROOT, generate code, prepare a database. Run things in "$MAPLE_WORKTREE".
   - teardown: cleans up what setup made outside the worktree (databases, containers), if anything.
   - archive: only if the repo has its own way of removing worktrees. Usually leave it out.
   - timeoutSecs: how long each may run (1–3600), only if setup needs more than 600.
   Each command is at most 4 KB; prefer calling a script that's already in the repo.
2. Prompt additions per role, in Markdown, each under 4000 characters, only what's specific to this repo and not already in its CLAUDE.md or AGENTS.md (the agents read those anyway): for the planner, where things live and what a plan must cover; for the builder, how to run, test and prove changes (commands, dev servers, test accounts); for the reviewer, what to check. Leave one empty when there's nothing worth adding.
3. Notes for the admin: 1–5 short lines on what you found and anything they should check.${now}

Answer with only a JSON object:
{"scripts": {"setup": "<command>", "teardown": "<command>"}, "prompts": {"planner": "<markdown>", "builder": "<markdown>", "reviewer": "<markdown>"}, "notes": ["<one line>"]}`;
}
