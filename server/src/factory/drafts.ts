// Draft with AI: a rough idea becomes a task's title, brief and Done when. An agent on one of its
// owner's machines works it out once, unable to change anything (`draft.run`): first which goal it
// belongs to (from the goals' names and summaries alone), then, in a throwaway worktree of that
// goal's code, what the task should say. Drafts live in the OrgHub's kv and only their owner sees them.

import type { Draft, Goal, Machine, ServerToClient, ServerToRunner } from "../wire.ts";
import type { Store } from "./store.ts";

type Deps = {
  sendTo(login: string, message: ServerToClient): void;
  machines(): Promise<Machine[]>;
  hasAgent(machine: Machine, agent: string): boolean;
  paused(machine: Machine): boolean;
  toRunner(machine: string, command: ServerToRunner): Promise<boolean>;
};

type Saved = { draft: Draft; owner: string };

/** The id a draft's run goes by on the runner (its token requests and its worktree's name). */
export const RUN_PREFIX = "draft-";

export class Drafts {
  constructor(private store: Store, private deps: Deps) {}

  private load(id: string): Saved | null {
    const raw = this.store.get(`draft:${id}`);
    return raw ? (JSON.parse(raw) as Saved) : null;
  }

  private save(saved: Saved) {
    this.store.set(`draft:${saved.draft.id}`, JSON.stringify(saved));
    this.deps.sendTo(saved.owner, { type: "draft.updated", draft: saved.draft });
  }

  /** The draft a runner's `draft-<id>` is working on, if that machine is the one running it. */
  forRun(runId: string, machine: string): Saved | null {
    if (!runId.startsWith(RUN_PREFIX)) return null;
    const saved = this.load(runId.slice(RUN_PREFIX.length));
    return saved && saved.draft.machine === machine ? saved : null;
  }

  /** Whether a draft's run may have a read-only token for owner/repo: only its goal's repos. */
  mayFetch(runId: string, machine: string, repo: string): boolean {
    const saved = this.forRun(runId, machine);
    const goal = saved?.draft.goal ? this.store.goal(saved.draft.goal) : null;
    return Boolean(saved && saved.draft.state === "reading" && goal?.repos.some((r) => r.toLowerCase() === repo.toLowerCase()));
  }

  async start(owner: string, id: string, idea: string, goal: string | null, agent: string | null) {
    if (!/^[0-9a-f-]{36}$/i.test(id)) throw new Error("A draft's id is a UUID.");
    if (this.load(id)) throw new Error("That draft is already going.");
    const text = idea.trim();
    if (!text) throw new Error("Write a line or two about what you want first.");
    if (text.length > 20_000) throw new Error("That's too long to draft from (20,000 characters at most).");
    const picked = goal ? this.store.goal(goal) : null;
    if (goal && (!picked || picked.archived)) throw new Error("That goal isn't there any more.");
    const draft: Draft = {
      id, idea: text, agent: agent || "claude", state: picked ? "reading" : "choosing", machine: null,
      goal: picked?.id ?? null, also: [], newGoal: null, why: null, title: null, brief: null, doneWhen: [], progress: "Starting…", error: null,
    };
    const saved = { draft, owner };
    const machine = await this.machine(saved);
    if (!machine) return;
    draft.machine = machine.id;
    this.save(saved);
    await this.run(saved);
  }

  /** Carry on with a goal (after it suggested a new one, or the person picked another). */
  async pickGoal(owner: string, id: string, goal: string) {
    const saved = this.mine(owner, id);
    const picked = this.store.goal(goal);
    if (!picked || picked.archived) throw new Error("That goal isn't there any more.");
    if (saved.draft.state === "choosing" || saved.draft.state === "reading") await this.stop(saved);
    Object.assign(saved.draft, { goal: picked.id, newGoal: null, state: "reading", progress: "Starting…", error: null });
    const machine = await this.machine(saved);
    if (!machine) return;
    saved.draft.machine = machine.id;
    this.save(saved);
    await this.run(saved);
  }

  async cancel(owner: string, id: string) {
    const saved = this.mine(owner, id);
    await this.stop(saved);
    this.store.set(`draft:${id}`, JSON.stringify({ ...saved, draft: { ...saved.draft, state: "failed", error: "Cancelled.", progress: null } }));
  }

  progress(runId: string, machine: string, text: string) {
    const saved = this.forRun(runId, machine);
    if (!saved || (saved.draft.state !== "choosing" && saved.draft.state !== "reading")) return;
    saved.draft.progress = text.slice(0, 200);
    this.save(saved);
  }

  async done(runId: string, machine: string, output: string | null, error: string | null) {
    const saved = this.forRun(runId, machine);
    if (!saved) return;
    const { draft } = saved;
    if (draft.state !== "choosing" && draft.state !== "reading") return;
    draft.progress = null;
    const reply = output ? lastJson(output) : null;
    if (!reply) {
      draft.state = "failed";
      draft.error = error ?? "The agent didn't say what the task should be. Try again, or write it yourself.";
      return this.save(saved);
    }
    if (draft.state === "choosing") {
      const goals = this.store.goals().filter((g) => !g.archived);
      const find = (v: unknown) => typeof v === "string" ? goals.find((g) => g.id === v || g.name.toLowerCase() === v.toLowerCase() || g.prefix === v.toUpperCase()) : undefined;
      const goal = find(reply.goal);
      draft.also = (Array.isArray(reply.also) ? reply.also : []).map(find).filter((g): g is Goal => !!g && g.id !== goal?.id).map((g) => g.id).slice(0, 3);
      draft.why = typeof reply.why === "string" ? reply.why.slice(0, 400) : null;
      if (goal) {
        draft.goal = goal.id;
        draft.state = "reading";
        draft.progress = "Starting…";
        this.save(saved);
        return this.run(saved);
      }
      const idea = reply.newGoal as { name?: unknown; summary?: unknown; repos?: unknown } | null;
      if (idea && typeof idea.name === "string" && idea.name.trim()) {
        const known = new Set(this.store.repos().map((r) => r.name.toLowerCase()));
        const repos = (Array.isArray(idea.repos) ? idea.repos : []).filter((r): r is string => typeof r === "string" && (!known.size || known.has(r.toLowerCase())));
        draft.newGoal = { name: idea.name.trim().slice(0, 60), summary: typeof idea.summary === "string" ? idea.summary.slice(0, 300) : "", repos };
        draft.state = "needsGoal";
        return this.save(saved);
      }
      draft.state = "failed";
      draft.error = "It couldn't tell which goal this belongs to. Pick one and try again.";
      return this.save(saved);
    }
    const title = typeof reply.title === "string" ? reply.title.trim() : "";
    const brief = typeof reply.brief === "string" ? reply.brief.trim() : "";
    if (!title || !brief) {
      draft.state = "failed";
      draft.error = "The agent's draft was missing its title or brief. Try again.";
      return this.save(saved);
    }
    draft.title = title.slice(0, 120);
    draft.brief = brief.slice(0, 20_000);
    draft.doneWhen = (Array.isArray(reply.doneWhen) ? reply.doneWhen : []).filter((d): d is string => typeof d === "string" && !!d.trim()).map((d) => d.trim()).slice(0, 12);
    draft.state = "ready";
    this.save(saved);
  }

  private mine(owner: string, id: string): Saved {
    const saved = this.load(id);
    if (!saved || saved.owner !== owner) throw new Error("That draft isn't there any more.");
    return saved;
  }

  /** One of the owner's machines that can run the agent; else the draft fails saying why. */
  private async machine(saved: Saved): Promise<Machine | null> {
    const mine = (await this.deps.machines()).filter((m) => m.owner === saved.owner);
    const machine = mine.find((m) => m.online && !this.deps.paused(m) && this.deps.hasAgent(m, saved.draft.agent));
    if (machine) return machine;
    const why = !mine.length ? "Draft with AI runs on one of your machines, and you have none: add one under Machines."
      : !mine.some((m) => m.online) ? "Draft with AI runs on one of your machines, and they're all offline."
      : !mine.some((m) => m.online && !this.deps.paused(m)) ? "Your machines are paused."
      : `None of your online machines has ${saved.draft.agent} installed.`;
    Object.assign(saved.draft, { state: "failed", error: why, progress: null });
    this.save(saved);
    return null;
  }

  private async run(saved: Saved) {
    const { draft } = saved;
    const goal = draft.goal ? this.store.goal(draft.goal) : null;
    const command: ServerToRunner = goal
      ? { type: "draft.run", id: RUN_PREFIX + draft.id, agent: draft.agent, prompt: readingPrompt(draft, goal), repo: goal.folder ? null : goal.repo ?? null, folder: goal.folder ?? null, base: goal.base ?? null }
      : { type: "draft.run", id: RUN_PREFIX + draft.id, agent: draft.agent, prompt: choosingPrompt(draft, this.store.goals().filter((g) => !g.archived), this.store.repos().map((r) => r.name)), repo: null, folder: null, base: null };
    if (!(await this.deps.toRunner(draft.machine!, command))) {
      Object.assign(draft, { state: "failed", error: "Couldn't reach your machine.", progress: null });
      this.save(saved);
    }
  }

  private async stop(saved: Saved) {
    if (saved.draft.machine) await this.deps.toRunner(saved.draft.machine, { type: "draft.cancel", id: RUN_PREFIX + saved.draft.id });
  }
}

/** The last JSON object in an agent's answer (it may say something around it, or fence it). */
export function lastJson(text: string): Record<string, unknown> | null {
  for (let end = text.lastIndexOf("}"); end > 0; end = text.lastIndexOf("}", end - 1)) {
    for (let start = text.lastIndexOf("{", end); start >= 0; start = text.lastIndexOf("{", start - 1)) {
      try {
        const v = JSON.parse(text.slice(start, end + 1));
        if (v && typeof v === "object" && !Array.isArray(v)) return v as Record<string, unknown>;
      } catch {
        // Not this brace; try an earlier one.
      }
    }
  }
  return null;
}

function choosingPrompt(draft: Draft, goals: Goal[], repos: string[]): string {
  const list = goals.map((g) => `- id ${g.id} · ${g.name} (${g.prefix})${g.team ? ` · team @${g.team}` : ""} · ${g.folder ?? (g.repos.join(", ") || "no code yet")}${g.summary ? `\n  ${g.summary}` : ""}`).join("\n");
  return `Someone wants a task done and has written this rough idea:

<idea>
${draft.idea}
</idea>

Which of the team's goals does it belong to? A goal groups tasks with a shared outcome and says where their code is.

<goals>
${list || "(there are no goals yet)"}
</goals>

The org's repositories: ${repos.slice(0, 300).join(", ") || "(none listed)"}.

Don't look anything up and don't change anything: decide from the above. Answer with only a JSON object:
{"goal": "<the id of the goal it belongs to, or null>", "also": ["<ids of other goals it could fit>"], "newGoal": null, "why": "<one short sentence>"}
If none of the goals fits, set "goal" to null and suggest one to make instead:
"newGoal": {"name": "<2–4 words>", "summary": "<one sentence on the outcome>", "repos": ["<owner/name from the org's repositories>"]}`;
}

function readingPrompt(draft: Draft, goal: Goal): string {
  return `You're drafting a task for a team's coding agents, from this rough idea:

<idea>
${draft.idea}
</idea>

It's for the goal "${goal.name}"${goal.summary ? `: ${goal.summary}` : ""}. You're in its code${goal.repos.length > 1 ? ` (${goal.repo}; the goal also spans ${goal.repos.slice(1).join(", ")})` : ""}, as it is on the base branch.

Read enough of the code to write a task a planner can run with: find where the change would go and what it touches. You can only read; don't try to change anything, and don't write the plan itself.

Then answer with only a JSON object:
{"title": "<an imperative title, under 70 characters>", "brief": "<Markdown: the outcome, what you found in the code that matters (name the files and functions), constraints and anything to watch out for. No Done when section here.>", "doneWhen": ["<3–6 checks, each something a builder could prove with a test, a command's output, a screenshot or a video>"]}
Keep the person's intent; where the idea is vague, choose the reading the code supports and say so in the brief.`;
}
