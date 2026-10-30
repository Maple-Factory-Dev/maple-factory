// Scout: a goal's leftovers come back as drafted plans. Someone starts it from the goal's header; an
// agent on one of their machines reads the goal's code, unable to change anything (the runner's
// `draft.run`, under a `scout-` id), and picks at most `scoutItems` of the goal's leftovers that are
// still real: its backlog tasks and the review findings its merged tasks left open. The engine
// turns each pick into a task in planning. A goal's latest run lives in the OrgHub's kv.

import type { Goal, Machine, RiskPolicy, ScoutRun, ServerToClient, ServerToRunner, Task } from "../wire.ts";
import { lastJson } from "./drafts.ts";
import type { Store } from "./store.ts";

/** The id a Scout run goes by on the runner (its token requests and its worktree's name). */
export const SCOUT_PREFIX = "scout-";

/** Items per run when the policy doesn't say. */
export const SCOUT_ITEMS = 3;

/** A run that's said nothing for this long is taken as lost, so the goal can be scouted again. */
const STALE_MS = 30 * 60_000;

/** The most leftovers one run is shown, newest first. */
const MAX_CANDIDATES = 40;

export type Candidate = { from: string; kind: "backlog" | "finding"; task: string; title: string; text: string };
export type ScoutPick = { from: string; title: string; brief: string; doneWhen: string[] };

type Deps = {
  broadcast(message: ServerToClient): void;
  machines(): Promise<Machine[]>;
  hasAgent(machine: Machine, agent: string): boolean;
  paused(machine: Machine): boolean;
  toRunner(machine: string, command: ServerToRunner): Promise<boolean>;
  /** Turn the picks into tasks in planning; the ids of the tasks they became. */
  make(goal: Goal, by: string, picks: ScoutPick[], candidates: Candidate[]): Promise<string[]>;
};

type Saved = { run: ScoutRun; id: string; machine: string | null; candidates: Candidate[] };

export function scoutItems(policy: RiskPolicy): number {
  return policy.scoutItems ?? SCOUT_ITEMS;
}

/** What a goal has left over: its backlog tasks, and the open or disputed findings on its merged
 *  tasks, less anything an earlier run already turned into a task. */
export function candidates(goal: string, tasks: Task[]): Candidate[] {
  const scouted = new Set(tasks.map((t) => t.scoutedFrom).filter((s): s is string => !!s));
  const mine = tasks.filter((t) => t.goal === goal).sort((a, b) => b.updatedAt - a.updatedAt);
  const out: Candidate[] = [];
  for (const t of mine) {
    if (t.state === "backlog") out.push({ from: t.id, kind: "backlog", task: t.id, title: t.title, text: t.brief.slice(0, 1_500) });
    if (t.state !== "merged") continue;
    for (const f of t.autoReview?.findings ?? []) {
      if (f.status === "fixed") continue;
      out.push({ from: `${t.id}#${f.id}`, kind: "finding", task: t.id, title: t.title, text: `${f.severity} ${f.kind}${f.status === "disputed" ? " (the builder disputed it)" : ""}${f.file ? ` in ${f.file}` : ""}: ${f.text}`.slice(0, 1_500) });
    }
  }
  return out.filter((c) => !scouted.has(c.from)).slice(0, MAX_CANDIDATES);
}

/** The agent's picks: only leftovers it was shown, each once, with a title and brief, `cap` at most. */
export function parsePicks(output: string, shown: Candidate[], cap: number): ScoutPick[] | null {
  const reply = lastJson(output);
  if (!reply || !Array.isArray(reply.items)) return null;
  const known = new Set(shown.map((c) => c.from));
  const seen = new Set<string>();
  const picks: ScoutPick[] = [];
  for (const raw of reply.items as unknown[]) {
    if (!raw || typeof raw !== "object") continue;
    const i = raw as Record<string, unknown>;
    const from = typeof i.from === "string" ? i.from.trim() : "";
    const title = typeof i.title === "string" ? i.title.trim() : "";
    const brief = typeof i.brief === "string" ? i.brief.trim() : "";
    if (!known.has(from) || seen.has(from) || !title || !brief) continue;
    seen.add(from);
    const doneWhen = (Array.isArray(i.doneWhen) ? i.doneWhen : []).filter((d): d is string => typeof d === "string" && !!d.trim()).map((d) => d.trim()).slice(0, 12);
    picks.push({ from, title: title.slice(0, 120), brief: brief.slice(0, 20_000), doneWhen });
  }
  return picks.slice(0, cap);
}

export class Scout {
  constructor(private store: Store, private deps: Deps) {}

  private load(goal: string): Saved | null {
    const raw = this.store.get(`scout:${goal}`);
    return raw ? (JSON.parse(raw) as Saved) : null;
  }

  private save(saved: Saved) {
    this.store.set(`scout:${saved.run.goal}`, JSON.stringify(saved));
    this.deps.broadcast({ type: "scout.updated", run: saved.run });
  }

  /** The run a runner's `scout-<id>` is, if that machine is the one running it. */
  forRun(runId: string, machine: string): Saved | null {
    if (!runId.startsWith(SCOUT_PREFIX)) return null;
    for (const g of this.store.goals()) {
      const saved = this.load(g.id);
      if (saved?.id === runId) return saved.machine === machine ? saved : null;
    }
    return null;
  }

  /** Whether a run may have a read-only token for owner/repo: only its goal's repos, while it runs. */
  mayFetch(runId: string, machine: string, repo: string): boolean {
    const saved = this.forRun(runId, machine);
    const goal = saved ? this.store.goal(saved.run.goal) : null;
    return Boolean(saved && saved.run.state === "running" && goal?.repos.some((r) => r.toLowerCase() === repo.toLowerCase()));
  }

  async start(by: string, goalId: string) {
    const goal = this.store.goal(goalId);
    if (!goal || goal.archived) throw new Error("That goal isn't there any more.");
    const was = this.load(goal.id);
    if (was?.run.state === "running" && Date.now() - was.run.startedAt < STALE_MS) throw new Error(`${goal.name} is already being scouted.`);
    const shown = candidates(goal.id, this.store.tasks());
    const run: ScoutRun = { goal: goal.id, by, state: "running", startedAt: Date.now(), tasks: [], error: null };
    const saved: Saved = { run, id: SCOUT_PREFIX + crypto.randomUUID(), machine: null, candidates: shown };
    if (!shown.length) {
      run.state = "done";
      return this.save(saved);
    }
    const mine = (await this.deps.machines()).filter((m) => m.owner === by && m.online && !this.deps.paused(m));
    const agent = ["claude", "codex"].find((a) => mine.some((m) => this.deps.hasAgent(m, a)));
    const machine = agent && mine.find((m) => this.deps.hasAgent(m, agent));
    if (!agent || !machine) {
      run.state = "failed";
      run.error = "Scout runs on one of your machines, and none of them is online, unpaused and has an agent.";
      return this.save(saved);
    }
    saved.machine = machine.id;
    this.save(saved);
    const cap = scoutItems(this.store.policy());
    const command: ServerToRunner = { type: "draft.run", id: saved.id, agent, prompt: scoutPrompt(goal, shown, cap), repo: goal.folder ? null : goal.repo ?? null, folder: goal.folder ?? null, base: goal.base ?? null };
    if (!(await this.deps.toRunner(machine.id, command))) {
      Object.assign(run, { state: "failed", error: "Couldn't reach your machine." });
      this.save(saved);
    }
  }

  async done(runId: string, machine: string, output: string | null, error: string | null) {
    const saved = this.forRun(runId, machine);
    if (!saved || saved.run.state !== "running") return;
    const goal = this.store.goal(saved.run.goal);
    const picks = output ? parsePicks(output, saved.candidates, scoutItems(this.store.policy())) : null;
    if (!goal || !picks) {
      Object.assign(saved.run, { state: "failed", error: !goal ? "The goal isn't there any more." : error ?? "The agent didn't say which leftovers to pick up." });
      return this.save(saved);
    }
    // Saved as done first, so a second `draft.done` can't make the tasks twice.
    saved.run.state = "done";
    this.store.set(`scout:${goal.id}`, JSON.stringify(saved));
    saved.run.tasks = await this.deps.make(goal, saved.run.by, picks, saved.candidates);
    this.save(saved);
  }
}

function scoutPrompt(goal: Goal, shown: Candidate[], cap: number): string {
  const list = shown.map((c) => `- from ${c.from} · ${c.kind === "backlog" ? `backlog task "${c.title}"` : `review finding left open on ${c.task} "${c.title}"`}\n  ${c.text.replace(/\n+/g, "\n  ")}`).join("\n");
  return `You're the Scout for the goal "${goal.name}"${goal.summary ? `: ${goal.summary}` : ""}. You're in its code${goal.repos.length > 1 ? ` (${goal.repo}; the goal also spans ${goal.repos.slice(1).join(", ")})` : ""}, as it is on the base branch.

These are the goal's leftovers: tasks parked in its backlog, and review findings its merged tasks didn't fix.

<leftovers>
${list}
</leftovers>

Check each against the code as it is now. Some are already fixed, no longer apply, or aren't worth a task; skip those. Pick at most ${cap}: the ones still real and most worth doing. You can only read; don't try to change anything, and don't write the plans themselves.

Answer with only a JSON object:
{"items": [{"from": "<the leftover's from, exactly as above>", "title": "<an imperative title, under 70 characters>", "brief": "<Markdown: what's still wrong, where in the code (name the files and functions), and what the fix should do. No Done when section here.>", "doneWhen": ["<2–5 checks, each something a builder could prove with a test, a command's output, a screenshot or a video>"]}]}
An empty "items" is a fine answer when nothing is left worth doing.`;
}
